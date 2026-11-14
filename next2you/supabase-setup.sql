-- Next2You – Supabase Setup (Projekt thgawuqcogugzurrijkp)
-- Angewendet als Migration "n2y_setup". Idempotent.
-- Registrierung läuft über die Edge Function n2y-signup (siehe edge-function-n2y-signup.ts),
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
