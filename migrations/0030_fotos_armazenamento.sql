-- =============================================================================
-- Fotografias do menu guardadas no Supabase (sem passar pelo Google Drive).
-- Bucket público "menu-fotos": qualquer pessoa vê as fotografias (o menu é público);
-- só os perfis fotos, supervisor e gerente enviam, e só para a pasta artigos/.
-- A página reduz cada fotografia no telemóvel e envia duas versões em JPEG:
--   artigos/<artigo>-<hora>.jpg (até 1200 px) e artigos/<artigo>-<hora>-mini.jpg (até 400 px, para as listas).
-- =============================================================================

create or replace function fn_pode_fotos() returns boolean language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from staff where auth_user_id = auth.uid() and activo and menu_perfil in ('fotos', 'supervisor', 'gerente'));
$$;
revoke all on function fn_pode_fotos() from public, anon;
grant execute on function fn_pode_fotos() to authenticated;

do $$ begin
  if to_regclass('storage.buckets') is null then return; end if; -- base local de testes (sem Storage)
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('menu-fotos', 'menu-fotos', true, 3145728, array['image/jpeg'])
    on conflict (id) do update set public = true, file_size_limit = 3145728, allowed_mime_types = array['image/jpeg'];
  execute 'drop policy if exists menu_fotos_enviar on storage.objects';
  execute 'drop policy if exists menu_fotos_ver on storage.objects';
  execute $p$create policy menu_fotos_enviar on storage.objects for insert to authenticated
    with check (bucket_id = 'menu-fotos' and name like 'artigos/%' and public.fn_pode_fotos())$p$;
  execute $p$create policy menu_fotos_ver on storage.objects for select to authenticated
    using (bucket_id = 'menu-fotos' and public.fn_pode_fotos())$p$;
end $$;
