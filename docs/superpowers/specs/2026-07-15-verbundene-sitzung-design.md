# Design-Spec: „Verbundene Sitzung" (explizites Verbinden + Tab-Gating)

- **Datum:** 2026-07-15
- **Status:** Entwurf (vom Nutzer freigegeben, Approach A)
- **Ziel-Release:** v0.57.0 (versionCode 105)
- **Betroffen v. a.:** `lib/main.dart` (Tabs/Nav/Actions/Session-State),
  `lib/src/evcc_updater.dart` (Connect-Log-Vorzeile)

---

## 1. Problem & Motivation

Der Nutzer beobachtet, dass der Terminal-Tab bei **jedem App-Öffnen** die Zeile
„Verbinde mit pi@host:port …" zeigt — als würde die App beim Öffnen verbinden.

**Ursachenanalyse (verifiziert im Code):**

- Die App verbindet sich beim Start/Resume **nicht** zum Pi.
  - `initState` (`main.dart:279`) ruft nur `_loadSettings()` (lädt Config),
    `_checkForUpdate()` (App-Update-Check gegen GitHub, `main.dart:908`) und
    `_loadEntitlement()` (Pro-Status). Kein SSH.
  - `didChangeAppLifecycleState(resumed)` (`main.dart:326`) ruft nur
    `_tryUnlock()` (Biometrie, `main.dart:941`). Kein SSH.
- Der sichtbare Text ist ein **warmer Resume**: Android hält den Prozess am
  Leben, der In-Memory-Log-Puffer `_log` (`main.dart:262`) enthält noch die
  Ausgabe der **letzten** Aktion, deren erste Zeile die Connect-Vorzeile aus
  `_withConnection` (`evcc_updater.dart:2311`) ist. Der Terminal-Tab rendert
  `_log` unverändert (`_LogView`, `main.dart:4597`).
- `_log` wird **nicht** persistiert und nur in `_beginBusy` (`main.dart:1074`)
  zu Beginn der nächsten Aktion geleert → bei einem echten Kaltstart ist das
  Terminal leer; bei warmem Resume bleibt die alte Zeile stehen.

**Architektur-Kontext:** Die App hält heute **keine** dauerhafte SSH-Verbindung.
Jede Aktion öffnet über `_withConnection` (`evcc_updater.dart:2299`) ihre eigene
Verbindung, führt den Body aus und schließt im `finally`. Aktionen sind über
`_busy` serialisiert (nur eine gleichzeitig).

## 2. Ziel

Ein **explizites, mental klares Verbindungsmodell**: Der Nutzer wählt einen Pi,
klickt „Verbindung herstellen", und die App gilt als **verbunden mit diesem Pi**,
bis er das Profil wechselt oder trennt. Die übrigen Tabs werden erst nach dem
Verbinden freigeschaltet. Die irritierende „Verbinde mit …"-Zeile verschwindet.

### Nicht-Ziele (Out of Scope)

- **Kein echter Dauer-Socket** (Approach B wurde bewusst verworfen: auf Mobil
  fragil — Android reißt Sockets im Hintergrund ab, Netzwechsel/Reboot töten sie;
  bräuchte Heartbeat/Reconnect + Umbau des `_withConnection`-Kerns → hohes
  Regressionsrisiko an stabiler App).
- Keine Parallelität von Aktionen (bleibt über `_busy` serialisiert).
- Keine getrennten Log-Puffer für Terminal vs. Aktionen (mögliche spätere
  Verbesserung, nicht Teil dieses Releases).
- Kein Auto-Reconnect / Auto-Revalidate beim Resume.

## 3. Gewählter Ansatz — „Verbindung" als Sitzungs-Zustand (Approach A)

„Verbunden" ist ein **gemerkter, geprüfter Zustand**, kein gehaltener Socket:
Bei „Verbindung herstellen" läuft der bereits vorhandene echte Connect +
Dienste-Erkennung; bei Erfolg merkt sich die App die Sitzung. Einzelaktionen
verbinden darunter weiterhin kurz-und-schließen (unverändert robust).

**Ehrliche Semantik:** „Verbunden" heißt „Zugangsdaten geprüft, Pi beim Connect
erreichbar". Wird der Pi später unerreichbar, schlägt die nächste Aktion wie
heute klar fehl und der Zustand kippt auf „getrennt".

## 4. Detail-Design

### 4.1 Sitzungs-Zustand

Neues Feld in `_HomePageState`:

```dart
bool _connected = false; // aktive Sitzung zum aktiven Profil?
```

