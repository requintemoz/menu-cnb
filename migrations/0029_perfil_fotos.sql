-- =============================================================================
-- Perfil "fotos": uma pessoa que só põe os links das fotografias dos artigos do menu.
-- Entra pela página única (nome + PIN) e vai directa para fotos.html. Não entra em turno,
-- não aparece nas listas de garçons e não vê pedidos, chamadas nem clientes.
-- =============================================================================

-- 1) novo perfil permitido
do $$ declare c record; begin
  for c in select conname from pg_constraint where conrelid = 'staff'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%menu_perfil%' loop
    execute format('alter table staff drop constraint %I', c.conname);
  end loop;
end $$;
alter table staff add constraint staff_menu_perfil_check check (menu_perfil in ('garcom', 'caixa', 'registo', 'supervisor', 'gerente', 'fotos'));

-- 2) quem pôs cada fotografia e quando
alter table menu_extra add column if not exists foto_por uuid references staff(id) on delete set null;
alter table menu_extra add column if not exists foto_em timestamptz;

-- 3) o perfil "fotos" só passa onde for pedido expressamente (as funções sem lista de perfis ficam só para a sala)
create or replace function menu_requer(p_perfis text[] default null) returns staff
language plpgsql stable security definer set search_path = public, extensions as $$
declare s staff;
begin
  s := fn_eu();
  if s.id is null then raise exception 'Sessão expirada. Entre de novo com o PIN.' using errcode = '42501'; end if;
  if s.menu_perfil is null then raise exception 'Sem acesso às páginas do restaurante' using errcode = '42501'; end if;
  if s.menu_perfil = 'fotos' and (p_perfis is null or not ('fotos' = any(p_perfis))) then raise exception 'Sem permissão' using errcode = '42501'; end if;
  if p_perfis is not null and not (s.menu_perfil = any(p_perfis)) and s.menu_perfil <> 'gerente' then
    raise exception 'Sem permissão' using errcode = '42501';
  end if;
  return s;
end $$;

-- leitura em tempo real (pedidos, chamadas, mesas...) só para a sala
create or replace function fn_e_equipa_menu() returns boolean language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from staff where auth_user_id = auth.uid() and activo and menu_perfil is not null and menu_perfil <> 'fotos');
$$;

-- não entra em turno
create or replace function fn_entrada_turno() returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare s staff;
begin s := fn_eu(); if s.id is null or s.menu_perfil is null or s.menu_perfil = 'fotos' then return false; end if; perform menu_entrar_turno(s.id); return true; end $$;

-- não aparece no balcão
create or replace function menu_b_utilizadores() returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform menu_requer(array['caixa', 'supervisor']);
  return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'perfil', menu_perfil) order by nome), '[]') from staff where activo and menu_perfil is not null and menu_perfil <> 'fotos');
end $$;

-- 4) lista dos artigos do menu (com secção), pela ordem do menu
create or replace function menu_fotos_lista() returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform menu_requer(array['fotos', 'supervisor']);
  return (select coalesce(jsonb_agg(jsonb_build_object('id', e.item_id, 'nome', coalesce(nullif(a.nome, ''), e.nome), 'seccao', btrim(e.seccao), 'preco', a.preco,
      'foto', e.foto_url, 'noMenu', a.activo and not e.oculto, 'por', coalesce(menu_nome(e.foto_por), ''), 'em', e.foto_em)
      order by coalesce(so.ord, 9999), btrim(e.seccao), coalesce(e.ordem, 9999), coalesce(nullif(a.nome, ''), e.nome)), '[]')
    from menu_extra e join menu_artigos a on a.item_id = e.item_id
    left join (select btrim(seccao) sec, min(coalesce(ordem, 9999)) ord from menu_extra where btrim(seccao) <> '' group by btrim(seccao)) so on so.sec = btrim(e.seccao)
    where btrim(e.seccao) <> '');
end $$;

