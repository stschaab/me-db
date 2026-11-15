# MeDB – Hinweise für Claude

## Arbeitsweise
- Selbstständig arbeiten, nicht nachfragen: planen, umsetzen, testen, committen, pushen, PR erstellen und mergen.
  Supabase-Änderungen (Migrationen, Edge Functions) direkt per Supabase-MCP anwenden.
- Nur bei echten Blockern oder unumkehrbar destruktiven Schritten an fremden Daten nachfragen.
- Kommunikation auf Deutsch.

## Projekt
- Statische HTML-Seiten (`me-db-*.html`) auf GitHub Pages, Supabase-Projekt `thgawuqcogugzurrijkp`.
- Neue Seiten: Menüeintrag im Hamburger-Menü aller `me-db-*.html` ergänzen.

## Next2You (`next2you/`)
- Pseudonyme Konten über Edge Function `n2y-signup` (`app_metadata.n2y = true`), Tabellen mit Präfix `n2y_`.
- Next2You-Konten dürfen keine me-db-Daten sehen: Restriktive Policy `"block n2y users"` auf allen me-db-Tabellen
  und `storage.objects`. Der Event-Trigger `n2y_autoguard` setzt sie automatisch für neue Tabellen mit RLS.
- Schema/Funktionen: `next2you/supabase-setup.sql`; Edge-Function-Quellen: `next2you/edge-functions/`.
- Interessen-Match: max(Wort-Match, semantisch per Embedding aus `n2y-embed`). Ohne Secret `VOYAGE_API_KEY`
  läuft gte-small (schwächer bei Deutsch); nach Setzen des Secrets alle Profile neu einbetten.
- Nach `ALTER TABLE` per SQL: `NOTIFY pgrst, 'reload schema'`, sonst kennt die REST-API neue Spalten nicht.
- KI-Testnutzer „… (KI)“ antworten über `n2y-bot-reply` (Logik in `bots.js`, lokal mit Node testbar).
- KI-Personen entstehen automatisch (8 Stück) um echte Nutzer, wenn im Umkreis ≈ 3 km < 4 existieren
  (Trigger `n2y_spawn_bots_nearby` → Queue `n2y_bot_spawn_requests` → Edge Function `n2y-spawn-bots`, max. 200).
  „(KI)“ im Spitznamen nur für KI-Konten (`n2y_is_ai_account`); Oberfläche erkennt KI per `n2yIsAI()` (presence.js).
- `execute_sql` mit `begin … rollback` nie im selben Aufruf wie dauerhafte Änderungen – das Rollback nimmt sie mit.
- DELETE/DROP lösen eine Supabase-Rückfrage aus; wenn möglich vermeiden (CREATE OR REPLACE, neue Funktion statt DROP).