- **In-Memory**, nicht in `AppConfig`/Secure-Storage persistiert.
- **Überlebt `_beginBusy`** — anders als `_connectionOk` (das bei jeder Aktion
  auf `null` zurückgesetzt wird, `main.dart:1078`). `_beginBusy` fasst
  `_connected` **nicht** an.
- An das **aktive Profil** gebunden (implizit, da bei Profilwechsel geleert).

**Zustandsübergänge:**

| `_connected` wird … | wann |
|---|---|
| `true` | erfolgreiches „Verbindung herstellen" (Connect + Erkennung ok) |
| `false` | „Trennen"-Tap |
| `false` | Profilwechsel (`_switchProfile`), Profil hinzufügen (`_addProfile`), aktives Profil gelöscht (`_deleteProfile`) |
| `false` | Edit eines Zugangsfelds des aktiven Profils (host/port/user/password/privateKey/keyPassphrase/authMode) — via bestehendem `_invalidateConnTest`-Pfad (`main.dart:383`) erweitert |
| `false` | Aktion scheitert mit Verbindungs-Fehler — `UpdateErrorKind.connection`, `.auth` oder `.hostKeyChanged` (`evcc_updater.dart:32`) — ehrliche Herabstufung im `_guard`-Catch (`main.dart:1095`). **Nicht** bei `sudo`/`serviceInactive`/`packageMissing`/`cancelled`/`unknown` (dort stand die Verbindung bzw. ist der Grund uneindeutig) |
| **unverändert** | `_beginBusy`, erfolgreiche Nicht-Connect-Aktionen, App-Resume, Tab-Wechsel |

### 4.2 „Verbindung herstellen" + Statusanzeige

- Der bestehende „Verbindung prüfen"-Button (`onTap: _testConnection`,
  `main.dart:4399`) wird zu **„Verbindung herstellen"** (Label abhängig von
  `_connected`).
- `_testConnection` (`main.dart:1227`) bleibt der Mechanismus (Connect +
  `detectServices`). Erfolgspfad (`main.dart:1270`) zusätzlich:
  `setState(() => _connected = true)`.
- Ist bereits verbunden, zeigt derselbe Bereich einen **Verbunden-Chip**
  „● Verbunden mit `<Pi-Name>`" + Aktion **„Trennen"** (`_connected = false`).
- **App-Bar-Indikator:** neben `_activeProfileName` (`main.dart:4224`) ein
  kleiner Punkt ● (verbunden) / ○ (getrennt).

### 4.3 Tab-Rename & Gating

- **Tab 0 „Dienste" → „Verwaltung"** (`NavigationDestination`, `main.dart:4533`).
  Icon von `Icons.dns(_outlined)` auf ein „Verwaltung"-passendes Icon
  (z. B. `Icons.tune` / `Icons.settings_outlined`) — Wahl in Umsetzung.
- **Gesperrte Tabs bis `_connected`:** Automatik (1), Terminal (2), Dateien (3).
  „Verwaltung" (0) bleibt immer offen (dort wird verbunden).

### 4.4 Navigations-Verhalten (ausgegraute Nav-Einträge)

`NavigationBar` hat **kein** eingebautes „deaktiviert pro Ziel". Umsetzung:

- Gesperrte Ziele (1/2/3 bei `!_connected`) mit **reduzierter Deckkraft** +
  kleinem **Schloss-Badge** rendern (eigene Icon-Widgets statt const-Liste,
  `main.dart:4529`).
- In `onDestinationSelected` (`main.dart:4522`) Taps auf gesperrte Ziele
  **abfangen**: kein `_tab`-Wechsel, stattdessen Snack „Zuerst verbinden".
- **Tab-Rücksprung:** Wird `_connected` `false` (Trennen/Profilwechsel/Invalidate)
  während `_tab ∈ {1,2,3}` angezeigt wird → `_tab = 0` (zurück auf Verwaltung).

### 4.5 Profilwechsel-Schutz

- Der Profil-Umschalter ist bereits während `_busy` gesperrt
  (`onTap: _busy ? null : _showProfileSwitcher`, `main.dart:4215`). Neu:
  sichtbar **ausgegraut** + Hinweis „Aktion läuft noch …" statt stiller Sperre.
- Ein Profilwechsel (`_switchProfile`, `main.dart:815`) **beendet die Sitzung**
  (`_connected = false`) — ergänzend zu `_resetDetectionForNewPi`
  (`main.dart:419`). Neuer Pi = neu verbinden.

### 4.6 Log/Terminal — die ursprüngliche Irritation

- Die automatische Connect-Vorzeile
  `log('Verbinde mit ${config.username}@${config.host}:${config.port} …')`
  (`evcc_updater.dart:2311`) wird **entfernt**. Verbindungsfehler liefern
  weiterhin klare `FEHLER:`-Meldungen über den Exception-Pfad
  (`_guard`, `main.dart:1097/1105`) — die Vorzeile ist zur Diagnose nicht nötig.
