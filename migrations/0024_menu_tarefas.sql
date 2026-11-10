-- =============================================================================
-- Menu digital CNB: tarefas periódicas (só no Supabase; usa fn_chamar_funcao da migração 0004 dos bilhetes)
-- Antes: publicar a função menu-loyverse e guardar o segredo LOYVERSE_TOKEN.
-- =============================================================================
create or replace function fn_menu_perfil() returns text language sql stable security definer set search_path = public, extensions as $$
  select menu_perfil from staff where auth_user_id = auth.uid() and activo limit 1;
$$;
revoke all on function fn_menu_perfil() from public, anon; grant execute on function fn_menu_perfil() to authenticated;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname in ('menu_sincronizar', 'menu_cruzamento');
    perform cron.schedule('menu_sincronizar', '*/10 * * * *', $c$select fn_chamar_funcao('menu-loyverse', '{"accao":"sincronizar"}')$c$);
    perform cron.schedule('menu_cruzamento', '45 21 * * *', $c$select fn_chamar_funcao('menu-loyverse', '{"accao":"cruzar"}')$c$); -- 23:45 em Maputo
  end if;
end $$;
