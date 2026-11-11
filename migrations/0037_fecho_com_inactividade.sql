-- =============================================================================
-- Fecho automático só depois de o restaurante parar (pedido do Carlos, 11/11):
-- pedidos e chamadas de dias anteriores que ficaram abertos fecham-se apenas quando
--   1) já passou das 07:10 em Maputo (Config fecho_auto_hora), e
--   2) houve um período de mais de 3 horas (Config fecho_auto_inactivo_h) sem actividade no sistema
--      (pedidos, registos, entregas, chamadas) e sem recibos no Loyverse (loja do restaurante).
-- Só se fecha o que é anterior a esse período parado. Se às 07:10 ainda houver movimento (eventos),
-- a verificação repete-se de 30 em 30 minutos até às 23:40.
-- A função menu-loyverse (accao "fecho") lê os recibos das últimas 36 horas e chama esta função.
-- =============================================================================
insert into menu_config (chave, valor, nota) values
  ('fecho_auto_hora', '07:10', 'hora (Maputo) a partir da qual pedidos e chamadas de dias anteriores podem fechar-se sozinhos'),
  ('fecho_auto_inactivo_h', '3', 'horas seguidas sem actividade no sistema e no Loyverse para o fecho automático')
on conflict (chave) do nothing;

drop function if exists menu_fechar_dias_anteriores();

create or replace function menu_fechar_dias_anteriores(p_recibos timestamptz[], p_ignorar_hora boolean default false) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare d date := menu_data_op(); v_hora time; v_h numeric; v_corte timestamptz; n1 int := 0; n2 int := 0;
begin
  if p_recibos is null then return jsonb_build_object('fechou', false, 'motivo', 'sem leitura do Loyverse'); end if;
  v_hora := coalesce(nullif(btrim(menu_cfg('fecho_auto_hora')), ''), '07:10')::time;
  if not p_ignorar_hora and (now() at time zone 'Africa/Maputo')::time < v_hora then
    return jsonb_build_object('fechou', false, 'motivo', 'antes das ' || to_char(v_hora, 'HH24:MI'));
  end if;
  v_h := greatest(1, menu_cfg_num('fecho_auto_inactivo_h', 3));
  -- linha do tempo da actividade das últimas 36 h (sistema + Loyverse) e o início do último período parado
  with act as (
    select t from (
      select t0 t from menu_pedidos where t0 > now() - interval '36 hours'
      union all select t1 from menu_pedidos where t1 > now() - interval '36 hours'
      union all select t2 from menu_pedidos where t2 > now() - interval '36 hours'
      union all select t3 from menu_pedidos where t3 > now() - interval '36 hours' and nfc <> 'auto'
      union all select c0 from menu_chamadas where c0 > now() - interval '36 hours'
      union all select c1 from menu_chamadas where c1 > now() - interval '36 hours' and nfc <> 'auto'
      union all select x from unnest(p_recibos) x where x > now() - interval '36 hours'
      union all select now()
    ) a where t is not null and t <= now()
  ), o as (select t, lag(t) over (order by t) ant from act)
  select max(ant) into v_corte from o where t - ant >= make_interval(secs => (v_h * 3600)::double precision);
  if v_corte is null then
    return jsonb_build_object('fechou', false, 'motivo', 'ainda sem ' || v_h || ' h seguidas sem actividade');
  end if;
  update menu_pedidos set t3 = now(), nfc = 'auto', estado = case when t2 is null then 'expirado' else 'entregue' end
    where data_op < d and anulado_motivo = '' and t3 is null and greatest(t0, coalesce(t1, t0), coalesce(t2, t0)) <= v_corte;
  get diagnostics n1 = row_count;
  update menu_chamadas set c1 = now(), aceite = coalesce(aceite, now()), nfc = 'auto'
    where data_op < d and c1 is null and greatest(c0, coalesce(aceite, c0)) <= v_corte;
  get diagnostics n2 = row_count;
  return jsonb_build_object('fechou', true, 'parado_desde', v_corte, 'pedidos', n1, 'chamadas', n2);
end $$;
revoke all on function menu_fechar_dias_anteriores(timestamptz[], boolean) from public, anon, authenticated;
grant execute on function menu_fechar_dias_anteriores(timestamptz[], boolean) to service_role;

create or replace function menu_ha_abertos_antigos() returns boolean language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from menu_pedidos where data_op < menu_data_op() and anulado_motivo = '' and t3 is null)
      or exists (select 1 from menu_chamadas where data_op < menu_data_op() and c1 is null);
$$;
revoke all on function menu_ha_abertos_antigos() from public, anon, authenticated;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'menu_fechar_dias';
    -- 07:10, 07:40 ... 23:40 em Maputo; só chama o Loyverse quando há pedidos ou chamadas antigos abertos
    perform cron.schedule('menu_fechar_dias', '10,40 5-21 * * *',
      $c$select fn_chamar_funcao('menu-loyverse', '{"accao":"fecho"}') where menu_ha_abertos_antigos()$c$);
  end if;
end $$;
