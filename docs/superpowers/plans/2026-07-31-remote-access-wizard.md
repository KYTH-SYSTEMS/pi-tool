# Fernzugriff-Wizard (Tailscale) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein Knopf richtet den Fernzugriff über Tailscale ein, beweist danach, dass das *Handy* den Pi wirklich erreicht, und die App wechselt ab dann von allein zwischen Heim-Adresse und Tailnet-IP.

**Architecture:** Die Bausteine existieren (`tailscaleInstallScript`, `tailscaleUpScript`, `parseTailscaleAuthUrl`, `parseTailscaleIp`, Profilfelder `lanHost`/`tailscaleIp`). Neu sind: eine reine Kandidaten-Funktion für die Verbindungsreihenfolge, ein billiger Erreichbarkeits-Probe auf der `EvccUpdater`-Ebene, und eine Karte mit drei Zuständen, die die vorhandenen Schritte verkettet. Kein modaler Wizard — jede Phase ist ein eigener Handler nach dem Pflichtmuster, damit `_busy`/`_guard` unangetastet bleiben.

**Tech Stack:** Flutter/Dart, `dartssh2` hinter `SshRunner`, l10n über `.arb` + `flutter gen-l10n`.

## Global Constraints

- Antworten/UI-Texte **Deutsch** mit echten Umlauten; Technik-Begriffe englisch. Commits englisch.
- Jede in Shell-Befehle interpolierte Variable durch `shSingleQuote`; Heredocs in On-Pi-Skripten quoten.
- Handler-Muster in `main.dart`: `if (_busy) return;` → `_prepare()` → `_lastAction` **vor** dem ersten `_guard` → SSH-Arbeit **in** `_guard`.
- Kein Android-Hintergrunddienst. Kein ungetesteter Native-/Plugin-Code im Startpfad.
- TDD: reine Logik zuerst testen. `flutter analyze` + kompletter `flutter test` grün, bevor getaggt wird.
- Neues Pro-Feature ⇒ über `_proGate(...)` + `pro: true` (schläft aktuell durch `DormantEntitlement`).
- Play-Limits: Changelog ≤ 500 Zeichen, in **de-DE UND en-US**.

**Abweichung vom Spec (bewusst):** Der Spec sprach von einem „geführten Dialog mit Fortschritt". Umgesetzt wird stattdessen eine **Karte mit drei Zuständen**. Grund: Zwischen Schritt 4 (Browser-Login) und 5 muss auf eine Nutzerhandlung *außerhalb der App* gewartet werden. Ein modaler Dialog müsste dafür `_busy` halten oder wieder loslassen — beides bricht das Handler-Pflichtmuster. Drei Kartenzustände mit je einem eigenen Handler sind ehrlicher, testbarer und passen zu den bestehenden Idiomen.

---

### Task 1: Reihenfolge der Verbindungsversuche (reine Logik)

**Files:**
- Modify: `lib/src/services/tailscale.dart` (ans Ende)
- Test: `test/tailscale_test.dart`

**Interfaces:**
- Produces: `List<String> remoteAccessCandidates({required String lanHost, required String tailscaleIp, required String lastGood})`

- [ ] **Step 1: Write the failing test**

