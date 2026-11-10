-- =============================================================================
-- Menu digital CNB: tabelas (substituem as folhas do Google Sheets)
-- Prefixo menu_ para não misturar com as tabelas dos bilhetes e das mesas de eventos.
-- A equipa é a tabela staff (0020). Os clientes do Cartão Requinte são os clientes dos bilhetes
-- (tabela clientes, pelo telemóvel), com os dados do cartão em menu_cartao.
-- =============================================================================

create table if not exists menu_config (
  chave text primary key,
  valor text not null default '',
  nota text not null default ''
);

create table if not exists menu_mesas (
  id text primary key,                         -- M1 ... M100
  nome text not null,
  zona text not null default '',
  codigo text unique,                          -- código do QR / NFC (as placas impressas usam estes códigos)
  activa boolean not null default true,
  garcom uuid references staff(id) on delete set null
);

-- Artigos lidos do Loyverse (antiga folha MenuCache)
create table if not exists menu_artigos (
  item_id text primary key,
  nome text not null,
  categoria text not null default '',
  categoria_id text not null default '',
  preco numeric not null default 0,
  sku text not null default '',
  variantes jsonb not null default '[]',
  modificadores jsonb not null default '[]',
  stock numeric,
  activo boolean not null default true,
  ordem_cat int not null default 0,            -- ordem da categoria no Loyverse (ordem de lançamento no POS)
  sincronizado_em timestamptz not null default now()
);

-- Dados próprios de cada artigo (antiga folha MenuExtra)
create table if not exists menu_extra (
  item_id text primary key,
  nome text not null default '',
  descricao_pt text not null default '',
  descricao_en text not null default '',
  nome_en text not null default '',
  seccao text not null default '',
  seccao_en text not null default '',
  etiquetas text not null default '',
  ordem int,
  oculto boolean not null default false,
  foto_url text not null default ''
);

create table if not exists menu_destaques (
  id text primary key default 'D' || substr(md5(random()::text), 1, 6),
  tipo text not null default 'chef',
  titulo text not null default '',
  texto text not null default '',
  titulo_en text not null default '',
  texto_en text not null default '',
  item text not null default '',
  item_id text not null default '',
  inicio date,
  fim date,
  dias_semana text not null default '',
  horario text not null default '',
  so_membros boolean not null default false,
  activo boolean not null default true
);

create table if not exists menu_regras (
  id text primary key default 'R' || substr(md5(random()::text), 1, 6),
  artigo text not null default '',
  artigo_id text not null default '',
  sugestao_1 text not null default '', sugestao_1_id text not null default '',
  sugestao_2 text not null default '', sugestao_2_id text not null default '',
  sugestao_3 text not null default '', sugestao_3_id text not null default '',
  horario text not null default ''
);

create table if not exists menu_turnos (
  id text primary key,
  data date not null,
  staff_id uuid not null references staff(id) on delete cascade,
  entrada timestamptz not null default now(),
  saida timestamptz,
  corrigido_por uuid references staff(id),
  nota text not null default ''
);
create index if not exists menu_turnos_abertos on menu_turnos (staff_id) where saida is null;

create table if not exists menu_pedidos (
  id text primary key,
  data_op date not null,
  mesa text not null references menu_mesas(id),
  visita text not null default '',
  t0 timestamptz not null default now(),
  t1 timestamptz, g1 uuid references staff(id),
  t2 timestamptz, g2 uuid references staff(id),
  t3 timestamptz, g3 uuid references staff(id),
  nfc text not null default '',
  caixa boolean not null default false,
  reg_por uuid references staff(id), r0 timestamptz,
  estado text not null default 'enviado',
  total numeric not null default 0,
  anulado_motivo text not null default '',
  anulado_por uuid references staff(id),
  cliente uuid references clientes(id)
);
create index if not exists menu_pedidos_abertos on menu_pedidos (data_op) where t3 is null and anulado_motivo = '';
create index if not exists menu_pedidos_mesa on menu_pedidos (mesa, visita);
create index if not exists menu_pedidos_cliente on menu_pedidos (cliente) where cliente is not null;

