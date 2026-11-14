-- =============================================================================
-- Menu digital completo (14/11). Causa das faltas: só aparecem artigos com secção; as secções vieram da folha
-- antiga (menus impressos de Setembro) e os artigos acrescentados aos menus impressos a 05/10 e 21/10 ficaram sem secção.
-- 1. Põe no menu os 5 artigos do menu impresso que faltavam.
-- 2. Artigos novos do Loyverse numa categoria do menu (1B ou 2R) recebem logo a secção que os outros artigos
--    dessa categoria usam (a mais frequente), no fim da secção. Categorias internas (9Z, 3L, sem categoria) ficam de fora.
-- 3. Os vinhos a copo (nome começado por "Taça") não desaparecem por falta de stock: o copo sai da garrafa,
--    o stock que conta é o da garrafa. Config stock_ignorar_nomes (expressão regular; vazio desliga).
-- =============================================================================

-- 1. artigos do menu impresso que faltavam
update menu_extra e set seccao = v.sec, ordem = v.ord, oculto = false, nome_en = case when coalesce(e.nome_en, '') = '' then v.en else e.nome_en end
  from (values ('11553', 'Para começar', 65, 'Garlic bread with cheese'),
               ('11607', 'Acompanhamentos e extras', 810, 'Extra butter'),
               ('11926', 'Acompanhamentos e extras', 820, 'Extra black beans'),
               ('13103', 'Para terminar', 890, 'Ice cream cake'),
               ('13104', 'Para terminar', 900, 'Caramel cake')) v(sku, sec, ord, en), menu_artigos a
  where a.item_id = e.item_id and a.sku = v.sku and btrim(coalesce(e.seccao, '')) = '';

-- 2. secção automática para artigos novos
create or replace function menu_extra_seccao_auto() returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare v_cat text; v_sec text; v_ord int;
begin
  if btrim(coalesce(new.seccao, '')) <> '' or coalesce(new.oculto, false) or coalesce(menu_cfg('seccao_auto'), 'sim') = 'nao' then return new; end if;
  select categoria into v_cat from menu_artigos where item_id = new.item_id;
  if v_cat is null or v_cat !~ '^(1B|2R)-' then return new; end if;
  select e.seccao into v_sec from menu_extra e join menu_artigos a on a.item_id = e.item_id
    where a.categoria = v_cat and btrim(coalesce(e.seccao, '')) <> '' and not coalesce(e.oculto, false)
    group by e.seccao order by count(*) desc, min(e.ordem) limit 1;
  if v_sec is null then return new; end if;
  select coalesce(max(ordem), 0) + 10 into v_ord from menu_extra where seccao = v_sec;
  new.seccao := v_sec; new.ordem := v_ord;
  return new;
end $$;
revoke all on function menu_extra_seccao_auto() from public, anon, authenticated;
drop trigger if exists menu_extra_seccao_auto on menu_extra;
create trigger menu_extra_seccao_auto before insert on menu_extra for each row execute function menu_extra_seccao_auto();

-- 3. vinhos a copo não dependem do stock do copo
insert into menu_config (chave, valor) values ('stock_ignorar_nomes', '^ta[cç]a\M') on conflict (chave) do nothing;
create or replace function menu_artigos_stock_ignorar() returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare r text := coalesce(menu_cfg('stock_ignorar_nomes'), '');
begin
  if not new.activo and r <> '' and new.nome ~* r then new.activo := true; end if;
  return new;
end $$;
revoke all on function menu_artigos_stock_ignorar() from public, anon, authenticated;
drop trigger if exists menu_artigos_stock_ignorar on menu_artigos;
create trigger menu_artigos_stock_ignorar before insert or update on menu_artigos for each row execute function menu_artigos_stock_ignorar();
update menu_artigos set activo = true where not activo and nome ~* coalesce(menu_cfg('stock_ignorar_nomes'), '^$x');
