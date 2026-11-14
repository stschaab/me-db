-- Next2You – Supabase Setup (Projekt thgawuqcogugzurrijkp)
-- Angewendet als Migration "n2y_setup". Idempotent.
-- Registrierung läuft über die Edge Function n2y-signup (siehe edge-functions/n2y-signup.ts),
-- die Nutzer mit app_metadata.n2y = true anlegt.

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;

-- ─── Tabellen ────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.n2y_users (
  id          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  nickname    TEXT CHECK (char_length(nickname) <= 30),
  gender      TEXT CHECK (gender IN ('m', 'f', 'd')),
  age_years   INT  CHECK (age_years BETWEEN 16 AND 99),
  latitude    DOUBLE PRECISION CHECK (latitude BETWEEN -90 AND 90),
  longitude   DOUBLE PRECISION CHECK (longitude BETWEEN -180 AND 180),
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  topics_text TEXT CHECK (char_length(topics_text) <= 500)
);

CREATE TABLE IF NOT EXISTS public.n2y_conversations (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  user1_id   UUID NOT NULL REFERENCES public.n2y_users(id) ON DELETE CASCADE,
  user2_id   UUID NOT NULL REFERENCES public.n2y_users(id) ON DELETE CASCADE,
  CHECK (user1_id <> user2_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS n2y_conversations_pair
  ON public.n2y_conversations (LEAST(user1_id, user2_id), GREATEST(user1_id, user2_id));

CREATE TABLE IF NOT EXISTS public.n2y_messages (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  conversation_id UUID NOT NULL REFERENCES public.n2y_conversations(id) ON DELETE CASCADE,
  sender_id       UUID NOT NULL REFERENCES public.n2y_users(id) ON DELETE CASCADE,
  content         TEXT NOT NULL CHECK (char_length(content) BETWEEN 1 AND 2000),
  is_read         BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE INDEX IF NOT EXISTS n2y_messages_conv ON public.n2y_messages (conversation_id, created_at);

-- ─── RLS für Next2You-Tabellen ───────────────────────────────────────────────

ALTER TABLE public.n2y_users         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.n2y_conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.n2y_messages      ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "n2y: own user row" ON public.n2y_users;
CREATE POLICY "n2y: own user row" ON public.n2y_users
  FOR ALL TO authenticated
  USING (auth.uid() = id) WITH CHECK (auth.uid() = id);

DROP POLICY IF EXISTS "n2y: own conversations" ON public.n2y_conversations;
DROP POLICY IF EXISTS "n2y: read own conversations" ON public.n2y_conversations;
CREATE POLICY "n2y: read own conversations" ON public.n2y_conversations
  FOR SELECT TO authenticated
  USING (auth.uid() IN (user1_id, user2_id));
DROP POLICY IF EXISTS "n2y: start conversation" ON public.n2y_conversations;
CREATE POLICY "n2y: start conversation" ON public.n2y_conversations
  FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = user1_id);

DROP POLICY IF EXISTS "n2y: own messages" ON public.n2y_messages;
DROP POLICY IF EXISTS "n2y: read messages" ON public.n2y_messages;
CREATE POLICY "n2y: read messages" ON public.n2y_messages
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.n2y_conversations c
                 WHERE c.id = conversation_id AND auth.uid() IN (c.user1_id, c.user2_id)));
DROP POLICY IF EXISTS "n2y: send messages" ON public.n2y_messages;
CREATE POLICY "n2y: send messages" ON public.n2y_messages
  FOR INSERT TO authenticated
  WITH CHECK (sender_id = auth.uid() AND EXISTS (
    SELECT 1 FROM public.n2y_conversations c
    WHERE c.id = conversation_id AND auth.uid() IN (c.user1_id, c.user2_id)));

-- ─── Schutz der me-db-Daten vor Next2You-Nutzern ─────────────────────────────

