-- =============================================================================
-- Um só telemóvel por mesa faz pedidos.
-- O primeiro telemóvel que envia um pedido com a mesa livre passa a ser o telemóvel da mesa;
-- os outros vêem o menu e chamam o garçom, mas não enviam pedidos.
-- A mesa fica livre: quando a conta é fechada (botão "Conta fechada" no balcão ou no POS do garçom, ou chamada "Conta" atendida),
-- ou ao fim de "telemovel_unico_min" minutos sem actividade desse telemóvel (pedido ou página aberta).
-- Config: telemovel_unico (sim/nao) e telemovel_unico_min (minutos, 60 por omissão).
-- =============================================================================

alter table menu_mesas add column if not exists visita_dona text;
alter table menu_mesas add column if not exists dona_desde timestamptz;
alter table menu_mesas add column if not exists dona_activa timestamptz;

insert into menu_config (chave, valor, nota) values
  ('telemovel_unico', 'sim', 'sim: só um telemóvel por mesa envia pedidos (o primeiro a pedir); nao: qualquer telemóvel'),
  ('telemovel_unico_min', '60', 'minutos sem actividade do telemóvel da mesa até outro telemóvel poder pedir')
on conflict (chave) do nothing;

create or replace function menu_telemovel_unico() returns boolean language sql stable security definer set search_path = public, extensions as $$
  select lower(coalesce(menu_cfg('telemovel_unico'), 'sim')) not in ('nao', 'não', 'no', 'false', '0');
$$;
create or replace function menu_mesa_dona_activa(m menu_mesas) returns boolean language sql stable security definer set search_path = public, extensions as $$
  select m.visita_dona is not null and m.dona_activa is not null
    and m.dona_activa > now() - make_interval(mins => greatest(5, menu_cfg_num('telemovel_unico_min', 60))::int);
$$;

create or replace function menu_enviar_pedido(p_codigo text, p_visita text, p_linhas jsonb, p_sug jsonb, p_tok text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare m menu_mesas; v_id text; v_total numeric; l jsonb; s jsonb; v_vis text := left(btrim(coalesce(p_visita, '')), 40); v_nova boolean := false;
begin
  m := menu_mesa(p_codigo);
  -- só um telemóvel por mesa faz pedidos (o primeiro a pedir com a mesa livre)
  if menu_telemovel_unico() then
    if v_vis = '' then raise exception 'Não foi possível identificar este telemóvel. Recarregue a página e tente de novo.'; end if;
    select * into m from menu_mesas where id = m.id for update;
    if menu_mesa_dona_activa(m) and m.visita_dona <> v_vis then
      raise exception 'Esta mesa já faz os pedidos noutro telemóvel. Peça a essa pessoa para pedir ou chame o garçom.';
    end if;
    v_nova := not menu_mesa_dona_activa(m) or m.visita_dona is distinct from v_vis;
    update menu_mesas set visita_dona = v_vis, dona_desde = case when v_nova then now() else dona_desde end, dona_activa = now() where id = m.id;
  end if;
  if p_linhas is null or jsonb_array_length(p_linhas) = 0 then raise exception 'Pedido vazio'; end if;
  if jsonb_array_length(p_linhas) > 60 then raise exception 'Pedido demasiado grande'; end if;
  select sum((x->>'qtd')::numeric * (x->>'preco')::numeric) into v_total from jsonb_array_elements(p_linhas) x;
  v_id := menu_novo_id('P');
  insert into menu_pedidos (id, data_op, mesa, visita, total, cliente) values (v_id, menu_data_op(), m.id, left(coalesce(p_visita, ''), 40), coalesce(v_total, 0), menu_cliente_por_token(p_tok));
  for l in select * from jsonb_array_elements(p_linhas) loop
    insert into menu_linhas (pedido, item_id, nome, categoria, qtd, preco, variante, modificadores, nota)
    values (v_id, coalesce(l->>'item', ''), left(coalesce(l->>'nome', ''), 120),
      coalesce((select categoria from menu_artigos where item_id = l->>'item'), l->>'cat', ''), greatest(1, least(99, coalesce((l->>'qtd')::numeric, 1))),
      coalesce((l->>'preco')::numeric, 0), left(coalesce(l->>'variante', ''), 80),
      left(coalesce((select string_agg(x, ', ') from jsonb_array_elements_text(case when jsonb_typeof(l->'mods') = 'array' then l->'mods' else '[]' end) x), ''), 300),
      '');
  end loop;
  for s in select * from jsonb_array_elements(coalesce(p_sug, '[]')) loop
    insert into menu_sugestoes (pedido, mesa, tipo, origem, item, aceite) values (v_id, m.id, s->>'tipo', coalesce(s->>'origem', ''), s->>'item', coalesce((s->>'aceite')::boolean, false));
  end loop;
  return jsonb_build_object('id', v_id, 't0', now(), 'telemovelNovo', v_nova);
end $$;

create or replace function menu_estado_mesa(p_codigo text, p_visita text) returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare m menu_mesas; s menu_supervisor;
begin
  m := menu_mesa(p_codigo);
  if menu_telemovel_unico() and menu_mesa_dona_activa(m) and m.visita_dona = left(btrim(coalesce(p_visita, '')), 40) and m.dona_activa < now() - interval '1 minute' then
    update menu_mesas set dona_activa = now() where id = m.id;
  end if;
  select * into s from menu_supervisor where mesa = m.id and visita = p_visita order by c0 desc limit 1;
  return jsonb_build_object('mesa', jsonb_build_object('id', m.id, 'nome', m.nome, 'zona', m.zona),
    'pedidos', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 't0', p.t0, 't1', p.t1, 't2', p.t2, 't3', p.t3, 'total', p.total, 'estado', p.estado,
        'linhas', (select coalesce(jsonb_agg(jsonb_build_object('item', l.item_id, 'nome', l.nome, 'qtd', l.qtd, 'indisponivel', l.indisponivel) order by l.id), '[]') from menu_linhas l where l.pedido = p.id)) order by p.t0), '[]')
      from menu_pedidos p where p.mesa = m.id and p.visita = p_visita and p.anulado_motivo = ''),
    'chamadas', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'motivo', c.motivo, 'c0', c.c0, 'aceite', c.aceite)), '[]') from menu_chamadas c where c.mesa = m.id and c.c1 is null),
    'supervisor', case when s.id is null then null else jsonb_build_object('id', s.id, 'c0', s.c0, 'aceite', coalesce(s.aceite::text, ''), 'c1', coalesce(s.c1::text, '')) end,
    'avaliada', exists (select 1 from menu_avaliacoes a where a.mesa = m.id and a.visita = p_visita),
    'telemovel', jsonb_build_object('unico', menu_telemovel_unico(),
      'meu', menu_telemovel_unico() and menu_mesa_dona_activa(m) and m.visita_dona = left(btrim(coalesce(p_visita, '')), 40),
      'outro', menu_telemovel_unico() and menu_mesa_dona_activa(m) and m.visita_dona <> left(btrim(coalesce(p_visita, '')), 40)));
