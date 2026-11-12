-- =============================================================================
-- Bilhetes: tipos vendidos só em quantidades fixas (mesas VVIP de 4, 6, 8 ou 10 pessoas).
-- tipos_bilhete.multiplos: lista das quantidades permitidas numa encomenda (vazio = qualquer quantidade).
-- fn_criar_encomenda recusa outras quantidades; fn_precos_evento passa a lista à página de compra.
-- =============================================================================
alter table tipos_bilhete add column if not exists multiplos int[];

create or replace function fn_qtds_texto(a int[]) returns text language sql immutable as $$
  select case when cardinality(a) = 1 then a[1]::text
    else array_to_string(a[1:cardinality(a) - 1], ', ') || ' ou ' || a[cardinality(a)] end;
$$;

create or replace function public.fn_criar_encomenda(p jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  s staff; ev eventos; c clientes; en encomendas; it jsonb; t tipos_bilhete; l lotes_preco;
  v_canal canal_venda; v_entrega modo_entrega; v_total numeric := 0; v_qtd int; v_preco numeric;
  v_promo codigos_promo; v_desc numeric := 0; v_prazo int; v_crm boolean; v_total_qtd int := 0;
  v_base text; v_lim jsonb;
begin
  v_canal := coalesce((p->>'canal')::canal_venda, 'assistida');
  if v_canal <> 'online' then s := fn_exigir_perfil('vendedor','porta'); end if;
  v_lim := coalesce(fn_def('limites'), '{}');

  select * into ev from eventos where id = (p->>'evento_id')::uuid for update;
  if ev.id is null then raise exception 'Evento não encontrado' using errcode='22023'; end if;
  if ev.estado <> 'a_venda' then raise exception 'Evento não está à venda (%)', ev.estado using errcode='22023'; end if;

  v_crm := exists (select 1 from clientes where telemovel = fn_norm_telemovel(p->'cliente'->>'telemovel'));
  c := fn_obter_ou_criar_cliente(p->'cliente', v_canal);
  v_entrega := coalesce((p->>'entrega')::modo_entrega, 'whatsapp');

  if v_canal = 'online' and (select count(*) from encomendas where cliente_id = c.id and estado = 'reservada' and (expira_em is null or expira_em > now()))
                            >= coalesce((v_lim->>'max_reservas_abertas_por_telemovel')::int, 2) then
    raise exception 'Este telemóvel já tem reservas por pagar. Conclua o pagamento ou aguarde que expirem.' using errcode='22023';
  end if;

  if p->>'codigo_promo' is not null and trim(p->>'codigo_promo') <> '' then
    select * into v_promo from codigos_promo where codigo = trim(p->>'codigo_promo') and activo
      and (evento_id is null or evento_id = ev.id) and (valido_ate is null or now() <= valido_ate)
      and (max_usos is null or usos < max_usos) for update;
    if v_promo.id is null then raise exception 'Código promocional inválido ou esgotado' using errcode='22023'; end if;
  end if;

  v_prazo := case when v_canal = 'online' then (fn_def('reservas')->>'prazo_pagamento_online_minutos')::int
                  else (fn_def('reservas')->>'prazo_pagamento_minutos')::int end;

  insert into encomendas (evento_id, cliente_id, canal, entrega, codigo_promo_id, observacoes, criado_por, expira_em)
  values (ev.id, c.id, v_canal, v_entrega, v_promo.id, nullif(trim(p->>'observacoes'),''), s.id,
          now() + make_interval(mins => v_prazo))
  returning * into en;

  for it in select * from jsonb_array_elements(p->'itens') loop
    v_qtd := (it->>'quantidade')::int;
    if v_qtd <= 0 then continue; end if;
    select * into t from tipos_bilhete where id = (it->>'tipo_bilhete_id')::uuid and evento_id = ev.id and activo for update;
    if t.id is null then raise exception 'Tipo de bilhete inválido' using errcode='22023'; end if;
    if t.tipo <> 'pago' then raise exception 'Convites emitem-se com fn_criar_convite' using errcode='22023'; end if;
    if cardinality(coalesce(t.multiplos, '{}')) > 0 and not (v_qtd = any(t.multiplos)) then
      raise exception '% vende-se só em grupos de % pessoas.', t.nome, fn_qtds_texto(t.multiplos) using errcode='22023';
    end if;
    if t.venda_inicio is not null and now() < t.venda_inicio then raise exception 'Venda de % ainda não abriu', t.nome using errcode='22023'; end if;
    if t.venda_fim is not null and now() > t.venda_fim then raise exception 'Venda de % já fechou', t.nome using errcode='22023'; end if;
    if fn_disponibilidade_tipo(t.id) < v_qtd then
      raise exception 'Só restam % bilhetes do tipo %', fn_disponibilidade_tipo(t.id), t.nome using errcode='22023';
    end if;
    l := fn_lote_actual(t.id, v_crm);
    v_preco := coalesce(l.preco, t.preco_base);
    insert into encomenda_itens (encomenda_id, tipo_bilhete_id, lote_id, quantidade, preco_unitario)
    values (en.id, t.id, l.id, v_qtd, v_preco);
    v_total := v_total + v_preco * v_qtd;
    v_total_qtd := v_total_qtd + v_qtd;
  end loop;
  if v_total_qtd = 0 then raise exception 'Encomenda sem bilhetes' using errcode='22023'; end if;
  if v_canal = 'online' and v_total_qtd > coalesce((v_lim->>'max_bilhetes_online')::int, 10) then
    raise exception 'Na compra online o máximo é de % bilhetes. Para grupos maiores, contacte-nos.', coalesce((v_lim->>'max_bilhetes_online')::int, 10) using errcode='22023';
  end if;
  if fn_disponibilidade_evento(ev.id) < 0 then raise exception 'Lotação do evento esgotada' using errcode='22023'; end if;

  if v_promo.id is not null then
    v_desc := coalesce(v_promo.desconto_valor, 0) + v_total * coalesce(v_promo.desconto_pct, 0) / 100;
    v_desc := least(v_desc, v_total);
    update codigos_promo set usos = usos + 1 where id = v_promo.id;
  end if;

  update encomendas set total = v_total - v_desc, desconto = v_desc where id = en.id returning * into en;

  if v_canal <> 'online' then
    v_base := fn_def('urls')->>'base';
    perform fn_enfileirar_mensagem(c.id, 'whatsapp', 'utilidade', 'cnb_termos',
      jsonb_build_array(c.nome, ev.nome, v_base || '/t/?o=' || en.token_publico),
      format('Olá %s! Obrigado pela reserva para %s. Para emitirmos o seu bilhete, confirme os termos aqui: %s/t/?o=%s',
             c.nome, ev.nome, v_base, en.token_publico),
      en.id);
  end if;

  return jsonb_build_object('encomenda_id', en.id, 'token_publico', en.token_publico, 'total', en.total,
                            'desconto', en.desconto, 'expira_em', en.expira_em, 'cliente_id', c.id);
end $function$;

create or replace function public.fn_precos_evento(p_evento uuid, p_telemovel text default null::text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', 'extensions'
as $function$
declare r jsonb := '[]'; t record; l lotes_preco; prox lotes_preco; v_crm boolean := false;
begin
  if p_telemovel is not null then
    v_crm := exists (select 1 from clientes where telemovel = fn_norm_telemovel(p_telemovel));
  end if;
  for t in select * from tipos_bilhete where evento_id = p_evento and activo and tipo = 'pago' order by ordem loop
    l := fn_lote_actual(t.id, v_crm);
    select * into prox from lotes_preco where tipo_bilhete_id = t.id and ordem > coalesce(l.ordem, 0) order by ordem limit 1;
    r := r || jsonb_build_object(
      'tipo_bilhete_id', t.id, 'nome', t.nome, 'cor', t.cor_pulseira, 'cor_hex', t.cor_hex,
      'preco', coalesce(l.preco, t.preco_base), 'lote', l.nome,
      'lote_termina_em', l.termina_em, 'lote_termina_apos_qtd', l.termina_apos_qtd,
      'vendidos', fn_vendidos_tipo(t.id),
      'proximo_preco', prox.preco, 'proximo_lote', prox.nome,
      'disponivel', fn_disponibilidade_tipo(t.id),
      'multiplos', coalesce(to_jsonb(t.multiplos), '[]'::jsonb),
      'venda_aberta', (t.venda_inicio is null or now() >= t.venda_inicio) and (t.venda_fim is null or now() <= t.venda_fim));
  end loop;
  return r;
end $function$;
