// Menu digital CNB: ligação ao Loyverse (só leitura).
//  accao "sincronizar" (de 10 em 10 min pelo pg_cron, ou pela gestão): artigos, categorias, modificadores e stock da loja
//  accao "cruzar" (23:45, ou pela gestão): confere os pedidos da app com os recibos do Loyverse
//  accao "lojas" (gestão): lista as lojas
//  accao "pagamentos" (de 2 em 2 min pelo pg_cron, só quando há mesas a pedir pelo telemóvel): procura nos recibos do Loyverse
//    o pagamento de cada uma dessas mesas (ticket "Mesa N") e liberta a mesa para o cliente seguinte. {"ver": true} só mostra.
// Segredo necessário: LOYVERSE_TOKEN (supabase secrets set LOYVERSE_TOKEN=...).
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const LV = "https://api.loyverse.com/v1.0/";

async function lvGet(path: string, params: Record<string, string | number> = {}) {
  const q = new URLSearchParams(Object.entries(params).map(([k, v]) => [k, String(v)])).toString();
  const r = await fetch(LV + path + (q ? "?" + q : ""), { headers: { Authorization: "Bearer " + Deno.env.get("LOYVERSE_TOKEN") } });
  if (!r.ok) throw new Error(`Loyverse ${path}: ${r.status} ${(await r.text()).slice(0, 200)}`);
  return await r.json();
}
async function lvAll(path: string, key: string, params: Record<string, string | number> = {}) {
  let out: any[] = [], cursor: string | undefined;
  do { const d = await lvGet(path, { limit: 250, ...params, ...(cursor ? { cursor } : {}) }); out = out.concat(d[key] || []); cursor = d.cursor; } while (cursor);
  return out;
}

async function sincronizar(db: any) {
  const { data: cfgRows } = await db.from("menu_config").select("chave, valor");
  const c: Record<string, string> = {}; (cfgRows || []).forEach((r: any) => c[r.chave] = r.valor);
  const store = c.loyverse_store_id;
  const cats: Record<string, string> = {}; (await lvAll("categories", "categories")).forEach((x: any) => cats[x.id] = x.name);
  const mods: Record<string, any> = {};
  (await lvAll("modifiers", "modifiers")).forEach((m: any) => mods[m.id] = { id: m.id, nome: m.name, opcoes: (m.modifier_options || []).map((o: any) => ({ id: o.id, nome: o.name, preco: Number(o.price || 0) })) });
  const stock: Record<string, number> = {};
  if (store) (await lvAll("inventory", "inventory_levels", { store_id: store })).forEach((i: any) => stock[i.variant_id] = Number(i.in_stock));
  const items = await lvAll("items", "items");
  const contaStockCats = String(c.esconder_sem_stock_categorias || "").split("|").map((x) => x.trim()).filter(Boolean);
  const ordemCat: string[] = []; const rows: any[] = []; const ts = new Date().toISOString();
  for (const it of items) {
    if (it.deleted_at) continue;
    const vs = (it.variants || []).filter((v: any) => !v.deleted_at && (!store || (v.stores || []).some((s: any) => s.store_id === store && s.available_for_sale !== false)));
    if (!vs.length) continue;
    const variantes = vs.map((v: any) => { const st = (v.stores || []).find((s: any) => s.store_id === store) || (v.stores || [])[0] || {};
      return { id: v.variant_id, nome: [v.option1_value, v.option2_value, v.option3_value].filter(Boolean).join(" "), preco: Number(st.price != null ? st.price : v.default_price || 0), sku: v.sku || "", stock: stock[v.variant_id] }; });
    const catNome = cats[it.category_id] || "Sem categoria"; if (!ordemCat.includes(catNome)) ordemCat.push(catNome);
    const conta = contaStockCats.some((x) => catNome.includes(x)); const track = !!it.track_stock;
    const temStock = !track || !conta || variantes.some((v: any) => v.stock === undefined || v.stock > 0);
    rows.push({ item_id: it.id, nome: it.item_name, categoria: catNome, categoria_id: it.category_id || "", preco: variantes[0].preco, sku: variantes[0].sku,
      variantes: variantes.length > 1 ? variantes : [], modificadores: (it.modifier_ids || it.modifiers_ids || []).map((id: string) => mods[id]).filter(Boolean),
      stock: track ? Math.max(0, ...variantes.map((v: any) => v.stock || 0)) : null, activo: temStock, ordem_cat: ordemCat.indexOf(catNome), sincronizado_em: ts });
  }
  for (let i = 0; i < rows.length; i += 200) { const { error } = await db.from("menu_artigos").upsert(rows.slice(i, i + 200)); if (error) throw new Error(error.message); }
  const ids = rows.map((r) => r.item_id);
  const { data: antigos } = await db.from("menu_artigos").select("item_id");
  const fora = (antigos || []).map((r: any) => r.item_id).filter((id: string) => !ids.includes(id));
  for (let i = 0; i < fora.length; i += 200) await db.from("menu_artigos").delete().in("item_id", fora.slice(i, i + 200));
  const { data: extra } = await db.from("menu_extra").select("item_id"); const tem = new Set((extra || []).map((e: any) => e.item_id));
  const novos = rows.filter((r) => !tem.has(r.item_id)).map((r) => ({ item_id: r.item_id, nome: r.nome }));
  if (novos.length) await db.from("menu_extra").insert(novos);
  const { data: refs } = await db.rpc("menu_sincronizar_referencias");
  return { artigos: rows.length, categorias: Object.keys(cats).length, novos: novos.length, removidos: fora.length, referencias: refs, quando: ts };
}

