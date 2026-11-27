-- MeDB · Neuer Hund: Nachrichten mit Haltern (Entwurf → Freigabe → Versand, plus eingehende Antworten)
-- Ablauf: Claude legt status='entwurf' an. Stefan bearbeitet in me-db-hund.html und gibt frei (status='freigegeben').
-- Claude verschickt nur 'freigegeben' und setzt danach 'gesendet' (oder 'fehler'). Antworten: richtung='rein', status='empfangen'.
create table if not exists public.hund_nachrichten (
  id bigint generated always as identity primary key,
  kandidat_id bigint not null references public.hund_kandidaten(id) on delete cascade,
  richtung text not null default 'raus' check (richtung in ('raus','rein')),
  kanal text not null default 'E-Mail',   -- 'E-Mail', 'Kleinanzeigen', 'WhatsApp', 'Formular', 'Telefon'
  empfaenger text,                        -- Mailadresse, Telefonnummer oder Formular-URL
  betreff text,
  text text not null default '',
  status text not null default 'entwurf' check (status in
    ('entwurf','freigegeben','gesendet','fehler','verworfen','empfangen')),
  erstellt_von text not null default 'claude' check (erstellt_von in ('claude','stefan','halter')),
  freigegeben_am timestamptz,
  gesendet_am timestamptz,
  fehler text,
  extern_id text,                         -- z. B. Gmail-Thread-ID oder Kleinanzeigen-Konversation
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists hund_nachrichten_kandidat on public.hund_nachrichten (kandidat_id, created_at);
create index if not exists hund_nachrichten_status on public.hund_nachrichten (status);

alter table public.hund_nachrichten enable row level security;

create policy "medb users all" on public.hund_nachrichten
  for all to authenticated using (true) with check (true);

do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'hund_nachrichten' and policyname = 'block n2y users') then
    execute 'create policy "block n2y users" on public.hund_nachrichten as restrictive for all to authenticated
             using (not (select n2y_is_n2y_user())) with check (not (select n2y_is_n2y_user()))';
  end if;
end $$;

create trigger hund_nachrichten_touch before update on public.hund_nachrichten
  for each row execute function public.hund_kandidaten_touch();

notify pgrst, 'reload schema';

-- Trigger: Nachrichtenstatus → hund_kandidaten (naechster_schritt, status, letzter_kontakt)
-- entwurf → „Entwurf wartet auf Freigabe“, freigegeben → „Freigegeben, wird über <Kanal> gesendet“,
-- gesendet → „Gesendet, Antwort abwarten“ (+ neu→angeschrieben), fehler, empfangen (+ →antwort), verworfen.
-- Quelle: Migration hund_nachrichten_sync_kandidat (Funktion public.hund_nachrichten_sync).