```dart
  group('remoteAccessCandidates', () {
    test('beide bekannt: Heim-Adresse zuerst (schnell, ohne VPN)', () {
      expect(
        remoteAccessCandidates(
            lanHost: '192.168.178.125', tailscaleIp: '100.64.0.5', lastGood: ''),
        ['192.168.178.125', '100.64.0.5'],
      );
    });

    test('zuletzt erfolgreich war das Tailnet: dann das zuerst', () {
      expect(
        remoteAccessCandidates(
            lanHost: '192.168.178.125',
            tailscaleIp: '100.64.0.5',
            lastGood: '100.64.0.5'),
        ['100.64.0.5', '192.168.178.125'],
      );
    });

    test('veralteter lastGood (Pi hat neue LAN-IP) wird ignoriert', () {
      expect(
        remoteAccessCandidates(
            lanHost: '192.168.178.125',
            tailscaleIp: '100.64.0.5',
            lastGood: '192.168.178.99'),
        ['192.168.178.125', '100.64.0.5'],
      );
    });

    test('nur eine Adresse bekannt: kein Rückfall, keine Wartezeit', () {
      expect(
        remoteAccessCandidates(
            lanHost: '192.168.178.125', tailscaleIp: '', lastGood: ''),
        ['192.168.178.125'],
      );
      expect(
        remoteAccessCandidates(
            lanHost: '', tailscaleIp: '100.64.0.5', lastGood: ''),
        ['100.64.0.5'],
      );
    });

    test('nichts bekannt: leer', () {
      expect(
        remoteAccessCandidates(lanHost: '  ', tailscaleIp: '', lastGood: ''),
        isEmpty,
      );
    });
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/tailscale_test.dart --plain-name "remoteAccessCandidates"`
Expected: FAIL — „Method not found: 'remoteAccessCandidates'".

- [ ] **Step 3: Write minimal implementation**

```dart
/// Ordered connect candidates for a Pi that has both a home address and a
/// tailnet IP. Home first — it is the fast path and needs no VPN — unless the
/// tailnet is what worked last time. A [lastGood] that matches neither known
/// address is stale (the Pi moved to a new LAN IP) and is ignored.
///
/// Fewer than two known addresses returns them as-is: callers then behave
/// exactly as before and pay no fallback delay.
List<String> remoteAccessCandidates({
  required String lanHost,
  required String tailscaleIp,
  required String lastGood,
}) {
  final lan = lanHost.trim();
  final ts = tailscaleIp.trim();
  final known = [if (lan.isNotEmpty) lan, if (ts.isNotEmpty) ts];
  if (known.length < 2) return known;
  return lastGood.trim() == ts ? [ts, lan] : [lan, ts];
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/tailscale_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/src/services/tailscale.dart test/tailscale_test.dart
git commit -m "feat(remote): order connect candidates home-first, last-good-first"
```

---

### Task 2: Billiger Erreichbarkeits-Probe + `SshConfig.copyWith`

**Files:**
- Modify: `lib/src/ssh_runner.dart:31-43` (copyWith an `SshConfig`)
- Modify: `lib/src/evcc_updater.dart` (neue Methode neben `installTailscale`)
- Test: `test/evcc_updater_test.dart`

**Interfaces:**
- Consumes: nichts aus Task 1.
- Produces:
  - `SshConfig SshConfig.copyWith({String? host, Duration? timeout})`
  - `Future<bool> EvccUpdater.probeConnection({required SshConfig config, void Function(String line)? onLog})`

- [ ] **Step 1: Write the failing test**

```dart
  group('EvccUpdater.probeConnection', () {
    test('true when the host answers', () async {
      final runner = FakeSshRunner({'true': [_r('')]});
      expect(await _updaterWith(runner).probeConnection(config: _config), isTrue);
    });

    test('false when the connection fails — never throws', () async {
      final runner = FakeSshRunner(const {},
          connectError: const SocketException('no route'));
      expect(await _updaterWith(runner).probeConnection(config: _config), isFalse);
    });

    test('a CHANGED HOST KEY still throws — never silently "unreachable"', () async {
      // Swallowing this would turn a possible MITM into a shrug.
      final runner = FakeSshRunner(const {},
          connectError: HostKeyChangedException('SHA256:new'));
      expect(
        () => _updaterWith(runner).probeConnection(config: _config),
        throwsA(isA<HostKeyChangedException>()),
      );
    });
  });
```

