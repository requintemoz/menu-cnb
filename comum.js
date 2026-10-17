/* Menu Digital CNB — funções comuns (API, folha, toast, formatos, sessão) */
(function () {
  const C = window.CNB;
  async function api(fn, ...args) {
    const r = await fetch(C.API_URL, { method: 'POST', body: JSON.stringify({ fn, args }), headers: { 'Content-Type': 'text/plain;charset=utf-8' }, redirect: 'follow' });
    const j = await r.json(); if (!j.ok) throw new Error(j.erro || 'Erro no servidor'); return j.data;
  }
  function toast(msg, ms) { const r = document.getElementById('toast-root'); r.innerHTML = `<div class="toast">${msg}</div>`; clearTimeout(toast.t); toast.t = setTimeout(() => r.innerHTML = '', ms || 2600); }
  function openSheet(html, after) { const r = document.getElementById('sheet-root'); r.innerHTML = `<div class="sheet-bg" id="sheet-bg"><div class="sheet" role="dialog" aria-modal="true">${html}</div></div>`; document.getElementById('sheet-bg').addEventListener('click', e => { if (e.target.id === 'sheet-bg') closeSheet(); }); if (after) after(r); }
  function closeSheet() { document.getElementById('sheet-root').innerHTML = ''; }
  const fmt = n => Math.round(Number(n)).toLocaleString('pt-PT') + ' MT';
  const hhmm = t => t ? new Date(t).toLocaleTimeString('pt-PT', { hour: '2-digit', minute: '2-digit' }) : '—';
  const mins = t => (Date.now() - new Date(t)) / 60000;
  const nivel = (m, lim) => m > lim ? 'crit' : m > lim * 0.6 ? 'warn' : 'ok';
  const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  // sessão do pessoal (token em localStorage; 6 h no servidor)
  const sess = { get() { try { return JSON.parse(localStorage.getItem('cnb-sess') || 'null'); } catch (e) { return null; } }, set(s) { try { localStorage.setItem('cnb-sess', JSON.stringify(s)); } catch (e) {} }, clear() { try { localStorage.removeItem('cnb-sess'); } catch (e) {} } };
  async function loginUI(perfis, onOk) {
    const nomes = await api('listarNomes'); const lista = nomes.filter(n => !perfis || perfis.includes(n.perfil));
    document.getElementById('login').innerHTML = `<div class="card login"><h2>Entrar</h2><p class="muted" style="margin:0 0 10px">O mesmo PIN do Loyverse.</p><div class="grid"><label>Nome<br><select id="l-nome">${lista.map(n => `<option>${esc(n.nome)}</option>`).join('')}</select></label><label>PIN<br><input id="l-pin" inputmode="numeric" maxlength="4" autocomplete="off"></label><button class="btn primary" id="l-go" type="button">Entrar</button><div class="muted" id="l-msg" style="font-size:13px"></div></div></div>`;
    const go = async () => { try { const r = await api('login', document.getElementById('l-nome').value, document.getElementById('l-pin').value); if (!r.ok) { document.getElementById('l-msg').textContent = r.erro; return; } sess.set({ token: r.token, user: r.user }); onOk(r); } catch (e) { document.getElementById('l-msg').textContent = e.message; } };
    document.getElementById('l-go').addEventListener('click', go); document.getElementById('l-pin').addEventListener('keydown', e => { if (e.key === 'Enter') go(); });
  }
  // som de aviso (só depois de um toque do utilizador, exigência dos browsers)
  let actx = null; function beep(n) { try { actx = actx || new (window.AudioContext || window.webkitAudioContext)(); for (let i = 0; i < (n || 1); i++) { const o = actx.createOscillator(), g = actx.createGain(); o.connect(g); g.connect(actx.destination); o.frequency.value = 880; g.gain.value = 0.15; o.start(actx.currentTime + i * 0.25); o.stop(actx.currentTime + i * 0.25 + 0.15); } } catch (e) {} }
  function armarSom() { document.addEventListener('pointerdown', () => { try { actx = actx || new (window.AudioContext || window.webkitAudioContext)(); actx.resume(); } catch (e) {} }, { once: true }); }
  // indicador de ligação
  function offlineBar() { const el = document.createElement('div'); el.className = 'offline'; el.hidden = true; el.textContent = 'Sem ligação. A tentar de novo…'; document.body.appendChild(el); return { on() { el.hidden = false; }, off() { el.hidden = true; } }; }
  window.U = { api, toast, openSheet, closeSheet, fmt, hhmm, mins, nivel, esc, sess, loginUI, beep, armarSom, offlineBar };
})();
