// Supabase Edge Function "n2y-bot-reply" – deployed via Supabase MCP.
// Called by the DB trigger n2y_test_bot_reply (pg_net) when someone writes to a test persona.
// Replies like a person: short reading pause, "tippt…" broadcast, typing time by length, then the message.
// Only answers for users listed in n2y_test_bots; the reply text is chosen server-side.
import { createClient } from "npm:@supabase/supabase-js@2";
import { pickReply } from "./bots.js";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const rand = (a: number, b: number) => a + Math.random() * (b - a);

async function broadcastTyping(conversationId: string, userId: string) {
  await fetch(`${SUPABASE_URL}/realtime/v1/api/broadcast`, {
    method: "POST",
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ messages: [{ topic: `typing:${conversationId}`, event: "typing", payload: { user_id: userId } }] }),
  }).catch(() => {});
}

async function handle(messageId: string) {
  const { data: msg } = await admin.from("n2y_messages")
    .select("id, conversation_id, sender_id, created_at").eq("id", messageId).maybeSingle();
  if (!msg) return;
  const { data: conv } = await admin.from("n2y_conversations")
    .select("user1_id, user2_id").eq("id", msg.conversation_id).maybeSingle();
  if (!conv) return;
  const botId = conv.user1_id === msg.sender_id ? conv.user2_id : conv.user1_id;
  const { data: isBot } = await admin.from("n2y_test_bots").select("user_id").eq("user_id", botId).maybeSingle();
  const { data: senderIsBot } = await admin.from("n2y_test_bots").select("user_id").eq("user_id", msg.sender_id).maybeSingle();
  if (!isBot || senderIsBot) return;

  await sleep(rand(2500, 5000));

  // Several quick messages in a row get one answer: only the newest message's call replies
  const isNewest = async () => {
    const { data: newer } = await admin.from("n2y_messages").select("id")
      .eq("conversation_id", msg.conversation_id).eq("sender_id", msg.sender_id)
      .or(`created_at.gt.${msg.created_at},and(created_at.eq.${msg.created_at},id.gt.${msg.id})`).limit(1);
    return !(newer && newer.length);
  };
  if (!(await isNewest())) return;

  const [{ data: people }, { data: history }] = await Promise.all([
    admin.from("n2y_users").select("id, nickname").in("id", [botId, msg.sender_id]),
    admin.from("n2y_messages").select("sender_id, content, created_at")
      .eq("conversation_id", msg.conversation_id).order("created_at", { ascending: true }).limit(300),
  ]);
  const nick = (id: string) => people?.find((p) => p.id === id)?.nickname ?? "";
  const text = pickReply({
    bot: nick(botId),
    humanName: nick(msg.sender_id),
    history: (history ?? []).map((h) => ({ fromBot: h.sender_id === botId, text: h.content })),
    now: new Date(),
  });

  const typingMs = Math.min(9000, Math.max(1800, text.length * 55));
  for (let t = 0; t < typingMs; t += 2500) {
    await broadcastTyping(msg.conversation_id, botId);
    await sleep(Math.min(2500, typingMs - t));
  }
  // Skip if the person wrote again meanwhile (that call answers) or the bot already replied
  const { data: replied } = await admin.from("n2y_messages").select("id")
    .eq("conversation_id", msg.conversation_id).eq("sender_id", botId).gt("created_at", msg.created_at).limit(1);
  if (!(await isNewest()) || (replied && replied.length)) return;
  await admin.from("n2y_messages").insert({ conversation_id: msg.conversation_id, sender_id: botId, content: text });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
  const { message_id } = await req.json().catch(() => ({}));
  if (typeof message_id !== "string") return new Response("message_id required", { status: 400 });
  // Answer immediately; the human-like delay runs in the background
  // @ts-ignore EdgeRuntime is provided by the Supabase runtime
  EdgeRuntime.waitUntil(handle(message_id));
  return new Response(JSON.stringify({ queued: true }), { status: 202, headers: { "Content-Type": "application/json" } });
});