`SocketException` braucht `import 'dart:io';` in der Testdatei (prüfen, ob schon vorhanden). Den genauen Konstruktor von `HostKeyChangedException` in `lib/src/ssh_runner.dart` nachschlagen und im Test exakt so verwenden.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/evcc_updater_test.dart --plain-name "probeConnection"`
Expected: FAIL — „The method 'probeConnection' isn't defined".

- [ ] **Step 3: Write minimal implementation**

In `lib/src/ssh_runner.dart`, innerhalb `class SshConfig` nach dem Konstruktor:

```dart
  /// Same connection, different address or deadline — used by the home/tailnet
  /// fallback (short timeout for the first attempt) and the reachability probe.
  SshConfig copyWith({String? host, Duration? timeout}) => SshConfig(
        host: host ?? this.host,
        port: port,
        username: username,
        password: password,
        timeout: timeout ?? this.timeout,
        commandTimeout: commandTimeout,
        privateKey: privateKey,
        keyPassphrase: keyPassphrase,
      );
```

In `lib/src/evcc_updater.dart`, direkt vor `installTailscale`:

```dart
  /// Cheap reachability check: connect, run `true`, done. Used by the
  /// home/tailnet fallback and to PROVE the phone can reach the tailnet before
  /// the app claims the remote access is set up.
  ///
  /// Returns false instead of throwing — "not reachable" is an answer, not an
  /// error. The one exception is [HostKeyChangedException]: a changed host key
  /// is a security event and must never be flattened into "unreachable".
  Future<bool> probeConnection({
    required SshConfig config,
    void Function(String line)? onLog,
  }) async {
    try {
      await _withConnection<void>(
        config: config,
        onLog: onLog ?? (_) {},
        body: (runner, log) async {
          await runner.run('true');
        },
      );
      return true;
    } on HostKeyChangedException {
      rethrow;
    } catch (_) {
      return false;
    }
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/evcc_updater_test.dart --plain-name "probeConnection"`
Expected: PASS. Danach `flutter test test/evcc_updater_test.dart` komplett — nichts anderes darf brechen.

- [ ] **Step 5: Commit**

```bash
git add lib/src/ssh_runner.dart lib/src/evcc_updater.dart test/evcc_updater_test.dart
git commit -m "feat(remote): add a cheap reachability probe that never hides a host-key change"
```

---

### Task 3: Automatischer Rückfall beim Verbinden

**Files:**
- Modify: `lib/src/profiles.dart:22-83` (Feld `lastGoodHost`)
- Modify: `lib/main.dart` — Feld `_lastGoodHost`, `_profileFromState`/`_applyProfile`, `_testConnection` (ab ~1343)
- Test: `test/profiles_test.dart`, `test/dispatch_test.dart`

**Interfaces:**
- Consumes: `remoteAccessCandidates` (Task 1), `probeConnection` + `SshConfig.copyWith` (Task 2).
- Produces: Profilfeld `lastGoodHost` (JSON-Schlüssel `lastGoodHost`), fortgeschrieben nach jedem erfolgreichen Verbinden.

- [ ] **Step 1: Write the failing test (Persistenz)**

In `test/profiles_test.dart`, im vorhandenen Round-Trip-Stil:

```dart
    test('lastGoodHost überlebt den JSON-Round-Trip', () {
      const p = Profile(
          name: 'Pi', lanHost: '192.168.178.125', tailscaleIp: '100.64.0.5',
          lastGoodHost: '100.64.0.5');
      expect(Profile.fromJson(p.toJson()).lastGoodHost, '100.64.0.5');
    });

    test('altes Profil ohne das Feld lädt als leer, nicht als Fehler', () {
      expect(Profile.fromJson(const {'name': 'Pi'}).lastGoodHost, '');
    });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/profiles_test.dart --plain-name "lastGoodHost"`
Expected: FAIL — „No named parameter with the name 'lastGoodHost'".

- [ ] **Step 3: Implement the profile field**

In `lib/src/profiles.dart` analog zu `tailscaleIp`/`lanHost` ergänzen: Feld `final String lastGoodHost;`, Konstruktor-Default `this.lastGoodHost = ''`, `copyWith({..., String? lastGoodHost})`, `toJson` (`'lastGoodHost': lastGoodHost`), `fromJson` (`(j['lastGoodHost'] ?? '').toString()`). Doku-Kommentar:

```dart
  /// Which of [lanHost]/[tailscaleIp] answered last. Only an ordering hint for
  /// the next connect — never a source of truth, and never shown to the user.
  final String lastGoodHost;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/profiles_test.dart`
Expected: PASS.

- [ ] **Step 5: Write the failing test (Rückfall im Verbinden)**

In `test/dispatch_test.dart`. `FakeEvccUpdater` bekommt:

```dart
  /// Hosts that answer probeConnection; everything else is "unreachable".
  Set<String> reachableHosts = {};
  final List<String> probedHosts = [];

  @override
  Future<bool> probeConnection({
    required SshConfig config,
    void Function(String line)? onLog,
  }) async {
    probedHosts.add(config.host);
    return reachableHosts.contains(config.host);
  }
```

und der Test:

```dart
  testWidgets('Verbinden fällt auf die Tailnet-IP zurück, wenn die Heim-IP tot ist',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()..reachableHosts = {'100.64.0.5'};
    await tester.pumpWidget(page(u, profile: const Profile(
        name: 'Pi',
        lanHost: '192.168.178.125',
        tailscaleIp: '100.64.0.5')));
    await tester.pumpAndSettle();
    await detect(tester);

    // Heim zuerst versucht, dann Tailnet — und mit der Tailnet-Adresse verbunden.
    expect(u.probedHosts, ['192.168.178.125', '100.64.0.5']);
    expect(find.text('100.64.0.5'), findsWidgets);
  });