- Die **Verbinde-Rückmeldung** kommt stattdessen aus dem UI-Layer beim
  ausdrücklichen Connect: ephemere Busy-Anzeige „Verbinde …" (bereits
  `_busyMessage`, `main.dart:1236`) während des Vorgangs, danach im Log **eine**
  Vergangenheits-Zeile „✓ Verbunden mit `<Pi>`" nur bei Erfolg.
- **Ergebnis:** Der String „Verbinde mit host …" existiert nirgends mehr als
  bleibende Log-Zeile. Zusammen mit `_beginBusy`-Clear (`main.dart:1074`) und
  dem Terminal-Gate (nur nach Connect erreichbar) startet das Terminal sauber;
  die Zeile taucht nie wieder „von selbst" beim App-Öffnen auf.
- **Prüfen in Umsetzung:** ob Tests die entfernte Vorzeile erwarten (grep nach
  „Verbinde mit" in `test/`), ggf. anpassen.

### 4.7 Freemium-Zusammenspiel

- Unverändert. Terminal & Dateien bleiben Pro (Paywall zuerst für Nicht-Pro,
  `main.dart:4649`, `_runConsoleCommand`-Gate `main.dart:2838`). Der
  Verbindungs-Gate greift für Pro-Nutzer **darüber**: Reihenfolge pro Tab =
  (a) `!_connected` → „Zuerst verbinden", sonst (b) bestehende Pro-Paywall,
  sonst (c) normaler Inhalt. Automatik-Kacheln behalten ihre Pro-Locks.

### 4.8 Lebenszyklus & Randfälle

- **Resume:** kein SSH, keine Revalidierung; `_connected` bleibt wie im Speicher.
- **Zugangsfeld-Edit:** Sitzung ungültig (Reconnect nötig).
- **Verbindungs-Fehler einer Aktion** (`connection`/`auth`/`hostKeyChanged`):
  ehrliche Herabstufung auf „getrennt". Andere Fehlerarten lassen die Sitzung
  bestehen.
- **Kaltstart:** `_connected = false` → nur „Verwaltung" nutzbar.

## 5. Architektur-Fit & Invarianten

- **Keine dauerhafte Hintergrund-Session / kein Android-Hintergrunddienst** —
  Sitzung ist reiner Vordergrund-UI-Zustand; kein Socket wird gehalten. Wahrt die
  v0.20.0-Lektion.
- **`_withConnection`-Seam unverändert** (bis auf das Entfernen einer Log-Zeile)
  → das robuste „open→body→finally close" pro Aktion bleibt.
- **Handler-Muster** (`_busy`/`_prepare`/`_guard`) bleibt; `_connected` ist
  additiv und wird gezielt (nicht in `_beginBusy`) verwaltet.

## 6. Testbare Einheiten (TDD zuerst)

Reine Logik als kleine, testbare Funktionen (vor UI), z. B.:

- `sessionTabEnabled(tabIndex, connected)` → welche Tabs frei sind.
- `sessionAfterEvent(current, event)` → Zustandsübergänge (connect ok, disconnect,
  profile switch, field edit, connection error).
- `tabAfterDisconnect(currentTab)` → Rücksprung-Regel (→ 0, falls gesperrt).

`flutter analyze` + kompletter `flutter test` grün; main-Build in CI vor Tag.

## 7. Doku- & Release-Checkliste (v0.57.0 / versionCode 105)

Nutzer-sichtbares Feature → im selben Release mitziehen:

- `pubspec.yaml`: `0.56.0+104` → `0.57.0+105`.
- `lib/src/whats_new.dart`: Eintrag „Explizites Verbinden + freigeschaltete Tabs".
- `README.md`: Funktionsliste/Intro anpassen (Verbindungsmodell, „Verwaltung").
- `docs/index.html`: falls Umfang/Screenshots betroffen.
- `fastlane/metadata/android/{de-DE,en-US}/full_description.txt` + `short_description.txt`.
- `fastlane/metadata/android/{de-DE,en-US}/changelogs/105.txt` (== versionCode,
  landet 1:1 als GitHub-Release-Body).
- **Store-Screenshots** zeigen aktuell „Dienste" → für Refresh markieren
  (nicht in diesem Code-Schritt, aber vor Play-Update nötig).

## 8. Offene Punkte

Keine — Richtung (Approach A), Gate-Umfang (Automatik + Terminal + Dateien),
Rename („Verwaltung") und Sperr-Optik (ausgegraute Nav-Einträge) sind entschieden.
