/// The "System (Pi)" service: OS info, pending apt updates, uptime — and the
/// whole-system upgrade / reboot actions. Pure parsers + command strings here;
/// the SSH orchestration is added in a later phase. See
/// design/2026-06-30-multi-service.md.
library;

/// Reads `/etc/os-release` (no sudo).
const String systemOsCommand = 'cat /etc/os-release';

/// Simulates the full-upgrade to count pending updates (no sudo, no list
/// refresh) — matches the `apt-get full-upgrade` the System action runs.
const String systemPendingCommand = 'LC_ALL=C apt-get -s full-upgrade';

/// How old the Pi's package index may be before the app stops claiming to know
/// whether a service is current. [systemPendingCommand] simulates against the
/// LOCAL index and never refreshes it, so beyond this age "0 upgraded" only
/// means "nothing new is known here" — not "up to date". Found the hard way:
/// a 10-day-old index reported 0 pending while 27 updates (incl. security)
/// waited, and the System card showed a green "aktuell".
const Duration kAptIndexMaxAge = Duration(days: 3);

/// Age of the package index in seconds, computed ON THE PI — comparing its
/// mtime against the phone's clock would break on any clock/timezone skew.
/// No sudo: /var/lib/apt/lists is world-readable.
const String systemAptAgeCommand =
    'expr \$(date +%s) - \$(stat -c %Y /var/lib/apt/lists) 2>/dev/null';

/// Human-readable uptime (no sudo).
const String systemUptimeCommand = 'uptime -p';

/// CPU/SoC temperature (no sudo): Pi's vcgencmd, falling back to the generic
/// sysfs thermal zone (millidegrees) on non-Pi Debian boxes.
const String systemTempCommand =
    "vcgencmd measure_temp 2>/dev/null || cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null";

/// Root filesystem usage in MB (POSIX format, no sudo).
const String systemDiskCommand = 'df -P -BM /';

/// Memory usage in MB (no sudo). LC_ALL=C pins the row label to "Mem:" —
/// a German-locale Pi would otherwise print "Speicher:" and break the parser.
const String systemMemCommand = 'LC_ALL=C free -m';

/// SD-card health probe (no sudo): the mount options of / and /boot (a failing
/// SD card typically forces a read-only remount) + a count of I/O-ish errors in
/// the kernel log. `journalctl -k` works for the default pi user (adm group);
/// `|| true` keeps the detection batch alive when grep counts zero (exit 1).
const String systemStorageCommand =
    "grep -E ' / | /boot' /proc/mounts 2>/dev/null; "
    "journalctl -k --no-pager -q 2>/dev/null | "
    "grep -icE 'i/o error|ext4-fs error|mmc[0-9]+: error' || true";

/// Result of [parseStorageHealth]: the read-only-remounted mount (null = none)
/// and the kernel-log I/O error count (null = unknown).
typedef StorageHealth = ({String? readOnlyMount, int? kernelErrors});

extension StorageHealthWarning on StorageHealth {
  /// A read-only root is the classic dying-SD symptom; a handful of transient
  /// I/O errors (USB hiccups) is tolerated before warning.
  bool get warning => readOnlyMount != null || (kernelErrors ?? 0) >= 5;
}

/// Parses [systemStorageCommand] output: `/proc/mounts` lines for `/`
/// (+`/boot*`) and a trailing bare-integer error count. Tolerant of garbage —
/// anything unparseable simply yields no data (no warning).
StorageHealth parseStorageHealth(String out) {
  String? roMount;
  int? errors;
  for (final raw in out.split('\n')) {
    final l = raw.trim();
    if (l.isEmpty) continue;
    final f = l.split(RegExp(r'\s+'));
    if (f.length >= 4 && f[1] == '/') {
      // Only the ROOT mount: a deliberately read-only /boot is a known
      // hardening practice and must not false-positive. The ro OPTION, not a
      // substring ("errors=remount-ro" must not match).
      if (f[3].split(',').contains('ro')) roMount = '/';
      continue;
    }
    final n = int.tryParse(l);
    if (n != null) errors = n; // the trailing count line
  }
  return (readOnlyMount: roMount, kernelErrors: errors);
}

final _vcgenTemp = RegExp(r"temp=([\d.]+)'?C");

/// Parses [systemTempCommand] output: either `temp=48.3'C` (vcgencmd) or a
/// bare millidegree integer like `48312` (sysfs). Null when unavailable.
double? parseTemperatureC(String output) {
  final m = _vcgenTemp.firstMatch(output);
  if (m != null) return double.tryParse(m.group(1)!);
  // sysfs fallback: use the LAST non-empty line — a failing vcgencmd may print
  // noise (e.g. "VCHI initialization failed") to stdout before the fallback.
  final lines =
      output.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty);
  if (lines.isEmpty) return null;
  final raw = int.tryParse(lines.last);
  if (raw == null) return null;
  // The sysfs thermal ABI is ALWAYS millidegrees — no unit heuristics.
  return raw / 1000.0;
}

/// Root-filesystem usage from `df -P -BM /`.
class DiskUsage {
  final int totalMb;
  final int availableMb;
  final int usedPercent;
  const DiskUsage({
    required this.totalMb,
    required this.availableMb,
    required this.usedPercent,
  });
}

/// Parses [systemDiskCommand] output (last data line: total, used, avail, %).
DiskUsage? parseDiskUsage(String dfOutput) {
  for (final line in dfOutput.split('\n').reversed) {
    final f = line.trim().split(RegExp(r'\s+'));
    // Filesystem  <total>M  <used>M  <avail>M  <pct>%  /mount
    if (f.length >= 6 && f[1].endsWith('M') && f[4].endsWith('%')) {
      final total = int.tryParse(f[1].substring(0, f[1].length - 1));
      final avail = int.tryParse(f[3].substring(0, f[3].length - 1));
      final pct = int.tryParse(f[4].substring(0, f[4].length - 1));
      if (total != null && avail != null && pct != null) {
        return DiskUsage(totalMb: total, availableMb: avail, usedPercent: pct);
      }
    }
  }
  return null;
}

