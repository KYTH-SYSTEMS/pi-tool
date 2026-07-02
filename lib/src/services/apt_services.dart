/// Additional apt-managed services the app can detect and update (Grafana,
/// InfluxDB, Mosquitto, …). They get a card only when actually installed; the
/// ones carrying an [AptService.installScript] can also be installed on demand
/// via the "Dienst installieren" picker.
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

  /// Root shell script that installs the service (official apt repo + package),
  /// or null when the app only detects/updates it. Experimental — the scripts
  /// follow each project's documented apt install but aren't validated against
  /// every Pi OS release.
  final String? installScript;

  const AptService({
    required this.id,
    required this.name,
    required this.packages,
    required this.unit,
    this.webPort,
    this.installScript,
  });

  /// Whether the app can install this service (not just detect/update it).
  bool get installable => installScript != null;
}

/// The apt services the app knows how to detect/update (and some to install).
const List<AptService> knownAptServices = [
  AptService(
    id: 'grafana',
    name: 'Grafana',
    // OSS, Enterprise and the legacy Pi package all run grafana-server.
    packages: ['grafana', 'grafana-enterprise', 'grafana-rpi'],
    unit: 'grafana-server',
    webPort: 3000,
    installScript: _grafanaInstall,
  ),
  AptService(
    id: 'influxdb',
    name: 'InfluxDB',
    packages: ['influxdb', 'influxdb2'],
    unit: 'influxdb',
    // v1 has no web UI; v2's runs on 8086 — the card only shows the web button
    // for the influxdb2 package (decided at detection time).
    webPort: 8086,
    installScript: _influxdbInstall,
  ),
  AptService(
    id: 'mosquitto',
    name: 'Mosquitto',
    packages: ['mosquitto'],
    unit: 'mosquitto',
    // MQTT broker — no web UI (pairs with Home Assistant / evcc over MQTT).
    installScript: _mosquittoInstall,
  ),
];

/// Services that can be installed on demand (carry an install script).
List<AptService> get knownInstallableServices =>
    knownAptServices.where((s) => s.installable).toList();

// --- install scripts (run as root via sudo) --------------------------------
// Each sets up the official apt source, installs the package and enables the
// service. `set -e` aborts on the first failure so a partial install surfaces.

// Grafana: current official flow stores the armored full keyring directly
// (no `gpg --dearmor`) — see grafana.com/docs .../installation/debian.
const String _grafanaInstall = '''
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get install -y wget
mkdir -p /etc/apt/keyrings
wget -q -O /etc/apt/keyrings/grafana.asc https://apt.grafana.com/gpg-full.key
echo "deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
apt-get update
apt-get install -y grafana
systemctl daemon-reload
systemctl enable --now grafana-server
''';

// InfluxDB v2: current official flow — the regular (non-_compat) key, verified
// by fingerprint before it is trusted (raw string so the grep's `\\+` survives).
const String _influxdbInstall = r'''
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get install -y wget gnupg
mkdir -p /etc/apt/keyrings
wget -q -O /tmp/influxdata-archive.key https://repos.influxdata.com/influxdata-archive.key
gpg --show-keys --with-fingerprint --with-colons /tmp/influxdata-archive.key 2>&1 | grep -q '^fpr:\+24C975CBA61A024EE1B631787C3D57159FC2F927:$'
gpg --dearmor < /tmp/influxdata-archive.key > /etc/apt/keyrings/influxdata-archive.gpg
rm -f /tmp/influxdata-archive.key
echo "deb [signed-by=/etc/apt/keyrings/influxdata-archive.gpg] https://repos.influxdata.com/debian stable main" > /etc/apt/sources.list.d/influxdata.list
apt-get update
apt-get install -y influxdb2
systemctl enable --now influxdb
''';

const String _mosquittoInstall = '''
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y mosquitto mosquitto-clients
systemctl enable --now mosquitto
''';

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