end $$;

create or replace function menu_g_fechar_mesa(p_codigo_ou_id text, p_nfc boolean, p_apenas jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u staff; m menu_mesas; n1 int; n2 int; v_ap text[];
begin
  u := menu_requer();
  select * into m from menu_mesas where codigo = p_codigo_ou_id or id = p_codigo_ou_id limit 1;
  if m.id is null then raise exception 'Mesa não reconhecida'; end if;
  v_ap := case when p_apenas is null or jsonb_typeof(p_apenas) <> 'array' then null else array(select jsonb_array_elements_text(p_apenas)) end;
  update menu_pedidos set t3 = now(), g3 = u.id, nfc = case when p_nfc then 'sim' else 'nao' end, estado = 'entregue'
    where mesa = m.id and anulado_motivo = '' and t2 is not null and t3 is null and (v_ap is null or id = any(v_ap));
  get diagnostics n1 = row_count;
  update menu_chamadas set c1 = now(), g = coalesce(g, u.id), aceite = coalesce(aceite, now()), nfc = case when p_nfc then 'sim' else 'nao' end
    where mesa = m.id and c1 is null and (v_ap is null or id = any(v_ap));
  get diagnostics n2 = row_count;
  if exists (select 1 from menu_chamadas where mesa = m.id and motivo = 'Conta' and c1 = now()) then
    update menu_mesas set visita_dona = null, dona_desde = null, dona_activa = null where id = m.id;
  end if;
  return jsonb_build_object('mesa', m.id, 'fechados', n1 + n2);
end $$;

-- o garçom, o caixa ou o supervisor deixam outro telemóvel pedir nesta mesa
create or replace function menu_g_libertar_telemovel(p_mesa text) returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare u staff;
begin
  u := menu_requer(array['garcom', 'caixa', 'supervisor']);
  update menu_mesas set visita_dona = null, dona_desde = null, dona_activa = null where id = p_mesa or codigo = p_mesa;
  if not found then raise exception 'Mesa não reconhecida'; end if;
  return true;
end $$;

-- mesas a pedir por telemóvel (para o botão "Conta fechada" no balcão e no POS do garçom)
create or replace function menu_telemoveis_json(p_garcom uuid default null) returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select coalesce(jsonb_agg(jsonb_build_object('mesa', mm.id, 'nome', mm.nome, 'garcom', coalesce(mm.garcom::text, ''), 'desde', mm.dona_desde, 'activa', mm.dona_activa)
    order by (case when mm.nome ~ '^\d+$' then mm.nome::int else 99999 end), mm.nome), '[]')
  from menu_mesas mm where menu_telemovel_unico() and menu_mesa_dona_activa(mm) and (p_garcom is null or mm.garcom = p_garcom);
$$;
create or replace function menu_g_listar() returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare u staff;
begin
  u := menu_requer();
  return menu_pendentes_para(u.id) || jsonb_build_object('modo', case when menu_modo_central() then 'central' else 'garcom' end,
    'supervisor', case when u.menu_perfil in ('supervisor', 'gerente') then menu_sup_abertas() else '[]'::jsonb end,
    'ordemCategorias', menu_ordem_categorias(), 'user', menu_user_json(u), 'limites', menu_limites(), 'nomes', menu_nomes(),
    'minhasMesas', (select coalesce(jsonb_agg(id order by id), '[]') from menu_mesas where garcom = u.id),
    'mesas', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'zona', zona, 'codigo', codigo)), '[]') from menu_mesas where activa), 'agora', now(),
    'telemoveis', menu_telemoveis_json(case when u.menu_perfil in ('supervisor', 'gerente') then null else u.id end));