create table if not exists menu_linhas (
  id bigserial primary key,
  pedido text not null references menu_pedidos(id) on delete cascade,
  item_id text not null default '',
  nome text not null,
  categoria text not null default '',
  qtd numeric not null default 1,
  preco numeric not null default 0,
  variante text not null default '',
  modificadores text not null default '',
  nota text not null default '',
  indisponivel boolean not null default false
);
create index if not exists menu_linhas_pedido on menu_linhas (pedido);

create table if not exists menu_chamadas (
  id text primary key,
  data_op date not null,
  mesa text not null references menu_mesas(id),
  motivo text not null default '',
  c0 timestamptz not null default now(),
  aceite timestamptz,
  g uuid references staff(id),
  c1 timestamptz,
  nfc text not null default '',
  pessoas text not null default '',
  cliente uuid references clientes(id)
);
create index if not exists menu_chamadas_abertas on menu_chamadas (mesa) where c1 is null;

create table if not exists menu_sugestoes (
  id bigserial primary key,
  pedido text references menu_pedidos(id) on delete cascade,
  mesa text, tipo text, origem text, item text,
  mostrada_em timestamptz not null default now(),
  aceite boolean not null default false
);

create table if not exists menu_cruzamento (
  id bigserial primary key,
  data date not null,
  pedido text, mesa text, g2 uuid,
  recibo text not null default '', empregado_recibo text not null default '',
  resultado text not null default '', detalhe text not null default '',
  criado_em timestamptz not null default now()
);

-- ------------------------------------------------------------------ Cartão Requinte
create table if not exists menu_cartao (
  cliente_id uuid primary key references clientes(id) on delete cascade,
  token_hashes text[] not null default '{}',   -- últimos 3 telemóveis/navegadores ligados ao cartão
  aceita_whatsapp boolean not null default false,
  aniversario text not null default '',        -- DD/MM, não muda depois de registado
  registado_em timestamptz not null default now(),
  base_mt numeric not null default 0,          -- valores trazidos da folha (pedidos já arquivados)
  base_visitas int not null default 0,
  base_carimbos jsonb not null default '{}',
  ultima_mensagem text not null default '',
  notas text not null default '',
  activo boolean not null default true
);

create table if not exists menu_brindes (           -- escalões por valor gasto (desligados: fid_pontos_por_valor = nao)
  limiar_mt numeric primary key,
  brinde text not null,
  activo boolean not null default true
);

create table if not exists menu_promocoes (
  id text primary key,
  nome text not null,
  artigos text not null default '',              -- nomes do Loyverse separados por |; um * no fim apanha os que começam assim
  artigos_ids text not null default '',
  categorias text not null default '',
  quantidade int not null default 10,
  brinde text not null default '',
  nome_en text not null default '',
  brinde_en text not null default '',
  inicio date, fim date,
  activo boolean not null default true
);

create table if not exists menu_brindes_entregues (
  id text primary key,
  cliente uuid not null references clientes(id) on delete cascade,
  chave text not null,
  brinde text not null,
  entregue_em timestamptz not null default now(),
  por uuid references staff(id),
  mesa text not null default '',
  unique (cliente, chave)
);

create table if not exists menu_avaliacoes (
  id text primary key,
  data_op date not null,
  quando timestamptz not null default now(),
  mesa text not null, visita text not null,
  garcom uuid references staff(id),
  estrelas_garcom int, comida text not null default '', espera text not null default '',
  comentario text not null default '',
  cliente uuid references clientes(id),
  unique (mesa, visita)
);

create table if not exists menu_supervisor (
  id text primary key,
  data_op date not null,
  mesa text not null, visita text not null default '',
  motivo text not null default 'insatisfacao',
  texto text not null default '',
  cliente uuid references clientes(id),
  c0 timestamptz not null default now(),
  aceite timestamptz, por uuid references staff(id),
  c1 timestamptz, resolucao text not null default ''
);
