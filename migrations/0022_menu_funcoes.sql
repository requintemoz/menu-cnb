-- =============================================================================
-- Menu digital CNB: regras de negócio (substituem o Código.gs, Fidelizacao.gs e Registo.gs do Apps Script)
-- As páginas chamam uma só função, menu_api(fn, args), com os mesmos nomes e respostas do Apps Script,
-- para mudarem o mínimo. A identidade da equipa vem da sessão Supabase (auth.uid()), não de um token.
-- =============================================================================

-- ---------------------------------------------------------------- utilitários
create or replace function menu_cfg(k text) returns text language sql stable security definer set search_path = public, extensions as $$
  select coalesce((select valor from menu_config where chave = k), '');
$$;
create or replace function menu_cfg_existe(k text) returns boolean language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from menu_config where chave = k);
$$;
create or replace function menu_cfg_num(k text, padrao numeric default 0) returns numeric language sql stable security definer set search_path = public, extensions as $$
  select coalesce(nullif(regexp_replace(menu_cfg(k), '[^0-9.]', '', 'g'), '')::numeric, padrao);
$$;
create or replace function menu_local() returns timestamp language sql stable as $$ select now() at time zone 'Africa/Maputo'; $$;
-- dia operacional: antes da hora dia_comeca_as conta para o dia anterior
create or replace function menu_data_op() returns date language sql stable security definer set search_path = public, extensions as $$
  select (menu_local() - coalesce(nullif(menu_cfg('dia_comeca_as'), '')::time, '06:00'::time)::interval)::date;
$$;
create or replace function menu_novo_id(p text) returns text language sql volatile as $$
  select p || to_char(menu_local(), 'YYMMDD') || '-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 4));
$$;
create or replace function menu_norm(s text) returns text language sql immutable as $$
  select btrim(regexp_replace(lower(translate(coalesce(s, ''),
    'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ', 'aaaaaeeeeiiiiooooouuuucnAAAAAEEEEIIIIOOOOOUUUUCN')), '\s+', ' ', 'g'));
$$;
create or replace function menu_mins(t timestamptz) returns numeric language sql stable as $$ select extract(epoch from now() - t) / 60; $$;
create or replace function menu_lista(s text) returns text[] language sql immutable as $$
  select coalesce(array_agg(btrim(x)) filter (where btrim(x) <> ''), '{}') from unnest(string_to_array(coalesce(s, ''), '|')) x;
$$;
create or replace function menu_txt(s text, n int default 500) returns text language sql immutable as $$
  select left(regexp_replace(btrim(coalesce(s, '')), '^[=+\-@]+', ''), n);
$$;
create or replace function menu_primeiro(s text) returns text language sql immutable as $$
  select coalesce(split_part(btrim(coalesce(s, '')), ' ', 1), '');
$$;
create or replace function menu_nome(id uuid) returns text language sql stable security definer set search_path = public, extensions as $$
  select nome from staff where staff.id = menu_nome.id;
$$;
create or replace function menu_limites() returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object('aceitar', menu_cfg_num('limite_aceitar_min', 2), 'registar', menu_cfg_num('limite_registar_min', 5),
    'chamada', menu_cfg_num('limite_chamada_min', 3), 'entregar', menu_cfg_num('limite_entregar_min', 20));
$$;
create or replace function menu_user_json(s staff) returns jsonb language sql stable as $$
  select jsonb_build_object('id', s.id, 'nome', s.nome, 'perfil', s.menu_perfil);
$$;
create or replace function menu_nomes() returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select coalesce(jsonb_object_agg(id, nome), '{}') from staff;
$$;
create or replace function menu_mesa(p_codigo text) returns menu_mesas
language plpgsql stable security definer set search_path = public, extensions as $$
declare m menu_mesas;
begin
  select * into m from menu_mesas where codigo = p_codigo and activa;
  if m.id is null then raise exception 'Mesa não reconhecida. Leia o QR da sua mesa.'; end if;
  return m;
end $$;
create or replace function menu_modo_central() returns boolean language sql stable security definer set search_path = public, extensions as $$
  select lower(btrim(menu_cfg('modo_registo'))) = 'central';
$$;
-- linha com observações: variante, opções ou nota do cliente
create or replace function menu_linha_obs(l menu_linhas) returns boolean language sql immutable as $$
  select btrim(l.variante) <> '' or btrim(l.modificadores) <> '' or btrim(l.nota) <> '';
$$;
create or replace function menu_ordem_categorias() returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select coalesce(jsonb_agg(categoria order by o), '[]') from (select categoria, min(ordem_cat) o from menu_artigos group by categoria) x;
$$;

-- ---------------------------------------------------------------- turnos e presença de quem regista
create or replace function menu_entrar_turno(p_staff uuid) returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if not exists (select 1 from menu_turnos where staff_id = p_staff and saida is null) then
    insert into menu_turnos (id, data, staff_id) values (menu_novo_id('T'), menu_data_op(), p_staff);
  end if;
end $$;
create or replace function menu_sair_turno(p_staff uuid) returns void language sql security definer set search_path = public, extensions as $$
  update menu_turnos set saida = now() where staff_id = p_staff and saida is null;
$$;

create table if not exists menu_presenca (staff_id uuid primary key references staff(id) on delete cascade, visto_em timestamptz not null default now());
create or replace function menu_registadores() returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', p.staff_id, 'nome', s.nome)), '[]')
  from menu_presenca p join staff s on s.id = p.staff_id where p.visto_em > now() - interval '90 seconds';
$$;
-- Em modo central, um pedido ainda não registado fica escondido dos garçons, excepto se ninguém tem a página
-- de registo aberta, ou se está parado há mais do que (aceitar + registar) minutos sem ninguém o ter assumido.
create or replace function menu_central_esconde(p menu_pedidos) returns boolean language plpgsql stable security definer set search_path = public, extensions as $$
begin
  if not menu_modo_central() or p.t2 is not null then return false; end if;
  if not exists (select 1 from menu_presenca where visto_em > now() - interval '90 seconds') then return false; end if;
  if p.reg_por is null and menu_mins(p.t0) > menu_cfg_num('limite_aceitar_min', 2) + menu_cfg_num('limite_registar_min', 5) then return false; end if;
  return true;
end $$;

-- ---------------------------------------------------------------- referências a artigos (por identificador ou nome)
create or replace view menu_v_visiveis as
  select a.item_id, a.nome from menu_artigos a left join menu_extra e on e.item_id = a.item_id
  where a.activo and not coalesce(e.oculto, false) and btrim(coalesce(e.seccao, '')) <> '';

create or replace function menu_ref(p_id text, p_nome text) returns text language plpgsql stable security definer set search_path = public, extensions as $$
declare r text;
begin
  p_id := btrim(coalesce(p_id, '')); p_nome := btrim(coalesce(p_nome, ''));
  if p_id <> '' and exists (select 1 from menu_v_visiveis where item_id = p_id) then return p_id; end if;
  if p_nome <> '' then
    select item_id into r from menu_v_visiveis where nome = p_nome limit 1; if r is not null then return r; end if;
    if exists (select 1 from menu_v_visiveis where item_id = p_nome) then return p_nome; end if;
  end if;
  return '';
end $$;
create or replace function menu_ref_lista(chave text) returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select coalesce(jsonb_agg(r order by i) filter (where r <> ''), '[]') from (
    select i, menu_ref((menu_lista(menu_cfg(chave || '_ids')))[i], n) r
    from unnest(menu_lista(menu_cfg(chave))) with ordinality as t(n, i)) x;
$$;

-- Mantém nome e identificador lado a lado (regras, destaques, lembretes, promoções). Corre depois de cada sincronização.
create or replace function menu_reconciliar(p_nome text, p_id text, out nome text, out id text) language plpgsql stable security definer set search_path = public, extensions as $$
#variable_conflict use_variable
declare n_id text; n_nome text;
begin
  nome := btrim(coalesce(p_nome, '')); id := btrim(coalesce(p_id, ''));
  if nome = '' and id = '' then return; end if;
  if id <> '' then select a.nome into n_nome from menu_artigos a where a.item_id = id; end if;
  if nome <> '' then select a.item_id into n_id from menu_artigos a where btrim(a.nome) = nome order by a.item_id limit 1; end if;
  if n_nome is not null then
    if n_nome = nome then return; end if;
    if n_id is not null then id := n_id; return; end if;
    nome := n_nome; return;
  end if;
  if n_id is not null then id := n_id; end if;
