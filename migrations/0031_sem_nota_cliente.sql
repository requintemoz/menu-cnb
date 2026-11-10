-- O cliente deixa de escrever pedidos especiais (nota livre) nos artigos: o menu já não mostra a caixa
-- e o servidor ignora qualquer nota que chegue de páginas antigas ainda abertas.
create or replace function menu_enviar_pedido(p_codigo text, p_visita text, p_linhas jsonb, p_sug jsonb, p_tok text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare m menu_mesas; v_id text; v_total numeric; l jsonb; s jsonb;
begin
  m := menu_mesa(p_codigo);
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
  return jsonb_build_object('id', v_id, 't0', now());
end $$;
