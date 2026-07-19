# Demo-Modus + Early-Adopter-Marker — Design (v0.61.0)

**Datum:** 2026-07-19 · **Status:** genehmigt, in Umsetzung
**Ziel:** Ein **Demo-Modus**, mit dem ein Google-Play-Prüfer (und jeder Nutzer)
die **komplette App inkl. aller Pro-Features** ohne echten Raspberry Pi
durchklicken kann — löst die Play-Ablehnung „provide valid login credentials /
LoginWall" ohne externen Server. Dazu im selben Release der zuvor geplante
**Early-Adopter-Marker** ([[2026-07-16-early-adopter-marker-design]]).

## Warum (Kontext)
Google hat v0.60.0 (versionCode 111) abgelehnt: der Prüfer sah den
SSH-Verbindungs-Screen als Login-Wall. Ein Demo-Modus ist die von Google
akzeptierte Alternative zu Demo-Zugangsdaten — permanent, ohne Infrastruktur,
und zugleich ein echtes „Try it"-Feature.

## Nicht-Ziele
- Kein Voll-Simulator: Aktionen (Update/Backup/Install) müssen im Demo nicht
  realistisch ablaufen — unbekannte Befehle liefern eine **harmlose Erfolgs-
  Antwort** (exitCode 0, leer), damit nie etwas crasht.
- Keine Persistenz: `_demoMode` ist **rein In-Memory** (wie `_connected`), NICHT
  in `AppConfig`.
- Kein Anfassen bestehender Logik: alles **additiv**, `_demoMode == false` ⇒
  exakt heutiges Verhalten.

## Architektur — der eine Seam
Alle SSH-Aktionen laufen durch `EvccUpdater`, das seinen Runner über
`SshRunnerFactory` (`typedef SshRunner Function(SshConfig)`,
`evcc_updater.dart:83`) baut — die **einzige** Runner-Konstruktionsstelle
(`evcc_updater.dart:122`). Jede Aktion funnelt durch `_withConnection`
(`evcc_updater.dart:2329`). Also: **ein `DemoSshRunner implements SshRunner`
deckt Verwaltung/Automatik/Terminal/Dateien in einem Rutsch ab.**

Interface (`ssh_runner.dart:88-103`): `connect()`, `run(cmd,{stdin,onOutput})
→ CommandResult{int? exitCode, String stdout, String stderr}`, `close()`.

### Neue Datei `lib/src/demo.dart` (Flutter-frei, testbar)
```dart
class DemoSshRunner implements SshRunner {
  DemoSshRunner(this.config);
  final SshConfig config;
  @override Future<void> connect() async {}      // no-op success
  @override Future<void> close() async {}
  @override Future<CommandResult> run(String command,
      {String? stdin, void Function(String chunk)? onOutput}) async {
    final out = demoResponseFor(command);         // pure, testable
    if (onOutput != null) {                        // stream whole lines (terminal/log)
      for (final line in const LineSplitter().convert(out)) onOutput('$line\n');
    }
    return CommandResult(exitCode: 0, stdout: out, stderr: '');
  }
}

/// Pure command→canned-stdout mapping (unit-tested against the real parsers).
String demoResponseFor(String command) { ... }

/// A ready-to-inject demo EvccUpdater + demo evcc API client.
EvccUpdater buildDemoUpdater() =>
    EvccUpdater(runnerFactory: (c) => DemoSshRunner(c));
```

### `demoResponseFor` — command matching (from the command inventory)
1. **Detection batch** — `command == detectShellCommand` (`'LC_ALL=C bash -s'`,
   `commands.dart:650`) → return the marker document below. **This one response
   powers the whole Verwaltung tab + System card.**
2. Bare `versionQuery` / `serviceStatus` / `dockerListCommand` (used by
   `detectInstall`) → `installed 0.207.0` / `active` / `` (empty).
3. `autoUpdateStatusCommand` / `scheduledBackupStatusCommand` /
   `alertsStatusCommand` → the `ENABLED/NEXT/STATUS` line triples (Automatik).
4. Terminal wrapper `{ … ; } 2>&1 | head -c 262144` (`commands.dart` console
   build) → echo a short canned line (or the inner command).
5. Dateien: `contains('ls -1Ap')` → canned dir listing; `contains('| base64')`
   / `base64 --` → base64 of a small canned file; `wc -c <` → an int.
6. **Default** → `CommandResult(0, '', '')` (benign; never `incorrect password`).

### The canned detection document (persona: Pi 4, Bookworm, apt-evcc active + Pi-hole)
Marker `@@PT@@` (`_detectMarker`, `commands.dart:728`); `splitDetectSections`
(`commands.dart:748`) keys on lines that start AND end with the marker. Only the
sections we want to show need to appear; the rest default to absent.
```
@@PT@@OS@@PT@@
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
NAME="Debian GNU/Linux"
VERSION_ID="12"
@@PT@@TEMP@@PT@@
temp=47.2'C
@@PT@@DISK@@PT@@
Filesystem 1M-blocks Used Available Use% Mounted on
/dev/root 30044M 8123M 20554M 29% /
@@PT@@MEM@@PT@@
              total        used        free      shared  buff/cache   available
Mem:           3792         842        1934          62        1015        2721
@@PT@@UPTIME@@PT@@
up 5 days, 3 hours
@@PT@@STORAGE@@PT@@
/dev/mmcblk0p2 / ext4 rw,noatime 0 0
0
@@PT@@PENDING@@PT@@
0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.
@@PT@@EVCC_V@@PT@@
installed 0.207.0
@@PT@@EVCC_SVC@@PT@@
active
@@PT@@PIHOLE_V@@PT@@
Core version is v6.0.6 (Latest: v6.0.6)
Web version is v6.0 (Latest: v6.0)
FTL version is v6.0 (Latest: v6.0)
@@PT@@PIHOLE_S@@PT@@
  [✓] FTL is listening on port 53
     [✓] Blocking is enabled
```
Parser constraints honored: `EVCC_V` starts with literal `installed`; `EVCC_SVC`
== `active`; `PENDING` contains `… upgraded, … newly installed …`; `DISK` cols
end `M`,`M`,`%`; `MEM` header has `available`; `PIHOLE_V` has `(Latest: …)`.
Result: **System (Pi) card + evcc card (apt, aktiv, aktuell) + Pi-hole card
(aktiv)**. Docker/HA/Tailscale/PiConnect/apt-services/systemd absent → clean.

