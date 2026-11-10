-- =============================================================================
-- Pagamento no Loyverse liberta a mesa (telemóvel único, migração 0032).
-- De 2 em 2 minutos, só quando há mesas a pedir pelo telemóvel, a função menu-loyverse (accao "pagamentos")
-- procura nos recibos do Loyverse um pagamento com o ticket da mesa ("Mesa N") feito depois de o telemóvel
-- ter ficado com a mesa, e liberta-a para o cliente seguinte.
-- =============================================================================

alter table menu_mesas add column if not exists pago_recibo text;
alter table menu_mesas add column if not exists pago_em timestamptz;

create or replace function menu_pagamento_libertar(p_mesa text, p_pago timestamptz, p_recibo text) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
begin
  update menu_mesas set visita_dona = null, dona_desde = null, dona_activa = null, pago_recibo = left(coalesce(p_recibo, ''), 40), pago_em = p_pago
    where id = p_mesa and visita_dona is not null and dona_desde <= p_pago;
  return found;
end $$;
revoke all on function menu_pagamento_libertar(text, timestamptz, text) from public, anon, authenticated;
grant execute on function menu_pagamento_libertar(text, timestamptz, text) to service_role;
grant execute on function menu_telemoveis_json(uuid) to service_role;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'menu_pagamentos';
    perform cron.schedule('menu_pagamentos', '*/2 * * * *',
      $c$select fn_chamar_funcao('menu-loyverse', '{"accao":"pagamentos"}') where menu_telemoveis_json(null) <> '[]'::jsonb$c$);
  end if;
end $$;
