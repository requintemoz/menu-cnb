-- =============================================================================
-- Eventos do menu com link (por exemplo a publicação no Instagram) e texto do botão.
-- Os eventos dos bilhetes passam a mostrar até 700 caracteres da descrição.
-- =============================================================================
alter table menu_eventos add column if not exists link text not null default '';
alter table menu_eventos add column if not exists link_texto text not null default '';
alter table menu_eventos add column if not exists link_texto_en text not null default '';

create or replace function menu_eventos_activos() returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v jsonb; b jsonb := '[]';
begin
  select coalesce(jsonb_agg(x.j order by x.d, x.id), '[]') into v from (
    select e.fim d, e.id, jsonb_build_object('id', e.id, 'titulo', e.titulo, 'titulo_en', e.titulo_en, 'texto', e.texto, 'texto_en', e.texto_en,
      'quando', e.quando, 'quando_en', e.quando_en, 'imagens', e.imagens,
      'link', nullif(e.link, ''), 'link_texto', e.link_texto, 'link_texto_en', e.link_texto_en,
      'promo', case when e.promo_qtd > 0 and cardinality(e.promo_itens) > 0 and menu_data_op() <= coalesce(e.promo_ate, e.fim) then
        jsonb_build_object('itens', to_jsonb(e.promo_itens), 'qtd', e.promo_qtd, 'ate', e.promo_ate, 'titulo', e.promo_titulo, 'titulo_en', e.promo_titulo_en,
          'premio', e.promo_premio, 'premio_en', e.promo_premio_en) end) j
    from menu_eventos e where e.activo and menu_data_op() between e.inicio and e.fim) x;
  -- eventos do sistema de bilhetes
  if to_regclass('public.eventos') is not null then
    execute $q$
      select coalesce(jsonb_agg(jsonb_build_object('id', 'b-' || e.slug, 'titulo', e.nome, 'titulo_en', '', 'texto', left(coalesce(e.descricao, ''), 700), 'texto_en', '',
          'quando', e.inicio_em, 'local', coalesce(e."local", ''), 'bilhetes', true, 'idade', e.idade_minima,
          'imagens', case when coalesce(e.imagem_url, '') <> '' then jsonb_build_array(jsonb_build_object('url', e.imagem_url, 'alt', e.nome)) else '[]'::jsonb end,
          'link', coalesce(menu_cfg('eventos_url_compra'), '') || e.slug) order by e.inicio_em), '[]')
      from eventos e
      where e.estado::text = 'a_venda' and coalesce(e.fim_em, e.inicio_em + interval '8 hours') > now()
        and not (e.slug = any(string_to_array(coalesce(menu_cfg('eventos_fora_do_menu'), ''), '|')))
    $q$ into b;
  end if;
  return v || coalesce(b, '[]');
end $$;
revoke all on function menu_eventos_activos() from public, anon, authenticated;
