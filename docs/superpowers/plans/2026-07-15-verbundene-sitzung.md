# „Verbundene Sitzung" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans
> to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Explizites „Verbindung herstellen" setzt eine gemerkte, geprüfte
Sitzung zum aktiven Pi; die Tabs Automatik/Terminal/Dateien sind bis dahin
gesperrt; die irritierende „Verbinde mit …"-Logzeile verschwindet.

**Architecture:** Sitzung als In-Memory-Zustand `_connected` (kein gehaltener
Socket). Reine Gating-Logik in `lib/src/session.dart` (TDD-testbar). Verdrahtung
in `main.dart` (Nav-Gate, Snap-Back, Indikator, Zustandsübergänge). Connect-Log-
Vorzeile aus `evcc_updater.dart` entfernt.

**Tech Stack:** Flutter/Dart, `flutter_test` (Widget-Tests mit FakeEvccUpdater).

## Global Constraints

- UI-Texte Deutsch (echte Umlaute), Technik englisch; Commits englisch.
- TDD: reine Logik zuerst; `flutter analyze` + kompletter `flutter test` grün.
- Sicherheit/Invarianten unverändert: kein gehaltener Socket, `_withConnection`
  öffnet/schließt pro Aktion; kein Android-Hintergrunddienst.
- `_connected` ist In-Memory (nicht in `AppConfig`), wird NICHT in `_beginBusy`
  zurückgesetzt.
- Nutzer-sichtbares Feature → Docs im selben Release (README, whats_new,
  fastlane de/en full+short, changelog `105.txt`, Version `0.57.0+105`).
- Tab-Indizes: 0 Verwaltung (immer offen), 1 Automatik, 2 Terminal, 3 Dateien.

---

### Task 1: Reine Sitzungs-/Gating-Logik (`lib/src/session.dart`)

**Files:**
- Create: `lib/src/session.dart`
- Test: `test/session_test.dart`

**Interfaces:**
- Produces:
  - `const int kTabVerwaltung = 0; kTabAutomatik = 1; kTabTerminal = 2; kTabDateien = 3;`
  - `bool isGatedTab(int tab)` — true außer für Verwaltung(0).
  - `bool tabAllowed(int tab, {required bool connected})` — connected || !gated.
  - `int tabAfterDisconnect(int currentTab)` — gated→0, sonst unverändert.

- [ ] **Step 1: Write the failing test** — `test/session_test.dart`

```dart
import 'package:evcc_updater/src/session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isGatedTab', () {
    test('Verwaltung is always open', () {
      expect(isGatedTab(kTabVerwaltung), isFalse);
    });
    test('Automatik/Terminal/Dateien are gated', () {
      expect(isGatedTab(kTabAutomatik), isTrue);
      expect(isGatedTab(kTabTerminal), isTrue);
      expect(isGatedTab(kTabDateien), isTrue);
    });
  });

  group('tabAllowed', () {
    test('gated tabs need a connection', () {
      expect(tabAllowed(kTabTerminal, connected: false), isFalse);
      expect(tabAllowed(kTabTerminal, connected: true), isTrue);
    });
    test('Verwaltung is allowed even when disconnected', () {
      expect(tabAllowed(kTabVerwaltung, connected: false), isTrue);
    });
  });

  group('tabAfterDisconnect', () {
    test('a gated tab falls back to Verwaltung', () {
      expect(tabAfterDisconnect(kTabTerminal), kTabVerwaltung);
      expect(tabAfterDisconnect(kTabDateien), kTabVerwaltung);
    });
    test('Verwaltung stays put', () {
      expect(tabAfterDisconnect(kTabVerwaltung), kTabVerwaltung);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/session_test.dart`
Expected: FAIL — `session.dart` / symbols not found.

- [ ] **Step 3: Write minimal implementation** — `lib/src/session.dart`