-- 5) guardar (ou apagar, com link vazio) a fotografia de um artigo
create or replace function menu_foto_guardar(p_item text, p_url text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u staff; v text := btrim(coalesce(p_url, ''));
begin
  u := menu_requer(array['fotos', 'supervisor']);
  if v <> '' and (v !~* '^https://\S+$' or length(v) > 1000) then raise exception 'O link tem de começar por https:// e não pode ter espaços.'; end if;
  update menu_extra set foto_url = v, foto_por = u.id, foto_em = now() where item_id = p_item and btrim(seccao) <> '';
  if not found then raise exception 'Artigo não encontrado no menu.'; end if;
  return jsonb_build_object('id', p_item, 'foto', v, 'por', u.nome, 'em', now());
end $$;
revoke all on function menu_fotos_lista() from public, anon, authenticated;
revoke all on function menu_foto_guardar(text, text) from public, anon, authenticated;

-- 6) página "Fotografias do menu" na entrada única
create or replace function fn_meus_acessos() returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare s staff; v jsonb := '[]'; v_mesas boolean := false;
begin
  s := fn_eu(); if s.id is null then return null; end if;
  if s.menu_perfil = 'garcom' then v := v || '[{"id":"garcom","titulo":"Pedidos e chamadas","texto":"Telemóvel POS do garçom","url":"/menu-cnb/garcom.html"}]'; end if;
  if s.menu_perfil in ('caixa', 'supervisor', 'gerente') then v := v || '[{"id":"balcao","titulo":"Balcão","texto":"Mapa de mesas, contas e chamadas","url":"/menu-cnb/balcao.html"}]'; end if;
  if s.menu_perfil in ('registo', 'caixa', 'supervisor', 'gerente') then v := v || '[{"id":"registo","titulo":"Registo de pedidos","texto":"Lançar no Loyverse e atribuir ao garçom","url":"/menu-cnb/registo.html"}]'; end if;
  if s.menu_perfil in ('supervisor', 'gerente') then v := v || '[{"id":"garcom","titulo":"POS de sala","texto":"Vista do garçom, com as chamadas ao supervisor","url":"/menu-cnb/garcom.html"},{"id":"gestao","titulo":"Gestão do restaurante","texto":"Menu, mesas, relatórios e Cartão Requinte","url":"/menu-cnb/gestao.html"}]'; end if;
  if s.menu_perfil in ('fotos', 'supervisor', 'gerente') then v := v || '[{"id":"fotos","titulo":"Fotografias do menu","texto":"Pôr e rever as fotografias dos artigos","url":"/menu-cnb/fotos.html"}]'; end if;
  if s.perfil is not null and s.perfil in ('admin', 'vendedor', 'comunicacao') then v := v || '[{"id":"bilhetes","titulo":"Bilhetes de eventos","texto":"Vendas, convites, clientes e campanhas","url":"/bilhetes/admin/"}]'; end if;
  if s.perfil is not null and s.perfil in ('admin', 'porta') then v := v || '[{"id":"porta","titulo":"Porta do evento","texto":"Validar bilhetes e pulseiras","url":"/bilhetes/porta/"}]'; end if;
  begin
    execute 'select exists (select 1 from mesas_utilizadores where lower(email) = lower($1))' into v_mesas using coalesce(s.email::text, '');
  exception when undefined_table then v_mesas := false; end;
  if v_mesas then v := v || '[{"id":"mesas","titulo":"Mesas do evento","texto":"Planta, grupos e alocação","url":"/bilhetes/mesas/"}]'; end if;
  return jsonb_build_object('nome', s.nome, 'menu_perfil', s.menu_perfil, 'acessos', (select coalesce(jsonb_agg(distinct_x), '[]') from (select distinct on (x->>'id') x distinct_x from jsonb_array_elements(v) with ordinality t(x, o) order by x->>'id', o) z));
end $$;