/// Parses the `available` column of the `Mem:` row from `free -m`. The column
/// is located via the HEADER line — old procps (< 3.3.10) has no `available`
/// column and its last column is `cached`, which must yield null, not a wrong
/// number.
int? parseMemAvailableMb(String freeOutput) {
  final lines = freeOutput.split('\n');
  var availCol = -1;
  for (final line in lines) {
    final f = line.trim().split(RegExp(r'\s+'));
    if (availCol == -1) {
      availCol = f.indexOf('available'); // header row (no "Mem:" label cell)
      continue;
    }
    if (f.isNotEmpty && f.first.startsWith('Mem') && f.length > availCol + 1) {
      // +1: the data row has the leading "Mem:" label the header lacks.
      return int.tryParse(f[availCol + 1]);
    }
  }
  return null;
}

/// Snapshot of the Pi's vitals, shown on the System card. All fields optional —
/// whatever couldn't be read is simply omitted from [summary].
class SystemHealth {
  final double? tempC;
  final DiskUsage? disk;
  final int? memAvailableMb;
  final String? uptime;
  final StorageHealth? storage;

  const SystemHealth(
      {this.tempC, this.disk, this.memAvailableMb, this.uptime, this.storage});

  /// Low on disk — updates may fail. "Will the update fit" is an absolute
  /// question, so the percent test is gated on little absolute room too: a
  /// 1-TB disk at 94% still has tens of GB free and must not warn.
  bool get lowDisk =>
      disk != null &&
      (disk!.availableMb < 1024 ||
          (disk!.usedPercent >= 90 && disk!.availableMb < 5120));

  /// Any reason the System card should show the warning tint: low disk or SD
  /// trouble (read-only root / kernel I/O errors).
  bool get warning => lowDisk || (storage?.warning ?? false);

  /// Compact one-liner, e.g. "48.3°C · 16.1 GB frei · RAM 240 MB frei · up 5 days".
  String get summary {
    final parts = <String>[
      if (storage?.warning ?? false)
        storage!.readOnlyMount != null
            ? '⚠ SD-Karte prüfen: Dateisystem nur-lesend!'
            : '⚠ SD-Karte prüfen: ${storage!.kernelErrors} I/O-Fehler im '
                'Kernel-Log',
      if (lowDisk) '⚠ Speicher fast voll',
      if (tempC != null) '${tempC!.toStringAsFixed(1)}°C',
      if (disk != null)
        disk!.availableMb >= 1024
            ? '${(disk!.availableMb / 1024).toStringAsFixed(1)} GB frei'
            : '${disk!.availableMb} MB frei',
      if (memAvailableMb != null) 'RAM $memAvailableMb MB frei',
      if (uptime != null && uptime!.isNotEmpty) uptime!,
    ];
    return parts.join('  ·  ');
  }
}

final _prettyName = RegExp(r'^\s*PRETTY_NAME="?([^"\n]+)"?', multiLine: true);
final _name = RegExp(r'^\s*NAME="?([^"\n]+)"?', multiLine: true);
final _upgraded = RegExp(r'(\d+) upgraded');
final _instLine = RegExp(r'^Inst (\S+)', multiLine: true);

/// Package names an `apt-get -s full-upgrade` simulation would install/upgrade
/// (the `Inst <pkg> …` lines). Used to tell whether a specific package (e.g.
/// evcc) actually has a pending update in the local package index.
Set<String> parseAptUpgrades(String simOutput) =>
    _instLine.allMatches(simOutput).map((m) => m.group(1)!).toSet();

/// Extracts a friendly OS name from `/etc/os-release` (PRETTY_NAME, else NAME).
String? parseOsPrettyName(String osRelease) {
  final pretty = _prettyName.firstMatch(osRelease);
  if (pretty != null) return pretty.group(1)!.trim();
  final name = _name.firstMatch(osRelease);
  return name?.group(1)?.trim();
}

/// Parses [systemAptAgeCommand] into seconds. Null when the probe produced
/// nothing usable, or when the age is negative (index mtime in the future =
/// broken clock) — both mean "age unknown".
int? parseAptListsAgeSeconds(String out) {
  final m = RegExp(r'^\s*(-?\d+)\s*$', multiLine: true).firstMatch(out);
  final v = m == null ? null : int.tryParse(m.group(1)!);
  return (v == null || v < 0) ? null : v;
}

/// Whether the package index is recent enough that "no pending upgrade" can be
/// trusted. Unknown age counts as NOT fresh: the app never claims a currency it
/// cannot back (same fail-safe as `isPiConnectCompatible`).
bool isAptIndexFresh(int? ageSeconds) =>
    ageSeconds != null && ageSeconds < kAptIndexMaxAge.inSeconds;

/// The System card's detail line while the index is too old to trust. Always
/// ≥ [kAptIndexMaxAge] here, so the day count never reads "1 Tage".
String aptIndexStaleDetail(int? ageSeconds) => ageSeconds == null
    ? 'Paketlisten-Stand unbekannt'
    : 'Paketlisten ${ageSeconds ~/ Duration.secondsPerDay} Tage alt — Stand unbekannt';

/// The "N upgraded" count from an `apt-get -s upgrade` summary, or null when no
/// summary line is present.
int? parsePendingUpdates(String aptSimulateOutput) {
  final m = _upgraded.firstMatch(aptSimulateOutput);
  return m == null ? null : int.tryParse(m.group(1)!);
}
