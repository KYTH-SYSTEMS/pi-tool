/// Additional apt-managed services the app can detect and update (Grafana,
/// InfluxDB, …). Unlike evcc/Pi-hole these get a card only when actually
/// installed — the app manages them but doesn't offer to install them.
library;

/// Descriptor for one apt-managed service.
class AptService {
  /// Stable card id (also used to route UI actions).
  final String id;

  /// Display name on the card.
  final String name;

  /// Package name(s) that count as this service (e.g. influxdb OR influxdb2).
  final List<String> packages;

  /// systemd unit for is-active / restart.
  final String unit;

  /// Web-UI port, or null when the service has none.
  final int? webPort;

  const AptService({
    required this.id,
    required this.name,
    required this.packages,
    required this.unit,
    this.webPort,
  });
}

/// The apt services the app knows how to detect/update.
const List<AptService> knownAptServices = [
  AptService(
    id: 'grafana',
    name: 'Grafana',
    packages: ['grafana'],
    unit: 'grafana-server',
    webPort: 3000,
  ),
  AptService(
    id: 'influxdb',
    name: 'InfluxDB',
    packages: ['influxdb', 'influxdb2'],
    unit: 'influxdb',
    // v1 has no web UI; v2's runs on 8086 — the card only shows the web button
    // for the influxdb2 package (decided at detection time).
    webPort: 8086,
  ),
];

/// One dpkg query for every known extra package (missing ones only error to
/// stderr, so stdout stays parseable). No sudo.
final String aptServicesQuery = () {
  final pkgs = knownAptServices.expand((s) => s.packages).join(' ');
  return "dpkg-query -W -f='\${Package} \${db:Status-Status} \${Version}\\n' "
      '$pkgs 2>/dev/null';
}();

/// Parses [aptServicesQuery] output into installed package → version. Only the
/// `installed` status counts (rc-state carries a stale version — see the evcc
/// dpkg fix).
Map<String, String> parseAptServiceVersions(String output) {
  final result = <String, String>{};
  for (final line in output.split('\n')) {
    final f = line.trim().split(RegExp(r'\s+'));
    if (f.length >= 3 && f[1] == 'installed') result[f[0]] = f[2];
  }
  return result;
}
