// Escrita controlada no Loyverse (só chamada pelo servidor, com a chave de serviço; nunca pelas páginas).
//  accao "indisponivel": põe "Disponível para venda" = não, em todas as lojas, nos artigos cujo nome contém
//    filtro.nome_contem e cuja categoria contém filtro.categoria_contem. Sem aplicar: true, só lista.
//  Procedimento seguro: GET do artigo no momento, mudar só available_for_sale, retirar datas, POST do objecto inteiro,
//  GET outra vez e comparar nome, categoria, composição, variantes e modificadores.
// Segredo necessário: LOYVERSE_TOKEN (o mesmo da função menu-loyverse).
import { createClient } from "jsr:@supabase/supabase-js@2";
const LV = "https://api.loyverse.com/v1.0/";
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });
const H = () => ({ Authorization: "Bearer " + Deno.env.get("LOYVERSE_TOKEN"), "Content-Type": "application/json" });
const espera = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function lv(path: string, init: RequestInit = {}) {
  const r = await fetch(LV + path, { ...init, headers: H() });
  const t = await r.text();
  if (!r.ok) throw new Error(`Loyverse ${path}: ${r.status} ${t.slice(0, 300)}`);
  return t ? JSON.parse(t) : {};
}
async function todos(path: string, key: string) {
  let out: any[] = [], cursor: string | undefined;
  do { const d = await lv(path + "?limit=250" + (cursor ? "&cursor=" + cursor : "")); out = out.concat(d[key] || []); cursor = d.cursor; } while (cursor);
  return out;
}
const assinatura = (it: any) => JSON.stringify({ n: it.item_name, c: it.category_id, comp: it.is_composite, k: (it.components || []).map((x: any) => [x.variant_id, x.quantity]),
  v: (it.variants || []).map((v: any) => [v.variant_id, v.sku, v.cost, (v.stores || []).map((s: any) => [s.store_id, s.price])]), m: it.modifier_ids || [] });

// só a chave de serviço do projecto (a do cofre usada pelo pg_net): confirmada com uma chamada que só ela pode fazer
async function autorizado(req: Request) {
  const k = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  if (!k) return false;
  if (k === Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")) return true;
  try { const { error } = await createClient(Deno.env.get("SUPABASE_URL")!, k, { auth: { persistSession: false } }).auth.admin.listUsers({ page: 1, perPage: 1 }); return !error; }
  catch { return false; }
}

Deno.serve(async (req) => {
  if (!(await autorizado(req))) return json({ erro: "não autorizado" }, 401);
  try {
    const b = await req.json().catch(() => ({}));
    if (b.accao !== "indisponivel") return json({ erro: "accao desconhecida" }, 400);
    const f = b.filtro || {}; const nc = String(f.nome_contem || "").toLowerCase(), cc = String(f.categoria_contem || "").toLowerCase();
    if (!nc) return json({ erro: "falta filtro.nome_contem" }, 400);
    const lojas: Record<string, string> = {}; (await todos("stores", "stores")).forEach((s: any) => lojas[s.id] = s.name);
    const cats: Record<string, string> = {}; (await todos("categories", "categories")).forEach((c: any) => cats[c.id] = c.name);
    const itens = (await todos("items", "items")).filter((it: any) => !it.deleted_at && String(it.item_name || "").toLowerCase().includes(nc)
      && (!cc || String(cats[it.category_id] || "").toLowerCase().includes(cc)));
    const lista = itens.map((it: any) => ({ id: it.id, nome: it.item_name, categoria: cats[it.category_id] || "", sku: (it.variants || []).map((v: any) => v.sku).join(","),
      a_venda_em: [...new Set((it.variants || []).flatMap((v: any) => (v.stores || []).filter((s: any) => s.available_for_sale).map((s: any) => lojas[s.store_id] || s.store_id)))] }));
    if (!b.aplicar) return json({ ver: true, itens: lista });
    const res: any[] = [];
    for (const x of lista) {
      if (!x.a_venda_em.length) { res.push({ nome: x.nome, estado: "já estava indisponível" }); continue; }
      try {
        const it = await lv("items/" + x.id); const antes = assinatura(it);
        for (const k of ["created_at", "updated_at", "deleted_at"]) delete it[k];
        for (const v of it.variants || []) { for (const k of ["created_at", "updated_at", "deleted_at"]) delete v[k]; for (const s of v.stores || []) s.available_for_sale = false; }
        await lv("items", { method: "POST", body: JSON.stringify(it) }); await espera(300);
        const dep = await lv("items/" + x.id);
        const ok = assinatura(dep) === antes && (dep.variants || []).every((v: any) => (v.stores || []).every((s: any) => !s.available_for_sale));
        res.push({ nome: x.nome, sku: x.sku, estado: ok ? "indisponível em todas as lojas" : "VERIFICAR: o artigo mudou mais do que o previsto", estava_em: x.a_venda_em });
      } catch (e) { res.push({ nome: x.nome, sku: x.sku, estado: "erro", erro: String((e as Error).message || e) }); }
      await espera(300);
    }
    return json({ aplicado: true, resultado: res });
  } catch (e) { return json({ erro: String((e as Error).message || e) }, 500); }
});
