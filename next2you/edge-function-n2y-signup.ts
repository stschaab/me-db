// Supabase Edge Function "n2y-signup" – deployed via Supabase MCP.
// Creates a pseudonymous Next2You account (random email + password, app_metadata.n2y = true)
// so no real identity is needed and the dashboard "anonymous sign-ins" toggle is not required.
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

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