```dart
/// Pure connection-session + tab-gating logic (UI-free, unit-testable).
library;

/// Bottom-navigation tab indices.
const int kTabVerwaltung = 0;
const int kTabAutomatik = 1;
const int kTabTerminal = 2;
const int kTabDateien = 3;

/// Every tab except Verwaltung(0) needs an active connection.
bool isGatedTab(int tab) => tab != kTabVerwaltung;

/// Whether [tab] may be shown given the connection state.
bool tabAllowed(int tab, {required bool connected}) =>
    connected || !isGatedTab(tab);

/// Tab to fall back to when the session drops (disconnect / profile switch):
/// a gated tab returns to Verwaltung; Verwaltung stays.
int tabAfterDisconnect(int currentTab) =>
    isGatedTab(currentTab) ? kTabVerwaltung : currentTab;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/session_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/src/session.dart test/session_test.dart
git commit -F <msg>   # "feat(session): pure connection/tab-gating logic"
```

---

### Task 2: Sitzungs-Zustand + Connect-Erfolg + Indikator in `main.dart`

**Files:**
- Modify: `lib/main.dart`
  - Feld nahe `_testing` (`main.dart:256`), Import `src/session.dart`.
  - `_testConnection` Erfolgspfad (`main.dart:1254-1272`): `_connected = true`.
  - App-Bar-Zeile (`main.dart:4218-4232`): Verbunden-Badge mit
    `Key('sessionConnected')`.
  - `_invalidateConnTest` (`main.dart:383-387`): zusätzlich `_connected=false`.

**Interfaces:**
- Consumes: `session.dart` (Task 1).
- Produces: `bool _connected`; app-bar `Key('sessionConnected')` sichtbar gdw.
  verbunden.

- [ ] **Step 1: Add import + field**

`main.dart` Import-Block: `import 'src/session.dart';`
Neben `bool _testing = false;` (`main.dart:256`):

```dart
  bool _connected = false; // active, validated session to the active Pi?
```

- [ ] **Step 2: Set `_connected` on a successful connect**

In `_testConnection` (`main.dart`), im Erfolgs-`setState` (`main.dart:1254`)
ergänzen:

```dart
      setState(() {
        _services = services;
        _rememberTailscaleIp(services);
        _rememberLanHost();
        _connExpanded = false;
        _connected = true; // NEW: explicit session established
        final found =
            services.where((s) => s.installed).map((s) => s.name).join(', ');
        _statusMessage = 'Verbindung OK – erkannt: $found.';
        _statusOk = true;
      });
```

- [ ] **Step 3: Invalidate the session when a connection field is edited**

`_invalidateConnTest` (`main.dart:383`) erweitern:

```dart
  void _invalidateConnTest() {
    if ((_connectionOk != null || _connected) && mounted) {
      setState(() {
        _connectionOk = null;
        _connected = false;
        if (isGatedTab(_tab)) _tab = tabAfterDisconnect(_tab);
      });
    }
  }
```

- [ ] **Step 4: App-bar connected badge (test hook)**

In der App-Bar-Profilzeile (`main.dart:4223-4228`), nach dem Profilnamen-`Text`
einfügen:

```dart
                  if (_connected)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Icon(Icons.check_circle,
                          key: const Key('sessionConnected'),
                          size: 14,
                          color: Colors.green),
                    ),
```

- [ ] **Step 5: analyze + run affected tests**

Run: `flutter analyze` (0 issues) und `flutter test test/widget_test.dart`
(erwartet: einige Fehler durch Rename/Gating — in Task 3/5 behoben; hier nur
sicherstellen, dass kein Kompilierfehler durch Task 2 entstand).

- [ ] **Step 6: Commit** — "feat(session): connected state + connect success + app-bar badge"

---

### Task 3: Tab-Rename „Dienste" → „Verwaltung" + Gating in der Navigation

**Files:**
- Modify: `lib/main.dart`
  - `NavigationBar` (`main.dart:4520-4547`): Label 0 → „Verwaltung", Icon;
    gesperrte Ziele ausgegraut + Schloss-Badge; `onDestinationSelected` fängt
    gesperrte Taps ab.

- [ ] **Step 1: Rename tab 0 + gated-nav rendering**

`NavigationBar` (`main.dart:4520`) so ändern, dass Ziele dynamisch gebaut werden
(nicht mehr `const`), gesperrte Ziele (Automatik/Terminal/Dateien bei
`!_connected`) mit reduzierter Deckkraft + kleinem Schloss:

