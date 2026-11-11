-- =============================================================================
-- 1) Dados do Vivino na ficha dos vinhos (pontuação, n.º de avaliações, produtor, castas, região, estilo, notas e harmonização).
--    Recolhidos à mão do Vivino (data em vivino->>'data'); a ficha mostra a fonte.
-- 2) Os eventos do sistema de bilhetes (tabela eventos, estado "a_venda", ainda por acontecer) aparecem no início do menu,
--    com ligação à página de compra. Config eventos_fora_do_menu: slugs a esconder, separados por |.
-- =============================================================================
alter table menu_extra add column if not exists vivino jsonb;

insert into menu_config (chave, valor, nota) values
  ('eventos_fora_do_menu', 'demo', 'slugs de eventos do sistema de bilhetes que não aparecem no menu, separados por |'),
  ('eventos_url_compra', 'https://requintemoz.github.io/bilhetes/comprar/?e=', 'endereço da página de compra de bilhetes (leva o slug do evento no fim)')
on conflict (chave) do nothing;

create or replace function menu_eventos_activos() returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v jsonb; b jsonb := '[]';
begin
  select coalesce(jsonb_agg(x.j order by x.d, x.id), '[]') into v from (
    select e.fim d, e.id, jsonb_build_object('id', e.id, 'titulo', e.titulo, 'titulo_en', e.titulo_en, 'texto', e.texto, 'texto_en', e.texto_en,
      'quando', e.quando, 'quando_en', e.quando_en, 'imagens', e.imagens,
      'promo', case when e.promo_qtd > 0 and cardinality(e.promo_itens) > 0 and menu_data_op() <= coalesce(e.promo_ate, e.fim) then
        jsonb_build_object('itens', to_jsonb(e.promo_itens), 'qtd', e.promo_qtd, 'ate', e.promo_ate, 'titulo', e.promo_titulo, 'titulo_en', e.promo_titulo_en,
          'premio', e.promo_premio, 'premio_en', e.promo_premio_en) end) j
    from menu_eventos e where e.activo and menu_data_op() between e.inicio and e.fim) x;
  -- eventos do sistema de bilhetes
  if to_regclass('public.eventos') is not null then
    execute $q$
      select coalesce(jsonb_agg(jsonb_build_object('id', 'b-' || e.slug, 'titulo', e.nome, 'titulo_en', '', 'texto', left(coalesce(e.descricao, ''), 400), 'texto_en', '',
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

create or replace function menu_publico() returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_menu jsonb; v_regras jsonb; v_obrig text[]; v_unica text[];
begin
  v_obrig := case when menu_cfg_existe('mod_obrigatorio') then array(select lower(x) from unnest(menu_lista(menu_cfg('mod_obrigatorio'))) x) else array['ponto da carne', 'tipo de chá'] end;
  v_unica := case when menu_cfg_existe('mod_escolha_unica') then array(select lower(x) from unnest(menu_lista(menu_cfg('mod_escolha_unica'))) x) else array['temperatura', 'como servir'] end;
  with it as (
    select a.*, e.nome_en, e.descricao_pt, e.descricao_en, e.etiquetas, e.foto_url, e.seccao_en, e.vivino,
      coalesce(nullif(btrim(e.seccao), ''), a.categoria) sec, coalesce(e.ordem, 9999) ord
    from menu_artigos a left join menu_extra e on e.item_id = a.item_id
    where a.activo and not coalesce(e.oculto, false) and btrim(coalesce(e.seccao, '')) <> ''),
  sec as (
    select sec, min(ord) ord, max(nullif(btrim(seccao_en), '')) sec_en,
      jsonb_agg(jsonb_build_object('id', item_id, 'nome', nome, 'nome_en', coalesce(nome_en, ''), 'cat', sec, 'preco', preco, 'sku', sku,
        'variantes', variantes,
        'modificadores', (select coalesce(jsonb_agg(g || jsonb_build_object('obrigatorio', lower(btrim(g->>'nome')) = any(v_obrig),
                            'unica', lower(btrim(g->>'nome')) = any(v_obrig) or lower(btrim(g->>'nome')) = any(v_unica))), '[]') from jsonb_array_elements(modificadores) g),
        'descricao', coalesce(descricao_pt, ''), 'descricao_en', coalesce(descricao_en, ''),
        'etiquetas', case when coalesce(etiquetas, '') = '' then '[]'::jsonb else (select coalesce(jsonb_agg(btrim(x)), '[]') from regexp_split_to_table(etiquetas, '[,|]') x) end,
        'ordem', ord, 'foto', coalesce(foto_url, ''), 'vivino', vivino) order by ord, nome) itens
    from it group by sec)
  select coalesce(jsonb_agg(jsonb_build_object('nome', sec, 'nome_en', coalesce(sec_en, ''), 'itens', itens, 'ordem', ord) order by ord, sec), '[]') into v_menu from sec;

  select coalesce(jsonb_object_agg(a, jsonb_build_object('itens', s, 'horario', h)), '{}') into v_regras from (
    select menu_ref(r.artigo_id, r.artigo) a, r.horario h,
      (select coalesce(jsonb_agg(x) filter (where x <> ''), '[]') from unnest(array[menu_ref(r.sugestao_1_id, r.sugestao_1), menu_ref(r.sugestao_2_id, r.sugestao_2), menu_ref(r.sugestao_3_id, r.sugestao_3)]) x) s
    from menu_regras r) z where a <> '';

  return jsonb_build_object('menu', v_menu, 'regras', v_regras, 'destaques', menu_destaques_activos(),
    'lembretes', jsonb_build_object('bebidas', menu_ref_lista('lembrete_bebidas'), 'sobremesa', menu_ref_lista('lembrete_sobremesa')),
    'principais', to_jsonb(string_to_array(menu_cfg('categorias_principais'), '|')), 'sobremesas', to_jsonb(string_to_array(menu_cfg('categorias_sobremesa'), '|')),
    'textos', jsonb_build_object('boas_vindas', menu_cfg('texto_boas_vindas'), 'garcom_vem', menu_cfg('texto_garcom_vem'), 'indisponivel', menu_cfg('texto_indisponivel'),
      'boas_vindas_en', menu_cfg('texto_boas_vindas_en'), 'garcom_vem_en', menu_cfg('texto_garcom_vem_en'), 'indisponivel_en', menu_cfg('texto_indisponivel_en')),
    'wifi', jsonb_build_object('nome', menu_cfg('wifi_nome'), 'senha', menu_cfg('wifi_senha')), 'nome', menu_cfg('nome_restaurante'), 'clube', menu_cfg('nome_clube'),
    'motivos', '["Preciso de ajuda","Outro"]'::jsonb,
    'eventos', menu_eventos_activos(),
    'fid', jsonb_build_object('google', menu_cfg('link_avaliacao_google'), 'instagram', menu_cfg('link_instagram'), 'agradecimento', menu_cfg('texto_agradecimento'),
      'escaloes', menu_escaloes(), 'promos', menu_promos_publico(), 'aniversario', true));
end $$;
