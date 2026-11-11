-- =============================================================================
-- Eventos no menu digital: cartão de publicidade com fotografias e, se houver, uma promoção ligada a artigos
-- (ex.: Pink Madness, 21/11/2026: na compra de 6 Brutal ganha 1 convite válido para 2 pessoas, até 20/11).
-- O cliente pede pelo cartão; ao confirmar o pedido recebe o aviso do prémio, e a linha do pedido leva a nota
-- "PROMOÇÃO ...: entregar N ..." para o caixa e o garçom.
-- =============================================================================
create table if not exists menu_eventos (
  id text primary key,
  titulo text not null,
  titulo_en text not null default '',
  texto text not null default '',
  texto_en text not null default '',
  quando text not null default '',
  quando_en text not null default '',
  imagens jsonb not null default '[]',         -- [{"url": "...", "alt": "...", "promo": true}]
  inicio date not null default current_date,   -- o cartão aparece de inicio a fim (dia operacional)
  fim date not null,
  activo boolean not null default true,
  promo_itens text[] not null default '{}',  -- artigos que contam para a promoção
  promo_qtd int not null default 0,            -- unidades no mesmo pedido para ganhar um prémio
  promo_ate date,                              -- último dia da promoção (nulo = até ao fim)
  promo_titulo text not null default '', promo_titulo_en text not null default '',
  promo_premio text not null default '', promo_premio_en text not null default '',       -- singular: "convite (válido para 2 pessoas)"
  promo_premio_pl text not null default '', promo_premio_pl_en text not null default '', -- plural
  promo_msg text not null default '', promo_msg_en text not null default ''
);
alter table menu_eventos enable row level security;
revoke all on menu_eventos from anon, authenticated;

create or replace function menu_eventos_activos() returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'titulo', e.titulo, 'titulo_en', e.titulo_en, 'texto', e.texto, 'texto_en', e.texto_en,
      'quando', e.quando, 'quando_en', e.quando_en, 'imagens', e.imagens,
      'promo', case when e.promo_qtd > 0 and cardinality(e.promo_itens) > 0 and menu_data_op() <= coalesce(e.promo_ate, e.fim) then
        jsonb_build_object('itens', to_jsonb(e.promo_itens), 'qtd', e.promo_qtd, 'ate', e.promo_ate, 'titulo', e.promo_titulo, 'titulo_en', e.promo_titulo_en,
          'premio', e.promo_premio, 'premio_en', e.promo_premio_en) end) order by e.fim, e.id), '[]')
  from menu_eventos e where e.activo and menu_data_op() between e.inicio and e.fim;
$$;
revoke all on function menu_eventos_activos() from public, anon, authenticated;

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
    'eventos', menu_eventos_activos(),
    'fid', jsonb_build_object('google', menu_cfg('link_avaliacao_google'), 'instagram', menu_cfg('link_instagram'), 'agradecimento', menu_cfg('texto_agradecimento'),
      'escaloes', menu_escaloes(), 'promos', menu_promos_publico(), 'aniversario', true));
end $$;

create or replace function menu_enviar_pedido(p_codigo text, p_visita text, p_linhas jsonb, p_sug jsonb, p_tok text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare m menu_mesas; v_id text; v_total numeric; l jsonb; s jsonb; ev menu_eventos; v_n numeric; v_pr int; v_premios jsonb := '[]'; v_vis text := left(btrim(coalesce(p_visita, '')), 40); v_nova boolean := false;
begin
  m := menu_mesa(p_codigo);
  -- só um telemóvel por mesa faz pedidos (o primeiro a pedir com a mesa livre)
  if menu_telemovel_unico() then
    if v_vis = '' then raise exception 'Não foi possível identificar este telemóvel. Recarregue a página e tente de novo.'; end if;
    select * into m from menu_mesas where id = m.id for update;
    if menu_mesa_dona_activa(m) and m.visita_dona <> v_vis then
      raise exception 'Esta mesa já faz os pedidos noutro telemóvel. Peça a essa pessoa para pedir ou chame o garçom.';
    end if;
    v_nova := not menu_mesa_dona_activa(m) or m.visita_dona is distinct from v_vis;
    update menu_mesas set visita_dona = v_vis, dona_desde = case when v_nova then now() else dona_desde end, dona_activa = now() where id = m.id;
  end if;
  if p_linhas is null or jsonb_array_length(p_linhas) = 0 then raise exception 'Pedido vazio'; end if;
  if jsonb_array_length(p_linhas) > 60 then raise exception 'Pedido demasiado grande'; end if;
  select sum((x->>'qtd')::numeric * (x->>'preco')::numeric) into v_total from jsonb_array_elements(p_linhas) x;
  v_id := menu_novo_id('P');
  insert into menu_pedidos (id, data_op, mesa, visita, total, cliente) values (v_id, menu_data_op(), m.id, left(coalesce(p_visita, ''), 40), coalesce(v_total, 0), menu_cliente_por_token(p_tok));
  for l in select * from jsonb_array_elements(p_linhas) loop
    insert into menu_linhas (pedido, item_id, nome, categoria, qtd, preco, variante, modificadores, nota)
    values (v_id, coalesce(l->>'item', ''), left(coalesce(l->>'nome', ''), 120),
      coalesce((select categoria from menu_artigos where item_id = l->>'item'), l->>'cat', ''), greatest(1, least(99, coalesce((l->>'qtd')::numeric, 1))),
      coalesce((l->>'preco')::numeric, 0), left(coalesce(l->>'variante', ''), 80),
      left(coalesce((select string_agg(x, ', ') from jsonb_array_elements_text(case when jsonb_typeof(l->'mods') = 'array' then l->'mods' else '[]' end) x), ''), 300),
      '');
  end loop;
  for s in select * from jsonb_array_elements(coalesce(p_sug, '[]')) loop
    insert into menu_sugestoes (pedido, mesa, tipo, origem, item, aceite) values (v_id, m.id, s->>'tipo', coalesce(s->>'origem', ''), s->>'item', coalesce((s->>'aceite')::boolean, false));
  end loop;
  -- promoções de eventos: N unidades dos artigos da promoção no mesmo pedido dão um prémio (ex.: 6 Brutal = 1 convite)
  for ev in select * from menu_eventos where activo and promo_qtd > 0 and cardinality(promo_itens) > 0 and menu_data_op() between inicio and coalesce(promo_ate, fim) loop
    select coalesce(sum(qtd), 0) into v_n from menu_linhas where pedido = v_id and item_id = any(ev.promo_itens);
    v_pr := floor(v_n / ev.promo_qtd);
    if v_pr > 0 then
      update menu_linhas set nota = left('PROMOÇÃO ' || ev.titulo || ': entregar ' || v_pr || ' ' || case when v_pr > 1 and ev.promo_premio_pl <> '' then ev.promo_premio_pl else ev.promo_premio end, 200)
        where id = (select min(id) from menu_linhas where pedido = v_id and item_id = any(ev.promo_itens));
      v_premios := v_premios || jsonb_build_object('evento', ev.id, 'titulo', ev.titulo, 'n', v_pr, 'premio', case when v_pr > 1 and ev.promo_premio_pl <> '' then ev.promo_premio_pl else ev.promo_premio end,
        'premio_en', case when v_pr > 1 and ev.promo_premio_pl_en <> '' then ev.promo_premio_pl_en else ev.promo_premio_en end,
        'msg', ev.promo_msg, 'msg_en', ev.promo_msg_en);
    end if;
  end loop;
  return jsonb_build_object('id', v_id, 't0', now(), 'telemovelNovo', v_nova, 'premios', v_premios);
end $$;
