/// In-app **demo mode**: a fake [SshRunner] + evcc API client that return canned,
/// believable data so a reviewer (or a curious user) can explore every tab
/// WITHOUT a real Raspberry Pi. Never opens a socket, never runs anything. Used
/// to satisfy Google Play's "reviewers must be able to access the app" rule
/// without shipping demo SSH credentials, and as a "try before you connect"
/// feature. Everything here is static; the pure parsing layer turns the canned
/// stdout into real-looking service cards, so no UI faking is needed.
library;

import 'dart:convert';

import 'commands.dart'
    show detectShellCommand, dockerListCommand, serviceStatus, versionQuery;
import 'evcc_api.dart';
import 'evcc_updater.dart';
import 'ssh_runner.dart';

/// A fake [SshRunner] backing demo mode: [connect]/[close] are no-ops, and
/// [run] returns canned stdout via [demoResponseFor]. Constructed per action by
/// the demo [EvccUpdater]'s factory, exactly like the real runner.
class DemoSshRunner implements SshRunner {
  DemoSshRunner(this.config);

  final SshConfig config;

  @override
  Future<void> connect() async {}

  @override
  Future<void> close() async {}

  @override
  Future<CommandResult> run(
    String command, {
    String? stdin,
    void Function(String chunk)? onOutput,
  }) async {
    final out = demoResponseFor(command);
    // Stream whole lines, mirroring the real runner's line-buffered callback so
    // the terminal/log shows output as it "arrives".
    if (onOutput != null && out.isNotEmpty) {
      for (final line in const LineSplitter().convert(out)) {
        onOutput('$line\n');
      }
    }
    return CommandResult(exitCode: 0, stdout: out, stderr: '');
  }
}

/// A ready-to-inject demo [EvccUpdater] whose runner is a [DemoSshRunner]. Every
/// SSH action funnels through this one factory, so the whole app is faked here.
EvccUpdater buildDemoUpdater() =>
    EvccUpdater(runnerFactory: (config) => DemoSshRunner(config));

/// A demo [EvccApiClient] for the evcc "Live-Status" sheet, which uses HTTP (not
/// SSH) and therefore needs its own fake.
EvccApiClient buildDemoApiClient() =>
    EvccApiClient(getJson: (_) async => demoEvccState);

/// Pure `command` → canned-stdout mapping. Unit-tested against the real parsers,
/// so the canned output must satisfy their format expectations.
String demoResponseFor(String command) {
  final c = command;

  // 1. The batched detection probe — one response powers the whole Verwaltung
  //    tab + the System card. (Probes arrive on stdin, which we ignore.)
  if (c == detectShellCommand) return _detectDoc;

  // 2. The individual probes used by detectInstall (update path).
  if (c == versionQuery) return 'installed 0.207.0\n';
  if (c == serviceStatus) return 'active\n';
  if (c == dockerListCommand || c.contains('docker ps')) return '';

  // 3. Dateien tab (file browser).
  if (c.contains(' ls -1Ap ')) return _dirListing;
  if (c.contains('head -c 524288') && c.contains('base64')) return _sampleFileB64;
  if (c.startsWith('wc -c <')) return '${_sampleFileBytes.length}\n';
  if (c.startsWith('base64 --')) return _sampleFileB64;

  // 4. Terminal tab (free-form console, wrapped by buildConsoleExec).
  if (c.contains('| head -c 262144')) return _terminalResponse(c);

  // 5. Benign default: succeed quietly. NEVER emit a sudo-failure token
  //    ("incorrect password"/"sorry, try again") — that would trip
  //    isSudoPasswordFailure and surface a fake auth error.
  return '';
}

// ---------------------------------------------------------------------------
// Canned data — persona: a healthy Raspberry Pi 4 (Bookworm) running apt-evcc
// (active, up to date) and Pi-hole (active). Everything else absent → 3 clean
// cards: System, evcc, Pi-hole.
// ---------------------------------------------------------------------------

const String _m = '@@PT@@'; // must match _detectMarker in commands.dart

