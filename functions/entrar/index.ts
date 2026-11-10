// Entrada única da equipa por nome + PIN.
// Verifica o PIN na base (com bloqueio ao fim de 5 falhas), garante que a pessoa tem conta de autenticação
// e devolve um código de uso único que a página troca por uma sessão Supabase normal (verifyOtp).
// Assim a mesma sessão serve o menu digital, os bilhetes e as mesas (mesmo projecto, mesmo endereço base).
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, erro: "Método não permitido" }, 405);
  let corpo: { nome?: string; pin?: string } = {};
  try { corpo = await req.json(); } catch { return json({ ok: false, erro: "Pedido inválido" }, 400); }
  const nome = String(corpo.nome || "").trim().slice(0, 60), pin = String(corpo.pin || "").trim();
  if (!nome || !/^\d{4,6}$/.test(pin)) return json({ ok: false, erro: "Nome ou PIN incorrecto" });

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: v, error } = await admin.rpc("fn_entrada_verificar", { p_nome: nome, p_pin: pin });
  if (error) return json({ ok: false, erro: "Erro no servidor" }, 500);
  if (!v?.ok) return json({ ok: false, erro: v?.erro || "Nome ou PIN incorrecto" });

  let uid: string | null = v.auth_user_id, email: string | null = v.email;
  if (uid) {
    const { data: u } = await admin.auth.admin.getUserById(uid);
    email = u?.user?.email ?? email;
  }
  if (!uid || !email) {
    // pessoa só com PIN: conta de autenticação com um endereço técnico (nunca recebe emails)
    email = email || `pin.${String(v.id).slice(0, 8)}${String(v.id).slice(-4)}@example.com`;
    const { data: novo, error: e2 } = await admin.auth.admin.createUser({ email, email_confirm: true, user_metadata: { nome: v.nome, via: "pin" } });
    if (e2 && !/already|registered|exists/i.test(e2.message)) return json({ ok: false, erro: "Não foi possível criar a sessão" }, 500);
    uid = novo?.user?.id ?? uid;
    if (!uid) { // já existia: procurar pelo email
      const { data: lista } = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 });
      uid = lista?.users?.find((x) => (x.email || "").toLowerCase() === email!.toLowerCase())?.id ?? null;
    }
    if (!uid) return json({ ok: false, erro: "Não foi possível criar a sessão" }, 500);
    await admin.from("staff").update({ auth_user_id: uid }).eq("id", v.id);
  }
  const { data: link, error: e3 } = await admin.auth.admin.generateLink({ type: "magiclink", email: email! });
  if (e3 || !link?.properties?.hashed_token) return json({ ok: false, erro: "Não foi possível criar a sessão" }, 500);
  return json({ ok: true, token_hash: link.properties.hashed_token, nome: v.nome });
});