```

Den `page(...)`-Helper in `dispatch_test.dart` prüfen: Nimmt er ein Startprofil entgegen? Falls nicht, den vorhandenen Weg nutzen, wie andere Tests ein Profil vorbelegen, und den Test daran anpassen — **nicht** den Produktionscode für den Test verbiegen.

- [ ] **Step 6: Run test to verify it fails**

Run: `flutter test test/dispatch_test.dart --plain-name "fällt auf die Tailnet-IP"`
Expected: FAIL — `probedHosts` ist leer (es wird gar nicht sondiert).

- [ ] **Step 7: Implement the fallback in `_testConnection`**

In `lib/main.dart`, in `_testConnection` **vor** dem `_guard`-Block mit `detectServices`:

```dart
    // Both addresses known → find the one that answers before the real work
    // starts. One address (the normal case) skips this entirely: nobody
    // without remote access pays a fallback delay.
    final candidates = remoteAccessCandidates(
      lanHost: _lanHost,
      tailscaleIp: _tailscaleIp,
      lastGood: _lastGoodHost,
    );
    if (candidates.length > 1) {
      for (final host in candidates) {
        final probe = config.copyWith(
            host: host, timeout: const Duration(seconds: 4));
        if (await _updater.probeConnection(config: probe, onLog: _appendLog)) {
          config = config.copyWith(host: host);
          if (!mounted) return;
          setState(() {
            _host.text = host;
            _lastGoodHost = host;
          });
          _scheduleSave();
          break;
        }
      }
      // None answered: fall through with the first candidate so the normal
      // error path reports a real connection failure instead of a silent stall.
    }
```

Dafür muss `config` in `_testConnection` von `final` auf `var` (bzw. lokale Kopie) umgestellt werden. Feld `String _lastGoodHost = '';` neben `_tailscaleIp`/`_lanHost` anlegen und in `_applyProfile` (~Zeile 478) sowie im Profil-Bau (~Zeile 532) mitführen. Import `services/tailscale.dart` in `main.dart` prüfen (bereits vorhanden wegen `isTailnetHost`).

- [ ] **Step 8: Run tests**

Run: `flutter test test/dispatch_test.dart test/profiles_test.dart`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add lib/src/profiles.dart lib/main.dart test/profiles_test.dart test/dispatch_test.dart
git commit -m "feat(remote): try home address, fall back to the tailnet IP, remember which won"
```