/// Marker-delimited detection document consumed by `splitDetectSections`.
const String _detectDoc = '$_m'
    'OS$_m\n'
    'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\n'
    'NAME="Debian GNU/Linux"\n'
    'VERSION_ID="12"\n'
    'VERSION="12 (bookworm)"\n'
    'ID=debian\n'
    '${_m}TEMP$_m\n'
    "temp=47.2'C\n"
    '${_m}DISK$_m\n'
    'Filesystem 1M-blocks Used Available Use% Mounted on\n'
    '/dev/root 30044M 8123M 20554M 29% /\n'
    '${_m}MEM$_m\n'
    '              total        used        free      shared  buff/cache   available\n'
    'Mem:           3792         842        1934          62        1015        2721\n'
    'Swap:           511           0         511\n'
    '${_m}UPTIME$_m\n'
    'up 5 days, 3 hours\n'
    '${_m}STORAGE$_m\n'
    '/dev/mmcblk0p2 / ext4 rw,noatime 0 0\n'
    '/dev/mmcblk0p1 /boot vfat rw,relatime 0 0\n'
    '0\n'
    '${_m}PENDING$_m\n'
    '0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.\n'
    // Package index refreshed an hour ago, so the demo Pi may legitimately
    // claim "aktuell" instead of "Stand unbekannt".
    '${_m}APTAGE$_m\n'
    '3600\n'
    '${_m}EVCC_V$_m\n'
    'installed 0.207.0\n'
    '${_m}EVCC_SVC$_m\n'
    'active\n'
    '${_m}PIHOLE_V$_m\n'
    'Core version is v6.0.6 (Latest: v6.0.6)\n'
    'Web version is v6.0 (Latest: v6.0)\n'
    'FTL version is v6.0 (Latest: v6.0)\n'
    '${_m}PIHOLE_S$_m\n'
    '  [✓] FTL is listening on port 53\n'
    '     [✓] Blocking is enabled\n';

/// Canned `ls -1Ap` listing (dirs end with `/`), parsed by `parseDirListing`.
const String _dirListing = 'backups/\n'
    'logs/\n'
    'evcc.yaml\n'
    'evcc.db\n'
    'README.md\n';

/// A small sample file shown when previewing/downloading in the browser.
const String _sampleFileText = '# evcc – Demo-Konfiguration\n'
    'network:\n'
    '  schema: http\n'
    '  host: demo.local\n'
    '  port: 7070\n'
    'site:\n'
    '  title: Zuhause\n';

final List<int> _sampleFileBytes = utf8.encode(_sampleFileText);
final String _sampleFileB64 = '${base64.encode(_sampleFileBytes)}\n';

/// A canned terminal response for a handful of common commands, so the console
/// feels alive; anything else gets a friendly demo note.
String _terminalResponse(String wrapped) {
  var inner = wrapped;
  final s = inner.indexOf('{ ');
  final e = inner.indexOf(' ; }');
  if (s >= 0 && e > s) inner = inner.substring(s + 2, e).trim();
  inner = inner.replaceFirst(RegExp(r"^sudo -S -p '' "), 'sudo ');
  final first = inner.split(RegExp(r'\s+')).first;
  switch (first) {
    case 'ls':
      return 'backups  evcc.db  evcc.yaml  logs  README.md\n';
    case 'pwd':
      return '/home/pi\n';
    case 'whoami':
      return 'pi\n';
    case 'uname':
      return 'Linux raspberrypi 6.6.20-v8+ #1 SMP aarch64 GNU/Linux\n';
    case 'uptime':
      return ' 14:30:01 up 5 days,  3:12,  1 user,  load average: 0.08, 0.12, 0.09\n';
    case 'df':
      return 'Filesystem      Size  Used Avail Use% Mounted on\n'
          '/dev/root        30G  8.0G   20G  29% /\n';
    case 'echo':
      return '${inner.length > 5 ? inner.substring(5) : ''}\n';
    default:
      return 'Demo-Modus: Befehle werden nicht wirklich ausgefuehrt.\n';
  }
}

/// Canned evcc live state for the "Live-Status" sheet (parsed by
/// `parseEvccState`). A sunny day: PV surplus, battery charging, one car on PV.
const Map<String, dynamic> demoEvccState = {
  'version': '0.207.0',
  'siteTitle': 'Zuhause',
  'gridPower': -1240.0,
  'homePower': 480.0,
  'pvPower': 2100.0,
  'batteryConfigured': true,
  'batterySoc': 76,
  'batteryPower': -380.0,
  'loadpoints': [
    {
      'title': 'Garage',
      'connected': true,
      'charging': true,
      'chargePower': 4100.0,
      'vehicleSoc': 62,
      'mode': 'pv',
    },
  ],
};
