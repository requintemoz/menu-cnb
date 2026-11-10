-- Só aparecem no menu do cliente os artigos com secção atribuída (as categorias do Loyverse têm códigos internos).
create or replace view menu_v_visiveis as
  select a.item_id, a.nome from menu_artigos a left join menu_extra e on e.item_id = a.item_id
  where a.activo and not coalesce(e.oculto, false) and btrim(coalesce(e.seccao, '')) <> '';

create or replace function menu_publico() returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_menu jsonb; v_regras jsonb; v_obrig text[]; v_unica text[];
begin
  v_obrig := case when menu_cfg_existe('mod_obrigatorio') then array(select lower(x) from unnest(menu_lista(menu_cfg('mod_obrigatorio'))) x) else array['ponto da carne', 'tipo de chá'] end;
  v_unica := case when menu_cfg_existe('mod_escolha_unica') then array(select lower(x) from unnest(menu_lista(menu_cfg('mod_escolha_unica'))) x) else array['temperatura', 'como servir'] end;
  with it as (
    select a.*, e.nome_en, e.descricao_pt, e.descricao_en, e.etiquetas, e.foto_url, e.seccao_en,
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
        'ordem', ord, 'foto', coalesce(foto_url, '')) order by ord, nome) itens
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
    'fid', jsonb_build_object('google', menu_cfg('link_avaliacao_google'), 'instagram', menu_cfg('link_instagram'), 'agradecimento', menu_cfg('texto_agradecimento'),
      'escaloes', menu_escaloes(), 'promos', menu_promos_publico(), 'aniversario', true));
end $$;

update menu_promocoes set categorias = '2R-13 Sobremesas' where id = 'sobremesas' and categorias = 'Sobremesas';
