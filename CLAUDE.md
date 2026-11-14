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
- Schema/Funktionen: `next2you/supabase-setup.sql`.