```dart
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) {
          if (!tabAllowed(i, connected: _connected)) {
            _snack('Zuerst verbinden: „Verbindung herstellen" im Tab Verwaltung.');
            return;
          }
          setState(() {
            _tab = i;
            _statusMessage = null;
          });
        },
        destinations: [
          const NavigationDestination(
              icon: Icon(Icons.tune_outlined),
              selectedIcon: Icon(Icons.tune),
              label: 'Verwaltung'),
          _navDest(kTabAutomatik, Icons.bolt_outlined, Icons.bolt, 'Automatik'),
          _navDest(kTabTerminal, Icons.terminal_outlined, Icons.terminal,
              'Terminal'),
          _navDest(kTabDateien, Icons.folder_outlined, Icons.folder, 'Dateien'),
        ],
      ),
```

Helper (in der State-Klasse):

```dart
  /// A bottom-nav destination that greys out + shows a lock while the session
  /// gate blocks it. Kept as NavigationDestination so labels stay findable.
  NavigationDestination _navDest(
      int index, IconData icon, IconData selected, String label) {
    final locked = !tabAllowed(index, connected: _connected);
    Widget wrap(Widget child) => locked
        ? Opacity(
            opacity: 0.38,
            child: Stack(clipBehavior: Clip.none, children: [
              child,
              const Positioned(
                  right: -6, top: -4, child: Icon(Icons.lock, size: 11)),
            ]),
          )
        : child;
    return NavigationDestination(
      icon: wrap(Icon(icon)),
      selectedIcon: wrap(Icon(selected)),
      label: label,
    );
  }
```

Hinweis: `find.byIcon(Icons.terminal_outlined)` etc. bleibt auffindbar (das Icon
steckt im `wrap`).

- [ ] **Step 2: analyze**

Run: `flutter analyze`
Expected: 0 issues.

- [ ] **Step 3: Commit** — "feat(session): rename Dienste→Verwaltung + gate nav tabs until connected"

---

### Task 4: Session bei Profilwechsel/-verwaltung beenden + Snap-Back

**Files:**
- Modify: `lib/main.dart`
  - `_resetDetectionForNewPi` (`main.dart:419-427`): `_connected=false` +
    Snap-Back.

**Interfaces:**
- Consumes: `tabAfterDisconnect`, `isGatedTab` (Task 1).

- [ ] **Step 1: Clear session + snap back in `_resetDetectionForNewPi`**

`_resetDetectionForNewPi` (`main.dart:419`) ergänzen (wird von `_switchProfile`,
`_addProfile` genutzt):

```dart
  void _resetDetectionForNewPi() {
    _services = [];
    _connectionOk = null;
    _connected = false;            // NEW: end the session for the previous Pi
    if (isGatedTab(_tab)) _tab = kTabVerwaltung; // NEW: snap back to Verwaltung
    _setupUrl = null;
    _statusMessage = null;
    _hostKeyIssue = false;
    _lastConfig = null;
    _lastAction = null;
  }
```

(`_deleteProfile` ruft `_applyProfile` und ist über den aktiven Index abgedeckt;
falls es das aktive Profil entfernt, ebenfalls `_resetDetectionForNewPi`-Pfad
prüfen — siehe `main.dart:856-884`; bei Bedarf dort `_connected=false` setzen.)

- [ ] **Step 2: analyze**

Run: `flutter analyze` — 0 issues.

- [ ] **Step 3: Commit** — "feat(session): end session + snap to Verwaltung on profile switch"

---

### Task 5: Ehrliche Herabstufung bei Verbindungs-Fehlern + Log-Vorzeile entfernen

**Files:**
- Modify: `lib/main.dart` — `_guard`-Catch (`main.dart:1095-1103`).
- Modify: `lib/src/evcc_updater.dart` — Connect-Vorzeile (`evcc_updater.dart:2311`).
- Modify: `lib/main.dart` — Erfolgs-Log „✓ Verbunden mit <Pi>" beim Connect.

- [ ] **Step 1: Downgrade session on connection-class failures**

Im `_guard` `on EvccUpdateException catch (e)` (`main.dart:1095`) ergänzen:

```dart
      final connectionLost = e.kind == UpdateErrorKind.connection ||
          e.kind == UpdateErrorKind.auth ||
          e.kind == UpdateErrorKind.hostKeyChanged;
      setState(() {
        _statusMessage = e.message;
        _statusOk = false;
        _hostKeyIssue = e.kind == UpdateErrorKind.hostKeyChanged;
        if (connectionLost) {
          _connected = false;
          if (isGatedTab(_tab)) _tab = kTabVerwaltung;
        }
      });
```

