# Design-Spec: App-Lokalisierung (Deutsch/Englisch, Auto + Umschalter)

- **Datum:** 2026-07-15
- **Status:** Entwurf (vom Nutzer freigegeben)
- **Ziel-Release:** v0.58.0 (versionCode 106)
- **Betroffen:** `lib/main.dart`, `lib/src/ui_widgets.dart`, `lib/src/profiles.dart`
  (AppConfig), neue `lib/l10n/*.arb` + generierte `AppLocalizations`, `l10n.yaml`,
  `pubspec.yaml`, Test-Helper.

---

## 1. Ziel

Die App soll **Deutsch und Englisch** können, **automatisch nach Handy-Sprache**,
mit optionalem **In-App-Umschalter** (System/Deutsch/English). Heute sind alle
UI-Texte fest deutsche Literale; die Root-`MaterialApp` erzwingt sogar
`locale: const Locale('de')` (`main.dart:120`).

## 2. Entscheidungen (vom Nutzer)

- **Umschalter:** ja — System / Deutsch / English (Default „System").
- **Fallback** für Nicht-DE/EN-Handys: **Englisch**.
- **„Was ist neu?"-Historie:** alte Einträge bleiben Deutsch; **ab v0.58.0
  neue Einträge bilingual** (de+en).
- **Meldungen:** alles Nutzer-Sichtbare — siehe Tier-Scoping unten.

## 3. Technik

**Flutters offizielles `gen-l10n`** (keine Runtime-Dependency; `flutter_localizations`
ist schon dep):

- `l10n.yaml` (arb-dir `lib/l10n`, template `app_en.arb`, output-class
  `AppLocalizations`, `nullable-getter: false`).
- `lib/l10n/app_en.arb` (Template, Keys + `@`-Metadaten) und `lib/l10n/app_de.arb`.
- `pubspec.yaml`: unter `flutter:` → `generate: true`.
- Zugriff im Code über eine Extension `context.l10n` → `AppLocalizations.of(context)!`.
- **Key-Konvention:** sprechendes camelCase, grob nach Bereich
  (`connectButton`, `connectionOkDetected`, `tabVerwaltung`, `settingsLanguage` …).
- **Platzhalter:** Strings mit `$var` werden ARB-Platzhalter
  (`"connectionOkDetected": "Verbindung OK – erkannt: {services}."` + `@`-Meta).

## 4. Auto-Erkennung + Umschalter

- `AppConfig.languageMode: String` (`'system' | 'de' | 'en'`, Default `'system'`),
  persistiert (JSON + copyWith + fromJson/toJson, wie `themeMode`).
- Globaler `localeNotifier = ValueNotifier<Locale?>` (analog `themeModeNotifier`):
  `system → null`, `de → const Locale('de')`, `en → const Locale('en')`.
- `EvccPiToolApp` (`main.dart:105`): das hartkodierte `locale: const Locale('de')`
  wird durch `localeNotifier` ersetzt; zusätzlich
  `localizationsDelegates: AppLocalizations.localizationsDelegates`,
  `supportedLocales: AppLocalizations.supportedLocales`, plus ein
  `localeResolutionCallback`, der **DE nur bei Handy-DE** liefert, sonst **EN**
  (Fallback-Englisch). Verschachtelt mit dem bestehenden
  `ValueListenableBuilder<ThemeMode>`.
- **Einstellung** im Settings-Sheet direkt neben dem Theme-Umschalter
  (System/Deutsch/English), setzt `languageMode` + `localeNotifier` + speichert.

## 5. Umfang — Tier-Scoping (transparent)

**Tier 1 (dieses Release, vollständig):**
- Gesamte **UI-Schicht**: `main.dart` (~237 Strings) + `ui_widgets.dart`
  (~54) — Buttons, Tabs, Karten, Dialoge, Bottom-Sheets, Einstellungen,
  Snackbars, Status-Banner, Hinweise, der Erst-Start-Disclaimer.
- Die **Sprach-Einstellung** selbst + Infra + Tests.
- `whats_new.dart`: Struktur auf bilingual umstellen; **v0.58.0-Eintrag de+en**,
  ältere Einträge Deutsch (Fallback DE).

**Tier 2 (dokumentiert, Folge-Release — NICHT in v0.58.0):**
- **Business-Layer-Meldungen**: `EvccUpdateException`-Texte + gestreamte
  Terminal-`log(...)`-Zeilen in `evcc_updater.dart` (~88) und die wenigen
  Strings in `security_check`/`system_service`/`alerts`/`parsing`/… Diese
  entstehen **ohne `BuildContext`** in der Logikschicht und sind im Terminal
  mit **rohem, nicht-übersetzbarem Befehls-Output** vermischt. Sie bleiben
  vorerst Deutsch. Saubere Lösung später: Exception trägt `kind`+Params, die
  UI-Grenze löst zu `l10n` auf; Log-Stream bleibt technisch.

**Nicht lokalisiert (bewusst):** Shell-Befehle, Keys, interne Marker/Logik,
roher Befehls-Output.

> Begründung des Cuts: Tier 1 deckt praktisch alles ab, was ein Nutzer im
> Normalbetrieb liest; Tier-2-Texte erscheinen nur im Fehlerfall bzw. im
> technischen Log. Tier 1 zusammen mit einem Business-Layer-Refactor in einem
> Rutsch zu machen wäre riskant („working over feature-complete").

## 6. Tests

- **App- und Test-`MaterialApp`s** bekommen die l10n-Delegates. Die Test-Helper
  (`_page()`/`page()`/… in `widget_test.dart`, `dispatch_test.dart`, ggf.
  `screenshots.dart`) werden auf `localizationsDelegates:
  AppLocalizations.localizationsDelegates`, `supportedLocales: …` und
  `locale: const Locale('de')` gesetzt → die ~600 deutschen Text-Finder bleiben
  **grün** (nur ~5 Helper-Funktionen ändern sich, nicht 600 Asserts).
- **Neue Tests:** (a) `session_`-artiger Unit-Test für die
  `languageMode → Locale`-Abbildung + Fallback-Resolution (reine Logik zuerst,
  TDD); (b) ein Widget-Test, der mit `locale: Locale('en')` eine englische
  Beschriftung findet; (c) Umschalter setzt `languageMode` und speichert.
- Gate: `flutter analyze` + kompletter `flutter test` grün; zusätzlich ein
  Residual-Check `grep` auf verbleibende deutsche Literale in `main.dart`/
  `ui_widgets.dart` (Tier-1-Vollständigkeit).

## 7. Ausführung (Etappen, jede grün + committet)

- **P1 — Infra + Umschalter + Test-Harness:** `l10n.yaml`, ARB-Gerüst (ein paar
  Seed-Keys), `generate: true`, `context.l10n`, `languageMode`/`localeNotifier`,
  `EvccPiToolApp`-Verdrahtung, Settings-Eintrag, Test-Helper-Delegates +
  `Locale('de')`, reine `languageMode→Locale`-Logik als getestete Einheit.
- **P2 — Strings extrahieren + übersetzen (Katalog):** read-only, pro Datei; kann
  via **Workflow parallelisiert** werden (ein Agent je Datei → `{key, de, en,
  placeholders}`). Ergebnis: vollständige `app_de.arb` + `app_en.arb`.
- **P3 — UI-Schicht umbauen:** Literale in `main.dart` + `ui_widgets.dart` durch
  `context.l10n.<key>` ersetzen (Import ergänzen; `final l10n = context.l10n;`
  in Build-Methoden). Danach `flutter analyze` + `flutter test` grün, Residual-
  Grep leer.
- **P4 — whats_new bilingual** + v0.58.0-Eintrag.
- **P5 — Docs/Release:** `pubspec` `0.57.0+105 → 0.58.0+106`, README/fastlane,
  Changelog `106.txt` (de+en), whats_new. Push + Tag `v0.58.0` (Auto, siehe
  [[branching]]).

## 8. Architektur-Fit & Invarianten

- Keine neue Runtime-Dependency (gen-l10n ist Build-Time). Kein Native/Startpfad-
  Risiko.
- Sicherheit unberührt: Shell-Quoting/Redaction/Marker bleiben; nur Anzeige-
  Strings wandern nach ARB.
- Doku-Pflicht (CLAUDE.md) erfüllt: README/fastlane/whats_new/Changelog im selben
  Release. ARCHITECTURE.md: l10n-Schicht als neuer Seam ergänzen.

## 9. Offene Punkte

Keine blockierenden — Tier-2 (Business-Layer-Meldungen) ist bewusst vertagt und
oben dokumentiert.
