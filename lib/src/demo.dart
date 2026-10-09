/// In-app **demo mode**: a fake [SshRunner] + evcc API client that return canned,
/// believable data so a reviewer (or a curious user) can explore every tab
/// WITHOUT a real Raspberry Pi. Never opens a socket, never runs anything. Used
/// to satisfy Google Play's "reviewers must be able to access the app" rule
/// without shipping demo SSH credentials, and as a "try before you connect"
/// feature. Everything here is static — except the three on-Pi timers, which
/// the demo Pi remembers ([DemoPi]); the pure parsing layer turns the canned
/// stdout into real-looking service cards, so no UI faking is needed.
library;

import 'dart:convert';

import 'alerts.dart' show alertsStatusCommand;
import 'auto_update.dart' show autoUpdateScheduleOf, autoUpdateStatusCommand;
import 'commands.dart'
    show
        detectEndKey,
        detectShellCommand,
        dockerListCommand,
        installShellCommand,
        serviceStatus,
        versionQuery;
import 'evcc_api.dart';
import 'evcc_updater.dart';
import 'on_pi_wrapper.dart'
    show
        alertsWrapperGeneration,
        autoUpdateWrapperGeneration,
        scheduledBackupWrapperGeneration;
import 'pi_job.dart';
import 'scheduled_backup.dart' show scheduledBackupStatusCommand;
import 'ssh_runner.dart';

/// What the demo Pi remembers between two actions: its three on-Pi timers
/// (Automatik tab). A sheet reads the timer's state before it opens — without
/// this, a timer switched on a moment ago would read as off. Everything else
/// in the demo is static. One per demo updater ([buildDemoUpdater]).
class DemoPi {
  /// `OnCalendar` of the automatic updates while they are on.
  String? autoUpdate;

  /// `OnCalendar` of the scheduled backups and the `n` of their wrapper's
  /// `tail -n +n` while they are on.
  ({String onCalendar, String drop})? backup;

  /// Whether the Health-Alerts are on.
  bool alerts = false;
}

/// A fake [SshRunner] backing demo mode: [connect]/[close] are no-ops, and
/// [run] returns canned stdout via [demoResponseFor]. Constructed per action by
/// the demo [EvccUpdater]'s factory, exactly like the real runner; [pi] is
/// what that factory's runners share.
class DemoSshRunner implements SshRunner {
  DemoSshRunner(this.config, [DemoPi? pi]) : pi = pi ?? DemoPi();

