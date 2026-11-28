-- AlarmBoard: zentrale Alarme aller MeDB-Apps (me-db-alarme.html)
-- Quellen:
--   1. Eingebaute Prüfregeln in public.alarm_check() (pg_cron alle 15 min + beim Öffnen des Boards)
--   2. Beliebige Apps/Worker/Agenten per RPC public.raise_alarm(...) / public.resolve_alarm(...)
-- Ein Alarm ist offen, solange resolved_at null ist. Pro alarm_key gibt es höchstens einen offenen Alarm.
-- Quittieren (acked_at) blendet ihn aus „Offen“ aus, bis er neu entsteht oder sich der Text ändert.

create table if not exists public.alarms (
  id bigint generated always as identity primary key,
  alarm_key text not null,
  source text not null,                      -- z. B. 'computer-vision', 'hund', 'sprinkler'
  severity text not null default 'warn' check (severity in ('info','warn','crit')),
  title text not null,
  detail text,
  link text,                                 -- Seite, auf der man es beheben kann
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  acked_at timestamptz,
  resolved_at timestamptz,
  auto boolean not null default false        -- true = von alarm_check() verwaltet
);
create unique index if not exists alarms_open_key on public.alarms (alarm_key) where resolved_at is null;
create index if not exists alarms_created on public.alarms (created_at desc);

alter table public.alarms enable row level security;
do $$ begin if not exists (select 1 from pg_policies where tablename = 'alarms' and policyname = 'medb users all') then
create policy "medb users all" on public.alarms for all to authenticated
  using (exists (select 1 from public.app_users where id = auth.uid()))
  with check (exists (select 1 from public.app_users where id = auth.uid()));
end if; end $$;

-- Nur MeDB-Nutzer (app_users) oder service_role/Cron (auth.uid() null) dürfen die RPCs nutzen
create or replace function public.alarm_assert_medb() returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not exists (select 1 from app_users where id = auth.uid()) then
    raise exception 'not allowed';
  end if;
end $$;

-- Alarm auslösen/aktualisieren (idempotent über alarm_key)
create or replace function public.raise_alarm(p_key text, p_source text, p_severity text, p_title text,
  p_detail text default null, p_link text default null, p_auto boolean default false)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  perform alarm_assert_medb();
  update alarms set severity = p_severity, source = p_source, link = coalesce(p_link, link), last_seen_at = now(),
         acked_at = case when title is distinct from p_title then null else acked_at end,
         title = p_title, detail = p_detail
   where alarm_key = p_key and resolved_at is null returning id into v_id;
  if v_id is null then
    insert into alarms (alarm_key, source, severity, title, detail, link, auto)
    values (p_key, p_source, p_severity, p_title, p_detail, p_link, p_auto) returning id into v_id;
  end if;
  return v_id;
end $$;