end $$;
create or replace function menu_sincronizar_referencias() returns int language plpgsql security definer set search_path = public, extensions as $$
declare n int := 0; r record; x record; k text; nomes text[]; ids text[]; novo_n text[]; novo_i text[]; i int;
begin
  if not exists (select 1 from menu_artigos) then return 0; end if;
  for r in select * from menu_regras loop
    declare a record; b record; c record; d record;
    begin
      a := menu_reconciliar(r.artigo, r.artigo_id); b := menu_reconciliar(r.sugestao_1, r.sugestao_1_id);
      c := menu_reconciliar(r.sugestao_2, r.sugestao_2_id); d := menu_reconciliar(r.sugestao_3, r.sugestao_3_id);
      if (a.nome, a.id, b.nome, b.id, c.nome, c.id, d.nome, d.id) is distinct from (r.artigo, r.artigo_id, r.sugestao_1, r.sugestao_1_id, r.sugestao_2, r.sugestao_2_id, r.sugestao_3, r.sugestao_3_id) then
        update menu_regras set artigo = a.nome, artigo_id = a.id, sugestao_1 = b.nome, sugestao_1_id = b.id, sugestao_2 = c.nome, sugestao_2_id = c.id, sugestao_3 = d.nome, sugestao_3_id = d.id where id = r.id;
        n := n + 1;
      end if;
    end;
  end loop;
  for r in select * from menu_destaques where btrim(item) <> '' or btrim(item_id) <> '' loop
    x := menu_reconciliar(r.item, r.item_id);
    if (x.nome, x.id) is distinct from (r.item, r.item_id) then update menu_destaques set item = x.nome, item_id = x.id where id = r.id; n := n + 1; end if;
  end loop;
  foreach k in array array['lembrete_bebidas', 'lembrete_sobremesa'] loop
    if not menu_cfg_existe(k) then continue; end if;
    nomes := menu_lista(menu_cfg(k)); ids := string_to_array(menu_cfg(k || '_ids'), '|'); novo_n := '{}'; novo_i := '{}';
    for i in 1 .. coalesce(array_length(nomes, 1), 0) loop
      x := menu_reconciliar(nomes[i], btrim(coalesce(ids[i], ''))); novo_n := novo_n || x.nome; novo_i := novo_i || x.id;
    end loop;
    if array_to_string(novo_n, ' | ') <> array_to_string(nomes, ' | ') then update menu_config set valor = array_to_string(novo_n, ' | ') where chave = k; n := n + 1; end if;
    insert into menu_config (chave, valor, nota) values (k || '_ids', array_to_string(novo_i, '|'), 'preenchido automaticamente: identificadores dos artigos de ' || k)
      on conflict (chave) do update set valor = excluded.valor where menu_config.valor is distinct from excluded.valor;
  end loop;
  for r in select * from menu_promocoes loop
    nomes := menu_lista(r.artigos); ids := string_to_array(r.artigos_ids, '|'); novo_n := '{}'; novo_i := '{}';
    if coalesce(array_length(nomes, 1), 0) = 0 then continue; end if;
    for i in 1 .. array_length(nomes, 1) loop
      if right(nomes[i], 1) = '*' then novo_n := novo_n || nomes[i]; novo_i := novo_i || ''::text;
      else x := menu_reconciliar(nomes[i], btrim(coalesce(ids[i], ''))); novo_n := novo_n || x.nome; novo_i := novo_i || x.id; end if;
    end loop;
    if array_to_string(novo_n, ' | ') <> array_to_string(nomes, ' | ') or array_to_string(novo_i, '|') <> r.artigos_ids then
      update menu_promocoes set artigos = array_to_string(novo_n, ' | '), artigos_ids = array_to_string(novo_i, '|') where id = r.id; n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------- menu para o cliente
create or replace function menu_destaques_activos() returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'tipo', d.tipo, 'titulo', d.titulo, 'texto', d.texto, 'titulo_en', d.titulo_en, 'texto_en', d.texto_en,
    'item', menu_ref(d.item_id, d.item), 'so_membros', d.so_membros, 'fim', case when d.fim is null then '' else to_char(d.fim, 'YYYY-MM-DD') || 'T23:59:59' end) order by d.id), '[]')
  from menu_destaques d
  where d.activo and (d.inicio is null or menu_local()::date >= d.inicio) and (d.fim is null or menu_local()::date <= d.fim)
    and (btrim(d.dias_semana) = '' or extract(isodow from menu_local())::text = any(string_to_array(replace(d.dias_semana, ' ', ''), ',')))
    and (position('-' in d.horario) = 0 or to_char(menu_local(), 'HH24:MI') between btrim(split_part(d.horario, '-', 1)) and btrim(split_part(d.horario, '-', 2)));
$$;

-- Promoções activas do Cartão Requinte, com os critérios já resolvidos
create or replace function menu_promos_activas() returns table (id text, nome text, nome_en text, qtd int, brinde text, brinde_en text, ids text[], nomes text[], prefixos text[], cats text[], ini date, fim date, a_vista boolean)
language sql stable security definer set search_path = public, extensions as $$
  with p as (
    select pr.*, menu_lista(pr.artigos) toks from menu_promocoes pr
    where pr.activo and pr.quantidade > 0 and btrim(pr.brinde) <> ''),
  q as (
    select p.*, array(select menu_norm(t) from unnest(p.toks) t where right(t, 1) <> '*') nm,
      array(select menu_norm(left(t, -1)) from unnest(p.toks) t where right(t, 1) = '*' and length(t) > 1) pf
    from p)
  select q.id, q.nome, q.nome_en, q.quantidade, btrim(q.brinde), btrim(q.brinde_en),
    array(select distinct x from (
      select unnest(menu_lista(q.artigos_ids)) x
      union select t from unnest(q.toks) t where exists (select 1 from menu_artigos a where a.item_id = t)
      union select a.item_id from menu_artigos a where menu_norm(a.nome) = any(q.nm) or exists (select 1 from unnest(q.pf) f where menu_norm(a.nome) like f || '%')) y),
    q.nm, q.pf, array(select menu_norm(c) from unnest(menu_lista(q.categorias)) c), q.inicio, q.fim,
    q.fim is null or menu_local()::date <= q.fim
  from q;
$$;
create or replace function menu_promos_publico() returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'nome', p.nome, 'nome_en', p.nome_en, 'qtd', p.qtd, 'brinde', p.brinde, 'brinde_en', p.brinde_en,
    'itens', (select coalesce(jsonb_agg(v.item_id), '[]') from menu_v_visiveis v join menu_artigos a on a.item_id = v.item_id
              where (p.ini is null or menu_local()::date >= p.ini) and (v.item_id = any(p.ids) or menu_norm(a.nome) = any(p.nomes)
                or exists (select 1 from unnest(p.prefixos) f where menu_norm(a.nome) like f || '%') or menu_norm(a.categoria) = any(p.cats))))), '[]')
  from menu_promos_activas() p where p.a_vista;
$$;
create or replace function menu_escaloes() returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select case when lower(btrim(menu_cfg('fid_pontos_por_valor'))) <> 'sim' then '[]'::jsonb
    else coalesce((select jsonb_agg(jsonb_build_object('limiar', limiar_mt, 'brinde', brinde) order by limiar_mt) from menu_brindes where activo and limiar_mt > 0), '[]') end;
$$;

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

-- ---------------------------------------------------------------- Cartão Requinte: contas do cliente
create or replace function menu_hash(tok text) returns text language sql immutable set search_path = public, extensions as $$
  select left(translate(encode(digest(coalesce(tok, ''), 'sha256'), 'base64'), '+/', '-_'), 32);
$$;
create or replace function menu_cliente_por_token(tok text) returns uuid language sql stable security definer set search_path = public, extensions as $$
  select c.cliente_id from menu_cartao c where coalesce(tok, '') <> '' and menu_hash(tok) = any(c.token_hashes) and c.activo limit 1;
