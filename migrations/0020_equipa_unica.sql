-- =============================================================================
-- Equipa única para todos os sistemas do CNB (bilhetes, mesas de eventos, menu digital)
-- e entrada única: um endereço, nome + PIN ou email + palavra-passe, encaminha cada pessoa
-- para as páginas a que tem acesso.
-- Corre depois das migrações 0001 a 0007 do sistema de bilhetes (usa a tabela staff).
-- =============================================================================

-- Perfil no restaurante (menu digital). Nulo = sem acesso às páginas do restaurante.
alter table staff add column if not exists menu_perfil text check (menu_perfil in ('garcom', 'caixa', 'registo', 'supervisor', 'gerente'));
alter table staff add column if not exists loyverse_employee_id text;
alter table staff add column if not exists pin_falhas int not null default 0;
alter table staff add column if not exists pin_bloqueado_ate timestamptz;
alter table staff add column if not exists ultima_entrada timestamptz;
-- perfil dos bilhetes passa a ser opcional: há pessoas só do restaurante
alter table staff alter column perfil drop not null;
alter table staff alter column perfil drop default;
create unique index if not exists staff_nome_activo_unq on staff (lower(nome)) where activo;

-- Membro da equipa da sessão (qualquer sistema)
create or replace function fn_eu() returns staff
language sql stable security definer set search_path = public, extensions as $$
  select * from staff where auth_user_id = auth.uid() and activo limit 1;
$$;

-- Exige um perfil do restaurante; devolve a ficha. 'gerente' passa sempre.
create or replace function menu_requer(p_perfis text[] default null) returns staff
language plpgsql stable security definer set search_path = public, extensions as $$
declare s staff;
begin
  s := fn_eu();
  if s.id is null then raise exception 'Sessão expirada. Entre de novo com o PIN.' using errcode = '42501'; end if;
  if s.menu_perfil is null then raise exception 'Sem acesso às páginas do restaurante' using errcode = '42501'; end if;
  if p_perfis is not null and not (s.menu_perfil = any(p_perfis)) and s.menu_perfil <> 'gerente' then
    raise exception 'Sem permissão' using errcode = '42501';
  end if;
  return s;
end $$;

-- Nomes para a lista da página de entrada (sem dados sensíveis)
create or replace function fn_entrada_nomes() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(jsonb_agg(jsonb_build_object('nome', nome) order by nome), '[]')
  from staff where activo and pin_hash is not null;
$$;

-- Verificação do PIN, só para a função "entrar" (chave de serviço). Bloqueia 15 min ao fim de 5 falhas.
create or replace function fn_entrada_verificar(p_nome text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare s staff;
begin
  select * into s from staff where activo and lower(nome) = lower(trim(p_nome)) limit 1;
  if s.id is null or s.pin_hash is null then return jsonb_build_object('ok', false, 'erro', 'Nome ou PIN incorrecto'); end if;
  if s.pin_bloqueado_ate is not null and s.pin_bloqueado_ate > now() then
    return jsonb_build_object('ok', false, 'erro', 'Demasiadas tentativas. Tente de novo dentro de ' || greatest(1, ceil(extract(epoch from s.pin_bloqueado_ate - now()) / 60))::int || ' min.');
  end if;
  if s.pin_hash <> crypt(coalesce(p_pin, ''), s.pin_hash) then
    update staff set pin_falhas = pin_falhas + 1,
      pin_bloqueado_ate = case when pin_falhas + 1 >= 5 then now() + interval '15 minutes' else pin_bloqueado_ate end where id = s.id;
    return jsonb_build_object('ok', false, 'erro', 'Nome ou PIN incorrecto');
  end if;
  update staff set pin_falhas = 0, pin_bloqueado_ate = null, ultima_entrada = now() where id = s.id;
  return jsonb_build_object('ok', true, 'id', s.id, 'nome', s.nome, 'email', s.email, 'auth_user_id', s.auth_user_id, 'menu_perfil', s.menu_perfil);
end $$;

-- -----------------------------------------------------------------------------
-- Segurança do sistema de bilhetes com a equipa do restaurante no mesmo projecto
-- -----------------------------------------------------------------------------
-- 1) fn_exigir_perfil deixava passar quem não tem perfil de bilhetes (perfil nulo): NULL não é "falso" no IF.
create or replace function fn_exigir_perfil(variadic p_perfis perfil_staff[]) returns staff
language plpgsql stable security definer set search_path = public, extensions as $$
declare s staff;
begin
  s := fn_staff_actual();
  if s.id is null then raise exception 'Sessão sem utilizador da equipa' using errcode = '42501'; end if;
  if s.perfil is null or (not (s.perfil = any(p_perfis)) and s.perfil <> 'admin') then
    raise exception 'Perfil % não autorizado para esta operação', coalesce(s.perfil::text, 'sem perfil de bilhetes') using errcode = '42501';
  end if;
  return s;
end $$;
-- 2) tabelas dos bilhetes que qualquer conta autenticada podia ler: passam a exigir perfil de bilhetes
--    (as contas do restaurante, entradas pelo PIN, deixam de ver eventos, preços, códigos promocionais e definições)
do $$ declare p record; begin
  for p in select * from (values ('definicoes', 'definicoes_ler'), ('eventos', 'eventos_ler'), ('tipos_bilhete', 'tipos_ler'), ('lotes_preco', 'lotes_ler'),
                                 ('codigos_promo', 'promo_ler'), ('quotas_convites', 'quotas_ler')) v(t, pol) loop
    if to_regclass(p.t) is not null then
      execute format('drop policy if exists %I on %I', p.pol, p.t);
      execute format('create policy %I on %I for select to authenticated using (fn_perfil_actual() is not null)', p.pol, p.t);
    end if;
  end loop;
end $$;
-- 3) a app de porta identifica pelo PIN só quem tem perfil de bilhetes (os PIN do restaurante não abrem a porta)
create or replace function fn_staff_por_pin(p_pin text) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare s staff;
begin
  perform fn_exigir_perfil('porta','vendedor');
  select * into s from staff where activo and perfil is not null and pin_hash is not null and pin_hash = crypt(p_pin, pin_hash) limit 1;
  if s.id is null then return null; end if;
  return jsonb_build_object('id', s.id, 'nome', s.nome, 'perfil', s.perfil);
end $$;