create or replace function public.resolve_alarm(p_key text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform alarm_assert_medb();
  update alarms set resolved_at = now() where alarm_key = p_key and resolved_at is null;
end $$;

-- Eingebaute Prüfregeln. Erzeugt Alarme und erledigt automatisch alle auto-Alarme, deren Bedingung weg ist.
create or replace function public.alarm_check()
returns int language plpgsql security definer set search_path = public as $$
declare
  r record; keys text[] := '{}'; k text; n int;
  fmt constant text := 'DD.MM. HH24:MI';
begin
  perform alarm_assert_medb();
  -- Computer Vision: letzte KI-Ablesung (Agent) zu alt. Manuelle Uploads zählen nicht.
  for r in
    select f.id, f.name, f.interval_min,
           (select max(captured_at) from meter_readings m where m.monitoring_function_id = f.id
             and m.plausibility_status in ('ok_by_ai','flagged_by_ai')) as last_ai
      from monitoring_functions f where f.active
  loop
    if r.last_ai is null or r.last_ai < now() - greatest(r.interval_min * 3, 360) * interval '1 minute' then
      k := 'cv-stale-' || r.id; keys := keys || k;
      perform raise_alarm(k, 'computer-vision', 'crit', 'Computer Vision: „' || r.name || '“ liest nicht mehr ab',
        case when r.last_ai is null then 'Noch keine automatische Ablesung.'
             else 'Letzte automatische Ablesung ' || to_char(r.last_ai at time zone 'Europe/Berlin', fmt)
                  || ' (vor ' || extract(day from now() - r.last_ai)::int || ' Tagen), Intervall ' || r.interval_min
                  || ' min. Läuft der Python-Agent auf dem PC (C:\MeDB-Agents)?' end,
        'me-db-computer-vision.html', true);
    end if;
  end loop;

  select count(*) into n from meter_readings where plausibility_status = 'flagged_by_ai' and captured_at > now() - interval '7 days';
  if n > 0 then k := 'cv-flagged'; keys := keys || k;
    perform raise_alarm(k, 'computer-vision', 'warn', 'Computer Vision: ' || n || ' unplausible Ablesung(en)',
      'Von der KI als unplausibel markiert (letzte 7 Tage). Bitte prüfen/korrigieren.', 'me-db-computer-vision.html', true);
  end if;

  -- Sprinkler
  select count(*) into n from sprinkler_commands where status = 'error' and requested_at > now() - interval '3 days';
  if n > 0 then k := 'sprinkler-error'; keys := keys || k;
    perform raise_alarm(k, 'sprinkler', 'warn', 'Sprinkler: ' || n || ' Befehl(e) fehlgeschlagen',
      (select 'Zuletzt ' || to_char(requested_at at time zone 'Europe/Berlin', fmt) || ': ' || coalesce(error_message, 'ohne Meldung')
         from sprinkler_commands where status = 'error' order by requested_at desc limit 1), 'me-db-sprinkler.html', true);
  end if;
  select count(*) into n from sprinkler_commands where status = 'pending' and requested_at < now() - interval '30 minutes';
  if n > 0 then k := 'sprinkler-pending'; keys := keys || k;
    perform raise_alarm(k, 'sprinkler', 'warn', 'Sprinkler: ' || n || ' Befehl(e) hängen', 'Seit über 30 min nicht ausgeführt.', 'me-db-sprinkler.html', true);
  end if;

  -- Datenfeeds
  if (select max(observed_at) from dwd_precip_hourly) < now() - interval '6 hours' then k := 'feed-dwd'; keys := keys || k;
    perform raise_alarm(k, 'sprinkler', 'warn', 'DWD-Regendaten veraltet',
      'Letzter Wert ' || (select to_char(max(observed_at) at time zone 'Europe/Berlin', fmt) from dwd_precip_hourly) || ' (Worker /sync-dwd-rain).', 'me-db-sprinkler.html', true);
  end if;
  if (select max(date) from pv_daily) < current_date - 3 then k := 'feed-pv'; keys := keys || k;
    perform raise_alarm(k, 'pv', 'warn', 'PV-Daten veraltet', 'Letzter Tag ' || (select to_char(max(date), 'DD.MM.YYYY') from pv_daily) || '.', 'me-db-pv.html', true);
  end if;
  if (select max(created_at) from activities) < now() - interval '14 days' then k := 'feed-strava'; keys := keys || k;
    perform raise_alarm(k, 'strava', 'info', 'Strava: seit 14 Tagen keine neue Aktivität',
      'Kein Training – oder hängt der Strava-Sync? Letzter Import ' || (select to_char(max(created_at) at time zone 'Europe/Berlin', fmt) from activities) || '.', 'me-db-strava.html', true);
  end if;

  -- Neuer Hund
  for r in select id, name, ort from hund_kandidaten d where status = 'neu' and not exists (select 1 from hund_nachrichten m
      where m.kandidat_id = d.id and m.richtung = 'raus' and m.status in ('freigegeben','gesendet','fehler')) loop
    k := 'hund-neu-' || r.id; keys := keys || k;
    perform raise_alarm(k, 'hund', 'info', 'Neuer Hund: ' || r.name || coalesce(' (' || r.ort || ')', ''), 'Neuer Kandidat gefunden.', 'me-db-hund.html', true);
  end loop;
  for r in select id, name from hund_kandidaten where status = 'antwort' loop
    k := 'hund-antwort-' || r.id; keys := keys || k;
    perform raise_alarm(k, 'hund', 'warn', 'Neuer Hund: Antwort zu ' || r.name, 'Es ist eine Antwort eingegangen.', 'me-db-hund.html', true);
  end loop;
  for r in select id, name, aktion from hund_kandidaten where aktion is not null and aktion <> '' and not coalesce(aktion_erledigt, false) loop
    k := 'hund-aktion-' || r.id; keys := keys || k;
    perform raise_alarm(k, 'hund', 'warn', 'Neuer Hund: Aktion für dich – ' || r.name, left(r.aktion, 300), 'me-db-hund.html', true);
  end loop;
  select count(*) into n from hund_nachrichten where richtung = 'raus' and
    (status = 'fehler' or (status = 'freigegeben' and coalesce(freigegeben_am, created_at) < now() - interval '15 minutes'));
  if n > 0 then k := 'hund-outbox'; keys := keys || k;
    perform raise_alarm(k, 'hund', 'crit', 'Neuer Hund: ' || n || ' Nachricht(en) hängen in der Outbox', 'Fehler oder seit über 15 min nicht versendet.', 'me-db-hund.html', true);
  end if;
  select count(*) into n from hund_nachrichten where richtung = 'raus' and status = 'entwurf';
  if n > 0 then k := 'hund-entwurf'; keys := keys || k;
    perform raise_alarm(k, 'hund', 'info', 'Neuer Hund: ' || n || ' Entwurf/Entwürfe warten auf Freigabe', null, 'me-db-hund.html', true);
  end if;

  -- Tasks
  select count(*) into n from tasks where status <> 'done' and coalesce(follow_up_date, due_date) < current_date;
  if n > 0 then k := 'tasks-overdue'; keys := keys || k;
    perform raise_alarm(k, 'tasks', 'info', n || ' überfällige Task(s)', null, 'me-db-tasks.html', true);
  end if;

  -- Erledigt: auto-Alarme, deren Bedingung nicht mehr zutrifft
  update alarms set resolved_at = now() where auto and resolved_at is null and not (alarm_key = any(keys));
  return coalesce(array_length(keys, 1), 0);
end $$;

revoke all on function public.raise_alarm(text,text,text,text,text,text,boolean), public.resolve_alarm(text), public.alarm_check(), public.alarm_assert_medb() from public, anon;
grant execute on function public.raise_alarm(text,text,text,text,text,text,boolean), public.resolve_alarm(text), public.alarm_check(), public.alarm_assert_medb() to authenticated, service_role;

-- Zeitplan
create extension if not exists pg_cron;
select cron.schedule('alarm-check', '*/15 * * * *', 'select public.alarm_check()');
notify pgrst, 'reload schema';
