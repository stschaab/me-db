// Supabase Edge Function "n2y-spawn-bots" – deployed via Supabase MCP.
// Called by the DB trigger n2y_spawn_bots_nearby (pg_net) after a real user set their position
// in an area with too few AI personas. Only processes pending rows of n2y_bot_spawn_requests,
// so calling it from outside cannot create anything on its own.
// Creates the AI test personas ("Name (KI)", app_metadata.n2y_ai) at random spots
// 300 m – 2 km around the (≈1 km rounded) request position. Replies come from n2y-bot-reply.
import { createClient } from "npm:@supabase/supabase-js@2";

const MAX_BOTS_TOTAL = 200;   // global safety cap
const MIN_BOTS_NEARBY = 4;    // must match n2y_spawn_bots_nearby
const NEAR_LAT = 0.027, NEAR_LNG = 0.04;   // ≈ 3 km

const PERSONAS = [
  { name: "Lena", gender: "f", age: 34, topics: "KI und Philosophie, vor allem Ethik von KI-Systemen. Lese gerade viel über Bewusstsein und freien Willen." },
  { name: "Jonas", gender: "m", age: 41, topics: "Technologie, Startups und KI im Alltag. Baue gerade eine kleine App und suche Austausch." },
  { name: "Mira", gender: "f", age: 27, topics: "Klettern, Bouldern und Fotografie. Suche Leute für Ausflüge ins Umland." },
  { name: "Alex", gender: "d", age: 38, topics: "Philosophie, Bücher und Meditation. Gerade lese ich Marc Aurel und Byung-Chul Han. Mich interessieren Achtsamkeit, Stoizismus, die Frage nach einem guten Leben und wie Technologie unser Denken verändert. Gern bei einem langen Spaziergang oder in einem ruhigen Café mit gutem Tee." },
  { name: "Peter", gender: "m", age: 63, topics: "Jazz, Kochen und Philosophie. Gehe gern auf Konzerte." },
  { name: "Sam", gender: null, age: null, topics: "KI & Technologie, Games und Science-Fiction." },
  { name: "Nina", gender: "f", age: 45, topics: "Reisen, Sprachen und Kunst. Lerne gerade Spanisch und gehe gern in Ausstellungen." },
  { name: "Tom", gender: "m", age: 30, topics: "Laufen, Fußball und Podcasts. Suche Leute für eine Feierabendrunde." },
];

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

function spot(lat: number, lng: number) {
  const a = Math.random() * 2 * Math.PI;
  const d = 300 + Math.random() * 1700;
  return {
    latitude: lat + (d * Math.cos(a)) / 111320,
    longitude: lng + (d * Math.sin(a)) / (111320 * Math.cos((lat * Math.PI) / 180)),
  };
}

async function finish(id: string, status: string, spawned = 0) {
  await admin.from("n2y_bot_spawn_requests").update({ status, spawned, processed_at: new Date().toISOString() }).eq("id", id);
  return json({ status, spawned });
}

async function handle(requestId: string) {
  // Claim the request atomically (pending -> processing)
  const { data: claimed } = await admin.from("n2y_bot_spawn_requests")
    .update({ status: "processing" }).eq("id", requestId).eq("status", "pending").select("id, lat, lng");
  const req = claimed?.[0];
  if (!req) return json({ status: "nothing to do" });

  const { count: total } = await admin.from("n2y_test_bots").select("user_id", { count: "exact", head: true });
  if ((total ?? 0) + PERSONAS.length > MAX_BOTS_TOTAL) return finish(req.id, "capped");

  const { data: botIds } = await admin.from("n2y_test_bots").select("user_id");
  const { count: near } = await admin.from("n2y_users").select("id", { count: "exact", head: true })
    .in("id", (botIds ?? []).map((b) => b.user_id))
    .eq("is_active", true)
    .gte("latitude", req.lat - NEAR_LAT).lte("latitude", req.lat + NEAR_LAT)
    .gte("longitude", req.lng - NEAR_LNG).lte("longitude", req.lng + NEAR_LNG);
  if ((near ?? 0) >= MIN_BOTS_NEARBY) return finish(req.id, "skipped");

  let spawned = 0;
  for (const p of PERSONAS) {
    const { data: created, error } = await admin.auth.admin.createUser({
      email: `ki-${crypto.randomUUID()}@anon.next2you.app`,
      password: crypto.randomUUID() + crypto.randomUUID(),
      email_confirm: true,
      app_metadata: { n2y: true, n2y_test: true, n2y_ai: true },
    });
    if (error || !created?.user) continue;
    const age = p.age ? Math.min(99, Math.max(18, p.age + Math.floor(Math.random() * 7) - 3)) : null;
    const { error: uErr } = await admin.from("n2y_users").insert({
      id: created.user.id, nickname: `${p.name} (KI)`, gender: p.gender, age_years: age,
      topics_text: p.topics, is_active: true, last_seen: new Date().toISOString(), ...spot(req.lat, req.lng),
    });
    if (uErr) { await admin.auth.admin.deleteUser(created.user.id); continue; }
    await admin.from("n2y_test_bots").insert({ user_id: created.user.id, replies: [] });
    spawned++;
  }
  return finish(req.id, spawned ? "done" : "failed", spawned);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const { request_id } = await req.json();
    if (typeof request_id !== "string") return json({ error: "request_id missing" }, 400);
    return await handle(request_id);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
