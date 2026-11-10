-- =============================================================================
-- Gestão da equipa na página de Gestão (só o gerente): ver, criar, mudar perfil e PIN,
-- desactivar e reactivar, desbloquear o PIN. Fica um histórico de cada alteração.
-- A equipa é a mesma dos bilhetes (tabela staff); o perfil dos bilhetes só se mostra.
-- =============================================================================

create table if not exists menu_equipa_historico (
  id bigserial primary key,
  quando timestamptz not null default now(),
  por uuid references staff(id) on delete set null,
  alvo uuid not null references staff(id) on delete cascade,
  accao text not null
);
create index if not exists menu_equipa_historico_alvo on menu_equipa_historico (alvo, quando desc);
alter table menu_equipa_historico enable row level security;
revoke all on menu_equipa_historico from anon, authenticated;

create or replace function menu_perfil_nome(p text) returns text language sql immutable as $$
  select case p when 'garcom' then 'Garçom' when 'caixa' then 'Caixa' when 'registo' then 'Registo' when 'supervisor' then 'Supervisor'
    when 'gerente' then 'Gerente' when 'fotos' then 'Fotografias' else 'Sem acesso ao restaurante' end;
$$;

create or replace function menu_equipa_lista() returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare u staff;
begin
  u := menu_requer(array['gerente']);
  return jsonb_build_object('eu', u.id, 'equipa', (select coalesce(jsonb_agg(jsonb_build_object(
      'id', s.id, 'nome', s.nome, 'perfil', coalesce(s.menu_perfil, ''), 'bilhetes', coalesce(s.perfil::text, ''), 'activo', s.activo,
      'temPin', s.pin_hash is not null, 'email', coalesce(s.email::text, ''), 'ultimaEntrada', s.ultima_entrada,
      'bloqueadoAte', case when s.pin_bloqueado_ate > now() then s.pin_bloqueado_ate end, 'falhas', s.pin_falhas,
      'historico', (select coalesce(jsonb_agg(jsonb_build_object('quando', h.quando, 'por', coalesce(menu_nome(h.por), ''), 'accao', h.accao) order by h.quando desc), '[]')
                    from (select * from menu_equipa_historico where alvo = s.id order by quando desc limit 6) h))
    order by s.activo desc, lower(s.nome)), '[]') from staff s));
end $$;

