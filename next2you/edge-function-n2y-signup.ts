// Supabase Edge Function "n2y-signup" – deployed via Supabase MCP.
// Creates a pseudonymous Next2You account (random email + password, app_metadata.n2y = true)
// so no real identity is needed and the dashboard "anonymous sign-ins" toggle is not required.
// Limited to MAX_PER_HOUR signups per client IP; only a SHA-256 hash of the IP is stored.
import { createClient } from "npm:@supabase/supabase-js@2";

const MAX_PER_HOUR = 5;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

async function sha256(text: string) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const ip = req.headers.get("cf-connecting-ip") ?? req.headers.get("x-forwarded-for")?.split(",")[0].trim() ?? "unknown";
  const ipHash = await sha256("n2y:" + ip);
  const { data: allowed, error: slotErr } = await admin.rpc("n2y_signup_slot", { p_ip_hash: ipHash, p_max: MAX_PER_HOUR });
  if (slotErr) return json({ error: slotErr.message }, 500);
  if (!allowed) return json({ error: "Zu viele Registrierungen – bitte später erneut versuchen." }, 429);

  const email = `${crypto.randomUUID()}@anon.next2you.app`;
  const password = crypto.randomUUID() + crypto.randomUUID();

  const { error } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    app_metadata: { n2y: true },
  });
  if (error) return json({ error: error.message }, 500);

  return json({ email, password });
});
