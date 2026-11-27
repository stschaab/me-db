-- MeDB · Neuer Hund: Kandidatenliste (eine Zeile pro Anzeige)
-- Wird vom Such-Thread per Upsert auf anzeige_url befüllt, Seite: me-db-hund.html
create table if not exists public.hund_kandidaten (
  id bigint generated always as identity primary key,
  user_id text default '54f4ec44-d2f6-49c7-baca-f76181ea0870',
  name text,
  rasse text,
  geschlecht text check (geschlecht in ('m','w')),
  alter_monate int,
  gewicht_kg numeric,
  ort text,
  plz text,
  entfernung_km numeric,              -- ab Erlangen-Tennenlohe
  quelle text,                        -- 'Tasso', 'Kleinanzeigen', 'Tierheim Erlangen', …
  anzeige_url text unique,
  anzeige_datum date,
  bild_url text,
  stubenrein boolean,                 -- null = unbekannt
  vertraeglich_hunde boolean,
  vertraeglich_fremde boolean,
  bellt_wenig boolean,
  kastriert boolean,
  kinderlieb boolean,
  score int check (score between 0 and 100),
  kontakt_name text,
  kontakt_info text,
  status text not null default 'neu' check (status in
    ('neu','angeschrieben','antwort','besuch_geplant','besucht','favorit','abgesagt','vergeben','passt_nicht')),
  letzter_kontakt timestamptz,
  naechster_schritt text,
  notizen text,
  verlauf jsonb not null default '[]'::jsonb,  -- [{datum, richtung:'raus'|'rein', kanal, text}]
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.hund_kandidaten enable row level security;

-- Familien-Tabelle: alle MeDB-Konten dürfen lesen/schreiben; Next2You-Konten blockt die restriktive Policy.
create policy "medb users all" on public.hund_kandidaten
  for all to authenticated using (true) with check (true);

do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'hund_kandidaten' and policyname = 'block n2y users') then
    execute 'create policy "block n2y users" on public.hund_kandidaten as restrictive for all to authenticated
             using (not (select n2y_is_n2y_user())) with check (not (select n2y_is_n2y_user()))';
  end if;
end $$;

create or replace function public.hund_kandidaten_touch() returns trigger
  language plpgsql set search_path = public as $$
begin new.updated_at = now(); return new; end $$;

create trigger hund_kandidaten_touch before update on public.hund_kandidaten
  for each row execute function public.hund_kandidaten_touch();

notify pgrst, 'reload schema';