---

### Task 4: Die Karte „Fernzugriff einrichten"

**Files:**
- Modify: `lib/l10n/app_de.arb`, `lib/l10n/app_en.arb`
- Modify: `lib/main.dart` (Handler + Karte im Verwaltungs-Tab)
- Test: `test/dispatch_test.dart`

**Interfaces:**
- Consumes: `installTailscale`, `tailscaleUp` (vorhanden), `probeConnection` (Task 2), Profilfeld `tailscaleIp`.
- Produces: Handler `_setupRemoteAccess()` und `_checkRemoteAccess()`.

**Drei Kartenzustände** (die Karte erscheint nur, wenn `_connected` **und** `_tailscaleIp.isEmpty`, plus Zustand C solange die Handy-Seite fehlt):

| Zustand | Text | Knopf |
|---|---|---|
| A — nichts eingerichtet | „Damit erreichst du deinen Pi auch von unterwegs." | „Fernzugriff einrichten" → `_setupRemoteAccess` |
| B — Browser-Login offen | „Bestätige die Anmeldung im Browser, dann hier weiter." | „Jetzt prüfen" → `_checkRemoteAccess` |
| C — Pi fertig, Handy fehlt | „Der Pi ist bereit. Auf diesem Handy fehlt noch Tailscale — mit demselben Konto anmelden." | „Tailscale-App holen" (Store) · „Erneut prüfen" |

- [ ] **Step 1: Add the l10n strings**

`lib/l10n/app_de.arb`:

```json
  "actionSetupRemoteAccess": "Fernzugriff einrichten",
  "actionCheckRemoteAccess": "Jetzt prüfen",
  "actionGetTailscaleApp": "Tailscale-App holen",
  "remoteAccessTitle": "Fernzugriff",
  "remoteAccessIntro": "Richte den Zugriff von unterwegs ein — danach funktioniert Pi-Tool überall wie zu Hause.",
  "remoteAccessConfirmInBrowser": "Bestätige die Anmeldung im Browser, dann hier weiter.",
  "remoteAccessPhoneMissing": "Der Pi ist bereit. Auf diesem Handy fehlt noch Tailscale — installiere die App und melde dich mit demselben Konto an.",
  "statusRemoteAccessReady": "Fernzugriff steht: {ip}",
  "busySettingUpRemoteAccess": "Fernzugriff wird eingerichtet …",
```

`lib/l10n/app_en.arb` mit denselben Schlüsseln auf Englisch. Für `statusRemoteAccessReady` in **app_en.arb** (Template) die Platzhalter-Beschreibung ergänzen, wie es dort bei anderen Platzhalter-Strings gemacht ist (`"@statusRemoteAccessReady": {"placeholders": {"ip": {"type": "String"}}}`).

Danach `flutter gen-l10n`.

- [ ] **Step 2: Write the failing test**

```dart
  testWidgets('Fernzugriff einrichten: installiert, meldet an, öffnet den Browser',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(id: 'system', name: 'System (Pi)', installed: true, active: true),
      ]
      ..tailscaleAuthUrl = 'https://login.tailscale.com/a/abc123';
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.text('Fernzugriff einrichten'));
    await tester.pumpAndSettle();

    expect(u.tailscaleInstallCalls, 1);
    expect(u.tailscaleUpCalls, 1);
    expect(u.openedUrls.last, 'https://login.tailscale.com/a/abc123');
    // Zustand B: der Nutzer muss im Browser bestätigen.
    expect(find.text('Jetzt prüfen'), findsOneWidget);
  });

  testWidgets('Prüfen meldet erst Erfolg, wenn das HANDY den Pi erreicht',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(id: 'tailscale', name: 'Tailscale', installed: true,
            active: true, version: '100.64.0.5'),
      ]
      ..reachableHosts = {}; // Handy ist NICHT im Tailnet
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);
    await tester.tap(find.text('Fernzugriff einrichten'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jetzt prüfen'));
    await tester.pumpAndSettle();

    expect(find.textContaining('fehlt noch Tailscale'), findsOneWidget);
    expect(find.textContaining('Fernzugriff steht'), findsNothing);
  });
```