- [ ] **Step 2: Remove the auto connect-preamble**

`evcc_updater.dart:2311` — die Zeile

```dart
      log('Verbinde mit ${config.username}@${config.host}:${config.port} …');
```

entfernen (Verbindungsfehler liefern weiterhin klare Exceptions).

- [ ] **Step 3: Add a past-tense success line on explicit connect**

In `_testConnection` (`main.dart`), im Erfolgs-`setState` (Task 2, Step 2)
zusätzlich vor dem `setState` ein Log:

```dart
      _appendLog('✓ Verbunden mit ${_host.text.trim()}.');
```

(Platzierung: unmittelbar vor dem `if (!mounted) return;`/`setState` im
Erfolgszweig.)

- [ ] **Step 4: Check tests referencing the removed preamble**

Run: `grep -rn "Verbinde mit" test/`
Falls Tests die Vorzeile erwarten → anpassen/entfernen.

- [ ] **Step 5: Run the updater tests**

Run: `flutter test test/evcc_updater_test.dart test/dispatch_test.dart`
Erwartete Nav-Fehler werden in Task 6 behoben; hier prüfen, dass keine
NICHT-Nav-Tests durch das Entfernen der Vorzeile brechen.

- [ ] **Step 6: Commit** — "feat(session): honest disconnect on connection errors; drop stale connect preamble"

---

### Task 6: Widget-Tests an das Gating anpassen

**Files:**
- Modify: `test/dispatch_test.dart` — Nav-Helper „verbinde-falls-nötig".
- Modify: `test/widget_test.dart` — Rename-Assertion + Gating-Test.
- Modify: `test/dispatch_test.dart` — profil-wechselnde Tests (Snap-Back).

- [ ] **Step 1: Ensure-connected in the nav helpers (`test/dispatch_test.dart`)**

`goTerminal/goAutomatik/goDateien` (`dispatch_test.dart:732-745`) je um einen
Guard ergänzen:

```dart
  Future<void> ensureConnected(WidgetTester tester) async {
    if (tester.any(find.byKey(const Key('sessionConnected')))) return;
    await tester
        .tap(find.widgetWithText(OutlinedButton, 'Verbindung herstellen'));
    await tester.pumpAndSettle();
  }

  Future<void> goTerminal(WidgetTester tester) async {
    await ensureConnected(tester);
    await tester.tap(find.byIcon(Icons.terminal_outlined));
    await tester.pumpAndSettle();
  }
  // ... goAutomatik, goDateien analog: ensureConnected zuerst.
```

- [ ] **Step 2: Fix widget_test rename + gating (`test/widget_test.dart`)**

In „renders the connection screen with the detect hint" (`widget_test.dart:111`):
- Zeile 123: `find.text('Dienste')` → `find.text('Verwaltung')`.
- Die Terminal-Navigation (`widget_test.dart:130-135`) ersetzen durch einen
  **Gating-Test** (dieser Test nutzt den echten Updater + leeres Profil → kann
  nicht verbinden, ideal für den Disconnected-Fall):

```dart
    // Disconnected: gated tabs don't open — tapping shows a hint, no console.
    await tester.tap(find.byIcon(Icons.terminal_outlined));
    await tester.pump();
    expect(find.byKey(const Key('consoleField')), findsNothing);
    expect(find.textContaining('Zuerst verbinden'), findsWidgets);
```

- [ ] **Step 3: Fix profile-switch tests for snap-back (`test/dispatch_test.dart`)**