  final SshConfig config;
  final DemoPi pi;

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
    final out = demoResponseFor(command, stdin: stdin, pi: pi);
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
EvccUpdater buildDemoUpdater() {
  final pi = DemoPi();
  return EvccUpdater(runnerFactory: (config) => DemoSshRunner(config, pi));
}

/// A demo [EvccApiClient] for the evcc "Live-Status" sheet, which uses HTTP (not
/// SSH) and therefore needs its own fake.
EvccApiClient buildDemoApiClient() =>
    EvccApiClient(getJson: (_) async => demoEvccState);

/// `command` → canned-stdout mapping. Unit-tested against the real parsers,
/// so the canned output must satisfy their format expectations. [stdin] is
/// only read for Pi-Jobs (which kind of job the launcher carries) and for the
/// root scripts of the on-Pi timers. [pi] holds those timers — the one thing
/// the answers depend on besides the command (a Pi without timers when
/// omitted); [now] is for tests of a timer's next run.
String demoResponseFor(String command,
    {String? stdin, DemoPi? pi, DateTime? now}) {
  final c = command;
  final timers = pi ?? DemoPi();

  // 0. Pi-Jobs (updates, repair): a short log that ends like a real job —
  //    RC 0 with the kind's markers. Without this the demo would report every
  //    update as "Verbindung abgerissen – läuft auf dem Pi weiter".
  final jobId = jobIdFromCommand(c);
  if (jobId != null) {
    final kind = (stdin == null ? null : jobKindFromStdin(stdin)) ??
        jobKindSystemUpgrade;
    return _demoJob(jobId, kind, stdin == null ? null : decodeJobPayload(stdin));
  }

  // 1. The batched detection probe — one response powers the whole Verwaltung
  //    tab + the System card. (Probes arrive on stdin, which we ignore.)
  if (c == detectShellCommand) return _detectDoc;

  // 2. The individual probes used by detectInstall (update path).
  if (c == versionQuery) return 'installed 0.207.0\n';
  if (c == serviceStatus) return 'active\n';
  if (c == dockerListCommand || c.contains('docker ps')) return '';

  // 3. Dateien tab (file browser).
  if (c.contains(' find -H ')) return _dirListing;
  if (c.contains('head -c 524288') && c.contains('base64')) return _sampleFileB64;
  if (c.startsWith('wc -c <')) return '${_sampleFileBytes.length}\n';
  if (c.startsWith('base64 --')) return _sampleFileB64;

  // 4. Terminal tab (free-form console, wrapped by buildConsoleExec).
  if (c.contains('| head -c 262144')) return _terminalResponse(c);

  // 5. Security check. Without this the sheet showed five "Konnte nicht
  //    ermittelt werden." rows under a green "Keine Warnungen" headline
  //    (audit 2026-08-15). The demo Pi is realistic, not perfect: root login
  //    off, but no automatic updates → one honest warning with a Fix button.
  if (c.contains('__SEC_SSHD__')) return _securityReport;

  // 6. The on-Pi timers of the Automatik tab. Setting one up or removing it
  //    counts as done only with the script's marker — without it every
  //    "Einschalten" ended as "fehlgeschlagen" — and the status probes answer
  //    what was set up.
  if (c == installShellCommand && stdin != null) {
    final marker = _timerScript(stdin, timers);
    if (marker != null) return '$marker\n';
  }
  if (c == autoUpdateStatusCommand) {
    return _timerStatus(timers.autoUpdate, autoUpdateWrapperGeneration, now);
  }
  if (c == scheduledBackupStatusCommand) {
    final status = _timerStatus(
        timers.backup?.onCalendar, scheduledBackupWrapperGeneration, now);
    return '${status}DROP ${timers.backup?.drop ?? ''}\n';
  }
  if (c == alertsStatusCommand) {
    // No LAST: the first check of alerts just switched on is still to come.
    return 'ENABLED ${timers.alerts ? 'enabled' : 'disabled'}\n'
        'LAST \n'
        'WRAPPER ${timers.alerts ? alertsWrapperGeneration : 'none'}\n';
  }

  // 7. Benign default: succeed quietly. NEVER emit a sudo-failure token
  //    ("incorrect password"/"sorry, try again") — that would trip
  //    isSudoPasswordFailure and surface a fake auth error.
  return '';
}

// ---------------------------------------------------------------------------
// Canned data — persona: a healthy Raspberry Pi 4 (Bookworm) running apt-evcc
// (active, up to date), Pi-hole (active) and Tailscale (connected, home
// network not shared). Everything else absent → 4 cards: System, evcc,
// Pi-hole, Tailscale.
// ---------------------------------------------------------------------------

const String _m = '@@PT@@'; // must match _detectMarker in commands.dart

/// The package an update job's payload names (for the demo log), or null.
String? _demoPackage(String? payload) => payload == null
    ? null
    : RegExp(r"PITOOL_PACKAGE=%s\\n' '([a-z0-9][a-z0-9+.-]*)'")
        .firstMatch(payload)
        ?.group(1);

/// A believable, short job run on a current demo Pi.
String _demoJob(String id, String kind, String? payload) {
  final b = StringBuffer('PITOOL_JOB_STARTED $id $kind\n');
  void apt(String what) => b
    ..writeln('Pi-Tool: Schließe unterbrochene Paketinstallationen ab …')
    ..writeln('Pi-Tool: Lade die Paketlisten …')
    ..writeln('PITOOL_APT_UPDATE_RC=0')
    ..writeln(what)
    ..writeln(jobUpgradeMarker)
    ..writeln('Reading package lists...')
    ..writeln('Building dependency tree...');
  switch (kind) {
    case jobKindEvccUpdate:
      apt('Pi-Tool: Aktualisiere evcc …');
      b
        ..writeln('evcc is already the newest version (0.207.0).')
        ..writeln('0 upgraded, 0 newly installed, 0 to remove and 0 not '
            'upgraded.')
        ..writeln('PITOOL_EVCC_ACTIVE=active')
        ..writeln('PITOOL_EVCC_VERSION=installed 0.207.0');
    case jobKindPackageUpdate:
      final pkg = _demoPackage(payload) ?? 'grafana';
      b.writeln('PITOOL_PACKAGE=$pkg');
      apt('Pi-Tool: Aktualisiere $pkg …');
      b
        ..writeln('$pkg is already the newest version.')
        ..writeln('0 upgraded, 0 newly installed, 0 to remove and 0 not '
            'upgraded.');
    case jobKindPackageRepair:
      b
        ..writeln('Pi-Tool: Repariere den Paketzustand …')
        ..writeln('Reading package lists...')
        ..writeln('0 upgraded, 0 newly installed, 0 to remove and 0 not '
            'upgraded.');
    case jobKindPiholeUpdate:
      b
        ..writeln('Pi-Tool: Aktualisiere Pi-hole (pihole -up) …')
        ..writeln('  [i] Checking for updates...')
        ..writeln('  [i] Everything is up to date!');
    default:
      apt('Pi-Tool: Installiere alle Updates (apt-get full-upgrade) …');
      b.writeln('0 upgraded, 0 newly installed, 0 to remove and 0 not '
          'upgraded.');
  }
  b.write('\nPITOOL_JOB_RC $id 0\n');
  return b.toString();
}

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
    '     [✓] Blocking is enabled\n'
    // Tailscale connected (`tailscale status`, `tailscale ip -4`, then the
    // node's own status), so its card shows evcc's address over the tailnet.
    // No TS_LAN section: without a home network the card offers no sharing,
    // which the demo has no sample backend for.
    '${_m}TAILSCALE$_m\n'
    '100.101.102.103  raspberrypi  demo@  linux  -\n'
    '100.101.102.103\n'
    '${_m}TS_SELF$_m\n'
    '{"BackendState":"Running","Self":{"HostName":"raspberrypi",'
    '"DNSName":"raspberrypi.example.ts.net.",'
    '"TailscaleIPs":["100.101.102.103"]}}\n'
    // No job.status on the demo Pi: just the boot id.
    '${_m}JOB$_m\n'
    'BOOT 6f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b\n'
    // The end marker of a batch that ran through — without it detection takes
    // the document for a cut-off one and shows nothing.
    '$_m$detectEndKey$_m\n';

final RegExp _onCalendarLine = RegExp(r'^OnCalendar=(.+)$', multiLine: true);
final RegExp _backupDrop = RegExp(r'sched-evcc-.*tail -n \+(\d+)');

/// The marker a root [script] ends with when it sets up or removes one of the
/// three timers, after noting the change in [pi]. Null for any other script —
/// the demo has no sample backend for those, and a made-up "done" would lie.
String? _timerScript(String script, DemoPi pi) {
  final last = script.trimRight().split('\n').last;
  String? first(RegExp re) => re.firstMatch(script)?.group(1);
  switch (last) {
    case 'echo AUTOUPDATE_INSTALLED':
      pi.autoUpdate = first(_onCalendarLine) ?? '';
    case 'echo AUTOUPDATE_REMOVED':
      pi.autoUpdate = null;
    case 'echo BACKUP_TIMER_INSTALLED':
      pi.backup = (
        onCalendar: first(_onCalendarLine) ?? '',
        drop: first(_backupDrop) ?? '',
      );
    case 'echo BACKUP_TIMER_REMOVED':
      pi.backup = null;
    case 'echo ALERTS_INSTALLED':
      pi.alerts = true;
    case 'echo ALERTS_REMOVED':
      pi.alerts = false;
    default:
      return null;
  }
  return last.substring(5);
}

/// The answer of a status probe for a timer with the schedule [onCalendar]
/// (null = the timer is off), as far as auto-update and backups share it:
/// the next run, no last run (the timer was only just set up), this version's
/// wrapper ([generation]) and the schedule in the unit.
String _timerStatus(String? onCalendar, int generation, DateTime? now) =>
    onCalendar == null
        ? 'ENABLED disabled\nNEXT \nSTATUS \nWRAPPER none\nONCALENDAR \n'
        : 'ENABLED enabled\n'
            'NEXT ${_nextRun(onCalendar, now ?? DateTime.now())}\n'
            'STATUS \n'
            'WRAPPER $generation\n'
            'ONCALENDAR $onCalendar\n';

/// The next run of [onCalendar] after [now], in the three fields the status
/// probes take from `systemctl list-timers` ("Sun 2026-10-11 04:00:00").
/// Empty for a schedule the app does not build.
String _nextRun(String onCalendar, DateTime now) {
  final s = autoUpdateScheduleOf(onCalendar);
  if (s == null) return '';
  var next = DateTime(now.year, now.month, now.day, s.hour);
  while (!next.isAfter(now) || (s.weekly && next.weekday != s.weekday)) {
    next = DateTime(next.year, next.month, next.day + 1, s.hour);
  }
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  String two(int n) => n.toString().padLeft(2, '0');
  return '${days[next.weekday - 1]} '
      '${next.year}-${two(next.month)}-${two(next.day)} ${two(s.hour)}:00:00';
}

/// Canned output of [buildSecurityProbe] for the demo Pi: hardened SSH, but
/// automatic updates off and no fail2ban — so the traffic light shows what it
/// is for, including a working "Beheben" button.
const String _securityReport = '__SEC_SSHD__\n'
    'permitrootlogin no\n'
    'passwordauthentication yes\n'
    '__SEC_UNATT__\n'
    'disabled\n'
    'inactive\n'
    '__SEC_F2B__\n'
    'inactive\n'
    '__SEC_PORTS__\n'
    '0.0.0.0:22\n'
    '0.0.0.0:53\n'
    '0.0.0.0:80\n'
    '0.0.0.0:7070\n';

/// Canned listing in the format of `buildListDirCommand`
/// (`<own type><type>\t<name>\0`), parsed by `parseDirListing`.
const String _dirListing = 'dd\tbackups\x00'
    'dd\tlogs\x00'
    'ff\tevcc.yaml\x00'
    'ff\tevcc.db\x00'
    'ff\tREADME.md\x00';

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
  // `{ <cmd>⏎} 2>&1 | head -c 262144` — see EvccUpdater.runConsoleCommand.
  final s = inner.indexOf('{ ');
  final e = inner.lastIndexOf('\n}');
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
      return 'Demo-Modus: Befehle werden nicht wirklich ausgeführt.\n';
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
