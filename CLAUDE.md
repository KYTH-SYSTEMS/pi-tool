# Pi-Tool — Arbeitsregeln für dieses Repo

## Doku aktuell halten (PFLICHT — ALLE Docs, nicht nur die Architektur)
Bei jeder Änderung **alle betroffenen Docs im selben Commit/Release mitpflegen.**
Nicht nur die interne Referenz — auch die nach außen gerichteten Texte:

- **`ARCHITECTURE.md`** (interne Architektur-Referenz): bei Struktur-Änderungen —
  neue/entfernte Dateien unter `lib/`, neue Dienste/Karten/Tabs, Schicht-/Seam-
  Änderungen, On-Pi-Skripte/Timer, Gating-/Persistenz-Felder (AppConfig),
  geänderte Sicherheits-Invarianten.
- **Nutzer-sichtbares Feature hinzugefügt/entfernt/geändert → im selben Release
  mitziehen:**
  - `README.md` (Funktionen-Liste + Intro),
  - `docs/index.html` (Pages-Landing, wenn sich der Umfang ändert),
  - `fastlane/metadata/android/{de-DE,en-US}/full_description.txt` **und**
    `short_description.txt`,
  - `fastlane/metadata/android/{de-DE,en-US}/changelogs/<versionCode>.txt`
    (Dateiname == Android-versionCode),
  - `lib/src/whats_new.dart` (In-App-„Was ist neu?").
- Entfernte Features auch aus den Docs **löschen** (nicht nur Neues ergänzen).
- Kleine Bugfixes ohne Nutzer-/Strukturwirkung brauchen kein Doku-Update.

GitHub-Release-Notes: Die CI nimmt den **fastlane-Changelog** des versionCode als
Release-Body (darunter die auto-generierte Commit-Liste). Also **immer den
Changelog `<versionCode>.txt` pflegen** — der landet 1:1 im Release. Die
Commit-Liste selbst nicht von Hand pflegen.

## Nicht verhandelbare Invarianten (Details in ARCHITECTURE.md)
- **Sicherheit:** Pi-Passwörter/Keys niemals in Repo/Logs (redactPassword);
  jede in Shell-Befehle interpolierte Variable durch `shSingleQuote`; Heredocs
  in On-Pi-Skripten IMMER quoten (`<<'WRAP'`); destruktive Root-Skripte laufen
  über `_runRootScriptExpectMarker` (Erfolg nur mit Marker).
- **Kein Android-Hintergrunddienst** für Automatik — On-Pi-systemd-Timer
  (v0.20.0-Absturz-Lektion). Kein ungetesteter Native-/Plugin-Code im Startpfad.
- **TDD:** reine Logik (Builder/Parser) zuerst testen; `flutter analyze` +
  kompletter `flutter test` müssen grün sein, main-Build in CI validiert,
  bevor getaggt wird (Tag == HEAD).
- **Handler-Muster in main.dart:** `if (_busy) return;` → `_prepare()` →
  `_lastAction` VOR dem ersten `_guard` → SSH-Arbeit IN `_guard` (setzt _busy
  zurück). Wer `_prepare()` ohne `_guard` nutzt, muss `_busy` selbst freigeben.
- **Freemium schläft:** `DormantEntitlement` (alle Pro) bis zum Play-Launch;
  neue Pro-Features durch `_proGate` + Schloss-Hinweis.

## Konventionen
- Antworten/UI-Texte Deutsch (echte Umlaute! kein Mojibake), Technik-Begriffe
  englisch. Commits englisch.
- Release: Version in `pubspec.yaml` bumpen, `whats_new.dart` ergänzen, **bei
  Feature-Änderung die Docs oben mitziehen** (README/Pages/fastlane/Changelog),
  `git commit -F <datei>` (PowerShell-Heredocs brechen), main-Build abwarten,
  dann `v*`-Tag → CI baut signiertes APK + Release.