`FakeEvccUpdater` dafür erweitern: `int tailscaleInstallCalls = 0, tailscaleUpCalls = 0;`, `String? tailscaleAuthUrl;`, Overrides für `installTailscale`/`tailscaleUp`. Wie der Test an geöffnete URLs kommt (`openedUrls`), am vorhandenen Muster in `dispatch_test.dart` orientieren — falls es keins gibt, den `_openUrl`-Pfad über den bestehenden Test-Hook nutzen und den Test daran anpassen.

- [ ] **Step 3: Run tests to verify they fail**

Run: `flutter test test/dispatch_test.dart --plain-name "Fernzugriff"`
Expected: FAIL — „Fernzugriff einrichten" ist nicht auffindbar.

- [ ] **Step 4: Implement the handlers**

In `lib/main.dart`, neben den Tailscale-Handlern (~4280). Beide folgen dem Pflichtmuster:

```dart
  /// Phase 1: Tailscale auf den Pi bringen und anmelden. Öffnet die Login-URL;
  /// bestätigen muss der Nutzer im Browser, deshalb endet die Phase hier.
  Future<void> _setupRemoteAccess() async {
    if (_busy) return;
    final l10n = context.l10n;
    final config = _prepare();
    if (config == null) return;
    _lastAction = _setupRemoteAccess;
    String? url;
    await _guard(() async {
      final installed = _services
          .any((s) => s.id == 'tailscale' && s.installed);
      if (!installed) {
        await _updater.installTailscale(config: config, onLog: _appendLog);
      }
      url = await _updater.tailscaleUp(config: config, onLog: _appendLog);
    }, backgroundMessage: l10n.busySettingUpRemoteAccess);
    if (!mounted) return;
    setState(() => _remoteAccessPhase = _RemoteAccessPhase.awaitingBrowser);
    if (url != null) await _openUrl(url!);
  }

  /// Phase 2: Tailnet-IP holen — und beweisen, dass DIESES Handy sie erreicht.
  /// Ohne den Beweis hielte sich der Nutzer für fertig und merkte es unterwegs.
  Future<void> _checkRemoteAccess() async {
    if (_busy) return;
    final l10n = context.l10n;
    final config = _prepare();
    if (config == null) return;
    _lastAction = _checkRemoteAccess;
    await _guard(() async {
      final services = await _updater.detectServices(
          config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _services = services;
        _rememberTailscaleIp(services);
      });
      if (_tailscaleIp.isEmpty) {
        setState(() => _remoteAccessPhase = _RemoteAccessPhase.awaitingBrowser);
        return;
      }
      final reachable = await _updater.probeConnection(
        config: config.copyWith(
            host: _tailscaleIp, timeout: const Duration(seconds: 8)),
        onLog: _appendLog,
      );
      if (!mounted) return;
      setState(() {
        _remoteAccessPhase = reachable
            ? _RemoteAccessPhase.done
            : _RemoteAccessPhase.phoneMissing;
        if (reachable) {
          _statusMessage = context.l10n.statusRemoteAccessReady(_tailscaleIp);
          _statusOk = true;
        }
      });
    }, backgroundMessage: l10n.busySettingUpRemoteAccess);
  }
```

Dazu auf State-Ebene:

```dart
enum _RemoteAccessPhase { idle, awaitingBrowser, phoneMissing, done }
```