-- 7) menu_api com as duas funções novas
create or replace function menu_api(p_fn text, p_args jsonb default '[]') returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a jsonb := coalesce(p_args, '[]'); r jsonb;
begin
  r := case p_fn
    -- cliente (sem sessão)
    when 'menuPublico' then menu_publico()
    when 'mesaPorCodigo' then (select jsonb_build_object('id', m.id, 'nome', m.nome, 'zona', m.zona) from menu_mesa(a->>0) m)
    when 'enviarPedido' then menu_enviar_pedido(a->>0, a->>1, a->2, a->3, a->>4)
    when 'chamarGarcom' then menu_chamar_garcom(a->>0, a->>1, a->>2)
    when 'estadoMesaCliente' then menu_estado_mesa(a->>0, a->>1)
    when 'fidRegistar' then menu_fid_registar(a->0, a->>1, a->>2)
    when 'fidCartao' then menu_fid_cartao(a->>0)
    when 'fidConta' then menu_fid_conta(a->>0, a->>1, a->>2, a->>3)
    when 'fidAvaliar' then to_jsonb(menu_fid_avaliar(a->>0, a->>1, a->2))
    when 'fidChamarSupervisor' then menu_fid_chamar_supervisor(a->>0, a->>1, a->>2, a->>3)
    when 'listarNomes' then fn_entrada_nomes()
    -- equipa (o 1.º argumento era o token)
    when 'logout' then (select to_jsonb(true) from (select menu_sair_turno((fn_eu()).id)) x)
    when 'gListar' then menu_g_listar()
    when 'gAbrirPedido' then to_jsonb(menu_g_abrir(a->>1))
    when 'gRegistado' then to_jsonb(menu_g_registado(a->>1))
    when 'gIndisponivel' then to_jsonb(menu_g_indisponivel(a->>1, (a->>2)::bigint))
    when 'gAceitarChamada' then to_jsonb(menu_g_aceitar_chamada(a->>1))
    when 'gFecharMesa' then menu_g_fechar_mesa(a->>1, coalesce((a->>2)::boolean, false), a->3)
    when 'gPassar' then to_jsonb(menu_g_passar(a->>1, a->>2, (a->>3)::uuid))
    when 'gAnular' then to_jsonb(menu_g_anular(a->>1, a->>2, a->>3))
    when 'gColegas' then menu_g_colegas()
    when 'bEstado' then menu_b_estado()
    when 'bAtribuir' then to_jsonb(menu_b_atribuir(a->1, a->>2))
    when 'bAtribuirLote' then to_jsonb(menu_b_atribuir_lote(a->1))
    when 'bVouRegistar' then to_jsonb(menu_b_vou_registar(a->>1))
    when 'bRegistadoCaixa' then to_jsonb(menu_b_registado_caixa(a->>1))
    when 'bTurno' then to_jsonb(menu_b_turno((a->>1)::uuid, a->>2))
    when 'bListarUtilizadores' then menu_b_utilizadores()
    when 'corrigirTurno' then to_jsonb(menu_corrigir_turno(a->>1, nullif(a->>2, '')::timestamptz, nullif(a->>3, '')::timestamptz, a->>4))
    when 'fecharTurnoGeral' then to_jsonb(menu_fechar_turno_geral())
    when 'relatorioPeriodo' then (select menu_relatorio((a->>1)::date, (a->>2)::date) from (select menu_requer(array['supervisor'])) x)
    when 'exportarRelatorio' then menu_exportar((a->>1)::date, (a->>2)::date)
    when 'gestaoDados' then menu_gestao_dados()
    when 'gestaoGuardar' then to_jsonb(menu_gestao_guardar(a->>1, a->>2, a->3))
    when 'gestaoGerarCodigos' then menu_gestao_gerar_codigos()
    when 'rFila' then menu_r_fila()
    when 'rAssumir' then to_jsonb(menu_r_assumir(a->>1))
    when 'rLargar' then to_jsonb(menu_r_largar(a->>1))
    when 'rRegistado' then menu_r_registado(a->>1, a->>2, (a->>3)::int)
    when 'fidSupAceitar' then to_jsonb(menu_fid_sup_aceitar(a->>1))
    when 'fidSupResolver' then to_jsonb(menu_fid_sup_resolver(a->>1, a->>2))
    when 'fidEntregarBrinde' then menu_fid_entregar((a->>1)::uuid, a->>2, a->>3)
    when 'fidProcurar' then menu_fid_procurar(a->>1)
    when 'fidGestao' then menu_fid_gestao()
    when 'fidMensagemEnviada' then to_jsonb(menu_fid_mensagem((a->>1)::uuid, a->>2))
    when 'fotosListar' then menu_fotos_lista()
    when 'fotoGuardar' then menu_foto_guardar(a->>1, a->>2)
    else null end;
  if r is null and p_fn not in ('fidCartao', 'mesaPorCodigo') then
    if p_fn not in ('menuPublico','enviarPedido','chamarGarcom','estadoMesaCliente','fidRegistar','fidConta','fidAvaliar','fidChamarSupervisor','listarNomes','logout','gListar','gAbrirPedido','gRegistado','gIndisponivel','gAceitarChamada','gFecharMesa','gPassar','gAnular','gColegas','bEstado','bAtribuir','bAtribuirLote','bVouRegistar','bRegistadoCaixa','bTurno','bListarUtilizadores','corrigirTurno','fecharTurnoGeral','relatorioPeriodo','exportarRelatorio','gestaoDados','gestaoGuardar','gestaoGerarCodigos','rFila','rAssumir','rLargar','rRegistado','fidSupAceitar','fidSupResolver','fidEntregarBrinde','fidProcurar','fidGestao','fidMensagemEnviada','fotosListar','fotoGuardar') then
      raise exception 'Função não permitida: %', p_fn;
    end if;
  end if;
  return coalesce(r, 'null'::jsonb);
end $$;