Tests, die nach einem Profilwechsel auf einem gesperrten Tab bleiben (z. B.
„Dateien tab re-lists after switching Pi", `dispatch_test.dart:901`), an das
neue Verhalten anpassen: nach `profileSwitcher` ist man wieder auf „Verwaltung"
und getrennt → vor der erneuten Prüfung erneut `goDateien(tester)` (verbindet neu
via Helper). Konkret: nach dem Switch-Tap eine erneute `goDateien(tester)`
einfügen, bevor auf die neue Liste geprüft wird.

- [ ] **Step 4: Run the full suite, fix stragglers**

Run: `flutter test`
Alle verbleibenden Nav-/Rename-Fehler nach demselben Muster beheben
(ensureConnected-Helper greift; nur profil-wechselnde bzw. free-user-Fälle
brauchen evtl. eine erneute Navigation). Ziel: **alles grün.**

- [ ] **Step 5: Commit** — "test(session): adapt nav/rename/snap-back to the connection gate"

---

### Task 7: Docs + Version-Bump (Release-Vorbereitung v0.57.0 / vc 105)

**Files:**
- Modify: `pubspec.yaml` (`0.56.0+104` → `0.57.0+105`).
- Modify: `lib/src/whats_new.dart` (+`test/whats_new_test.dart` bleibt grün).
- Modify: `README.md`.
- Create: `fastlane/metadata/android/de-DE/changelogs/105.txt`,
  `fastlane/metadata/android/en-US/changelogs/105.txt`.
- Modify: `fastlane/metadata/android/{de-DE,en-US}/full_description.txt`,
  `short_description.txt` (nur wenn Umfang es erfordert).

- [ ] **Step 1: Bump version** — `pubspec.yaml`: `version: 0.57.0+105`.

- [ ] **Step 2: whats_new entry** — in `lib/src/whats_new.dart` `_whatsNew` oben:

```dart
  '0.57.0': [
    'Klarere Verbindung: Du verbindest dich jetzt bewusst über „Verbindung '
        'herstellen" und bleibst mit diesem Pi verbunden, bis du das Profil '
        'wechselst. Erst danach sind Automatik, Terminal und Dateien '
        'freigeschaltet — vorher sind sie dezent gesperrt. Der Tab „Dienste" '
        'heißt jetzt „Verwaltung". Nebenbei verschwindet die alte „Verbinde '
        'mit …"-Zeile, die beim App-Öffnen fälschlich nach einer laufenden '
        'Verbindung aussah.',
  ],
```

- [ ] **Step 3: README functions list** — den Verbindungs-/Tab-Abschnitt
  aktualisieren (bewusstes Verbinden, „Verwaltung", freigeschaltete Tabs).

- [ ] **Step 4: fastlane changelog 105 (de + en)**

`fastlane/metadata/android/de-DE/changelogs/105.txt`:

```
Klarere Verbindung: Du verbindest dich jetzt bewusst über „Verbindung herstellen" und bleibst mit diesem Pi verbunden, bis du das Profil wechselst. Erst danach sind Automatik, Terminal und Dateien freigeschaltet. Der Tab „Dienste" heißt jetzt „Verwaltung". Die alte „Verbinde mit …"-Zeile beim App-Öffnen ist weg.
```

`.../en-US/changelogs/105.txt`:

```
Clearer connection model: connect deliberately via "Verbindung herstellen" and stay connected to that Pi until you switch profiles. Automation, Terminal and Files unlock only once connected. The "Dienste" tab is now "Verwaltung". The stale "connecting…" line on app open is gone.
```

- [ ] **Step 5: full/short descriptions** — de+en nur anpassen, wenn der
  Funktionsumfang-Text die Tabs/Verbindung nennt (sonst unverändert lassen).

- [ ] **Step 6: analyze + full test** — `flutter analyze` && `flutter test` grün.

- [ ] **Step 7: Commit** — "docs(v0.57.0): connection session + Verwaltung rename (README/whats_new/fastlane)"

---

## Self-Review Notes

- Spec-Abdeckung: Sitzungs-Zustand (T2), Connect+Indikator (T2), Rename+Gating
  (T3), Profilwechsel/Snap-Back (T4), Fehler-Herabstufung + Log-Bereinigung (T5),
  Tests (T6), Docs/Version (T7). Randfälle: Feld-Edit-Invalidate (T2/Step3),
  Resume=kein SSH (unverändert, kein Code nötig).
- Store-Screenshots (zeigen „Dienste") und `test/screenshots.dart`-Goldens sind
  NICHT Teil von `flutter test` (kein `_test.dart`) → CI bleibt grün; Screenshot-
  Refresh ist ein separater Schritt vor dem Play-Update (nicht in diesem Plan).
- Release/Tag (CI-Signierung) ist bewusst NICHT Teil dieses Plans — erst nach
  ausdrücklicher Freigabe.