und `_RemoteAccessPhase _remoteAccessPhase = _RemoteAccessPhase.idle;` als Feld (nur im Speicher, nicht persistiert — nach einem Neustart entscheidet wieder `_tailscaleIp`).

- [ ] **Step 5: Implement the card**

Im Verwaltungs-Tab, dort wo die Service-Karten zusammengebaut werden, **vor** den Dienst-Karten einfügen — sichtbar nur wenn `_connected && (_tailscaleIp.isEmpty || _remoteAccessPhase == _RemoteAccessPhase.phoneMissing)`. Primärknopf über `_proGate`:

```dart
onPressed: _busy ? null : () => _proGate(_setupRemoteAccess),
```

Der Store-Knopf in Zustand C öffnet
`https://play.google.com/store/apps/details?id=com.tailscale.ipn` über `_openUrl`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `flutter test test/dispatch_test.dart`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/l10n lib/main.dart test/dispatch_test.dart
git commit -m "feat(remote): one card that sets up Tailscale and proves the phone can reach it"
```

---

### Task 5: Doku + Release v0.64.0+122

**Files:**
- Modify: `ARCHITECTURE.md`, `README.md`, `lib/src/whats_new.dart`, `pubspec.yaml`
- Create: `fastlane/metadata/android/de-DE/changelogs/122.txt`, `fastlane/metadata/android/en-US/changelogs/122.txt`

- [ ] **Step 1: ARCHITECTURE.md**

Im Dienst-Katalog-Abschnitt bei Tailscale ergänzen: `remoteAccessCandidates` als reine Reihenfolge-Logik, `probeConnection` (und **warum** es `HostKeyChangedException` durchreicht), das Profilfeld `lastGoodHost` als reiner Ordnungs-Hinweis, und die Invariante: **kein Portforwarding/DynDNS** — der Sicherheits-Check der App markiert offene SSH-Ports, das darf die App nicht selbst anbieten.

- [ ] **Step 2: README.md**

Neuer Punkt in der Funktionen-Liste, nach dem Tailscale-Eintrag: ein Knopf richtet den Fernzugriff ein; die App prüft danach selbst, ob das Handy den Pi erreicht, und wechselt beim Verbinden automatisch zwischen Heim-Adresse und Tailnet-IP. Ausdrücklich erwähnen, dass die Tailscale-App aufs Handy muss — das ist der Punkt, an dem sonst Support-Fragen entstehen.

- [ ] **Step 3: whats_new.dart**

`'0.64.0'` in `_whatsNew` (de) **und** `_whatsNewEn` (en) ganz oben ergänzen: was der Knopf tut, dass die App den Erfolg misst statt ihn zu behaupten, und dass die Adresse beim Verbinden automatisch gewählt wird.

- [ ] **Step 4: fastlane-Changelogs (beide Sprachen, je ≤ 500 Zeichen)**

Nach dem Schreiben zwingend messen:

```bash
for f in fastlane/metadata/android/*/changelogs/122.txt; do \
  python -c "import io,sys;print(sys.argv[1], len(io.open(sys.argv[1],encoding='utf-8').read().rstrip(chr(10))))" "$f"; done
```

- [ ] **Step 5: Version bump + grün prüfen**

`pubspec.yaml` auf `version: 0.64.0+122`. Dann `flutter analyze` und kompletter `flutter test` — beide müssen grün sein.

- [ ] **Step 6: Commit, push, Release**

```bash
git add -A && git commit -F <nachricht.txt> && git push origin main
```

Danach: main-Build abwarten, **Play-Trockenlauf** (`gh workflow run build.yml -R KYTH-SYSTEMS/pi-tool -f play_dry_run=true`) grün abwarten, dann `v0.64.0` taggen und pushen. Der Tag veröffentlicht automatisch bei Play (Produktion, 100 %). Zum Schluss das AAB samt beider Changelogs nach `Desktop\Pi-Tool Play-Upload\v0.64.0\` legen.
