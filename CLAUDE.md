# Pi-Tool — Arbeitsregeln für dieses Repo

## Architektur-Doku aktuell halten (PFLICHT)
`ARCHITECTURE.md` ist die Architektur-Referenz dieser App. **Bei jeder Änderung,
die Architektur betrifft, muss sie im selben Commit mitgepflegt werden** —
insbesondere bei: neuen/entfernten Dateien unter `lib/`, neuen Diensten/Karten,
Änderungen an den Schichten (SshRunner-Seam, Command-Layer, UI-Shell), neuen
On-Pi-Skripten/Timern, Gating-/Persistenz-Feldern (AppConfig) oder geänderten
Sicherheits-Invarianten. Kleine Bugfixes ohne Strukturwirkung brauchen kein
Doku-Update.

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
- Release: Version in `pubspec.yaml` bumpen, `whats_new.dart` ergänzen,
  `git commit -F <datei>` (PowerShell-Heredocs brechen), main-Build abwarten,
  dann `v*`-Tag → CI baut signiertes APK + Release.
