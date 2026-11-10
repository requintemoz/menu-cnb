-- Entrada única: identificação resumida de quem entrou (para as páginas do restaurante)
create or replace function fn_eu_resumo() returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object('id', id, 'nome', nome, 'perfil', menu_perfil, 'perfil_bilhetes', perfil) from staff where auth_user_id = auth.uid() and activo limit 1;
$$;
revoke all on function fn_eu_resumo() from public, anon; grant execute on function fn_eu_resumo() to authenticated;