end $$;

create or replace function menu_b_estado() returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare u staff;
begin
  u := menu_requer(array['caixa', 'supervisor', 'garcom', 'registo']);
  return jsonb_build_object('user', menu_user_json(u), 'limites', menu_limites(),
    'mesas', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'zona', zona, 'garcom', coalesce(garcom::text, '')) order by (case when nome ~ '^\d+$' then nome::int else 99999 end), nome), '[]') from menu_mesas where activa),
    'emTurno', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'nome', s.nome, 'entrada', t.entrada, 'turnoId', t.id, 'perfil', s.menu_perfil) order by s.nome), '[]')
      from menu_turnos t join staff s on s.id = t.staff_id where t.saida is null),
    'nomes', menu_nomes(),
    'pedidos', (select coalesce(jsonb_agg(menu_pedido_json(p, false) || jsonb_build_object('n', (select coalesce(sum(qtd), 0) from menu_linhas where pedido = p.id)) order by p.t0), '[]')
      from menu_pedidos p where p.anulado_motivo = '' and p.t3 is null),
    'chamadas', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'mesa', mesa, 'motivo', motivo, 'c0', c0, 'aceite', aceite, 'g', g) order by c0), '[]') from menu_chamadas where c1 is null),
    'agora', now(), 'relatorio', menu_relatorio(menu_data_op()), 'fid', menu_fid_balcao(), 'telemoveis', menu_telemoveis_json(null));
end $$;

revoke all on function menu_telemoveis_json(uuid) from public, anon, authenticated;
revoke all on function menu_telemovel_unico() from public, anon, authenticated;
revoke all on function menu_mesa_dona_activa(menu_mesas) from public, anon, authenticated;
revoke all on function menu_g_libertar_telemovel(text) from public, anon, authenticated;

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
    when 'gLibertarTelemovel' then to_jsonb(menu_g_libertar_telemovel(a->>1))
    when 'fotosListar' then menu_fotos_lista()
    when 'fotoGuardar' then menu_foto_guardar(a->>1, a->>2)
    else null end;
  if r is null and p_fn not in ('fidCartao', 'mesaPorCodigo') then
    if p_fn not in ('menuPublico','enviarPedido','chamarGarcom','estadoMesaCliente','fidRegistar','fidConta','fidAvaliar','fidChamarSupervisor','listarNomes','logout','gListar','gAbrirPedido','gRegistado','gIndisponivel','gAceitarChamada','gFecharMesa','gPassar','gAnular','gColegas','bEstado','bAtribuir','bAtribuirLote','bVouRegistar','bRegistadoCaixa','bTurno','bListarUtilizadores','corrigirTurno','fecharTurnoGeral','relatorioPeriodo','exportarRelatorio','gestaoDados','gestaoGuardar','gestaoGerarCodigos','rFila','rAssumir','rLargar','rRegistado','fidSupAceitar','fidSupResolver','fidEntregarBrinde','fidProcurar','fidGestao','fidMensagemEnviada','fotosListar','fotoGuardar','gLibertarTelemovel') then
      raise exception 'Função não permitida: %', p_fn;
    end if;
  end if;
  return coalesce(r, 'null'::jsonb);
end $$;
