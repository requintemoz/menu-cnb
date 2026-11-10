/* Menu Digital CNB - funções comuns (API, folha, toast, formatos, sessão) */
(function () {
  const C = window.CNB;
  // ---------- servidor: Supabase (função menu_api para tudo; função menu-loyverse para o Loyverse) ----------
  const REF = (C.SUPABASE_URL.match(/\/\/([^.]+)\./) || [])[1] || 'cnb'; const CHAVE_SESSAO = 'sb-' + REF + '-auth-token';
  const sb = window.supabase && window.supabase.createClient ? window.supabase.createClient(C.SUPABASE_URL, C.SUPABASE_KEY) : null;
  async function tokenActual() { if (!sb) return C.SUPABASE_KEY; try { const { data } = await sb.auth.getSession(); return (data && data.session && data.session.access_token) || C.SUPABASE_KEY; } catch (e) { return C.SUPABASE_KEY; } }
  async function pedir(caminho, corpo) {
    const tk = await tokenActual();
    const r = await fetch(C.SUPABASE_URL + caminho, { method: 'POST', body: JSON.stringify(corpo), headers: { 'Content-Type': 'application/json', apikey: C.SUPABASE_KEY, Authorization: 'Bearer ' + tk } });
    let j = null; try { j = await r.json(); } catch (e) {}
    if (!r.ok) { const m = (j && (j.message || j.erro || j.error_description || j.msg)) || 'Erro no servidor'; throw new Error(/JWT|jwt/.test(m) ? 'Sessão expirada. Entre de novo com o PIN.' : m); }
    return j;
  }
  function transferirCsv(nome, linhas) { const csv = linhas.map(l => l.map(v => '"' + String(v == null ? '' : v).replace(/"/g, '""') + '"').join(';')).join('\r\n'); const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8' })); a.download = nome; document.body.appendChild(a); a.click(); a.remove(); }
  async function api(fn, ...args) {
    if (fn === 'gestaoSincronizar' || fn === 'gestaoCruzar' || fn === 'gestaoLojas') {
      const j = await pedir('/functions/v1/menu-loyverse', { accao: fn === 'gestaoSincronizar' ? 'sincronizar' : fn === 'gestaoCruzar' ? 'cruzar' : 'lojas' });
      if (!j || !j.ok) throw new Error((j && j.erro) || 'Erro no servidor');
      return fn === 'gestaoCruzar' ? 'Cruzamento de ' + j.data.dia + ' concluído: ' + j.data.ok + ' de ' + j.data.pedidos + ' pedidos conferem' : j.data;
    }
    const d = await pedir('/rest/v1/rpc/menu_api', { p_fn: fn, p_args: args });
    if (fn === 'exportarRelatorio') {
      const n = v => v == null ? '' : (typeof v === 'number' ? String(Math.round(v * 10) / 10).replace('.', ',') : v);
      const L = [['Relatório de tempos', args[1] + ' a ' + args[2]], [], ['Nome', 'Perfil', 'Pedidos', 'Registo mediana (min)', 'Registo máx', 'Acima do limite', 'Aceitar mediana', 'Entrega mediana', 'Chamadas', 'Chamada mediana', 'Acima do limite', 'Sem NFC', 'De colegas', 'Sugestões mostradas', 'Sugestões aceites', 'Horas']];
      d.relatorio.linhas.forEach(l => L.push([l.nome, l.perfil, l.pedidos, n(l.t2t0_med), n(l.t2t0_max), l.t2t0_fora, n(l.t1t0_med), n(l.t3t2_med), l.chamadas, n(l.c1c0_med), l.c1c0_fora, l.semNfc, l.deColegas, l.sugMostradas, l.sugAceites, n(l.horas)]));
      L.push([], ['Pedidos'], ['id', 'data', 'mesa', 'pedido', 'recebido', 'por', 'registado', 'por', 'entregue', 'por', 'nfc', 'caixa', 'estado', 'anulado', 'total']);
      d.pedidos.forEach(p => L.push([p.id, p.data, p.mesa, p.t0, p.t1, p.g1, p.t2, p.g2, p.t3, p.g3, p.nfc, p.caixa, p.estado, p.anulado, p.total]));
      transferirCsv('relatorio_' + args[1] + '_' + args[2] + '.csv', L); return 'Relatório transferido (ficheiro CSV, abre no Excel)';
    }
    return d;
  }
  // avisos em tempo real: chama fn (com um pequeno atraso para juntar várias alterações) quando há pedidos, chamadas ou mesas novas
  function tempoReal(fn) {
    if (!sb) return; let t = null; const dispara = () => { clearTimeout(t); t = setTimeout(fn, 250); };
    try { const canal = sb.channel('menu-equipa'); ['menu_pedidos', 'menu_chamadas', 'menu_mesas', 'menu_supervisor', 'menu_turnos'].forEach(tb => canal.on('postgres_changes', { event: '*', schema: 'public', table: tb }, dispara)); canal.subscribe(); } catch (e) {}
    document.addEventListener('visibilitychange', () => { if (!document.hidden) dispara(); });
  }
  // copiar texto (SKU, notas) para colar no Loyverse; com alternativa para browsers sem acesso à área de transferência
  async function copiar(txt) {
    txt = String(txt == null ? '' : txt);
    try { if (navigator.clipboard && window.isSecureContext) { await navigator.clipboard.writeText(txt); return true; } } catch (e) {}
    try { const t = document.createElement('textarea'); t.value = txt; t.setAttribute('readonly', ''); t.style.cssText = 'position:fixed;top:0;left:0;opacity:0'; document.body.appendChild(t);
      t.select(); t.setSelectionRange(0, txt.length); const ok = document.execCommand('copy'); t.remove(); return ok; } catch (e) { return false; }
  }
  // tocar num SKU copia o número
  document.addEventListener('click', async e => {
    const b = e.target.closest && e.target.closest('[data-sku]'); if (!b) return;
    e.preventDefault(); const sku = b.dataset.sku;
    if (await copiar(sku)) { b.classList.add('copiado'); clearTimeout(b._t); b._t = setTimeout(() => b.classList.remove('copiado'), 1500); toast('SKU ' + esc(sku) + ' copiado. Cole no Loyverse.', 1800); }
    else toast('Não foi possível copiar. O SKU é ' + esc(sku) + '.', 4000);
  });
  function toast(msg, ms) { const r = document.getElementById('toast-root'); r.innerHTML = `<div class="toast">${msg}</div>`; clearTimeout(toast.t); toast.t = setTimeout(() => r.innerHTML = '', ms || 2600); }
  function openSheet(html, after) { const r = document.getElementById('sheet-root'); r.innerHTML = `<div class="sheet-bg" id="sheet-bg"><div class="sheet" role="dialog" aria-modal="true">${html}</div></div>`; document.getElementById('sheet-bg').addEventListener('click', e => { if (e.target.id === 'sheet-bg') closeSheet(); }); if (after) after(r); }
  function closeSheet() { document.getElementById('sheet-root').innerHTML = ''; }
  const fmt = n => Math.round(Number(n)).toLocaleString('pt-PT') + ' MT';
  const hhmm = t => t ? new Date(t).toLocaleTimeString('pt-PT', { hour: '2-digit', minute: '2-digit' }) : '-';
  const mins = t => (Date.now() - new Date(t)) / 60000;
  const nivel = (m, lim) => m > lim ? 'crit' : m > lim * 0.6 ? 'warn' : 'ok';
  // texto vindo do Loyverse ou da folha: troca travessões, aspas angulares, reticências e pontos médios por sinais simples
  const limpa = s => String(s == null ? '' : s).replace(/(\d)\s*[\u2013\u2014]\s*(\d)/g, '$1-$2').replace(/\s+[\u2013\u2014]\s+([^\u2013\u2014]+)$/, ' ($1)').replace(/[\u2013\u2014]/g, '-').replace(/[\u00ab\u00bb\u201c\u201d]/g, '"').replace(/\u2026/g, '...').replace(/\s\u00b7\s/g, ', ');
  const esc = s => limpa(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  // sessão da equipa: a sessão é a do Supabase (partilhada com os bilhetes e as mesas); aqui guarda-se só o nome e o perfil
  const sess = {
    get() { try { if (!localStorage.getItem(CHAVE_SESSAO)) return null; const u = JSON.parse(localStorage.getItem('cnb-eu') || 'null'); return u && u.perfil ? { token: 'supabase', user: u } : null; } catch (e) { return null; } },
    set(s) { try { localStorage.setItem('cnb-eu', JSON.stringify(s.user || s)); } catch (e) {} },
    clear() { try { localStorage.removeItem('cnb-eu'); if (sb) sb.auth.signOut({ scope: 'local' }).catch(() => {}); localStorage.removeItem(CHAVE_SESSAO); } catch (e) {} }
  };
  // sem sessão: vai para a página única de entrada, que depois devolve a pessoa a esta página
  async function loginUI() { const aqui = location.pathname.split('/').pop() || 'index.html'; location.replace((C.ENTRADA || 'entrar.html') + '?para=' + encodeURIComponent(aqui)); }
  // som de aviso (só depois de um toque do utilizador, exigência dos browsers)
  let actx = null; function beep(n, freq) { try { actx = actx || new (window.AudioContext || window.webkitAudioContext)(); for (let i = 0; i < (n || 1); i++) { const o = actx.createOscillator(), g = actx.createGain(); o.connect(g); g.connect(actx.destination); o.frequency.value = freq || 880; g.gain.value = 0.15; o.start(actx.currentTime + i * 0.25); o.stop(actx.currentTime + i * 0.25 + 0.15); } } catch (e) {} }
  function armarSom() { document.addEventListener('pointerdown', () => { try { actx = actx || new (window.AudioContext || window.webkitAudioContext)(); actx.resume(); } catch (e) {} }, { once: true }); }
  // indicador de ligação
  function offlineBar() { const el = document.createElement('div'); el.className = 'offline'; el.hidden = true; el.textContent = 'Sem ligação. A tentar de novo...'; document.body.appendChild(el); return { on() { el.hidden = false; }, off() { el.hidden = true; } }; }
  window.U = { sb, tempoReal, api, toast, copiar, openSheet, closeSheet, fmt, hhmm, mins, nivel, esc, limpa, sess, loginUI, beep, armarSom, offlineBar };
})();
