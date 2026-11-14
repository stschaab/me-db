// Supabase Edge Function "n2y-embed" – deployed via Supabase MCP.
// Computes a semantic embedding of a user's topics_text and stores it in n2y_users.
// Called by the DB trigger on n2y_users (pg_net) whenever topics_text changes.
// Uses Voyage (voyage-3, multilingual) if VOYAGE_API_KEY is set, otherwise Supabase's built-in gte-small.
// {probe: true} compares a fixed set of German example texts (no user input) to check model quality.
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const VOYAGE_KEY = Deno.env.get("VOYAGE_API_KEY");
// @ts-ignore Supabase.ai is provided by the Supabase edge runtime
const gte = new Supabase.ai.Session("gte-small");

async function embedGte(text: string): Promise<number[]> {
  return Array.from(await gte.run(text, { mean_pool: true, normalize: true }) as number[]);
}

async function embedVoyage(text: string): Promise<number[]> {
  const r = await fetch("https://api.voyageai.com/v1/embeddings", {
    method: "POST",
    headers: { Authorization: `Bearer ${VOYAGE_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ input: [text], model: "voyage-3", input_type: "document" }),
  });
  if (!r.ok) throw new Error("voyage " + r.status);
  return (await r.json()).data[0].embedding;
}

const model = VOYAGE_KEY ? "voyage-3" : "gte-small";
const embed = (t: string) => (VOYAGE_KEY ? embedVoyage(t) : embedGte(t));
const cos = (a: number[], b: number[]) => {
  let d = 0, na = 0, nb = 0;
  for (let i = 0; i < a.length; i++) { d += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]; }
  return d / Math.sqrt(na * nb);
};

const PROBE: [string, string][] = [
  ["Klettern und Bouldern", "Ich gehe gern in die Kletterhalle"],
  ["Klettern und Bouldern", "Jazz, Kochen und Philosophie"],
  ["KI & Technologie, Philosophie", "Künstliche Intelligenz und Ethik, Bewusstsein"],
  ["KI & Technologie, Philosophie", "Technologie, Startups und KI im Alltag"],
  ["KI & Technologie, Philosophie", "Stoizismus, Meditation und Bücher"],
  ["KI & Technologie, Philosophie", "Klettern, Bouldern und Fotografie"],
  ["KI & Technologie, Philosophie", "Jazz, Kochen und Rezepte"],
  ["Machine Learning", "Künstliche Intelligenz"],
  ["Fußball", "Kochen"],
];

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
  const body = await req.json().catch(() => ({}));
  const json = (x: unknown, s = 200) => new Response(JSON.stringify(x), { status: s, headers: { "Content-Type": "application/json" } });

  if (body.probe === true) {
    const results = [];
    for (const [a, b] of PROBE) results.push({ a, b, cos: +cos(await embed(a), await embed(b)).toFixed(3) });
    return json({ model, keys: { voyage: !!VOYAGE_KEY, openai: !!Deno.env.get("OPENAI_API_KEY"), anthropic: !!Deno.env.get("ANTHROPIC_API_KEY") }, results });
  }

  if (typeof body.user_id !== "string") return json({ error: "user_id required" }, 400);
  const { data: u } = await admin.from("n2y_users").select("topics_text").eq("id", body.user_id).maybeSingle();
  if (!u) return json({ error: "not found" }, 404);
  const text = (u.topics_text || "").trim();
  const embedding = text ? await embed(text) : null;
  const { error } = await admin.from("n2y_users")
    .update({ topics_embedding: embedding ? JSON.stringify(embedding) : null, topics_embedding_model: embedding ? model : null })
    .eq("id", body.user_id);
  return error ? json({ error: error.message }, 500) : json({ ok: true, model, dims: embedding?.length ?? 0 });
});
