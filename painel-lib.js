// Painel de gestão CNB e Requinte: leitura dos dados no Supabase e pequeno motor de desenho.
// Os dados vêm todos de painel_ler(), que só responde a quem tem a permissão do painel.
(function () {
  const desenhos = {}, ouvintes = []; let dados = null, estado = 'loading', t = null;
  const filtros = { periodo: 'Últimos 7 dias', loja: 'Todas' };
  function correr() {
    ouvintes.forEach((f) => { try { f(); } catch (e) { console.error(e); } });
    Object.keys(desenhos).forEach((n) => document.querySelectorAll('[data-draw="' + n + '"]').forEach((el) => {
      if (el.closest('[hidden]')) return;
      try { desenhos[n](el); } catch (e) { console.error(n, e); }
    }));
  }
  window.dash = {
    colors: ['var(--sea)', 'var(--accent)'],
    params: () => filtros,
    setParams(p) { Object.assign(filtros, p); correr(); },
    setLink(id) { try { history.replaceState(null, '', '#' + id); } catch (e) {} },
    data(id) { return estado !== 'ok' ? { status: estado, data: [] } : dados[id] ? { status: 'ok', data: dados[id] } : { status: 'missing', data: [] }; },
    draw(n, f) { desenhos[n] = f; },
    onData(f) { ouvintes.push(f); },
    correr,
    carregar(d) { dados = d; estado = d ? 'ok' : 'error'; correr(); },
  };
  window.addEventListener('resize', () => { clearTimeout(t); t = setTimeout(correr, 150); });
})();