### evcc-Status (Live) — NOT SSH (`evcc_api.dart`)
Inject a demo API client: `EvccApiClient(getJson: (uri) async => demoStateJson)`
(the `JsonGetter` seam, `evcc_api.dart:127`). Canned state: siteTitle "Zuhause",
pv/home/grid power, a battery + one loadpoint charging. Parsed by
`parseEvccState` (tolerant).

## UI + State wiring (`lib/main.dart`) — additive
- **New in-memory flag** `bool _demoMode = false;` next to `_connected` (~:281).
  In-memory only (never persisted), mirroring `_connected`.
- **Updater/API swap** (because `_updater` is `late final` :211): make the field
  a mutable pointer:
  ```dart
  late final EvccUpdater _realUpdater = widget.updater ?? EvccUpdater.real(...);
  late final EvccUpdater _demoUpdater = widget.demoUpdater ?? buildDemoUpdater();
  late EvccUpdater _updater = _realUpdater;                 // call-sites unchanged
  late final EvccApiClient _realApi = widget.apiClient ?? EvccApiClient();
  late final EvccApiClient _demoApi = widget.demoApiClient ?? buildDemoApiClient();
  late EvccApiClient _apiClient = _realApi;
  ```
  All existing `_updater.` / `_apiClient.` call-sites stay untouched; only the two
  field decls change from `final` to a mutable pointer + a `_real*` source.
- **`_startDemo()`** (mirrors `_testConnection` success :1300):
  `setState(() { _demoMode = true; _updater = _demoUpdater; _apiClient = _demoApi;
   _connected = true; _connExpanded = false; })` then run the normal
  `detectServices` path against `_demoUpdater` so the cards populate for real.
- **Exit demo** = the existing disconnect paths (`_invalidateConnTest` :413,
  `_resetDetectionForNewPi` :452, `_guard` connection-fail :1143, `_shutdown`):
  add `_demoMode = false; _updater = _realUpdater; _apiClient = _realApi;` there.
- **Entitlement bypass (full unlock):** add `bool get _demoUnlocked => _isPro ||
  _demoMode;` and use it at the gate sites — `_proGate` (:616 `if (_demoUnlocked)`),
  `isAddProfileLocked(isPro: _demoUnlocked, …)` (:860), and the lock badges/`isPro:`
  args (:3580… , :4726…, :4787). Real `_isPro`/entitlement untouched.
- **"Demo ausprobieren" button:** insert after `_TestButton` at `main.dart:4516`
  (Tab 0 children). An `OutlinedButton.icon` (play icon) → `_startDemo`.
- **Demo banner:** a `MaterialBanner`/thin bar shown while `_demoMode` (e.g. above
  the tabs) — l10n `demoBanner` = „Demo-Modus – Beispieldaten, kein echter Pi".

## Early-Adopter-Marker (bundled — see its own spec)
Implement `lib/src/early_adopter.dart` + `AppConfig.firstSeenVersionCode` + the
once-only stamp in init, exactly per [[2026-07-16-early-adopter-marker-design]].
No gating (DormantEntitlement stays). Independent of demo mode; same release.

## Test plan (TDD, all must stay green + new)
- `test/demo_test.dart`:
  - `demoResponseFor(detectShellCommand)` → feed through the REAL
    `splitDetectSections` + `detectServices` pipeline (via `buildDemoUpdater()`)
    and assert: services include a System card, evcc (installed, active,
    up-to-date), Pi-hole (active/blocking); Docker/HA absent.
  - `DemoSshRunner.run` streams whole lines to `onOutput`; `connect`/`close`
    succeed; unknown command → exitCode 0, empty stdout.
  - demo evcc API client → `parseEvccState` yields the canned loadpoint.
- `test/early_adopter_test.dart`: per the marker spec.
- Widget/dispatch: a test that `_startDemo` sets `_connected` + unlocks a gated
  tab and that `_demoUnlocked` opens a Pro-gated action without the paywall sheet.
- Full `flutter test` + `flutter analyze` green before tag.

## Docs (CLAUDE.md-Pflicht)
- `whats_new.dart`: user-facing „Demo-Modus zum Ausprobieren ohne Pi" (de+en).
- `README.md` Funktionen + `docs/index.html` (if scope shown) + fastlane
  `full_description` (de+en, watch 4000-char limit) + short_description if it fits
  + changelog `112.txt` (de+en).
- `ARCHITECTURE.md`: DemoSshRunner seam usage, `_demoMode`/`_demoUnlocked`,
  `AppConfig.firstSeenVersionCode`.

## Release + Play resubmit
- Bump `pubspec.yaml` → `0.61.0+112`. TDD → analyze → full test → **adversarial
  review pass** → local/CI build → tag `v0.61.0` → CI signs AAB.
- Play: App access → back to **"no credentials needed"** + note „On the first
  screen, tap 'Demo' to explore the app without a device." → resubmit.
- URLs/GitHub-org migration deliberately NOT in this release (Option A).