async function cruzar(db: any, diaPedido?: string) {
  const { data: cfgRows } = await db.from("menu_config").select("chave, valor");
  const c: Record<string, string> = {}; (cfgRows || []).forEach((r: any) => c[r.chave] = r.valor);
  const [h, m] = String(c.dia_comeca_as || "06:00").split(":").map(Number);
  const agoraMz = new Date(Date.now() + 2 * 3600000); // Maputo = UTC+2, sem hora de Verão
  const dia = diaPedido || new Date(agoraMz.getTime() - (h * 60 + m) * 60000).toISOString().slice(0, 10);
  const ini = new Date(Date.parse(dia + "T00:00:00Z") - 2 * 3600000 + (h * 60 + m) * 60000); const fim = new Date(ini.getTime() + 86400000);
  const recibos = await lvAll("receipts", "receipts", { created_at_min: ini.toISOString(), created_at_max: fim.toISOString(), store_id: c.loyverse_store_id });
  const { data: equipa } = await db.from("staff").select("id, nome, loyverse_employee_id");
  const empDe: Record<string, string> = {}; (equipa || []).forEach((u: any) => { if (u.loyverse_employee_id) empDe[u.loyverse_employee_id] = u.id; });
  const nomeDe = (id: string) => ((equipa || []).find((u: any) => u.id === id) || {}).nome || id;
  const { data: peds } = await db.from("menu_pedidos").select("id, mesa, t2, g2, caixa").eq("data_op", dia).eq("anulado_motivo", "");
  const { data: linhas } = await db.from("menu_linhas").select("pedido, item_id, nome, qtd, indisponivel").in("pedido", (peds || []).map((p: any) => p.id).concat(["-"]));
  await db.from("menu_cruzamento").delete().eq("data", dia);
  const usados = new Set<string>(); const out: any[] = [];
  for (const p of (peds || [])) {
    const ls = (linhas || []).filter((l: any) => l.pedido === p.id && !l.indisponivel);
    if (!p.t2) { out.push({ data: dia, pedido: p.id, mesa: p.mesa, g2: p.g2, resultado: "nao_registado", detalhe: 'Pedido sem "Registado no POS"' }); continue; }
    const t2 = Date.parse(p.t2);
    const cand = recibos.filter((r: any) => !usados.has(r.receipt_number) && Date.parse(r.receipt_date) >= t2 - 600000 && Date.parse(r.receipt_date) <= t2 + 5 * 3600000
      && ls.every((l: any) => (r.line_items || []).some((li: any) => li.item_id === l.item_id && Number(li.quantity) >= Number(l.qtd))));
    if (!cand.length) { out.push({ data: dia, pedido: p.id, mesa: p.mesa, g2: p.g2, resultado: "sem_recibo", detalhe: "Nenhum recibo do Loyverse contém os artigos: " + ls.map((l: any) => l.qtd + "x " + l.nome).join(", ") }); continue; }
    const r = cand[0]; usados.add(r.receipt_number); const empApp = empDe[r.employee_id];
    const ok = !r.employee_id || !empApp || empApp === p.g2 || p.caixa;
    out.push({ data: dia, pedido: p.id, mesa: p.mesa, g2: p.g2, recibo: r.receipt_number, empregado_recibo: r.employee_id || "", resultado: ok ? "ok" : "outro_empregado",
      detalhe: ok ? "" : "Registado na app por " + nomeDe(p.g2) + ", recibo no Loyverse por " + nomeDe(empApp || r.employee_id) });
  }
  if (out.length) await db.from("menu_cruzamento").insert(out);
  return { dia, pedidos: out.length, ok: out.filter((x) => x.resultado === "ok").length };
}