// Funções comuns do painel: filtros, formatos, tabelas e gráficos.
(function () {
const enc = (s) => String(s).replace(/[%&=]/g, (c) => encodeURIComponent(c));
const N = (v) => (v === '' || v == null ? null : +v);
const P = () => {
  const p = dash.params() || {};
  return { periodo: p.periodo || 'Últimos 7 dias', loja: p.loja || 'Todas', mercado: p.mercado || '' };
};
let nf0, nf1;
try {
  nf0 = new Intl.NumberFormat('pt-PT', { maximumFractionDigits: 0, useGrouping: 'always' });
  nf1 = new Intl.NumberFormat('pt-PT', { minimumFractionDigits: 1, maximumFractionDigits: 1, useGrouping: 'always' });
} catch (e) {
  nf0 = new Intl.NumberFormat('pt-PT', { maximumFractionDigits: 0 });
  nf1 = new Intl.NumberFormat('pt-PT', { minimumFractionDigits: 1, maximumFractionDigits: 1 });
}
const sinal = (v, t) => (v > 0 ? '+' : v < 0 ? '-' : '') + t;
const dataPt = (s) => (s && s.length >= 10 ? s.slice(8, 10) + '/' + s.slice(5, 7) + '/' + s.slice(0, 4) : 'n/d');
const F = (fmt, v) => {
  if (fmt === 'txt') return v == null || v === '' ? 'n/d' : String(v);
  if (fmt === 'data') return dataPt(v);
  if (v == null || isNaN(v)) return 'n/d';
  switch (fmt) {
    case 'mt': return nf0.format(v) + ' MT';
    case 'dmt': return sinal(v, nf0.format(Math.abs(v))) + ' MT';
    case 'n': return nf0.format(v);
    case 'n1': return nf1.format(v);
    case 'pct': return sinal(v, nf1.format(Math.abs(v))) + '%';
    case 'pct0': return nf1.format(v) + '%';
    case 'pp': return sinal(v, nf1.format(Math.abs(v))) + ' p.p.';
  }
  return String(v);
};
const curto = (v) => (v >= 1e6 ? nf1.format(v / 1e6) + ' M' : v >= 1000 ? nf0.format(v / 1000) + ' mil' : nf0.format(v));
const SINAIS = { pct: 1, dmt: 1, pp: 1 };
const classeSinal = (v, bom) => (v == null || v === 0 ? '' : (v > 0) === (bom !== 'desce') ? 'pg-ok' : 'pg-bad');
const E = (tag, cls, txt) => { const e = document.createElement(tag); if (cls) e.className = cls; if (txt != null) e.textContent = txt; return e; };
const selecao = (rows) => { const c = P(); return rows.filter((r) => r.periodo === c.periodo && r.loja === c.loja); };
const estado = (d) => (d.status === 'ok' ? null : d.status === 'loading' ? 'A carregar' : d.status === 'error' || d.status === 'missing' ? 'Não foi possível carregar estes dados.' : 'À espera da ligação a esta fonte.');

// Uma tabela: o.src, o.rows(dados, filtros) e o.cols = [[coluna, formato, opção]]
function tabela(nome, o) {
  dash.draw(nome, (tb) => {
    const d = dash.data(o.src);
    const aviso = (t) => { const tr = E('tr'); const td = E('td', 'pg-vazio', t); td.colSpan = o.cols.length; tr.append(td); tb.replaceChildren(tr); };
    const e = estado(d);
    if (e) return aviso(e);
    const rs = o.rows(d.data, P());
    if (!rs.length) return aviso(o.vazio || 'Sem dados para esta selecção.');
    tb.replaceChildren(...rs.map((r) => {
      const tr = E('tr');
      tr.dataset.key = enc(r[o.key || 'id']);
      o.cols.forEach(([f, fmt, op]) => {
        const v = fmt === 'txt' || fmt === 'data' || fmt === 'badge' ? r[f] : N(r[f]);
        const td = E('td', fmt === 'txt' || fmt === 'data' || fmt === 'badge' ? '' : 'pg-r');
        if (fmt === 'badge') td.append(E('span', 'pg-badge ' + (/Ruptura|Crítico|abaixo/.test(v) ? 'pg-g-critico' : /Atenção|anómalo/.test(v) ? 'pg-g-atencao' : ''), v || 'n/d'));
        else td.textContent = F(fmt, v);
        if (SINAIS[fmt]) { const c = classeSinal(v, op); if (c) td.classList.add(c); }
        if (op === 'barra' && v != null) { const b = E('span', 'pg-bar'); b.style.width = Math.max(0, Math.min(100, v)) + '%'; td.append(b); }
        tr.append(td);
      });
      return tr;
    }));
  });
}

// Preparação comum de um gráfico: devolve null quando os dados não estão prontos.
function tela(el, d, alt, H) {
  const e = estado(d);
  if (e) { el.replaceChildren(E('div', 'pg-fail', e === 'A carregar' ? 'n/d' : e)); return null; }
  const W = Math.max(280, el.clientWidth || 600);
  const svg = d3.create('svg').attr('viewBox', `0 0 ${W} ${H}`).attr('height', H).attr('role', 'img').attr('aria-label', alt);
  const tip = E('div', 'pg-tip'); tip.hidden = true;
  el.replaceChildren(svg.node(), tip);
  const mostra = (x, y, linhas) => {
    tip.replaceChildren(...linhas.map(([a, b], i) => { const p = E('div'); if (i === 0) p.append(E('b', '', a)); else p.append(a + ': ', E('b', '', b)); return p; }));
    tip.hidden = false;
    const w = tip.offsetWidth;
    tip.style.left = Math.max(0, Math.min(W - w, x - w / 2)) + 'px';
    tip.style.top = Math.max(0, y - tip.offsetHeight - 10) + 'px';
  };
  return { W, svg, mostra, esconde: () => { tip.hidden = true; } };
}
function largura(svg, textos) {
  const t = svg.append('text').attr('opacity', 0);
  let m = 0;
  textos.forEach((s) => { t.text(s); m = Math.max(m, t.node().getComputedTextLength()); });
  t.remove();
  return m || 40;
}
function eixoY(svg, y, m, W) {
  const g = svg.append('g');
  y.ticks(4).forEach((v) => {
    g.append('line').attr('x1', m.l).attr('x2', W - m.r).attr('y1', y(v)).attr('y2', y(v)).style('stroke', 'var(--cds-chart-grid)');
    g.append('text').attr('x', m.l - 6).attr('y', y(v)).attr('dy', '0.32em').attr('text-anchor', 'end').text(curto(v));
  });
}

window.PG = { enc, N, P, F, E, curto, classeSinal, selecao, estado, tabela, tela, largura, eixoY, dataPt, nf0 };
})();
