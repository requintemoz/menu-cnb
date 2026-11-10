-- Linhas dos pedidos com o SKU do Loyverse (registo e garçom)
-- SKU do artigo (ou da variante escolhida), para facilitar o lançamento no Loyverse
create or replace function menu_sku(p_item text, p_variante text) returns text language sql stable security definer set search_path = public, extensions as $$
  select coalesce(nullif((select v->>'sku' from menu_artigos a, jsonb_array_elements(a.variantes) v where a.item_id = p_item and btrim(coalesce(p_variante, '')) <> '' and v->>'nome' = p_variante limit 1), ''),
    (select nullif(sku, '') from menu_artigos where item_id = p_item), '');
$$;
create or replace function menu_pedido_json(p menu_pedidos, com_linhas boolean default true) returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object('id', p.id, 'mesa', p.mesa, 't0', p.t0, 't1', p.t1, 't2', p.t2, 'g1', p.g1, 'g2', p.g2, 'caixa', p.caixa, 'reg_por', coalesce(p.reg_por::text, ''), 'total', p.total,
    'garcomMesa', coalesce((select garcom::text from menu_mesas where id = p.mesa), ''),
    'linhas', case when com_linhas then (select coalesce(jsonb_agg(jsonb_build_object('item', l.item_id, 'nome', l.nome, 'cat', l.categoria, 'qtd', l.qtd, 'variante', l.variante,
      'mods', l.modificadores, 'nota', l.nota, 'indisponivel', l.indisponivel, 'obs', menu_linha_obs(l), '_row', l.id, 'sku', menu_sku(l.item_id, l.variante)) order by l.id), '[]') from menu_linhas l where l.pedido = p.id) else '[]'::jsonb end);
$$;
revoke all on function menu_sku(text, text) from public, anon, authenticated;
