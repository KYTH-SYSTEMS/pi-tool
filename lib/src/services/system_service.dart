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

/// Human-readable uptime (no sudo).
const String systemUptimeCommand = 'uptime -p';

/// CPU/SoC temperature (no sudo): Pi's vcgencmd, falling back to the generic
/// sysfs thermal zone (millidegrees) on non-Pi Debian boxes.
const String systemTempCommand =
    "vcgencmd measure_temp 2>/dev/null || cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null";

/// Root filesystem usage in MB (POSIX format, no sudo).
const String systemDiskCommand = 'df -P -BM /';

/// Memory usage in MB (no sudo).
const String systemMemCommand = 'free -m';

final _vcgenTemp = RegExp(r"temp=([\d.]+)'?C");

/// Parses [systemTempCommand] output: either `temp=48.3'C` (vcgencmd) or a
/// bare millidegree integer like `48312` (sysfs). Null when unavailable.
double? parseTemperatureC(String output) {
  final m = _vcgenTemp.firstMatch(output);
  if (m != null) return double.tryParse(m.group(1)!);
  final raw = int.tryParse(output.trim());
  if (raw == null) return null;
  // sysfs reports millidegrees; a plain small number would be degrees already.
  return raw > 1000 ? raw / 1000.0 : raw.toDouble();
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

/// Parses the `available` column of the `Mem:` row from `free -m`.
int? parseMemAvailableMb(String freeOutput) {
  for (final line in freeOutput.split('\n')) {
    final f = line.trim().split(RegExp(r'\s+'));
    if (f.isNotEmpty && f.first.startsWith('Mem') && f.length >= 7) {
      return int.tryParse(f.last);
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

  const SystemHealth({this.tempC, this.disk, this.memAvailableMb, this.uptime});

  /// Low on disk: less than 1 GB free or ≥90% used — updates may fail.
  bool get lowDisk =>
      disk != null && (disk!.availableMb < 1024 || disk!.usedPercent >= 90);

  /// Compact one-liner, e.g. "48.3°C · 16.1 GB frei · RAM 240 MB frei · up 5 days".
  String get summary {
    final parts = <String>[
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

/// The "N upgraded" count from an `apt-get -s upgrade` summary, or null when no
/// summary line is present.
int? parsePendingUpdates(String aptSimulateOutput) {
  final m = _upgraded.firstMatch(aptSimulateOutput);
  return m == null ? null : int.tryParse(m.group(1)!);
}