// pagamento no Loyverse liberta o telemóvel da mesa (o ticket tem o nome "Mesa N")
const semAcento = (s: string) => String(s || "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().replace(/\s+/g, " ").trim();
function ticketDaMesa(ticket: string, mesa: { mesa: string; nome: string }) {
  const t = semAcento(ticket), n = semAcento(mesa.nome); if (!t || !n) return false;
  const num = n.replace(/^0+/, "");
  return t === n || t === semAcento(mesa.mesa) || new RegExp("^(mesa|m)\\s*0*" + num.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "(?![0-9])").test(t);
}
async function pagamentos(db: any, ver: boolean) {
  const { data: mesas, error } = await db.rpc("menu_telemoveis_json", { p_garcom: null });
  if (error) throw new Error(error.message);
  const lista = (mesas || []) as { mesa: string; nome: string; desde: string }[];
  if (!lista.length && !ver) return { mesas: 0, libertadas: [] };
  const { data: cfgRows } = await db.from("menu_config").select("chave, valor");
  const c: Record<string, string> = {}; (cfgRows || []).forEach((r: any) => c[r.chave] = r.valor);
  const inicio = lista.length ? Math.min(...lista.map((m) => Date.parse(m.desde))) - 10 * 60000 : Date.now() - 6 * 3600000;
  const recibos = await lvAll("receipts", "receipts", { created_at_min: new Date(inicio).toISOString(), ...(c.loyverse_store_id ? { store_id: c.loyverse_store_id } : {}) });
  const vendas = recibos.filter((r: any) => (r.receipt_type || "SALE") === "SALE" && !r.cancelled_at);
  const libertadas: any[] = [];
  for (const m of lista) {
    const r = vendas.find((x: any) => ticketDaMesa(x.order || "", m) && Date.parse(x.receipt_date || x.created_at) >= Date.parse(m.desde));
    if (!r) continue;
    let ok = true;
    if (!ver) { const { data, error: e2 } = await db.rpc("menu_pagamento_libertar", { p_mesa: m.mesa, p_pago: r.receipt_date || r.created_at, p_recibo: r.receipt_number }); if (e2) throw new Error(e2.message); ok = !!data; }
    if (ok) libertadas.push({ mesa: m.mesa, recibo: r.receipt_number, pago: r.receipt_date });
  }
  const out: any = { mesas: lista.length, recibos: vendas.length, libertadas };
  if (ver) out.amostra = vendas.slice(0, 20).map((r: any) => ({ recibo: r.receipt_number, data: r.receipt_date, ticket: r.order ?? null, servico: r.dining_option ?? null }));
  if (ver && vendas[0]) out.campos = Object.keys(vendas[0]).join(", ");
  return out;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const url = Deno.env.get("SUPABASE_URL")!, chave = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const auth = req.headers.get("Authorization") || "";
  const corpo = await req.json().catch(() => ({}));
  const accao = corpo.accao || "sincronizar";
  // o cron entra com a chave de serviço; as pessoas só se forem da gestão
  if (auth !== "Bearer " + chave) {
    const eu = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
    // chave de serviço guardada no Vault (cron): só ela consegue ler menu_cruzamento
    const servico = auth.startsWith("Bearer ") && !(await eu.from("menu_cruzamento").select("id").limit(1)).error;
    if (!servico) {
      const { data: perfil } = await eu.rpc("fn_menu_perfil");
      const pode = accao === "lojas" ? ["gerente"] : ["gerente", "supervisor"];
      if (!pode.includes(perfil)) return json({ ok: false, erro: "Sem permissão" }, 403);
    }
  }
  if (!Deno.env.get("LOYVERSE_TOKEN")) return json({ ok: false, erro: "Falta o segredo LOYVERSE_TOKEN" }, 500);
  const db = createClient(url, chave, { auth: { persistSession: false } });
  try {
    if (accao === "lojas") return json({ ok: true, data: (await lvGet("stores")).stores.map((s: any) => ({ id: s.id, nome: s.name })) });
    if (accao === "pagamentos") return json({ ok: true, data: await pagamentos(db, !!corpo.ver) });
    if (accao === "cruzar") return json({ ok: true, data: await cruzar(db, corpo.dia) });
    return json({ ok: true, data: await sincronizar(db) });
  } catch (e) { return json({ ok: false, erro: String((e as Error).message || e) }, 500); }
});