$$;
create or replace function menu_aniv(s text) returns int[] language sql immutable as $$
  select case when m is null then null when m[1]::int between 1 and 31 and m[2]::int between 1 and 12 then array[m[1]::int, m[2]::int] else null end
  from (select regexp_match(btrim(replace(coalesce(s, ''), '''', '')), '^(\d{1,2})[/.\-](\d{1,2})$') m) x;
$$;
create or replace function menu_aniv_txt(a int[]) returns text language sql immutable as $$
  select case when a is null then '' else lpad(a[1]::text, 2, '0') || '/' || lpad(a[2]::text, 2, '0') end;
$$;

-- Total, visitas, última visita, brindes e selos de um cliente
create or replace function menu_brindes_de(p_cliente uuid) returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare k menu_cartao; v_total numeric; v_vis int; v_ult date; v_esc jsonb; v_disp jsonb := '[]'; v_lista jsonb := '[]'; v_prox jsonb := null;
  v_ciclo numeric := 0; v_r numeric := 0; v_k int; v_ganhos int := 0; pr record; v_cont numeric; v_tot numeric; n int; e jsonb; v_brA text; v_an int[]; v_ch text;
begin
  select * into k from menu_cartao where cliente_id = p_cliente;
  select coalesce(sum(l.qtd * l.preco), 0) into v_total from menu_pedidos p join menu_linhas l on l.pedido = p.id
    where p.cliente = p_cliente and p.t2 is not null and p.anulado_motivo = '' and not l.indisponivel;
  select count(distinct p.data_op), max(p.t2 at time zone 'Africa/Maputo')::date into v_vis, v_ult from menu_pedidos p
    where p.cliente = p_cliente and p.t2 is not null and p.anulado_motivo = '';
  v_total := round(v_total + coalesce(k.base_mt, 0)); v_vis := v_vis + coalesce(k.base_visitas, 0);
  -- selos por promoção
  for pr in select * from menu_promos_activas() loop
    select coalesce(sum(l.qtd), 0) into v_cont from menu_pedidos p join menu_linhas l on l.pedido = p.id
      where p.cliente = p_cliente and p.t2 is not null and p.anulado_motivo = '' and not l.indisponivel
        and (pr.ini is null or p.data_op >= pr.ini) and (pr.fim is null or p.data_op <= pr.fim)
        and (l.item_id = any(pr.ids) or menu_norm(l.nome) = any(pr.nomes) or exists (select 1 from unnest(pr.prefixos) f where menu_norm(l.nome) like f || '%') or menu_norm(l.categoria) = any(pr.cats));
    v_tot := v_cont + coalesce((k.base_carimbos ->> pr.id)::numeric, 0);
    for n in 1 .. least(floor(v_tot / pr.qtd)::int, 500) loop
      v_ch := 'p:' || pr.id || ':' || n;
      if not exists (select 1 from menu_brindes_entregues b where b.cliente = p_cliente and b.chave = v_ch) then
        v_disp := v_disp || jsonb_build_object('chave', v_ch, 'brinde', pr.brinde, 'brinde_en', pr.brinde_en, 'promo', pr.nome);
      end if;
    end loop;
    if pr.a_vista then
      v_lista := v_lista || jsonb_build_object('id', pr.id, 'nome', pr.nome, 'nome_en', pr.nome_en, 'qtd', pr.qtd, 'brinde', pr.brinde, 'brinde_en', pr.brinde_en,
        'carimbos', (v_tot::int % pr.qtd), 'total', v_tot);
    end if;
  end loop;
  -- escalões por valor (só com fid_pontos_por_valor = sim)
  v_esc := menu_escaloes();
  if jsonb_array_length(v_esc) > 0 then
    v_ciclo := (v_esc -> -1 ->> 'limiar')::numeric; v_k := floor(v_total / v_ciclo); v_r := v_total - v_k * v_ciclo;
    for n in 1 .. least(v_k, 100) loop
      for e in select * from jsonb_array_elements(v_esc) loop
        v_ganhos := v_ganhos + 1; v_ch := n || ':' || (e ->> 'limiar');
        if not exists (select 1 from menu_brindes_entregues b where b.cliente = p_cliente and b.chave = v_ch) then v_disp := jsonb_build_object('chave', v_ch, 'brinde', e ->> 'brinde') || '{}' || v_disp; end if;
      end loop;
    end loop;
    for e in select * from jsonb_array_elements(v_esc) loop
      if (e ->> 'limiar')::numeric <= v_r then
        v_ganhos := v_ganhos + 1; v_ch := (v_k + 1) || ':' || (e ->> 'limiar');
        if not exists (select 1 from menu_brindes_entregues b where b.cliente = p_cliente and b.chave = v_ch) then v_disp := v_disp || jsonb_build_object('chave', v_ch, 'brinde', e ->> 'brinde'); end if;
      elsif v_prox is null then v_prox := jsonb_build_object('brinde', e ->> 'brinde', 'falta', (e ->> 'limiar')::numeric - v_r, 'limiar', (e ->> 'limiar')::numeric);
      end if;
    end loop;
  end if;
  -- aniversário: no mês de anos, uma vez por ano, com pelo menos uma visita
  v_brA := btrim(menu_cfg('brinde_aniversario')); v_an := menu_aniv(k.aniversario);
  if v_an is not null and v_brA <> '' and v_an[2] = extract(month from menu_local())::int and v_vis >= 1 then
    v_ch := 'aniv:' || extract(year from menu_local())::int;
    if not exists (select 1 from menu_brindes_entregues b where b.cliente = p_cliente and b.chave = v_ch) then v_disp := v_disp || jsonb_build_object('chave', v_ch, 'brinde', 'Aniversário: ' || v_brA); end if;
  end if;
  return jsonb_build_object('total', v_total, 'visitas', v_vis, 'ultima', v_ult, 'ganhos', v_ganhos, 'disponiveis', v_disp, 'proximo', v_prox,
    'ciclo', v_ciclo, 'noCiclo', v_r, 'promos', v_lista, 'escaloes', v_esc);
end $$;

create or replace function menu_cartao_de(p_cliente uuid) returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare c clientes; k menu_cartao; b jsonb;
begin
  select * into c from clientes where id = p_cliente; select * into k from menu_cartao where cliente_id = p_cliente;
  if c.id is null or k.cliente_id is null then raise exception 'Cartão não encontrado'; end if;
  b := menu_brindes_de(p_cliente);
  return jsonb_build_object('nome', menu_primeiro(c.nome), 'total', b->'total', 'visitas', b->'visitas', 'disponiveis', b->'disponiveis', 'proximo', b->'proximo',
    'escaloes', b->'escaloes', 'ciclo', b->'ciclo', 'noCiclo', b->'noCiclo', 'promos', b->'promos', 'aceita', k.aceita_whatsapp);
end $$;

create or replace function menu_associar(p_cliente uuid, p_mesa text, p_visita text) returns int language sql security definer set search_path = public, extensions as $$
  with u as (update menu_pedidos set cliente = p_cliente where mesa = p_mesa and visita = p_visita and cliente is null returning 1) select count(*)::int from u;
$$;
create or replace function menu_garcom_visita(p_mesa text, p_visita text) returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select case when s.id is null then null else jsonb_build_object('id', s.id, 'nome', menu_primeiro(s.nome)) end
  from (select coalesce((select coalesce(g1, g2) from menu_pedidos where mesa = p_mesa and visita = p_visita and anulado_motivo = '' and coalesce(g1, g2) is not null
                         group by coalesce(g1, g2) order by count(*) desc limit 1), (select garcom from menu_mesas where id = p_mesa)) gid) x
  left join staff s on s.id = x.gid;
$$;

-- ---------------------------------------------------------------- cliente: pedidos, chamadas, cartão
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
      menu_txt(l->>'nota', 200));
  end loop;
  for s in select * from jsonb_array_elements(coalesce(p_sug, '[]')) loop
    insert into menu_sugestoes (pedido, mesa, tipo, origem, item, aceite) values (v_id, m.id, s->>'tipo', coalesce(s->>'origem', ''), s->>'item', coalesce((s->>'aceite')::boolean, false));
  end loop;
  return jsonb_build_object('id', v_id, 't0', now());
end $$;

create or replace function menu_chamar_garcom(p_codigo text, p_motivo text, p_pessoas text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare m menu_mesas; ab menu_chamadas; v_id text;
begin
  m := menu_mesa(p_codigo);
  select * into ab from menu_chamadas where mesa = m.id and c1 is null and c0 > now() - interval '3 minutes' limit 1;
  if ab.id is not null then return jsonb_build_object('id', ab.id, 'repetida', true); end if;
  v_id := menu_novo_id('C');
  insert into menu_chamadas (id, data_op, mesa, motivo, pessoas) values (v_id, menu_data_op(), m.id, menu_txt(p_motivo, 60), coalesce(p_pessoas, ''));
  return jsonb_build_object('id', v_id);
end $$;

create or replace function menu_estado_mesa(p_codigo text, p_visita text) returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare m menu_mesas; s menu_supervisor;
begin
  m := menu_mesa(p_codigo);
  select * into s from menu_supervisor where mesa = m.id and visita = p_visita order by c0 desc limit 1;
  return jsonb_build_object('mesa', jsonb_build_object('id', m.id, 'nome', m.nome, 'zona', m.zona),
    'pedidos', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 't0', p.t0, 't1', p.t1, 't2', p.t2, 't3', p.t3, 'total', p.total, 'estado', p.estado,
        'linhas', (select coalesce(jsonb_agg(jsonb_build_object('item', l.item_id, 'nome', l.nome, 'qtd', l.qtd, 'indisponivel', l.indisponivel) order by l.id), '[]') from menu_linhas l where l.pedido = p.id)) order by p.t0), '[]')
      from menu_pedidos p where p.mesa = m.id and p.visita = p_visita and p.anulado_motivo = ''),
    'chamadas', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'motivo', c.motivo, 'c0', c.c0, 'aceite', c.aceite)), '[]') from menu_chamadas c where c.mesa = m.id and c.c1 is null),
    'supervisor', case when s.id is null then null else jsonb_build_object('id', s.id, 'c0', s.c0, 'aceite', coalesce(s.aceite::text, ''), 'c1', coalesce(s.c1::text, '')) end,
    'avaliada', exists (select 1 from menu_avaliacoes a where a.mesa = m.id and a.visita = p_visita));
end $$;

create or replace function menu_fid_registar(d jsonb, p_codigo text, p_visita text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_nome text; v_dig text; v_tel text; v_email text; v_aceita boolean; v_an int[]; v_tok text; v_h text; c clientes; k menu_cartao; v_id uuid; m menu_mesas;
begin
  d := coalesce(d, '{}');
  v_nome := left(regexp_replace(menu_txt(d->>'nome', 200), '\s+', ' ', 'g'), 60);
  v_email := lower(left(menu_txt(d->>'email', 200), 80)); v_aceita := coalesce((d->>'aceita')::boolean, false);
  if length(v_nome) < 2 then raise exception 'Escreva o seu nome.'; end if;
  v_dig := regexp_replace(coalesce(d->>'celular', ''), '\D', '', 'g'); if v_dig like '00%' then v_dig := substr(v_dig, 3); end if;
  if length(v_dig) = 9 and v_dig ~ '^8[2-7]' then v_dig := '258' || v_dig; end if;
  if length(v_dig) < 11 or length(v_dig) > 15 then raise exception 'Número de celular inválido. Ex.: 84 123 4567'; end if;
  v_tel := '+' || v_dig;
  if v_email <> '' and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Email inválido.'; end if;
  v_an := menu_aniv(d->>'aniversario'); if coalesce(d->>'aniversario', '') <> '' and v_an is null then raise exception 'Dia de anos inválido.'; end if;
  v_tok := md5(random()::text || clock_timestamp()::text) || substr(md5(random()::text), 1, 12); v_h := menu_hash(v_tok);
  select * into c from clientes where telemovel = v_tel;
  if c.id is not null then
    if menu_norm(menu_primeiro(c.nome)) <> menu_norm(menu_primeiro(v_nome)) then raise exception 'Este número já está registado com outro nome. Peça ajuda ao garçom.'; end if;
    v_id := c.id;
    if v_email <> '' and c.email is null then update clientes set email = v_email, actualizado_em = now() where id = v_id; end if;
    update clientes set etiquetas = array(select distinct unnest(etiquetas || '{cartao_requinte}')) where id = v_id;
  else
    insert into clientes (telemovel, nome, email, etiquetas) values (v_tel, v_nome, nullif(v_email, ''), '{cartao_requinte}') returning id into v_id;
  end if;
  insert into menu_cartao (cliente_id, token_hashes, aceita_whatsapp, aniversario) values (v_id, array[v_h], v_aceita, menu_aniv_txt(v_an))
  on conflict (cliente_id) do update set token_hashes = (select array_agg(x) from (select x from unnest(menu_cartao.token_hashes || v_h) with ordinality t(x, o) order by o desc limit 3) z),
    aceita_whatsapp = excluded.aceita_whatsapp, activo = true,
    aniversario = case when menu_aniv(menu_cartao.aniversario) is null then excluded.aniversario else menu_cartao.aniversario end;
  insert into consentimentos (cliente_id, canal, concedido, recolhido_via) values (v_id, 'whatsapp', v_aceita, 'cartao_requinte');
  if coalesce(p_codigo, '') <> '' and coalesce(p_visita, '') <> '' then
    begin m := menu_mesa(p_codigo); perform menu_associar(v_id, m.id, p_visita); exception when others then null; end;
  end if;
  return jsonb_build_object('token', v_tok, 'cartao', menu_cartao_de(v_id));
end $$;

create or replace function menu_fid_cartao(p_tok text) returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select case when menu_cliente_por_token(p_tok) is null then null else menu_cartao_de(menu_cliente_por_token(p_tok)) end;
$$;

create or replace function menu_fid_conta(p_codigo text, p_visita text, p_tok text, p_pessoas text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare m menu_mesas; v_c uuid; ab menu_chamadas; v_id text; v_rep boolean := false; v_cartao jsonb;
begin
  m := menu_mesa(p_codigo); v_c := menu_cliente_por_token(p_tok);
  if v_c is not null then perform menu_associar(v_c, m.id, p_visita); end if;
  select * into ab from menu_chamadas where mesa = m.id and c1 is null and motivo = 'Conta' limit 1;
  if ab.id is not null then
    v_id := ab.id; v_rep := true;
    if v_c is not null and ab.cliente is null then update menu_chamadas set cliente = v_c where id = ab.id; end if;
  else
    v_id := menu_novo_id('C');
    insert into menu_chamadas (id, data_op, mesa, motivo, pessoas, cliente) values (v_id, menu_data_op(), m.id, 'Conta', coalesce(p_pessoas, ''), v_c);
  end if;
  if v_c is not null then v_cartao := menu_cartao_de(v_c); end if;
  return jsonb_build_object('id', v_id, 'repetida', v_rep, 'garcom', menu_garcom_visita(m.id, p_visita), 'cartao', v_cartao);
end $$;

create or replace function menu_fid_avaliar(p_codigo text, p_visita text, d jsonb) returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare m menu_mesas; v_est int; v_g jsonb; v_op text[] := array['sim', 'razoavel', 'nao', 'rapido', 'aceitavel', 'demorado'];
begin
  m := menu_mesa(p_codigo); d := coalesce(d, '{}');
  v_est := greatest(0, least(5, round(coalesce(nullif(d->>'estrelas', '')::numeric, 0))))::int; v_g := menu_garcom_visita(m.id, p_visita);
  insert into menu_avaliacoes (id, data_op, mesa, visita, garcom, estrelas_garcom, comida, espera, comentario, cliente)
  values (menu_novo_id('A'), menu_data_op(), m.id, p_visita, (v_g->>'id')::uuid, nullif(v_est, 0),
    case when d->>'comida' = any(v_op) then d->>'comida' else '' end, case when d->>'espera' = any(v_op) then d->>'espera' else '' end,
    menu_txt(d->>'comentario', 500), menu_cliente_por_token(d->>'token'))
  on conflict (mesa, visita) do update set data_op = excluded.data_op, quando = now(), garcom = excluded.garcom, estrelas_garcom = excluded.estrelas_garcom,
    comida = excluded.comida, espera = excluded.espera, comentario = excluded.comentario, cliente = excluded.cliente;
  return true;
end $$;

create or replace function menu_fid_chamar_supervisor(p_codigo text, p_visita text, p_texto text, p_tok text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare m menu_mesas; ab menu_supervisor; v_id text;
begin
  m := menu_mesa(p_codigo);
  select * into ab from menu_supervisor where mesa = m.id and c1 is null limit 1;
  if ab.id is not null then return jsonb_build_object('id', ab.id, 'repetida', true); end if;
  v_id := menu_novo_id('S');
  insert into menu_supervisor (id, data_op, mesa, visita, texto, cliente) values (v_id, menu_data_op(), m.id, coalesce(p_visita, ''), menu_txt(p_texto, 500), menu_cliente_por_token(p_tok));
  return jsonb_build_object('id', v_id);
end $$;

-- ---------------------------------------------------------------- garçom
create or replace function menu_pedido_json(p menu_pedidos, com_linhas boolean default true) returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object('id', p.id, 'mesa', p.mesa, 't0', p.t0, 't1', p.t1, 't2', p.t2, 'g1', p.g1, 'g2', p.g2, 'caixa', p.caixa, 'reg_por', coalesce(p.reg_por::text, ''), 'total', p.total,
    'garcomMesa', coalesce((select garcom::text from menu_mesas where id = p.mesa), ''),
    'linhas', case when com_linhas then (select coalesce(jsonb_agg(jsonb_build_object('item', l.item_id, 'nome', l.nome, 'cat', l.categoria, 'qtd', l.qtd, 'variante', l.variante,
      'mods', l.modificadores, 'nota', l.nota, 'indisponivel', l.indisponivel, 'obs', menu_linha_obs(l), '_row', l.id) order by l.id), '[]') from menu_linhas l where l.pedido = p.id) else '[]'::jsonb end);
$$;
create or replace function menu_pendentes_para(p_uid uuid) returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'pedidos', (select coalesce(jsonb_agg(menu_pedido_json(p) order by p.t0), '[]') from menu_pedidos p left join menu_mesas m on m.id = p.mesa
      where p.anulado_motivo = '' and p.t3 is null and not (p.caixa and p.t2 is null) and not menu_central_esconde(p)
        and (case when p.g1 is not null then p.g1 = p_uid else (m.garcom = p_uid or m.garcom is null or menu_mins(p.t0) > menu_cfg_num('limite_aceitar_min', 2)) end)),
    'chamadas', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'mesa', c.mesa, 'motivo', c.motivo, 'c0', c.c0, 'aceite', c.aceite, 'g', c.g, 'garcomMesa', coalesce(m.garcom::text, '')) order by c.c0), '[]')
      from menu_chamadas c left join menu_mesas m on m.id = c.mesa
      where c.c1 is null and (case when c.g is not null then c.g = p_uid else (m.garcom = p_uid or m.garcom is null or menu_mins(c.c0) > menu_cfg_num('limite_aceitar_min', 2)) end)));
$$;
create or replace function menu_sup_abertas() returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'mesa', s.mesa, 'texto', s.texto, 'c0', s.c0, 'aceite', coalesce(s.aceite::text, ''), 'por', coalesce(s.por::text, ''),
    'porNome', coalesce(menu_nome(s.por), ''), 'cliente', coalesce((select nome from clientes where id = s.cliente), '')) order by s.c0), '[]')
  from menu_supervisor s where s.c1 is null;
$$;
create or replace function menu_g_listar() returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare u staff;
begin
  u := menu_requer();
  return menu_pendentes_para(u.id) || jsonb_build_object('modo', case when menu_modo_central() then 'central' else 'garcom' end,
    'supervisor', case when u.menu_perfil in ('supervisor', 'gerente') then menu_sup_abertas() else '[]'::jsonb end,
    'ordemCategorias', menu_ordem_categorias(), 'user', menu_user_json(u), 'limites', menu_limites(), 'nomes', menu_nomes(),
    'minhasMesas', (select coalesce(jsonb_agg(id order by id), '[]') from menu_mesas where garcom = u.id),
    'mesas', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'zona', zona, 'codigo', codigo)), '[]') from menu_mesas where activa), 'agora', now());
end $$;
create or replace function menu_g_abrir(p_id text) returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare u staff;
begin
  u := menu_requer();
  update menu_pedidos set t1 = now(), g1 = u.id, estado = 'recebido' where id = p_id and t1 is null;
  if not found and not exists (select 1 from menu_pedidos where id = p_id) then raise exception 'Pedido não encontrado'; end if;
  return true;
end $$;
create or replace function menu_g_registado(p_id text) returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare u staff;
begin
  u := menu_requer();
  update menu_pedidos set t1 = coalesce(t1, now()), g1 = coalesce(g1, u.id), t2 = now(), g2 = u.id, estado = 'registado' where id = p_id;
  if not found then raise exception 'Pedido não encontrado'; end if;
  return true;
end $$;
create or replace function menu_g_indisponivel(p_pedido text, p_linha bigint) returns boolean language plpgsql security definer set search_path = public, extensions as $$
begin perform menu_requer(); update menu_linhas set indisponivel = true where id = p_linha and pedido = p_pedido; return true; end $$;
create or replace function menu_g_aceitar_chamada(p_id text) returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare u staff;
begin u := menu_requer(); update menu_chamadas set aceite = now(), g = u.id where id = p_id and aceite is null; return true; end $$;
-- Fecho na mesa: por NFC/QR (com_nfc) ou à mão. Pedidos registados passam a entregues; chamadas abertas a atendidas.
create or replace function menu_g_fechar_mesa(p_codigo_ou_id text, p_nfc boolean, p_apenas jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u staff; m menu_mesas; n1 int; n2 int; v_ap text[];
begin
  u := menu_requer();
  select * into m from menu_mesas where codigo = p_codigo_ou_id or id = p_codigo_ou_id limit 1;
  if m.id is null then raise exception 'Mesa não reconhecida'; end if;
  v_ap := case when p_apenas is null or jsonb_typeof(p_apenas) <> 'array' then null else array(select jsonb_array_elements_text(p_apenas)) end;
  update menu_pedidos set t3 = now(), g3 = u.id, nfc = case when p_nfc then 'sim' else 'nao' end, estado = 'entregue'
    where mesa = m.id and anulado_motivo = '' and t2 is not null and t3 is null and (v_ap is null or id = any(v_ap));
  get diagnostics n1 = row_count;
  update menu_chamadas set c1 = now(), g = coalesce(g, u.id), aceite = coalesce(aceite, now()), nfc = case when p_nfc then 'sim' else 'nao' end
    where mesa = m.id and c1 is null and (v_ap is null or id = any(v_ap));
  get diagnostics n2 = row_count;
  return jsonb_build_object('mesa', m.id, 'fechados', n1 + n2);
end $$;
create or replace function menu_g_passar(p_tipo text, p_id text, p_para uuid) returns boolean language plpgsql security definer set search_path = public, extensions as $$
begin
  perform menu_requer();
  if p_tipo = 'pedido' then update menu_pedidos set g1 = p_para, t1 = coalesce(t1, now()) where id = p_id;
  else update menu_chamadas set g = p_para, aceite = coalesce(aceite, now()) where id = p_id; end if;
  return true;
end $$;
create or replace function menu_g_anular(p_id text, p_motivo text, p_nova_mesa text) returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare u staff;
begin
  u := menu_requer();
  if p_motivo = 'mesa_errada' and coalesce(p_nova_mesa, '') <> '' then update menu_pedidos set mesa = p_nova_mesa where id = p_id; return true; end if;
  update menu_pedidos set anulado_motivo = coalesce(nullif(menu_txt(p_motivo, 60), ''), 'anulado'), anulado_por = u.id, estado = 'anulado' where id = p_id;
  return true;
end $$;
create or replace function menu_g_colegas() returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare u staff;
begin
  u := menu_requer();
  return (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'nome', s.nome) order by s.nome), '[]') from staff s
    where s.activo and s.menu_perfil = 'garcom' and s.id <> u.id and exists (select 1 from menu_turnos t where t.staff_id = s.id and t.saida is null));
end $$;

-- ---------------------------------------------------------------- relatórios
create or replace function menu_mediana(a numeric[]) returns numeric language sql immutable as $$
  select case when coalesce(array_length(a, 1), 0) = 0 then null else (select percentile_cont(0.5) within group (order by x) from unnest(a) x)::numeric end;
$$;
create or replace function menu_relatorio(p_ini date, p_fim date default null) returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_fim date := coalesce(p_fim, p_ini); v_lin jsonb;
begin
  with ped as (select * from menu_pedidos where data_op between p_ini and v_fim),
  ch as (select * from menu_chamadas where data_op between p_ini and v_fim),
  u as (select * from staff where menu_perfil in ('garcom', 'caixa', 'registo')),
  r as (
    select u.id, u.nome, u.menu_perfil perfil,
      (select count(*) from ped where g2 = u.id and anulado_motivo = '') pedidos,
      (select array_agg(extract(epoch from t2 - t0) / 60) from ped where g2 = u.id and anulado_motivo = '' and t2 is not null) d,
      (select array_agg(extract(epoch from t1 - t0) / 60) from ped where g2 = u.id and anulado_motivo = '' and t1 is not null) d1,
      (select array_agg(extract(epoch from t3 - t2) / 60) from ped where g3 = u.id and t3 is not null) d3,
      (select array_agg(extract(epoch from c1 - c0) / 60) from ch where g = u.id and c1 is not null) dc,
      (select count(*) from ch where g = u.id and c1 is not null) chamadas,
      (select count(*) from ped where g3 = u.id and nfc = 'nao') + (select count(*) from ch where g = u.id and c1 is not null and nfc = 'nao') sem_nfc,
      (select count(*) from ped p join menu_mesas m on m.id = p.mesa where p.g2 = u.id and p.anulado_motivo = '' and m.garcom is not null and m.garcom <> u.id)
        + (select count(*) from ch c join menu_mesas m on m.id = c.mesa where c.g = u.id and c.c1 is not null and m.garcom is not null and m.garcom <> u.id) de_colegas,
      (select count(*) from menu_sugestoes s join ped p on p.id = s.pedido where p.g2 = u.id and p.anulado_motivo = '') sug_m,
      (select count(*) from menu_sugestoes s join ped p on p.id = s.pedido where p.g2 = u.id and p.anulado_motivo = '' and s.aceite) sug_a,
      (select coalesce(sum(extract(epoch from saida - entrada) / 3600), 0) from menu_turnos t where t.staff_id = u.id and t.data between p_ini and v_fim and t.saida is not null) horas
    from u)
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'perfil', perfil, 'pedidos', pedidos, 't2t0_med', menu_mediana(d),
    't2t0_max', (select max(x) from unnest(d) x), 't2t0_fora', (select count(*) from unnest(d) x where x > menu_cfg_num('limite_registar_min', 5)),
    't1t0_med', menu_mediana(d1), 't3t2_med', menu_mediana(d3), 'chamadas', chamadas, 'c1c0_med', menu_mediana(dc),
    'c1c0_fora', (select count(*) from unnest(dc) x where x > menu_cfg_num('limite_chamada_min', 3)), 'semNfc', sem_nfc, 'deColegas', de_colegas,
    'sugMostradas', sug_m, 'sugAceites', sug_a, 'horas', round(horas::numeric, 1)) order by nome), '[]') into v_lin from r;
  return jsonb_build_object('periodo', jsonb_build_array(p_ini, v_fim), 'linhas', v_lin, 'totais', jsonb_build_object(
    'pedidos', (select count(*) from menu_pedidos where data_op between p_ini and v_fim and anulado_motivo = ''),
    'anulados', (select count(*) from menu_pedidos where data_op between p_ini and v_fim and anulado_motivo <> ''),
    'chamadas', (select count(*) from menu_chamadas where data_op between p_ini and v_fim),
    't2t0_med', menu_mediana((select array_agg(extract(epoch from t2 - t0) / 60) from menu_pedidos where data_op between p_ini and v_fim and t2 is not null and anulado_motivo = ''))));
end $$;

-- ---------------------------------------------------------------- balcão (caixa, supervisor)
create or replace function menu_fid_balcao() returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_contas jsonb := '{}'; x record; b jsonb;
begin
  for x in select c.id cid, k.cliente_id, cl.nome, cl.telemovel from menu_chamadas c join menu_cartao k on k.cliente_id = c.cliente join clientes cl on cl.id = c.cliente
           where c.c1 is null and c.motivo = 'Conta' loop
    b := menu_brindes_de(x.cliente_id);
    v_contas := v_contas || jsonb_build_object(x.cid, jsonb_build_object('id', x.cliente_id, 'nome', x.nome, 'celular', x.telemovel, 'total', b->'total', 'visitas', b->'visitas',
      'disponiveis', b->'disponiveis', 'proximo', b->'proximo', 'promos', b->'promos'));
  end loop;
  return jsonb_build_object('supervisor', menu_sup_abertas(), 'contas', v_contas);
end $$;
create or replace function menu_b_estado() returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare u staff;
begin
  u := menu_requer(array['caixa', 'supervisor', 'garcom', 'registo']);
  return jsonb_build_object('user', menu_user_json(u), 'limites', menu_limites(),
    'mesas', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'zona', zona, 'garcom', coalesce(garcom::text, '')) order by (case when nome ~ '^\d+$' then nome::int else 99999 end), nome), '[]') from menu_mesas where activa),
    'emTurno', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'nome', s.nome, 'entrada', t.entrada, 'turnoId', t.id, 'perfil', s.menu_perfil) order by s.nome), '[]')
      from menu_turnos t join staff s on s.id = t.staff_id where t.saida is null),
    'nomes', menu_nomes(),
    'pedidos', (select coalesce(jsonb_agg(menu_pedido_json(p, false) || jsonb_build_object('n', (select coalesce(sum(qtd), 0) from menu_linhas where pedido = p.id)) order by p.t0), '[]')
      from menu_pedidos p where p.anulado_motivo = '' and p.t3 is null),
    'chamadas', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'mesa', mesa, 'motivo', motivo, 'c0', c0, 'aceite', aceite, 'g', g) order by c0), '[]') from menu_chamadas where c1 is null),
    'agora', now(), 'relatorio', menu_relatorio(menu_data_op()), 'fid', menu_fid_balcao());
end $$;
create or replace function menu_b_atribuir_lote(p_pares jsonb) returns int language plpgsql security definer set search_path = public, extensions as $$
declare x jsonb; n int := 0;
begin
  perform menu_requer(array['caixa', 'supervisor']);
  for x in select * from jsonb_array_elements(coalesce(p_pares, '[]')) loop
    update menu_mesas set garcom = nullif(x->>1, '')::uuid where id = x->>0; n := n + 1;
  end loop;
  return n;
end $$;
create or replace function menu_b_atribuir(p_mesas jsonb, p_uid text) returns boolean language plpgsql security definer set search_path = public, extensions as $$
begin
  perform menu_requer(array['caixa', 'supervisor']);
  update menu_mesas set garcom = nullif(p_uid, '')::uuid where id in (select jsonb_array_elements_text(p_mesas));
  return true;
end $$;
create or replace function menu_b_vou_registar(p_id text) returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare u staff; p menu_pedidos;
begin
  u := menu_requer(array['caixa', 'supervisor']);
  select * into p from menu_pedidos where id = p_id for update;
  if p.id is null then raise exception 'Pedido não encontrado'; end if;
  if p.t2 is not null then raise exception 'Este pedido já foi registado'; end if;
  if p.reg_por is not null and p.reg_por <> u.id and p.r0 > now() - interval '10 minutes' then raise exception 'Já está a ser registado por %', coalesce(menu_nome(p.reg_por), 'outra pessoa'); end if;
  update menu_pedidos set caixa = true, t1 = coalesce(t1, now()), g1 = coalesce(g1, u.id), reg_por = u.id, r0 = now() where id = p_id;
  return true;
end $$;
create or replace function menu_b_registado_caixa(p_id text) returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare u staff;
begin u := menu_requer(array['caixa', 'supervisor']); update menu_pedidos set t2 = now(), g2 = u.id, estado = 'registado' where id = p_id; return true; end $$;
create or replace function menu_b_turno(p_uid uuid, p_accao text) returns boolean language plpgsql security definer set search_path = public, extensions as $$
begin
  perform menu_requer(array['caixa', 'supervisor']);
  if p_accao = 'entrar' then perform menu_entrar_turno(p_uid); else perform menu_sair_turno(p_uid); end if;
  return true;
end $$;
create or replace function menu_b_utilizadores() returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform menu_requer(array['caixa', 'supervisor']);
  return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'perfil', menu_perfil) order by nome), '[]') from staff where activo and menu_perfil is not null);
end $$;
create or replace function menu_corrigir_turno(p_id text, p_entrada timestamptz, p_saida timestamptz, p_nota text) returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare u staff;
begin
  u := menu_requer(array['supervisor']);
  update menu_turnos set entrada = coalesce(p_entrada, entrada), saida = coalesce(p_saida, saida), corrigido_por = u.id, nota = coalesce(menu_txt(p_nota, 200), '') where id = p_id;
  if not found then raise exception 'Turno não encontrado'; end if;
  return true;
end $$;
create or replace function menu_fechar_turno_geral() returns boolean language plpgsql security definer set search_path = public, extensions as $$
begin perform menu_requer(array['supervisor']); update menu_turnos set saida = now(), nota = 'fechado pelo supervisor' where saida is null; return true; end $$;

-- ---------------------------------------------------------------- registo central
create or replace function menu_r_fila() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u staff; v_hoje date := menu_data_op();
begin
  u := menu_requer(array['registo', 'caixa', 'supervisor']);
  insert into menu_presenca (staff_id, visto_em) values (u.id, now()) on conflict (staff_id) do update set visto_em = now();
  return jsonb_build_object('user', menu_user_json(u), 'modo', case when menu_modo_central() then 'central' else 'garcom' end,
    'limites', jsonb_build_object('aceitar', menu_cfg_num('limite_aceitar_min', 2), 'registar', menu_cfg_num('limite_registar_min', 5)),
    'fila', (select coalesce(jsonb_agg(menu_pedido_json(p) || jsonb_build_object('mesaNome', coalesce(m.nome, p.mesa), 'regPor', coalesce(p.reg_por::text, ''),
        'regNome', coalesce(menu_nome(p.reg_por), ''), 'r0', p.r0, 'cliente', coalesce(p.cliente::text, '')) order by p.t0), '[]')
      from menu_pedidos p left join menu_mesas m on m.id = p.mesa where p.data_op = v_hoje and p.anulado_motivo = '' and p.t2 is null),
    'garcons', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'nome', s.nome, 'emTurno', exists (select 1 from menu_turnos t where t.staff_id = s.id and t.saida is null))
        order by exists (select 1 from menu_turnos t where t.staff_id = s.id and t.saida is null) desc, s.nome), '[]') from staff s where s.activo and s.menu_perfil = 'garcom'),
    'nomes', menu_nomes(), 'ordemCategorias', menu_ordem_categorias(), 'registadores', menu_registadores(),
    'meusHoje', (select count(*) from menu_pedidos where data_op = v_hoje and anulado_motivo = '' and t2 is not null and g2 = u.id), 'agora', now());
end $$;
create or replace function menu_r_assumir(p_id text) returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare u staff; p menu_pedidos;
begin
  u := menu_requer(array['registo', 'caixa', 'supervisor']);
  select * into p from menu_pedidos where id = p_id for update;
  if p.id is null then raise exception 'Pedido não encontrado'; end if;
  if p.anulado_motivo <> '' then raise exception 'Este pedido foi anulado'; end if;
  if p.t2 is not null then raise exception 'Este pedido já foi registado'; end if;
  if p.reg_por is not null and p.reg_por <> u.id and p.r0 > now() - interval '10 minutes' then raise exception 'Já está a ser registado por %', coalesce(menu_nome(p.reg_por), 'outra pessoa'); end if;
  update menu_pedidos set reg_por = u.id, r0 = now(), t1 = coalesce(t1, now()), estado = 'recebido' where id = p_id;
  return true;
end $$;
create or replace function menu_r_largar(p_id text) returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare u staff;
begin u := menu_requer(array['registo', 'caixa', 'supervisor']); update menu_pedidos set reg_por = null, r0 = null where id = p_id and reg_por = u.id and t2 is null; return true; end $$;
create or replace function menu_r_registado(p_id text, p_garcom text, p_confirmadas int) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u staff; p menu_pedidos; v_obs int; v_g uuid; v_mesa_g uuid;
begin
  u := menu_requer(array['registo', 'caixa', 'supervisor']);
  select * into p from menu_pedidos where id = p_id for update;
  if p.id is null then raise exception 'Pedido não encontrado'; end if;
  if p.anulado_motivo <> '' then raise exception 'Este pedido foi anulado'; end if;
  if p.t2 is not null then return jsonb_build_object('ja', true); end if;
  select count(*) into v_obs from menu_linhas l where l.pedido = p.id and not l.indisponivel and menu_linha_obs(l);
  if coalesce(p_confirmadas, 0) < v_obs then raise exception 'Marque primeiro todas as linhas com observações (%)', v_obs; end if;
  select garcom into v_mesa_g from menu_mesas where id = p.mesa;
  v_g := coalesce(nullif(p_garcom, '')::uuid, v_mesa_g);
  if v_g is null then raise exception 'Escolha o garçom a quem atribuiu o ticket'; end if;
  if v_mesa_g is null then update menu_mesas set garcom = v_g where id = p.mesa; end if;
  update menu_pedidos set reg_por = coalesce(reg_por, u.id), r0 = coalesce(r0, now()), t1 = coalesce(t1, now()), g1 = v_g, t2 = now(), g2 = u.id, caixa = true, estado = 'registado' where id = p_id;
  return jsonb_build_object('ok', true, 'garcom', v_g);
end $$;

-- ---------------------------------------------------------------- Cartão Requinte: equipa
create or replace function menu_fid_sup_aceitar(p_id text) returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare u staff;
begin
  u := menu_requer(array['supervisor', 'caixa']);
  update menu_supervisor set aceite = now(), por = u.id where id = p_id and aceite is null;
  if not exists (select 1 from menu_supervisor where id = p_id) then raise exception 'Chamada não encontrada'; end if;
  return true;
end $$;
create or replace function menu_fid_sup_resolver(p_id text, p_resolucao text) returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare u staff;
begin
  u := menu_requer(array['supervisor', 'caixa']);
  update menu_supervisor set c1 = now(), aceite = coalesce(aceite, now()), por = coalesce(por, u.id), resolucao = menu_txt(p_resolucao, 500) where id = p_id;
  if not found then raise exception 'Chamada não encontrada'; end if;
  return true;
end $$;
create or replace function menu_fid_entregar(p_cliente uuid, p_chave text, p_mesa text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u staff; b jsonb; g jsonb; c clientes;
begin
  u := menu_requer(array['caixa', 'supervisor']);
  select * into c from clientes where id = p_cliente; if c.id is null then raise exception 'Cliente não encontrado'; end if;
  perform pg_advisory_xact_lock(hashtext(p_cliente::text));
  b := menu_brindes_de(p_cliente);
  select x into g from jsonb_array_elements(b->'disponiveis') x where x->>'chave' = p_chave limit 1;
  if g is null then raise exception 'Este brinde já foi entregue ou ainda não está disponível.'; end if;
  insert into menu_brindes_entregues (id, cliente, chave, brinde, por, mesa) values (menu_novo_id('B'), p_cliente, p_chave, g->>'brinde', u.id, coalesce(p_mesa, ''));
  return jsonb_build_object('brinde', g->>'brinde', 'cliente', menu_primeiro(c.nome));
end $$;
create or replace function menu_fid_procurar(p_termo text) returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare q text := menu_norm(p_termo); dig text := regexp_replace(coalesce(p_termo, ''), '\D', '', 'g');
begin
  perform menu_requer(array['caixa', 'supervisor']);
  if length(dig) < 3 and (length(q) < 2 or q ~ '^\d+$') then return '[]'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'nome', c.nome, 'celular', c.telemovel, 'total', b->'total', 'visitas', b->'visitas',
      'disponiveis', b->'disponiveis', 'proximo', b->'proximo', 'promos', b->'promos')), '[]')
    from (select c.* from clientes c join menu_cartao k on k.cliente_id = c.id and k.activo
          where (length(dig) >= 3 and regexp_replace(c.telemovel, '\D', '', 'g') like '%' || dig || '%') or (q !~ '\d' and length(q) >= 2 and menu_norm(c.nome) like '%' || q || '%')
          limit 8) c, lateral (select menu_brindes_de(c.id) b) z);
end $$;
create or replace function menu_fid_gestao() returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v_desde date := menu_data_op() - 60;
begin
  perform menu_requer(array['supervisor']);
  return jsonb_build_object(
    'clientes', (select coalesce(jsonb_agg(x order by (x->>'total')::numeric desc), '[]') from (
      select jsonb_build_object('id', c.id, 'nome', c.nome, 'celular', c.telemovel, 'wa', regexp_replace(c.telemovel, '\D', '', 'g'), 'email', coalesce(c.email::text, ''),
        'aceita', k.aceita_whatsapp, 'registado', to_char(k.registado_em at time zone 'Africa/Maputo', 'YYYY-MM-DD'), 'total', b->'total', 'visitas', b->'visitas',
        'ultima', coalesce(b->>'ultima', ''), 'diasSem', case when b->>'ultima' is null then null else (menu_local()::date - (b->>'ultima')::date) end,
        'disponiveis', b->'disponiveis', 'proximo', b->'proximo', 'promos', b->'promos', 'ultimaMensagem', k.ultima_mensagem,
        'aniversario', menu_aniv_txt(menu_aniv(k.aniversario)), 'anosEsteMes', coalesce((menu_aniv(k.aniversario))[2] = extract(month from menu_local())::int, false)) x
      from menu_cartao k join clientes c on c.id = k.cliente_id, lateral (select menu_brindes_de(c.id) b) z where k.activo) y),
    'escaloes', menu_escaloes(), 'promos', menu_promos_publico(),
    'avaliacoes', jsonb_build_object(
      'resumo', (select coalesce(jsonb_agg(jsonb_build_object('garcom', coalesce(g::text, ''), 'nome', coalesce(menu_nome(g), 'sem garçom'), 'n', n,
          'media', case when ne > 0 then round(se / ne, 1) end, 'comida', case when nc > 0 then round(cs * 100.0 / nc) end, 'rapido', case when nsp > 0 then round(rp * 100.0 / nsp) end) order by n desc), '[]')
        from (select garcom g, count(*) n, sum(estrelas_garcom) se, count(estrelas_garcom) ne, count(*) filter (where comida <> '') nc, count(*) filter (where comida = 'sim') cs,
                count(*) filter (where espera <> '') nsp, count(*) filter (where espera = 'rapido') rp from menu_avaliacoes where data_op >= v_desde group by garcom) a),
      'ultimas', (select coalesce(jsonb_agg(jsonb_build_object('data', data_op, 'mesa', mesa, 'garcom', coalesce(menu_nome(garcom), ''), 'estrelas', estrelas_garcom, 'comida', comida, 'espera', espera, 'comentario', comentario) order by quando desc), '[]')
        from (select * from menu_avaliacoes where data_op >= v_desde order by quando desc limit 40) a)),
    'supervisor', (select coalesce(jsonb_agg(jsonb_build_object('data', data_op, 'c0', c0, 'mesa', mesa, 'texto', texto, 'aceite', coalesce(aceite::text, ''), 'c1', coalesce(c1::text, ''),
        'por', coalesce(menu_nome(por), ''), 'resolucao', resolucao) order by c0 desc), '[]') from (select * from menu_supervisor order by c0 desc limit 30) s),
    'textos', jsonb_build_object('brinde', menu_cfg('whatsapp_msg_brinde'), 'saudade', menu_cfg('whatsapp_msg_saudade'), 'geral', menu_cfg('whatsapp_msg_geral')),
    'diasSemVisita', menu_cfg_num('fid_dias_sem_visita', 30));
end $$;
create or replace function menu_fid_mensagem(p_cliente uuid, p_tipo text) returns boolean language plpgsql security definer set search_path = public, extensions as $$
begin
  perform menu_requer(array['supervisor']);
  update menu_cartao set ultima_mensagem = to_char(menu_local(), 'YYYY-MM-DD HH24:MI') || ', ' || menu_txt(p_tipo, 40) where cliente_id = p_cliente;
  if not found then raise exception 'Cliente não encontrado'; end if;
  return true;
end $$;

-- ---------------------------------------------------------------- gestão
create or replace function menu_sim(b boolean) returns text language sql immutable as $$ select case when b then 'sim' else 'nao' end; $$;
create or replace function menu_bool(v jsonb) returns boolean language sql immutable as $$
  select case when v is null or v = 'null'::jsonb then null when jsonb_typeof(v) = 'boolean' then (v)::text::boolean else lower(btrim(v #>> '{}')) in ('sim', 'true', '1', 's', 'yes') end;
$$;
create or replace function menu_gestao_dados() returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare u staff;
begin
  u := menu_requer(array['supervisor']);
  return jsonb_build_object('user', menu_user_json(u),
    'config', (select coalesce(jsonb_agg(jsonb_build_object('chave', chave, 'valor', valor, 'nota', nota, '_row', chave) order by chave), '[]') from menu_config),
    'mesas', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'zona', zona, 'codigo', coalesce(codigo, ''), 'activa', menu_sim(activa), 'garcom', coalesce(garcom::text, ''), '_row', id)
      order by (case when nome ~ '^\d+$' then nome::int else 99999 end), nome), '[]') from menu_mesas),
    'destaques', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'tipo', tipo, 'titulo', titulo, 'texto', texto, 'titulo_en', titulo_en, 'texto_en', texto_en, 'item', item, 'item_id', item_id,
      'inicio', coalesce(inicio::text, ''), 'fim', coalesce(fim::text, ''), 'dias_semana', dias_semana, 'horario', horario, 'so_membros', menu_sim(so_membros), 'activo', menu_sim(activo), '_row', id) order by id), '[]') from menu_destaques),
    'regras', (select coalesce(jsonb_agg(to_jsonb(r) || jsonb_build_object('_row', r.id) order by r.artigo), '[]') from menu_regras r),
    'promocoes', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'artigos', artigos, 'categorias', categorias, 'quantidade', quantidade, 'brinde', brinde,
      'nome_en', nome_en, 'brinde_en', brinde_en, 'inicio', coalesce(inicio::text, ''), 'fim', coalesce(fim::text, ''), 'activo', menu_sim(activo), '_row', id) order by id), '[]') from menu_promocoes),
    'utilizadores', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'perfil', menu_perfil, 'activo', menu_sim(activo)) order by nome), '[]') from staff where menu_perfil is not null),
    'url', menu_cfg('url_app'), 'cache', (select count(*) from menu_artigos), 'ultimaSinc', (select max(sincronizado_em) from menu_artigos),
    'cruzamento', (select coalesce(jsonb_agg(to_jsonb(c) order by c.id), '[]') from (select * from menu_cruzamento order by id desc limit 50) c),
    'turnos', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'data', t.data, 'utilizador', t.staff_id, 'entrada', t.entrada, 'saida', t.saida, 'corrigido_por', t.corrigido_por, 'nota', t.nota) order by t.entrada), '[]')
      from (select * from menu_turnos order by entrada desc limit 100) t));
end $$;

-- Guardar uma linha a partir da página de gestão (folha = nome da antiga folha; row = chave da linha; vazio = nova)
create or replace function menu_gestao_guardar(p_folha text, p_row text, o jsonb) returns boolean language plpgsql security definer set search_path = public, extensions as $$
begin
  perform menu_requer(array['gerente']);
  o := coalesce(o, '{}');
  if p_folha = 'Config' then
    insert into menu_config (chave, valor, nota) values (coalesce(nullif(o->>'chave', ''), p_row), coalesce(o->>'valor', ''), coalesce(o->>'nota', ''))
    on conflict (chave) do update set valor = coalesce(o->>'valor', menu_config.valor), nota = coalesce(o->>'nota', menu_config.nota);
  elsif p_folha = 'Mesas' then
    if coalesce(p_row, '') = '' then insert into menu_mesas (id, nome, zona, codigo, activa) values (o->>'id', coalesce(o->>'nome', o->>'id'), coalesce(o->>'zona', ''), nullif(o->>'codigo', ''), coalesce(menu_bool(o->'activa'), true));
    else update menu_mesas set nome = coalesce(o->>'nome', nome), zona = coalesce(o->>'zona', zona), codigo = coalesce(nullif(o->>'codigo', ''), codigo), activa = coalesce(menu_bool(o->'activa'), activa) where id = p_row; end if;
  elsif p_folha = 'Destaques' then
    if coalesce(p_row, '') = '' then p_row := coalesce(nullif(o->>'id', ''), 'D' || substr(md5(random()::text), 1, 6)); insert into menu_destaques (id) values (p_row); end if;
    update menu_destaques set tipo = coalesce(o->>'tipo', tipo), titulo = coalesce(o->>'titulo', titulo), texto = coalesce(o->>'texto', texto), titulo_en = coalesce(o->>'titulo_en', titulo_en),
      texto_en = coalesce(o->>'texto_en', texto_en), item = coalesce(o->>'item', item), item_id = case when o ? 'item' then '' else item_id end,
      inicio = case when o ? 'inicio' then nullif(o->>'inicio', '')::date else inicio end, fim = case when o ? 'fim' then nullif(o->>'fim', '')::date else fim end,
      dias_semana = coalesce(o->>'dias_semana', dias_semana), horario = coalesce(o->>'horario', horario), so_membros = coalesce(menu_bool(o->'so_membros'), so_membros), activo = coalesce(menu_bool(o->'activo'), activo)
    where id = p_row;
  elsif p_folha = 'Regras' then
    if coalesce(p_row, '') = '' then p_row := 'R' || substr(md5(random()::text), 1, 6); insert into menu_regras (id) values (p_row); end if;
    update menu_regras set artigo = coalesce(o->>'artigo', artigo), sugestao_1 = coalesce(o->>'sugestao_1', sugestao_1), sugestao_2 = coalesce(o->>'sugestao_2', sugestao_2),
      sugestao_3 = coalesce(o->>'sugestao_3', sugestao_3), horario = coalesce(o->>'horario', horario) where id = p_row;
  elsif p_folha = 'Promocoes' then
    if coalesce(p_row, '') = '' then p_row := coalesce(nullif(o->>'id', ''), lower(regexp_replace(menu_norm(o->>'nome'), '[^a-z0-9]+', '_', 'g'))); insert into menu_promocoes (id, nome) values (p_row, coalesce(o->>'nome', p_row)); end if;
    update menu_promocoes set nome = coalesce(o->>'nome', nome), artigos = coalesce(o->>'artigos', artigos), categorias = coalesce(o->>'categorias', categorias),
      quantidade = coalesce(nullif(o->>'quantidade', '')::int, quantidade), brinde = coalesce(o->>'brinde', brinde), nome_en = coalesce(o->>'nome_en', nome_en), brinde_en = coalesce(o->>'brinde_en', brinde_en),
      inicio = case when o ? 'inicio' then nullif(o->>'inicio', '')::date else inicio end, fim = case when o ? 'fim' then nullif(o->>'fim', '')::date else fim end,
      activo = coalesce(menu_bool(o->'activo'), activo) where id = p_row;
  elsif p_folha = 'MenuExtra' then
    insert into menu_extra (item_id) values (p_row) on conflict do nothing;
    update menu_extra set descricao_pt = coalesce(o->>'descricao_pt', descricao_pt), descricao_en = coalesce(o->>'descricao_en', descricao_en), nome_en = coalesce(o->>'nome_en', nome_en),
      seccao = coalesce(o->>'seccao', seccao), seccao_en = coalesce(o->>'seccao_en', seccao_en), etiquetas = coalesce(o->>'etiquetas', etiquetas),
      ordem = case when o ? 'ordem' then nullif(o->>'ordem', '')::int else ordem end, oculto = coalesce(menu_bool(o->'oculto'), oculto), foto_url = coalesce(o->>'foto_url', foto_url)
    where item_id = p_row;
  elsif p_folha = 'Utilizadores' then
    update staff set menu_perfil = case when o ? 'perfil' then nullif(o->>'perfil', '') else menu_perfil end, activo = coalesce(menu_bool(o->'activo'), activo) where id = p_row::uuid;
  else raise exception 'Folha não editável';
  end if;
  if p_folha in ('Regras', 'Destaques', 'Config', 'Promocoes') then perform menu_sincronizar_referencias(); end if;
  return true;
end $$;
create or replace function menu_gestao_gerar_codigos() returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  perform menu_requer(array['gerente']);
  update menu_mesas set codigo = substr(replace(gen_random_uuid()::text, '-', ''), 1, 10) where codigo is null or codigo = '';
  return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'codigo', codigo, 'url', menu_cfg('url_app') || 'index.html?m=' || codigo) order by id), '[]') from menu_mesas);
end $$;
create or replace function menu_exportar(p_ini date, p_fim date) returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform menu_requer(array['supervisor']);
  return jsonb_build_object('relatorio', menu_relatorio(p_ini, p_fim),
    'pedidos', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'data', data_op, 'mesa', mesa, 't0', t0, 't1', t1, 'g1', menu_nome(g1), 't2', t2, 'g2', menu_nome(g2), 't3', t3, 'g3', menu_nome(g3),
      'nfc', nfc, 'caixa', menu_sim(caixa), 'estado', estado, 'anulado', anulado_motivo, 'total', total) order by t0), '[]') from menu_pedidos where data_op between p_ini and p_fim));
end $$;

-- ---------------------------------------------------------------- entrada única: para onde vai cada pessoa
create or replace function fn_meus_acessos() returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare s staff; v jsonb := '[]'; v_mesas boolean := false;
begin
  s := fn_eu(); if s.id is null then return null; end if;
  if s.menu_perfil = 'garcom' then v := v || '[{"id":"garcom","titulo":"Pedidos e chamadas","texto":"Telemóvel POS do garçom","url":"/menu-cnb/garcom.html"}]'; end if;
  if s.menu_perfil in ('caixa', 'supervisor', 'gerente') then v := v || '[{"id":"balcao","titulo":"Balcão","texto":"Mapa de mesas, contas e chamadas","url":"/menu-cnb/balcao.html"}]'; end if;
  if s.menu_perfil in ('registo', 'caixa', 'supervisor', 'gerente') then v := v || '[{"id":"registo","titulo":"Registo de pedidos","texto":"Lançar no Loyverse e atribuir ao garçom","url":"/menu-cnb/registo.html"}]'; end if;
  if s.menu_perfil in ('supervisor', 'gerente') then v := v || '[{"id":"garcom","titulo":"POS de sala","texto":"Vista do garçom, com as chamadas ao supervisor","url":"/menu-cnb/garcom.html"},{"id":"gestao","titulo":"Gestão do restaurante","texto":"Menu, mesas, relatórios e Cartão Requinte","url":"/menu-cnb/gestao.html"}]'; end if;
  if s.perfil is not null and s.perfil in ('admin', 'vendedor', 'comunicacao') then v := v || '[{"id":"bilhetes","titulo":"Bilhetes de eventos","texto":"Vendas, convites, clientes e campanhas","url":"/bilhetes/admin/"}]'; end if;
  if s.perfil is not null and s.perfil in ('admin', 'porta') then v := v || '[{"id":"porta","titulo":"Porta do evento","texto":"Validar bilhetes e pulseiras","url":"/bilhetes/porta/"}]'; end if;
  begin
    execute 'select exists (select 1 from mesas_utilizadores where lower(email) = lower($1))' into v_mesas using coalesce(s.email::text, '');
  exception when undefined_table then v_mesas := false; end;
  if v_mesas then v := v || '[{"id":"mesas","titulo":"Mesas do evento","texto":"Planta, grupos e alocação","url":"/bilhetes/mesas/"}]'; end if;
  return jsonb_build_object('nome', s.nome, 'menu_perfil', s.menu_perfil, 'acessos', (select coalesce(jsonb_agg(distinct_x), '[]') from (select distinct on (x->>'id') x distinct_x from jsonb_array_elements(v) with ordinality t(x, o) order by x->>'id', o) z));
end $$;
-- entrar em turno ao abrir a sessão pelo PIN (chamado pela função "entrar" e pela página de entrada)
create or replace function fn_entrada_turno() returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare s staff;
begin s := fn_eu(); if s.id is null or s.menu_perfil is null then return false; end if; perform menu_entrar_turno(s.id); return true; end $$;

-- ---------------------------------------------------------------- função única chamada pelas páginas
-- Mesmos nomes e argumentos do Apps Script. O token de sessão que as páginas antigas passavam em primeiro lugar é ignorado
-- (a identidade vem da sessão Supabase).
create or replace function menu_api(p_fn text, p_args jsonb default '[]') returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a jsonb := coalesce(p_args, '[]'); r jsonb;
begin
  r := case p_fn
    -- cliente (sem sessão)
    when 'menuPublico' then menu_publico()
    when 'mesaPorCodigo' then (select jsonb_build_object('id', m.id, 'nome', m.nome, 'zona', m.zona) from menu_mesa(a->>0) m)
    when 'enviarPedido' then menu_enviar_pedido(a->>0, a->>1, a->2, a->3, a->>4)
    when 'chamarGarcom' then menu_chamar_garcom(a->>0, a->>1, a->>2)
    when 'estadoMesaCliente' then menu_estado_mesa(a->>0, a->>1)
    when 'fidRegistar' then menu_fid_registar(a->0, a->>1, a->>2)
    when 'fidCartao' then menu_fid_cartao(a->>0)
    when 'fidConta' then menu_fid_conta(a->>0, a->>1, a->>2, a->>3)
    when 'fidAvaliar' then to_jsonb(menu_fid_avaliar(a->>0, a->>1, a->2))
    when 'fidChamarSupervisor' then menu_fid_chamar_supervisor(a->>0, a->>1, a->>2, a->>3)
    when 'listarNomes' then fn_entrada_nomes()
    -- equipa (o 1.º argumento era o token)
    when 'logout' then (select to_jsonb(true) from (select menu_sair_turno((fn_eu()).id)) x)
    when 'gListar' then menu_g_listar()
    when 'gAbrirPedido' then to_jsonb(menu_g_abrir(a->>1))
    when 'gRegistado' then to_jsonb(menu_g_registado(a->>1))
    when 'gIndisponivel' then to_jsonb(menu_g_indisponivel(a->>1, (a->>2)::bigint))
    when 'gAceitarChamada' then to_jsonb(menu_g_aceitar_chamada(a->>1))
    when 'gFecharMesa' then menu_g_fechar_mesa(a->>1, coalesce((a->>2)::boolean, false), a->3)
    when 'gPassar' then to_jsonb(menu_g_passar(a->>1, a->>2, (a->>3)::uuid))
    when 'gAnular' then to_jsonb(menu_g_anular(a->>1, a->>2, a->>3))
    when 'gColegas' then menu_g_colegas()
    when 'bEstado' then menu_b_estado()
    when 'bAtribuir' then to_jsonb(menu_b_atribuir(a->1, a->>2))
    when 'bAtribuirLote' then to_jsonb(menu_b_atribuir_lote(a->1))
    when 'bVouRegistar' then to_jsonb(menu_b_vou_registar(a->>1))
    when 'bRegistadoCaixa' then to_jsonb(menu_b_registado_caixa(a->>1))
    when 'bTurno' then to_jsonb(menu_b_turno((a->>1)::uuid, a->>2))
    when 'bListarUtilizadores' then menu_b_utilizadores()
    when 'corrigirTurno' then to_jsonb(menu_corrigir_turno(a->>1, nullif(a->>2, '')::timestamptz, nullif(a->>3, '')::timestamptz, a->>4))
    when 'fecharTurnoGeral' then to_jsonb(menu_fechar_turno_geral())
    when 'relatorioPeriodo' then (select menu_relatorio((a->>1)::date, (a->>2)::date) from (select menu_requer(array['supervisor'])) x)
    when 'exportarRelatorio' then menu_exportar((a->>1)::date, (a->>2)::date)
    when 'gestaoDados' then menu_gestao_dados()
    when 'gestaoGuardar' then to_jsonb(menu_gestao_guardar(a->>1, a->>2, a->3))
    when 'gestaoGerarCodigos' then menu_gestao_gerar_codigos()
    when 'rFila' then menu_r_fila()
    when 'rAssumir' then to_jsonb(menu_r_assumir(a->>1))
    when 'rLargar' then to_jsonb(menu_r_largar(a->>1))
    when 'rRegistado' then menu_r_registado(a->>1, a->>2, (a->>3)::int)
    when 'fidSupAceitar' then to_jsonb(menu_fid_sup_aceitar(a->>1))
    when 'fidSupResolver' then to_jsonb(menu_fid_sup_resolver(a->>1, a->>2))
    when 'fidEntregarBrinde' then menu_fid_entregar((a->>1)::uuid, a->>2, a->>3)
    when 'fidProcurar' then menu_fid_procurar(a->>1)
    when 'fidGestao' then menu_fid_gestao()
    when 'fidMensagemEnviada' then to_jsonb(menu_fid_mensagem((a->>1)::uuid, a->>2))
    else null end;
  if r is null and p_fn not in ('fidCartao', 'mesaPorCodigo') then
    if p_fn not in ('menuPublico','enviarPedido','chamarGarcom','estadoMesaCliente','fidRegistar','fidConta','fidAvaliar','fidChamarSupervisor','listarNomes','logout','gListar','gAbrirPedido','gRegistado','gIndisponivel','gAceitarChamada','gFecharMesa','gPassar','gAnular','gColegas','bEstado','bAtribuir','bAtribuirLote','bVouRegistar','bRegistadoCaixa','bTurno','bListarUtilizadores','corrigirTurno','fecharTurnoGeral','relatorioPeriodo','exportarRelatorio','gestaoDados','gestaoGuardar','gestaoGerarCodigos','rFila','rAssumir','rLargar','rRegistado','fidSupAceitar','fidSupResolver','fidEntregarBrinde','fidProcurar','fidGestao','fidMensagemEnviada') then
      raise exception 'Função não permitida: %', p_fn;
    end if;
  end if;
  return coalesce(r, 'null'::jsonb);
end $$;