-- criar (sem id) ou alterar (com id): {id, nome, perfil, pin, activo}. PIN vazio = mantém.
create or replace function menu_equipa_guardar(p jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u staff; s staff; v_id uuid; v_nome text; v_perfil text; v_pin text; v_activo boolean; mud text[] := '{}';
begin
  u := menu_requer(array['gerente']);
  v_id := nullif(btrim(coalesce(p->>'id', '')), '')::uuid;
  v_nome := regexp_replace(btrim(coalesce(p->>'nome', '')), '\s+', ' ', 'g');
  v_perfil := nullif(btrim(coalesce(p->>'perfil', '')), '');
  v_pin := btrim(coalesce(p->>'pin', ''));
  v_activo := coalesce((p->>'activo')::boolean, true);
  if length(v_nome) < 2 or length(v_nome) > 40 then raise exception 'Escreva o nome (2 a 40 letras).'; end if;
  if v_perfil is not null and v_perfil not in ('garcom', 'caixa', 'registo', 'supervisor', 'gerente', 'fotos') then raise exception 'Perfil desconhecido.'; end if;
  if v_pin <> '' and v_pin !~ '^\d{4,6}$' then raise exception 'O PIN tem de ter 4 a 6 algarismos.'; end if;
  -- PIN único na equipa (é o mesmo do Loyverse e a porta dos eventos identifica só pelo PIN)
  if v_pin <> '' and exists (select 1 from staff where activo and pin_hash is not null and id is distinct from v_id and pin_hash = crypt(v_pin, pin_hash)) then
    raise exception 'Este PIN já é usado por outra pessoa da equipa. Escolha outro.';
  end if;

  if v_id is null then
    if v_perfil is null then raise exception 'Escolha o perfil da pessoa.'; end if;
    if v_pin = '' then raise exception 'Escolha um PIN para a pessoa nova.'; end if;
    begin
      insert into staff (nome, menu_perfil, activo, pin_hash) values (v_nome, v_perfil, true, crypt(v_pin, gen_salt('bf'))) returning * into s;
    exception when unique_violation then
      raise exception 'Já existe uma pessoa activa com o nome %. Acrescente o apelido.', v_nome;
    end;
    insert into menu_equipa_historico (por, alvo, accao) values (u.id, s.id, 'Criada com o perfil ' || menu_perfil_nome(v_perfil));
    return jsonb_build_object('id', s.id, 'criada', true);
  end if;

  select * into s from staff where id = v_id for update;
  if s.id is null then raise exception 'Pessoa não encontrada.'; end if;
  if s.id = u.id and (not v_activo or v_perfil is distinct from 'gerente') then
    raise exception 'Não pode tirar a si próprio o perfil de gerente nem desactivar a sua conta.';
  end if;
  if v_activo and s.menu_perfil is null and v_perfil is null and s.perfil is null then raise exception 'Escolha o perfil da pessoa.'; end if;
  if s.nome <> v_nome then mud := mud || ('Nome: ' || s.nome || ' para ' || v_nome); end if;
  if s.menu_perfil is distinct from v_perfil then mud := mud || ('Perfil: ' || menu_perfil_nome(s.menu_perfil) || ' para ' || menu_perfil_nome(v_perfil)); end if;
  if v_pin <> '' then mud := mud || 'PIN alterado'::text; end if;
  if s.activo <> v_activo then mud := mud || (case when v_activo then 'Reactivada' else 'Desactivada' end); end if;
  if cardinality(mud) = 0 then return jsonb_build_object('id', s.id, 'semAlteracoes', true); end if;
  begin
    update staff set nome = v_nome, menu_perfil = v_perfil, activo = v_activo,
      pin_hash = case when v_pin <> '' then crypt(v_pin, gen_salt('bf')) else pin_hash end,
      pin_falhas = case when v_pin <> '' then 0 else pin_falhas end,
      pin_bloqueado_ate = case when v_pin <> '' then null else pin_bloqueado_ate end
    where id = s.id;
  exception when unique_violation then
    raise exception 'Já existe uma pessoa activa com o nome %. Acrescente o apelido.', v_nome;
  end;
  -- quem sai ou deixa de ter perfil do restaurante sai do turno
  if not v_activo or v_perfil is null or v_perfil = 'fotos' then perform menu_sair_turno(s.id); end if;
  insert into menu_equipa_historico (por, alvo, accao) values (u.id, s.id, array_to_string(mud, '; '));
  return jsonb_build_object('id', s.id);
end $$;

create or replace function menu_equipa_desbloquear(p_id uuid) returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare u staff;
begin
  u := menu_requer(array['gerente']);
  update staff set pin_falhas = 0, pin_bloqueado_ate = null where id = p_id;
  if not found then raise exception 'Pessoa não encontrada.'; end if;
  insert into menu_equipa_historico (por, alvo, accao) values (u.id, p_id, 'PIN desbloqueado');
  return true;
end $$;

revoke all on function menu_perfil_nome(text) from public, anon, authenticated;
revoke all on function menu_equipa_lista() from public, anon, authenticated;
revoke all on function menu_equipa_guardar(jsonb) from public, anon, authenticated;
revoke all on function menu_equipa_desbloquear(uuid) from public, anon, authenticated;

-- menu_api com as funções da equipa
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
    when 'equipaListar' then menu_equipa_lista()
    when 'equipaGuardar' then menu_equipa_guardar(a->1)
    when 'equipaDesbloquear' then to_jsonb(menu_equipa_desbloquear((a->>1)::uuid))
    when 'fotosListar' then menu_fotos_lista()
    when 'fotoGuardar' then menu_foto_guardar(a->>1, a->>2)
    else null end;
  if r is null and p_fn not in ('fidCartao', 'mesaPorCodigo') then
    if p_fn not in ('menuPublico','enviarPedido','chamarGarcom','estadoMesaCliente','fidRegistar','fidConta','fidAvaliar','fidChamarSupervisor','listarNomes','logout','gListar','gAbrirPedido','gRegistado','gIndisponivel','gAceitarChamada','gFecharMesa','gPassar','gAnular','gColegas','bEstado','bAtribuir','bAtribuirLote','bVouRegistar','bRegistadoCaixa','bTurno','bListarUtilizadores','corrigirTurno','fecharTurnoGeral','relatorioPeriodo','exportarRelatorio','gestaoDados','gestaoGuardar','gestaoGerarCodigos','rFila','rAssumir','rLargar','rRegistado','fidSupAceitar','fidSupResolver','fidEntregarBrinde','fidProcurar','fidGestao','fidMensagemEnviada','fotosListar','fotoGuardar','gLibertarTelemovel','equipaListar','equipaGuardar','equipaDesbloquear') then
      raise exception 'Função não permitida: %', p_fn;
    end if;
  end if;
  return coalesce(r, 'null'::jsonb);
end $$;