CREATE OR REPLACE FUNCTION public.n2y_is_n2y_user()
RETURNS BOOLEAN LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT COALESCE((auth.jwt() -> 'app_metadata' ->> 'n2y')::BOOLEAN, FALSE)
      OR COALESCE((auth.jwt() ->> 'is_anonymous')::BOOLEAN, FALSE);
$$;

DO $$
DECLARE t RECORD;
BEGIN
  FOR t IN SELECT tablename FROM pg_tables
           WHERE schemaname = 'public' AND rowsecurity AND tablename NOT LIKE 'n2y\_%'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS "block n2y users" ON public.%I', t.tablename);
    EXECUTE format('CREATE POLICY "block n2y users" ON public.%I AS RESTRICTIVE FOR ALL TO authenticated
                    USING (NOT (SELECT public.n2y_is_n2y_user())) WITH CHECK (NOT (SELECT public.n2y_is_n2y_user()))', t.tablename);
  END LOOP;

  BEGIN
    EXECUTE 'DROP POLICY IF EXISTS "block n2y users" ON storage.objects';
    EXECUTE 'CREATE POLICY "block n2y users" ON storage.objects AS RESTRICTIVE FOR ALL TO authenticated
             USING (NOT (SELECT public.n2y_is_n2y_user())) WITH CHECK (NOT (SELECT public.n2y_is_n2y_user()))';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'storage.objects: keine Rechte für Policy';
  END;
END $$;

-- ─── Funktionen ──────────────────────────────────────────────────────────────

-- Distanz und Ausgabe nur auf ~200-m-Raster, damit sich keine genaue Position triangulieren lässt
DROP FUNCTION IF EXISTS public.n2y_nearby_matches(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, TEXT, TEXT, INT, INT);
CREATE FUNCTION public.n2y_nearby_matches(
  my_lat        DOUBLE PRECISION,
  my_lng        DOUBLE PRECISION,
  radius_km     DOUBLE PRECISION,
  my_text       TEXT,
  gender_filter TEXT DEFAULT NULL,
  age_min       INT  DEFAULT NULL,
  age_max       INT  DEFAULT NULL
)
RETURNS TABLE(id UUID, nickname TEXT, gender TEXT, age_years INT,
              lat_approx DOUBLE PRECISION, lng_approx DOUBLE PRECISION,
              topics_text TEXT, sim REAL)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH cand AS (
    SELECT u.id, u.nickname, u.gender, u.age_years, u.topics_text,
           ROUND(u.latitude  / 0.0018) * 0.0018 AS lat_a,
           ROUND(u.longitude / 0.0027) * 0.0027 AS lng_a
    FROM public.n2y_users u
    WHERE auth.uid() IS NOT NULL
      AND u.id <> auth.uid()
      AND u.is_active
      AND u.last_seen > NOW() - INTERVAL '2 hours'
      AND u.latitude IS NOT NULL
      AND (gender_filter IS NULL OR u.gender = gender_filter)
      AND (age_min IS NULL OR u.age_years >= age_min)
      AND (age_max IS NULL OR u.age_years <= age_max)
  )
  SELECT c.id, c.nickname, c.gender, c.age_years, c.lat_a, c.lng_a, c.topics_text,
         extensions.similarity(COALESCE(c.topics_text, ''), COALESCE(my_text, ''))::REAL
  FROM cand c
  WHERE 6371 * acos(LEAST(1.0,
          cos(radians(my_lat)) * cos(radians(c.lat_a)) * cos(radians(c.lng_a) - radians(my_lng)) +
          sin(radians(my_lat)) * sin(radians(c.lat_a)))) < LEAST(radius_km, 10)
  ORDER BY 8 DESC
  LIMIT 30;
$$;

-- Öffentliches Profil (ohne Koordinaten): aktive Nutzer oder eigene Gesprächspartner
CREATE OR REPLACE FUNCTION public.n2y_profile(p_id UUID)
RETURNS TABLE(id UUID, nickname TEXT, gender TEXT, age_years INT, topics_text TEXT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT u.id, u.nickname, u.gender, u.age_years, u.topics_text
  FROM public.n2y_users u
  WHERE u.id = p_id AND auth.uid() IS NOT NULL
    AND (u.is_active OR EXISTS (
      SELECT 1 FROM public.n2y_conversations c
      WHERE LEAST(c.user1_id, c.user2_id) = LEAST(u.id, auth.uid())
        AND GREATEST(c.user1_id, c.user2_id) = GREATEST(u.id, auth.uid())));
$$;

CREATE OR REPLACE FUNCTION public.n2y_my_conversations()
RETURNS TABLE(conversation_id UUID, partner_id UUID, partner_nickname TEXT,
              last_message TEXT, last_at TIMESTAMPTZ, unread BIGINT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT c.id, p.id, p.nickname, lm.content, COALESCE(lm.created_at, c.created_at),
         (SELECT COUNT(*) FROM public.n2y_messages m
          WHERE m.conversation_id = c.id AND m.sender_id <> auth.uid() AND NOT m.is_read)
  FROM public.n2y_conversations c
  JOIN public.n2y_users p
    ON p.id = CASE WHEN c.user1_id = auth.uid() THEN c.user2_id ELSE c.user1_id END
  LEFT JOIN LATERAL (
    SELECT m.content, m.created_at FROM public.n2y_messages m
    WHERE m.conversation_id = c.id ORDER BY m.created_at DESC LIMIT 1
  ) lm ON TRUE
  WHERE auth.uid() IN (c.user1_id, c.user2_id)
  ORDER BY 5 DESC;
$$;

CREATE OR REPLACE FUNCTION public.n2y_mark_read(p_conversation UUID)
RETURNS VOID LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE public.n2y_messages m SET is_read = TRUE
  WHERE m.conversation_id = p_conversation
    AND m.sender_id <> auth.uid()
    AND NOT m.is_read
    AND EXISTS (SELECT 1 FROM public.n2y_conversations c
                WHERE c.id = p_conversation AND auth.uid() IN (c.user1_id, c.user2_id));
$$;

REVOKE EXECUTE ON FUNCTION public.n2y_nearby_matches(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, TEXT, TEXT, INT, INT) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.n2y_profile(UUID) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.n2y_my_conversations() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.n2y_mark_read(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2y_nearby_matches(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, TEXT, TEXT, INT, INT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.n2y_profile(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.n2y_my_conversations() TO authenticated;
GRANT EXECUTE ON FUNCTION public.n2y_mark_read(UUID) TO authenticated;

-- ─── Realtime ────────────────────────────────────────────────────────────────

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                 WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'n2y_messages') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.n2y_messages;
  END IF;
END $$;

-- ─── Migration "n2y_autoguard_and_signup_limit" + "n2y_signup_slot" ──────────

-- Neue me-db-Tabellen mit RLS bekommen den Next2You-Riegel automatisch
CREATE OR REPLACE FUNCTION public.n2y_autoguard_new_tables()
RETURNS event_trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT c.relname
    FROM pg_event_trigger_ddl_commands() d
    JOIN pg_class c ON c.oid = d.objid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE d.object_type = 'table' AND n.nspname = 'public'
      AND c.relrowsecurity AND c.relname NOT LIKE 'n2y\_%'
      AND NOT EXISTS (SELECT 1 FROM pg_policies p
                      WHERE p.schemaname = 'public' AND p.tablename = c.relname AND p.policyname = 'block n2y users')
  LOOP
    EXECUTE format('CREATE POLICY "block n2y users" ON public.%I AS RESTRICTIVE FOR ALL TO authenticated
                    USING (NOT (SELECT public.n2y_is_n2y_user())) WITH CHECK (NOT (SELECT public.n2y_is_n2y_user()))', r.relname);
  END LOOP;
END $$;

DROP EVENT TRIGGER IF EXISTS n2y_autoguard;
CREATE EVENT TRIGGER n2y_autoguard ON ddl_command_end
  WHEN TAG IN ('CREATE TABLE', 'ALTER TABLE')
  EXECUTE FUNCTION public.n2y_autoguard_new_tables();
REVOKE EXECUTE ON FUNCTION public.n2y_autoguard_new_tables() FROM PUBLIC, anon, authenticated;

-- Registrierungs-Limit pro IP (nur Hash gespeichert, nur service_role)
CREATE TABLE IF NOT EXISTS public.n2y_signups (
  ip_hash    TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS n2y_signups_ip_time ON public.n2y_signups (ip_hash, created_at);
ALTER TABLE public.n2y_signups ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.n2y_signup_slot(p_ip_hash TEXT, p_max INT)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('n2y_signup:' || p_ip_hash));
  IF (SELECT COUNT(*) FROM public.n2y_signups
      WHERE ip_hash = p_ip_hash AND created_at > NOW() - INTERVAL '1 hour') >= p_max THEN
    RETURN FALSE;
  END IF;
  INSERT INTO public.n2y_signups (ip_hash) VALUES (p_ip_hash);
  DELETE FROM public.n2y_signups WHERE created_at < NOW() - INTERVAL '1 day';
  RETURN TRUE;
END $$;
REVOKE EXECUTE ON FUNCTION public.n2y_signup_slot(TEXT, INT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2y_signup_slot(TEXT, INT) TO service_role;

-- ─── Themen-Match: Anteil meiner Themenwörter, die beim anderen vorkommen ─────
-- Ersetzt die reine Trigramm-Ähnlichkeit, die lange Texte stark benachteiligt hat.
CREATE OR REPLACE FUNCTION public.n2y_topic_match(mine TEXT, theirs TEXT)
RETURNS REAL LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  WITH words AS (
    SELECT DISTINCT w FROM regexp_split_to_table(lower(COALESCE(mine, '')), '[^[:alnum:]äöüß]+') AS w
    WHERE char_length(w) >= 2 AND w NOT IN (
      'und','oder','ich','mich','mir','mein','meine','gerade','viel','sehr','gern','gerne','auch','über','ueber',
      'für','fuer','mit','der','die','das','den','dem','des','ein','eine','einen','einem','zu','zum','zur','im','in',
      'am','an','auf','vor','allem','bin','mag','liebe','lese','suche','leute','interessiere','interessieren',
      'mich','sich','wie','was','ist','sind','bei','von','vom','aus','als','es','du','wir','man','alles','gut')
  )
  SELECT CASE WHEN COUNT(*) = 0 OR COALESCE(theirs, '') = '' THEN 0::REAL
    ELSE (COUNT(*) FILTER (WHERE extensions.word_similarity(w, lower(theirs)) >= 0.6))::REAL / COUNT(*) END
  FROM words;
$$;
-- n2y_nearby_matches nutzt seitdem public.n2y_topic_match(my_text, c.topics_text) als "sim"
-- und sortiert bei Gleichstand nach Spitzname.

-- ─── Nur für Tests: Antwort-Bots ─────────────────────────────────────────────
-- KI-Testnutzer (Spitzname "… (KI)", früher "… (Test)", app_metadata.n2y_test) antworten automatisch.
-- Aufräumen:
--   DELETE FROM auth.users WHERE raw_app_meta_data->>'n2y_test' = 'true';
--   DROP TRIGGER n2y_test_bot_reply ON public.n2y_messages;
--   DROP FUNCTION public.n2y_test_bot_reply(); DROP TABLE public.n2y_test_bots;
CREATE TABLE IF NOT EXISTS public.n2y_test_bots (
  user_id UUID PRIMARY KEY REFERENCES public.n2y_users(id) ON DELETE CASCADE,
  replies TEXT[] NOT NULL
);
ALTER TABLE public.n2y_test_bots ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.n2y_test_bot_reply()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $f$
DECLARE v_bot UUID; v_replies TEXT[]; n INT;
BEGIN
  SELECT b.user_id, b.replies INTO v_bot, v_replies
  FROM public.n2y_conversations c
  JOIN public.n2y_test_bots b
    ON b.user_id = CASE WHEN c.user1_id = NEW.sender_id THEN c.user2_id ELSE c.user1_id END
  WHERE c.id = NEW.conversation_id;
  IF v_bot IS NULL OR EXISTS (SELECT 1 FROM public.n2y_test_bots WHERE user_id = NEW.sender_id) THEN
    RETURN NULL;
  END IF;
  SELECT COUNT(*) INTO n FROM public.n2y_messages
  WHERE conversation_id = NEW.conversation_id AND sender_id = NEW.sender_id;
  INSERT INTO public.n2y_messages (conversation_id, sender_id, content, created_at)
  VALUES (NEW.conversation_id, v_bot, v_replies[LEAST(n, array_length(v_replies, 1))], NOW() + INTERVAL '2 seconds');
  RETURN NULL;
END $f$;
REVOKE EXECUTE ON FUNCTION public.n2y_test_bot_reply() FROM PUBLIC, anon, authenticated;
CREATE OR REPLACE TRIGGER n2y_test_bot_reply AFTER INSERT ON public.n2y_messages
  FOR EACH ROW EXECUTE FUNCTION public.n2y_test_bot_reply();

-- ─── Anwesenheit: aktiv / inaktiv / offline ──────────────────────────────────
-- Jede sichtbare Next2You-Seite ruft minütlich n2y_heartbeat() (presence.js),
-- beim Schließen des Tabs n2y_offline(). Pins verschwinden bei offline oder
-- nach 2 h ohne Heartbeat; dazwischen liefert n2y_people_nearby inactive_min.
-- Hinweis: n2y_topic_match (oben) war versehentlich nicht aktiv und wurde hier neu angelegt.
ALTER TABLE public.n2y_users ADD COLUMN IF NOT EXISTS offline_at TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION public.n2y_heartbeat()
RETURNS VOID LANGUAGE sql SET search_path = '' AS $$
  UPDATE public.n2y_users SET last_seen = GREATEST(last_seen, NOW()), offline_at = NULL WHERE id = auth.uid();
$$;

CREATE OR REPLACE FUNCTION public.n2y_offline()
RETURNS VOID LANGUAGE sql SET search_path = '' AS $$
  UPDATE public.n2y_users SET offline_at = NOW() WHERE id = auth.uid();
$$;

CREATE OR REPLACE FUNCTION public.n2y_people_nearby(
  my_lat DOUBLE PRECISION, my_lng DOUBLE PRECISION, radius_km DOUBLE PRECISION, my_text TEXT,
  gender_filter TEXT DEFAULT NULL, age_min INT DEFAULT NULL, age_max INT DEFAULT NULL)
RETURNS TABLE(id UUID, nickname TEXT, gender TEXT, age_years INT,
              lat_approx DOUBLE PRECISION, lng_approx DOUBLE PRECISION, topics_text TEXT, sim REAL,
              inactive_min INT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH cand AS (
    SELECT u.id, u.nickname, u.gender, u.age_years, u.topics_text, u.last_seen,
           ROUND(u.latitude  / 0.0018) * 0.0018 AS lat_a,
           ROUND(u.longitude / 0.0027) * 0.0027 AS lng_a
    FROM public.n2y_users u
    WHERE auth.uid() IS NOT NULL AND u.id <> auth.uid() AND u.is_active
      AND u.last_seen > NOW() - INTERVAL '2 hours' AND u.latitude IS NOT NULL
      AND (u.offline_at IS NULL OR u.offline_at < u.last_seen)
      AND (gender_filter IS NULL OR u.gender = gender_filter)
      AND (age_min IS NULL OR u.age_years >= age_min)
      AND (age_max IS NULL OR u.age_years <= age_max)
  )
  SELECT c.id, c.nickname, c.gender, c.age_years, c.lat_a, c.lng_a, c.topics_text,
         public.n2y_topic_match(my_text, c.topics_text),
         GREATEST(0, FLOOR(EXTRACT(EPOCH FROM (NOW() - c.last_seen)) / 60))::INT
  FROM cand c
  WHERE 6371 * acos(LEAST(1.0,
          cos(radians(my_lat)) * cos(radians(c.lat_a)) * cos(radians(c.lng_a) - radians(my_lng)) +
          sin(radians(my_lat)) * sin(radians(c.lat_a)))) < LEAST(radius_km, 10)
  ORDER BY 8 DESC, c.nickname
  LIMIT 30;
$$;

-- Alte Funktion bleibt als Wrapper erhalten (Ersetzen bräuchte DROP)
CREATE OR REPLACE FUNCTION public.n2y_nearby_matches(
  my_lat DOUBLE PRECISION, my_lng DOUBLE PRECISION, radius_km DOUBLE PRECISION, my_text TEXT,
  gender_filter TEXT DEFAULT NULL, age_min INT DEFAULT NULL, age_max INT DEFAULT NULL)
RETURNS TABLE(id UUID, nickname TEXT, gender TEXT, age_years INT,
              lat_approx DOUBLE PRECISION, lng_approx DOUBLE PRECISION, topics_text TEXT, sim REAL)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT p.id, p.nickname, p.gender, p.age_years, p.lat_approx, p.lng_approx, p.topics_text, p.sim
  FROM public.n2y_people_nearby(my_lat, my_lng, radius_km, my_text, gender_filter, age_min, age_max) p;
$$;

REVOKE EXECUTE ON FUNCTION public.n2y_heartbeat() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.n2y_offline() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.n2y_people_nearby(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, TEXT, TEXT, INT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2y_heartbeat() TO authenticated;
GRANT EXECUTE ON FUNCTION public.n2y_offline() TO authenticated;
GRANT EXECUTE ON FUNCTION public.n2y_people_nearby(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, TEXT, TEXT, INT, INT) TO authenticated;

-- ─── Status der Gesprächspartner (aktiv / inaktiv / offline) ─────────────────
-- Nur für eigene Gesprächspartner; wer "unsichtbar" ist, liefert 'hidden'.
CREATE OR REPLACE FUNCTION public.n2y_partner_presence()
RETURNS TABLE(partner_id UUID, status TEXT, inactive_min INT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT p.id,
         CASE WHEN NOT p.is_active THEN 'hidden'
              WHEN (p.offline_at IS NOT NULL AND p.offline_at >= p.last_seen)
                   OR p.last_seen < NOW() - INTERVAL '2 hours' THEN 'offline'
              WHEN p.last_seen > NOW() - INTERVAL '3 minutes' THEN 'active'
              ELSE 'idle' END,
         GREATEST(0, FLOOR(EXTRACT(EPOCH FROM (NOW() - p.last_seen)) / 60))::INT
  FROM public.n2y_conversations c
  JOIN public.n2y_users p
    ON p.id = CASE WHEN c.user1_id = auth.uid() THEN c.user2_id ELSE c.user1_id END
  WHERE auth.uid() IN (c.user1_id, c.user2_id);
$$;
REVOKE EXECUTE ON FUNCTION public.n2y_partner_presence() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2y_partner_presence() TO authenticated;

-- ─── Testnutzer antworten menschlich (Edge Function n2y-bot-reply) ───────────
-- Der Trigger antwortet nicht mehr selbst, sondern ruft per pg_net die Edge Function
-- auf (edge-functions/n2y-bot-reply). Diese wartet kurz, sendet "tippt…" (Realtime-Broadcast
-- auf typing:<conversation_id>) und antwortet passend zum Gesprächsverlauf (bots.js).
-- n2y_test_bots.replies wird nicht mehr genutzt.
CREATE OR REPLACE FUNCTION public.n2y_test_bot_reply()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $f$
DECLARE v_bot UUID;
BEGIN
  IF EXISTS (SELECT 1 FROM public.n2y_test_bots WHERE user_id = NEW.sender_id) THEN
    RETURN NULL;
  END IF;
  SELECT b.user_id INTO v_bot
  FROM public.n2y_conversations c
  JOIN public.n2y_test_bots b
    ON b.user_id = CASE WHEN c.user1_id = NEW.sender_id THEN c.user2_id ELSE c.user1_id END
  WHERE c.id = NEW.conversation_id;
  IF v_bot IS NULL THEN
    RETURN NULL;
  END IF;
  PERFORM net.http_post(
    url := 'https://thgawuqcogugzurrijkp.supabase.co/functions/v1/n2y-bot-reply',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'Authorization', 'Bearer <ANON_KEY>'),
    body := jsonb_build_object('message_id', NEW.id),
    timeout_milliseconds := 5000);
  RETURN NULL;
END $f$;
-- (Live-Version enthält den öffentlichen Anon-Key statt <ANON_KEY>.)

-- ─── Semantischer Interessen-Match (Embeddings) ──────────────────────────────
-- Edge Function n2y-embed (edge-functions/n2y-embed) berechnet bei jeder Änderung von
-- topics_text ein Embedding: voyage-3, wenn das Secret VOYAGE_API_KEY gesetzt ist, sonst
-- Supabases eingebautes gte-small. Match = max(Wort-Match, kalibrierter Cosinus).
-- Nach Wechsel des Modells: alle Profile neu einbetten (n2y-embed mit {user_id} je Profil aufrufen).
ALTER TABLE public.n2y_users ADD COLUMN IF NOT EXISTS topics_embedding public.vector;
ALTER TABLE public.n2y_users ADD COLUMN IF NOT EXISTS topics_embedding_model TEXT;

CREATE OR REPLACE FUNCTION public.n2y_semantic_match(model TEXT, cos_sim DOUBLE PRECISION)
RETURNS REAL LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE
    WHEN cos_sim IS NULL THEN 0
    WHEN model = 'gte-small' THEN GREATEST(0, LEAST(1, (cos_sim - 0.80) / 0.12))
    WHEN model = 'voyage-3'  THEN GREATEST(0, LEAST(1, (cos_sim - 0.35) / 0.40))
    ELSE 0 END::REAL;
$$;

CREATE OR REPLACE FUNCTION public.n2y_request_embedding()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $f$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.topics_text IS NOT DISTINCT FROM OLD.topics_text THEN
    RETURN NULL;
  END IF;
  PERFORM net.http_post(
    url := 'https://thgawuqcogugzurrijkp.supabase.co/functions/v1/n2y-embed',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer <ANON_KEY>'),
    body := jsonb_build_object('user_id', NEW.id),
    timeout_milliseconds := 30000);
  RETURN NULL;
END $f$;
REVOKE EXECUTE ON FUNCTION public.n2y_request_embedding() FROM PUBLIC, anon, authenticated;
CREATE OR REPLACE TRIGGER n2y_request_embedding AFTER INSERT OR UPDATE OF topics_text ON public.n2y_users
  FOR EACH ROW EXECUTE FUNCTION public.n2y_request_embedding();

-- n2y_people_nearby: Spalte "sim" ist jetzt
--   GREATEST(n2y_topic_match(my_text, c.topics_text),
--            n2y_semantic_match(me.model, 1 - (me.emb <=> c.topics_embedding)))  -- nur bei gleichem Modell
-- (vollständige Live-Definition siehe Datenbank; Signatur unverändert)
