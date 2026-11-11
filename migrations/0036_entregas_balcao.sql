-- =============================================================================
-- Pedidos registados no POS mas não marcados como entregues ficavam no mapa do balcão como pendentes,
-- sem aparecer em nenhuma lista e sem forma de os limpar.
-- 1) O caixa (ou o supervisor) marca "Entregue" na nova lista "Registados, por entregar" (nfc = 'balcao').
-- 2) Às 06:10 de Maputo (o dia operacional começa às 06:00), pedidos e chamadas de dias anteriores que
--    ficaram abertos fecham-se sozinhos (nfc = 'auto'; não contam para nenhum garçom).
-- =============================================================================
create or replace function menu_b_entregar_pedidos(p_ids jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u staff; v_ids text[]; n int;
begin
  u := menu_requer(array['caixa', 'supervisor']);
  if p_ids is null or jsonb_typeof(p_ids) <> 'array' or jsonb_array_length(p_ids) = 0 then raise exception 'Nenhum pedido escolhido.'; end if;
  v_ids := array(select jsonb_array_elements_text(p_ids));
  update menu_pedidos set t3 = now(), nfc = 'balcao', estado = 'entregue'
    where id = any(v_ids) and anulado_motivo = '' and t2 is not null and t3 is null;
  get diagnostics n = row_count;
  return jsonb_build_object('entregues', n);
end $$;
revoke all on function menu_b_entregar_pedidos(jsonb) from public, anon, authenticated;

create or replace function menu_fechar_dias_anteriores() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare d date := menu_data_op(); n1 int; n2 int;
begin
  update menu_pedidos set t3 = now(), nfc = 'auto', estado = case when t2 is null then 'expirado' else 'entregue' end
    where data_op < d and anulado_motivo = '' and t3 is null;
  get diagnostics n1 = row_count;
  update menu_chamadas set c1 = now(), aceite = coalesce(aceite, now()), nfc = 'auto' where data_op < d and c1 is null;
  get diagnostics n2 = row_count;
  return jsonb_build_object('pedidos', n1, 'chamadas', n2);
end $$;
revoke all on function menu_fechar_dias_anteriores() from public, anon, authenticated;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'menu_fechar_dias';
    perform cron.schedule('menu_fechar_dias', '10 4 * * *', $c$select menu_fechar_dias_anteriores()$c$); -- 06:10 em Maputo
  end if;
end $$;

-- menu_api com a entrega pelo balcão
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
    when 'bFecharChamadas' then menu_b_fechar_chamadas(a->1)
    when 'bEntregarPedidos' then menu_b_entregar_pedidos(a->1)
    when 'equipaListar' then menu_equipa_lista()
    when 'equipaGuardar' then menu_equipa_guardar(a->1)
    when 'equipaDesbloquear' then to_jsonb(menu_equipa_desbloquear((a->>1)::uuid))
    when 'fotosListar' then menu_fotos_lista()
    when 'fotoGuardar' then menu_foto_guardar(a->>1, a->>2)
    else null end;
  if r is null and p_fn not in ('fidCartao', 'mesaPorCodigo') then
    if p_fn not in ('menuPublico','enviarPedido','chamarGarcom','estadoMesaCliente','fidRegistar','fidConta','fidAvaliar','fidChamarSupervisor','listarNomes','logout','gListar','gAbrirPedido','gRegistado','gIndisponivel','gAceitarChamada','gFecharMesa','gPassar','gAnular','gColegas','bEstado','bAtribuir','bAtribuirLote','bVouRegistar','bRegistadoCaixa','bTurno','bListarUtilizadores','corrigirTurno','fecharTurnoGeral','relatorioPeriodo','exportarRelatorio','gestaoDados','gestaoGuardar','gestaoGerarCodigos','rFila','rAssumir','rLargar','rRegistado','fidSupAceitar','fidSupResolver','fidEntregarBrinde','fidProcurar','fidGestao','fidMensagemEnviada','fotosListar','fotoGuardar','gLibertarTelemovel','equipaListar','equipaGuardar','equipaDesbloquear','bFecharChamadas','bEntregarPedidos') then
      raise exception 'Função não permitida: %', p_fn;
    end if;
  end if;
  return coalesce(r, 'null'::jsonb);
end $$;
