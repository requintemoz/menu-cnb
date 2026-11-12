(function () {
// Desenhos do painel. Cada número vem de uma fonte de dados; aqui só se escolhe a linha e se formata.
const { enc, N, P, F, E, curto, classeSinal, selecao, estado, tabela, tela, largura, eixoY, dataPt, nf0 } = window.PG;

// ---------- separadores ----------
const seccoes = () => document.querySelectorAll('.pg-sec');
const botoes = () => document.querySelectorAll('.pg-tab');
function abrir(id, ligar) {
  if (!document.getElementById(id)) id = 'resumo';
  seccoes().forEach((s) => { s.hidden = s.id !== id; });
  botoes().forEach((b) => { b.setAttribute('aria-selected', String(b.dataset.tab === id)); });
  if (ligar) { dash.setLink(id); dash.correr(); }
}
botoes().forEach((b) => b.addEventListener('click', () => abrir(b.dataset.tab, true)));
abrir((location.hash || '#resumo').slice(1), false);

// ---------- filtros ----------
const liga = (id, nome) => document.querySelectorAll('#' + id).forEach((s) =>
  s.addEventListener('change', () => dash.setParams({ [nome]: s.value })));
liga('sel-periodo', 'periodo'); liga('sel-loja', 'loja');

const linhaResumo = () => {
  const d = dash.data('resumo'); const c = P();
  return d.status === 'ok' ? d.data.find((r) => r.periodo === c.periodo && r.loja === c.loja) : null;
};
dash.onData(() => {
  const c = P();
  [['sel-periodo', c.periodo], ['sel-loja', c.loja]].forEach(([id, v]) =>
    document.querySelectorAll('#' + id).forEach((s) => { if (document.activeElement !== s) s.value = v; }));
  const r = linhaResumo();
  document.querySelectorAll('#f-comp-wrap').forEach((w) => { w.hidden = !!r && N(r.var_pct) == null; });
});

// ---------- indicadores ----------
const onde = (el) => { const c = P(); el.dataset.where = 'periodo=' + enc(c.periodo) + '&loja=' + enc(c.loja); };
dash.draw('kpi', (el) => { onde(el); const r = linhaResumo(); el.textContent = r ? F(el.dataset.fmt, N(r[el.dataset.field])) : 'n/d'; });
dash.draw('delta', (el) => {
  onde(el); const r = linhaResumo(); const v = r ? N(r[el.dataset.field]) : null;
  el.textContent = v == null ? 'sem comparação' : F(el.dataset.fmt, v);
  el.className = classeSinal(v, el.dataset.bom);
});
dash.draw('comp', (el) => { const r = linhaResumo(); el.textContent = r && r.comparacao && N(r.var_pct) != null ? 'face a' + r.comparacao : ''; });
const NOMES = { 'Ontem': 'Ontem', 'Últimos 7 dias': 'Nos últimos 7 dias', 'Últimos 30 dias': 'Nos últimos 30 dias', 'Mês em curso': 'No mês em curso', 'Últimos 12 meses': 'Nos últimos 12 meses' };
const QUEM = { 'Todas': 'o grupo', 'Restaurante CNB': 'o Restaurante CNB', 'Requinte loja': 'a Requinte loja', 'Armazém Náutico': 'o Armazém Náutico' };
dash.draw('f-periodo', (el) => { el.textContent = NOMES[P().periodo] || P().periodo; });
dash.draw('f-quem', (el) => { el.textContent = QUEM[P().loja] || P().loja; });
dash.draw('f-datas', (el) => { const r = linhaResumo(); el.textContent = !r ? 'n/d' : r.de === r.ate ? dataPt(r.de) : dataPt(r.de) + ' a ' + dataPt(r.ate); });

const umaLinha = (nome, src, col, valor) => dash.draw(nome, (el) => {
  const d = dash.data(src); const v = valor();
  el.dataset.where = col + '=' + enc(v);
  const r = d.status === 'ok' ? d.data.find((x) => x[col] === v) : null;
  el.textContent = r ? F(el.dataset.fmt, N(r[el.dataset.field])) : 'n/d';
});
umaLinha('stk', 'stock_lojas', 'loja', () => P().loja);

// ---------- alertas ----------
dash.draw('alertas', (ul) => {
  const d = dash.data('alertas'); const e = estado(d);
  if (e) { ul.replaceChildren(E('li', 'pg-note', e === 'A carregar' ? 'n/d' : e)); return; }
  if (!d.data.length) { ul.replaceChildren(E('li', 'pg-note', 'Nada a assinalar.')); return; }
  ul.replaceChildren(...d.data.map((r) => {
    const li = E('li', 'pg-alerta');
    li.append(E('span', 'pg-badge ' + (r.gravidade === 'Crítico' ? 'pg-g-critico' : r.gravidade === 'Atenção' ? 'pg-g-atencao' : ''), r.gravidade));
    const tx = E('span'); tx.append(E('b', '', r.area + ': '), r.alerta); li.append(tx);
    if (r.seccao) { const b = E('button', '', 'Ver detalhe'); b.type = 'button'; b.addEventListener('click', () => abrir(r.seccao, true)); li.append(b); }
    return li;
  }));
});

// ---------- tabelas ----------
const top = (rs, n) => rs.slice().sort((a, b) => N(b.liquido) - N(a.liquido)).slice(0, n);
tabela('t-lojas', { src: 'resumo', rows: (d, c) => d.filter((r) => r.periodo === c.periodo && r.loja !== 'Todas'),
  cols: [['loja', 'txt'], ['liquido', 'mt'], ['var_pct', 'pct'], ['recibos', 'n'], ['ticket', 'mt'], ['margem_pct', 'pct0'], ['desc_pct', 'pct0']] });
tabela('t-pagamentos', { src: 'pagamentos', rows: (d) => selecao(d), cols: [['metodo', 'txt'], ['valor', 'mt'], ['pct', 'pct0', 'barra']] });
tabela('t-categorias', { src: 'categorias', rows: (d) => top(selecao(d), 15),
  cols: [['categoria', 'txt'], ['liquido', 'mt'], ['peso_pct', 'pct0', 'barra'], ['var_pct', 'pct'], ['margem_pct', 'pct0']] });
tabela('t-produtos', { src: 'produtos', rows: (d) => top(selecao(d), 25),
  cols: [['item', 'txt'], ['categoria', 'txt'], ['qtd', 'n1'], ['liquido', 'mt'], ['var_pct', 'pct'], ['margem_pct', 'pct0']] });
const mov = (s) => ({ src: 'movimentos', rows: (d) => selecao(d).filter((r) => r.sentido === s), vazio: 'Sem comparação para este período.',
  cols: [['item', 'txt'], ['liquido', 'mt'], ['variacao', 'dmt']] });
tabela('t-sobe', mov('A subir')); tabela('t-desce', mov('A descer'));
tabela('t-margem', { src: 'margem_problemas', rows: (d) => d, vazio: 'Nenhum problema encontrado.',
  cols: [['problema', 'badge'], ['item', 'txt'], ['qtd', 'n1'], ['liquido', 'mt'], ['custo', 'mt'], ['exposicao', 'mt']] });
tabela('t-equipa', { src: 'equipa', rows: (d) => selecao(d),
  cols: [['empregado', 'txt'], ['liquido', 'mt'], ['peso_pct', 'pct0', 'barra'], ['recibos', 'n'], ['ticket', 'mt'], ['itens_por_recibo', 'n1'], ['desc_pct', 'pct0'], ['consumo_casa', 'mt']] });
tabela('t-descontos', { src: 'descontos', rows: (d) => selecao(d), vazio: 'Sem descontos neste período.',
  cols: [['tipo', 'txt'], ['valor', 'mt'], ['recibos', 'n'], ['pct_das_vendas', 'pct0']] });
tabela('t-caixa', { src: 'caixa', vazio: 'Sem diferenças de caixa.',
  rows: (d, c) => d.filter((r) => N(r.diferenca) !== 0 && (c.loja === 'Todas' || r.loja === c.loja)).slice(0, 12),
  cols: [['data', 'data'], ['loja', 'txt'], ['turnos', 'n'], ['diferenca', 'dmt']] });
tabela('t-modulos', { src: 'modulos', key: 'o', rows: (d) => d, cols: [['modulo', 'txt'], ['indicador', 'txt'], ['valor', 'n']] });

// ---------- gráfico: vendas diárias ----------
const diaMes = d3.utcFormat('%d/%m');
dash.draw('g-tendencia', (el) => {
  const d = dash.data('dias');
  const t = tela(el, d, 'Vendas líquidas diárias dos últimos 90 dias, com a média de 7 dias e a do ano anterior', 260);
  if (!t) return;
  const rs = d.data.filter((r) => r.loja === P().loja).map((r) => ({ d: new Date(r.data + 'T00:00:00Z'), v: N(r.liquido) || 0, m: N(r.media_7_dias), a: N(r.media_7_dias_ano_anterior), n: N(r.recibos) }));
  if (!rs.length) return;
  const { W, svg } = t; const H = 260;
  const y = d3.scaleLinear().domain([0, d3.max(rs, (r) => Math.max(r.v, r.m || 0, r.a || 0)) || 1]).nice(4);
  const m = { t: 10, r: 6, b: 22, l: largura(svg, y.ticks(4).map(curto)) + 10 };
  y.range([H - m.b, m.t]);
  const x = d3.scaleBand().domain(rs.map((r) => +r.d)).range([m.l, W - m.r]).padding(0.2);
  eixoY(svg, y, m, W);
  svg.append('g').selectAll('rect').data(rs).join('rect').attr('x', (r) => x(+r.d)).attr('width', x.bandwidth())
    .attr('y', (r) => y(Math.max(0, r.v))).attr('height', (r) => Math.max(0, y(0) - y(Math.max(0, r.v)))).style('fill', 'var(--cds-chart-muted)');
  const cx = (r) => x(+r.d) + x.bandwidth() / 2;
  const linha = (k) => d3.line().defined((r) => r[k] != null).x(cx).y((r) => y(r[k]));
  svg.append('path').attr('d', linha('a')(rs)).attr('fill', 'none').attr('stroke-width', 1.5).attr('stroke-dasharray', '4 3').style('stroke', 'var(--cds-chart-reference)');
  svg.append('path').attr('d', linha('m')(rs)).attr('fill', 'none').attr('stroke-width', 2).style('stroke', dash.colors[0]);
  const passo = Math.max(1, Math.ceil(rs.length / Math.max(2, Math.floor((W - m.l) / 62))));
  svg.append('g').selectAll('text').data(rs.filter((r, i) => (rs.length - 1 - i) % passo === 0)).join('text')
    .attr('x', cx).attr('y', H - 6).attr('text-anchor', 'middle').text((r) => diaMes(r.d));
  const marca = svg.append('line').attr('y1', m.t).attr('y2', H - m.b).style('stroke', 'var(--cds-chart-axis)').attr('opacity', 0);
  svg.append('rect').attr('x', m.l).attr('y', 0).attr('width', W - m.l - m.r).attr('height', H).attr('fill', 'transparent')
    .on('pointermove', (ev) => {
      const [px] = d3.pointer(ev);
      const i = Math.max(0, Math.min(rs.length - 1, Math.floor((px - m.l) / x.step())));
      const r = rs[i];
      marca.attr('x1', cx(r)).attr('x2', cx(r)).attr('opacity', 1);
      t.mostra(cx(r), y(Math.max(r.v, r.m || 0)), [[d3.utcFormat('%d/%m/%Y')(r.d)], ['Vendas', F('mt', r.v)], ['Recibos', F('n', r.n)], ['Média de 7 dias', F('mt', r.m)], ['Média no ano anterior', F('mt', r.a)]]);
    })
    .on('pointerleave', () => { marca.attr('opacity', 0); t.esconde(); });
});

// ---------- gráfico: meses ----------
const MES = ['jan', 'fev', 'mar', 'abr', 'mai', 'jun', 'jul', 'ago', 'set', 'out', 'nov', 'dez'];
const nomeMes = (s) => MES[+s.slice(5, 7) - 1] + ' ' + s.slice(2, 4);
dash.draw('g-meses', (el) => {
  const d = dash.data('meses');
  const t = tela(el, d, 'Vendas líquidas por mês', 260);
  if (!t) return;
  const rs = d.data.filter((r) => r.loja === P().loja).map((r) => ({ mes: r.mes, v: N(r.liquido) || 0, n: N(r.recibos), tk: N(r.ticket), mg: N(r.margem_pct), curso: r.estado === 'Em curso' }));
  if (!rs.length) return;
  const { W, svg } = t; const H = 260;
  const y = d3.scaleLinear().domain([0, d3.max(rs, (r) => r.v) || 1]).nice(4);
  const m = { t: 18, r: 6, b: 22, l: largura(svg, y.ticks(4).map(curto)) + 10 };
  y.range([H - m.b, m.t]);
  const x = d3.scaleBand().domain(rs.map((r) => r.mes)).range([m.l, W - m.r]).padding(0.25);
  eixoY(svg, y, m, W);
  svg.append('g').selectAll('rect').data(rs).join('rect').attr('x', (r) => x(r.mes)).attr('width', x.bandwidth())
    .attr('y', (r) => y(r.v)).attr('height', (r) => Math.max(0, y(0) - y(r.v))).attr('rx', 2)
    .style('fill', dash.colors[0]).attr('fill-opacity', (r) => (r.curso ? 0.45 : 1))
    .on('pointermove', (ev, r) => t.mostra(x(r.mes) + x.bandwidth() / 2, y(r.v), [[nomeMes(r.mes) + (r.curso ? ' (em curso)' : '')], ['Vendas', F('mt', r.v)], ['Recibos', F('n', r.n)], ['Ticket médio', F('mt', r.tk)], ['Margem', F('pct0', r.mg)]]))
    .on('pointerleave', t.esconde);
  const cabe = x.bandwidth() >= largura(svg, rs.map((r) => curto(r.v))) + 2;
  const passo = cabe ? 1 : Math.ceil((largura(svg, ['nov 26']) + 8) / x.step());
  if (cabe) svg.append('g').selectAll('text').data(rs).join('text').attr('x', (r) => x(r.mes) + x.bandwidth() / 2).attr('y', (r) => y(r.v) - 5).attr('text-anchor', 'middle').text((r) => curto(r.v));
  svg.append('g').selectAll('text').data(rs.filter((r, i) => (rs.length - 1 - i) % passo === 0)).join('text')
    .attr('x', (r) => x(r.mes) + x.bandwidth() / 2).attr('y', H - 6).attr('text-anchor', 'middle').text((r) => nomeMes(r.mes));
});

// ---------- gráfico: dia da semana por hora ----------
const DIAS = ['Segunda', 'Terça', 'Quarta', 'Quinta', 'Sexta', 'Sábado', 'Domingo'];
dash.draw('g-horas', (el) => {
  const d = dash.data('horas');
  const t = tela(el, d, 'Média de vendas por dia da semana e por hora nas últimas 8 semanas', 250);
  if (!t) return;
  const rs = d.data.filter((r) => r.loja === P().loja).map((r) => ({ dn: N(r.dia_n), dia: r.dia, h: N(r.hora), v: N(r.liquido_medio) || 0, n: N(r.recibos_medio) })).filter((r) => r.v > 0);
  if (!rs.length) { el.replaceChildren(E('div', 'pg-fail', 'Sem vendas nas últimas 8 semanas para esta loja.')); return; }
  const { W, svg } = t; const H = 250;
  const horas = d3.range(d3.min(rs, (r) => r.h), d3.max(rs, (r) => r.h) + 1);
  const m = { t: 4, r: 4, b: 22, l: largura(svg, DIAS) + 10 };
  const x = d3.scaleBand().domain(horas).range([m.l, W - m.r]).padding(0.06);
  const y = d3.scaleBand().domain(d3.range(1, 8)).range([m.t, H - m.b]).padding(0.08);
  const max = d3.max(rs, (r) => r.v);
  svg.append('g').selectAll('text').data(d3.range(1, 8)).join('text').attr('x', m.l - 8).attr('y', (k) => y(k) + y.bandwidth() / 2).attr('dy', '0.32em').attr('text-anchor', 'end').text((k) => DIAS[k - 1]);
  const passo = Math.max(1, Math.ceil((largura(svg, ['00h']) + 6) / x.step()));
  svg.append('g').selectAll('text').data(horas.filter((h, i) => i % passo === 0)).join('text').attr('x', (h) => x(h) + x.bandwidth() / 2).attr('y', H - 6).attr('text-anchor', 'middle').text((h) => String(h).padStart(2, '0') + 'h');
  svg.append('g').selectAll('rect').data(rs).join('rect').attr('x', (r) => x(r.h)).attr('y', (r) => y(r.dn)).attr('width', x.bandwidth()).attr('height', y.bandwidth()).attr('rx', 2)
    .style('fill', dash.colors[0]).attr('fill-opacity', (r) => 0.08 + 0.92 * Math.sqrt(r.v / max))
    .on('pointermove', (ev, r) => t.mostra(x(r.h) + x.bandwidth() / 2, y(r.dn), [[r.dia + ', ' + String(r.h).padStart(2, '0') + 'h'], ['Vendas médias', F('mt', r.v)], ['Recibos médios', F('n1', r.n)]]))
    .on('pointerleave', t.esconde);
});
})();
