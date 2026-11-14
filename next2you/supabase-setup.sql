-- Next2You – Supabase Setup
-- Ausführen im Supabase SQL Editor (Projekt: thgawuqcogugzurrijkp)
--
-- Voraussetzung: Anonymous Sign-ins aktivieren unter
--   Authentication → Configuration → "Enable anonymous sign-ins" ✓

-- Extension für Trigram-Ähnlichkeit (Interesse-Matching)
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ─── Tabellen ────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS n2y_users (
  id              UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  last_seen       TIMESTAMPTZ DEFAULT NOW(),
  nickname        TEXT,
  gender          TEXT CHECK (gender IN ('m', 'f', 'd')),
  age_years       INT  CHECK (age_years BETWEEN 16 AND 99),
  latitude        DOUBLE PRECISION,
  longitude       DOUBLE PRECISION,
  is_active       BOOLEAN DEFAULT TRUE,
  topics_text     TEXT,
  topics_tsvector TSVECTOR GENERATED ALWAYS AS
                  (to_tsvector('german', COALESCE(topics_text, ''))) STORED
);

CREATE TABLE IF NOT EXISTS n2y_conversations (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  user1_id   UUID NOT NULL REFERENCES n2y_users(id) ON DELETE CASCADE,
  user2_id   UUID NOT NULL REFERENCES n2y_users(id) ON DELETE CASCADE,
  UNIQUE(user1_id, user2_id)
);

CREATE TABLE IF NOT EXISTS n2y_messages (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  conversation_id UUID NOT NULL REFERENCES n2y_conversations(id) ON DELETE CASCADE,
  sender_id       UUID NOT NULL REFERENCES n2y_users(id) ON DELETE CASCADE,
  content         TEXT NOT NULL,
  is_read         BOOLEAN DEFAULT FALSE
);

-- ─── Row Level Security ───────────────────────────────────────────────────────

ALTER TABLE n2y_users          ENABLE ROW LEVEL SECURITY;
ALTER TABLE n2y_conversations  ENABLE ROW LEVEL SECURITY;
ALTER TABLE n2y_messages       ENABLE ROW LEVEL SECURITY;

-- Jeder kann nur seine eigene Zeile lesen/schreiben
-- (Koordinaten bleiben so privat; Discovery läuft über die Funktion unten)
CREATE POLICY "n2y: own user row"
  ON n2y_users FOR ALL
  USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

-- Konversationen: nur eigene
CREATE POLICY "n2y: own conversations"
  ON n2y_conversations FOR ALL
  USING (auth.uid() = user1_id OR auth.uid() = user2_id)
  WITH CHECK (auth.uid() = user1_id OR auth.uid() = user2_id);

-- Nachrichten: nur in eigenen Konversationen
CREATE POLICY "n2y: own messages"
  ON n2y_messages FOR ALL
  USING (
    conversation_id IN (
      SELECT id FROM n2y_conversations
      WHERE user1_id = auth.uid() OR user2_id = auth.uid()
    )
  )
  WITH CHECK (
    sender_id = auth.uid() AND
    conversation_id IN (
      SELECT id FROM n2y_conversations
      WHERE user1_id = auth.uid() OR user2_id = auth.uid()
    )
  );

-- ─── Matching-Funktion ────────────────────────────────────────────────────────
-- SECURITY DEFINER: umgeht RLS → kann andere Nutzer sehen,
-- gibt aber nur gerundete Koordinaten zurück (200 m Raster)

CREATE OR REPLACE FUNCTION n2y_nearby_matches(
  my_lat        DOUBLE PRECISION,
  my_lng        DOUBLE PRECISION,
  radius_km     DOUBLE PRECISION,
  my_text       TEXT,
  gender_filter TEXT DEFAULT NULL,
  age_min       INT  DEFAULT NULL,
  age_max       INT  DEFAULT NULL
)
RETURNS TABLE(
  id           UUID,
  nickname     TEXT,
  gender       TEXT,
  age_years    INT,
  lat_approx   DOUBLE PRECISION,
  lng_approx   DOUBLE PRECISION,
  topics_text  TEXT,
  sim          REAL
)
LANGUAGE SQL SECURITY DEFINER AS $$
  SELECT
    u.id,
    u.nickname,
    u.gender,
    u.age_years,
    -- Koordinaten auf ~200 m gerundet (0.0018° ≈ 200 m Lat, 0.0027° ≈ 200 m Lng bei 48°N)
    ROUND(u.latitude  / 0.0018)::DOUBLE PRECISION * 0.0018 AS lat_approx,
    ROUND(u.longitude / 0.0027)::DOUBLE PRECISION * 0.0027 AS lng_approx,
    u.topics_text,
    GREATEST(0, similarity(COALESCE(u.topics_text, ''), COALESCE(my_text, '')))::REAL AS sim
  FROM n2y_users u
  WHERE u.id <> auth.uid()
    AND u.is_active = TRUE
    AND u.last_seen > NOW() - INTERVAL '2 hours'
    AND u.latitude IS NOT NULL
    AND (gender_filter IS NULL OR u.gender = gender_filter)
    AND (age_min IS NULL OR u.age_years >= age_min)
    AND (age_max IS NULL OR u.age_years <= age_max)
    AND (
      6371 * acos(
        LEAST(1.0,
          cos(radians(my_lat)) * cos(radians(u.latitude)) *
          cos(radians(u.longitude) - radians(my_lng)) +
          sin(radians(my_lat)) * sin(radians(u.latitude))
        )
      )
    ) < radius_km
  ORDER BY sim DESC
  LIMIT 30;
$$;

-- Funktion für authentifizierte und anonyme Nutzer aufrufbar machen
GRANT EXECUTE ON FUNCTION n2y_nearby_matches TO authenticated, anon;

-- Realtime für n2y_messages aktivieren
ALTER PUBLICATION supabase_realtime ADD TABLE n2y_messages;
