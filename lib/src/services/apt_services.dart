/// Additional apt-managed services the app can detect and update (Grafana,
/// InfluxDB, Mosquitto, …). They get a card only when actually installed; the
/// ones carrying an [AptService.installScript] can also be installed on demand
/// via the "Dienst installieren" picker, and every one can be uninstalled
/// ([buildAptServiceUninstallScript]).
library;

import '../commands.dart' show shSingleQuote;
import 'stack_wiring.dart'
    show buildEvccInfluxUnwireScriptPart, buildInfluxCliProfileCleanupScriptPart;

/// What an uninstall touches besides [AptService.packages]. Everything here
/// is what the app's install script (or the package itself) put on the Pi —
/// never shared tooling (curl, wget, gnupg, adduser, ucf, …).
class AptUninstallFootprint {
  /// Packages the install script pulls in with the service. Purge only: they
  /// are general client tools (mosquitto_pub, influx) that scripts may use
  /// against another broker / InfluxDB, and the card only watches
  /// [AptService.packages].
  final List<String> companions;

  /// Config, data and log paths deleted on purge only. Absolute and specific
  /// (checked when the script is built).
  final List<String> purgePaths;

  /// Unit symlinks the package leaves behind on Debian; purge removes them
  /// only while they are symlinks.
  final List<String> purgeLinks;

  /// The apt source list + keyring the install script wrote (purge only).
  final String? aptSourceList;
  final String? aptKeyring;

  /// Package shipping the repo's keyring; purged together with the source.
  final String? repoKeyringPackage;

  /// Other packages served by the same apt repo. While one is installed, the
  /// source, keyring and [repoKeyringPackage] stay.
  final List<String> repoSiblings;

  /// File-name prefixes of app-made backups under /var/backups/pi-tool
  /// (config editor: `config-<basename>-<YYYYmmdd-HHMMSS>.bak`), deleted on
  /// purge. The name carries only the basename, so list only basenames that
  /// on a Pi can be this service's file alone — `influxdb.conf` (Telegraf's
  /// telegraf.d/) or `mosquitto.conf` (a Docker broker) can belong to others.
  final List<String> backupPrefixes;

  /// Top-level evcc.yaml key that points at this service (`influx`, `mqtt`):
  /// the script only prints a hint, evcc's config is the user's.
  final String? evccConfigKey;

  /// Purge also takes back what the monitoring-stack wiring wrote for this
  /// service (evcc.yaml `influx:` block, influx CLI profile).
  final bool undoStackWiring;

  const AptUninstallFootprint({
    this.companions = const [],
    this.purgePaths = const [],
    this.purgeLinks = const [],
    this.aptSourceList,
    this.aptKeyring,
    this.repoKeyringPackage,
    this.repoSiblings = const [],
    this.backupPrefixes = const [],
    this.evccConfigKey,
    this.undoStackWiring = false,
  });
}

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

  /// What [buildAptServiceUninstallScript] removes besides [packages].
  final AptUninstallFootprint footprint;

  const AptService({
    required this.id,
    required this.name,
    required this.packages,
    required this.unit,
    this.webPort,
    this.installScript,
    this.footprint = const AptUninstallFootprint(),
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
    footprint: AptUninstallFootprint(
      // grafana.ini + provisioning come from the postinst (not dpkg's), so
      // even `apt-get purge` leaves them; the wiring's files live here too.
      purgePaths: [
        '/etc/grafana',
        '/var/lib/grafana',
        '/var/log/grafana',
        '/etc/default/grafana-server',
      ],
      aptSourceList: '/etc/apt/sources.list.d/grafana.list',
      aptKeyring: '/etc/apt/keyrings/grafana.asc',
      repoSiblings: [
        'alloy',
        'grafana-agent',
        'grafana-agent-flow',
        'loki',
        'promtail',
        'mimir',
        'tempo',
        'pyroscope',
        'logcli',
        'carbon-relay-ng',
        'synthetic-monitoring-agent',
      ],
      backupPrefixes: ['config-grafana.ini-', 'config-grafana-server-'],
    ),
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
    footprint: AptUninstallFootprint(
      // Recommends of influxdb2; ships the `influx` CLI the wiring uses.
      companions: ['influxdb2-cli'],
      // config.toml + /etc/default/influxdb2 come from the post-install (not
      // dpkg's) and survive a purge.
      purgePaths: [
        '/etc/influxdb',
        '/var/lib/influxdb',
        '/var/log/influxdb',
        '/etc/default/influxdb2',
      ],
      // influxdb2's post-uninstall only disables on Ubuntu (/etc/lsb-release).
      purgeLinks: [
        '/etc/systemd/system/influxd.service',
        '/etc/systemd/system/multi-user.target.wants/influxdb.service',
      ],
      aptSourceList: '/etc/apt/sources.list.d/influxdata.list',
      aptKeyring: '/etc/apt/keyrings/influxdata-archive.gpg',
      // Its postrm deletes influxdata.list already on remove.
      repoKeyringPackage: 'influxdata-archive-keyring',
      repoSiblings: [
        'telegraf',
        'chronograf',
        'kapacitor',
        'influxctl',
        'influxdb3-core',
        'influxdb3-enterprise',
      ],
      // /etc/default/influxdb2 only; influxdb.conf is ambiguous (Telegraf).
      backupPrefixes: ['config-influxdb2-'],
      evccConfigKey: 'influx',
      undoStackWiring: true,
    ),
  ),
  AptService(
    id: 'mosquitto',
    name: 'Mosquitto',
    packages: ['mosquitto'],
    unit: 'mosquitto',
    // MQTT broker — no web UI (pairs with Home Assistant / evcc over MQTT).
    installScript: _mosquittoInstall,
    footprint: AptUninstallFootprint(
      companions: ['mosquitto-clients'],
      // Includes the user's passwd/ACL/cert files next to the conffiles.
      purgePaths: ['/etc/mosquitto', '/var/lib/mosquitto', '/var/log/mosquitto'],
      // No backup prefixes: mosquitto.conf is also a Docker broker's file.
      evccConfigKey: 'mqtt',
    ),
  ),
];

/// Services that can be installed on demand (carry an install script).
List<AptService> get knownInstallableServices =>
    knownAptServices.where((s) => s.installable).toList();

// --- install scripts (run as root via sudo) --------------------------------
// Each sets up the official apt source, installs the package and enables the
// service. `set -e` aborts on the first failure so a partial install surfaces.
// The script arrives on stdin (`bash -s`): every apt-get gets its own
// </dev/null, and --force-confdef/--force-confold keep a user's changed
// conffiles (left by an uninstall that kept the config) without asking —
// dpkg's question would otherwise read the rest of the script as its answer.

// Grafana: current official flow stores the armored full keyring directly
// (no `gpg --dearmor`) — see grafana.com/docs .../installation/debian.
const String _grafanaInstall = '''
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=120 -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y wget </dev/null
mkdir -p /etc/apt/keyrings
wget -q -O /etc/apt/keyrings/grafana.asc https://apt.grafana.com/gpg-full.key
echo "deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
apt-get update </dev/null
apt-get -o DPkg::Lock::Timeout=120 -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y grafana </dev/null
systemctl daemon-reload
systemctl enable --now grafana-server
''';

// InfluxDB v2: current official flow — the regular (non-_compat) key, verified
// by fingerprint before it is trusted (raw string so the grep's `\\+` survives).
// UCF_FORCE_CONFFOLD: influxdata-archive-keyring manages influxdata.list via
// ucf, which would otherwise ask about the list this script already wrote.
const String _influxdbInstall = r'''
set -e
export DEBIAN_FRONTEND=noninteractive
export UCF_FORCE_CONFFOLD=1
apt-get -o DPkg::Lock::Timeout=120 -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y wget gnupg </dev/null
mkdir -p /etc/apt/keyrings
wget -q -O /tmp/influxdata-archive.key https://repos.influxdata.com/influxdata-archive.key
gpg --show-keys --with-fingerprint --with-colons /tmp/influxdata-archive.key 2>&1 | grep -q '^fpr:\+24C975CBA61A024EE1B631787C3D57159FC2F927:$'
gpg --dearmor < /tmp/influxdata-archive.key > /etc/apt/keyrings/influxdata-archive.gpg
rm -f /tmp/influxdata-archive.key
echo "deb [signed-by=/etc/apt/keyrings/influxdata-archive.gpg] https://repos.influxdata.com/debian stable main" > /etc/apt/sources.list.d/influxdata.list
apt-get update </dev/null
apt-get -o DPkg::Lock::Timeout=120 -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y influxdb2 </dev/null
systemctl enable --now influxdb
''';

const String _mosquittoInstall = '''
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update </dev/null
apt-get -o DPkg::Lock::Timeout=120 -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y mosquitto mosquitto-clients </dev/null
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

// --- uninstall (run as root via `sudo -S bash -s`) ---------------------------

/// Last line of a successful uninstall script, printed only on the happy path
/// after the final checks. Free of `INSTALL_OK` (the runner uses contains()).
const String aptServiceRemovedMarker = 'APTSVC_REMOVED_OK';

/// Root script that uninstalls [svc].
///
/// - [purge] false: `apt-get remove` of every installed [AptService.packages]
///   entry — the companions (client tools) stay. Config and data stay, so the
///   app's install path picks them up again. That alone makes the card
///   disappear: the detection only counts dpkg status `installed`.
/// - [purge] true: complete rollback — `apt-get purge` of the card packages
///   and companions (rc leftovers too), the footprint's config/data/log paths
///   and unit links, the app-made backups of the service's own files, the apt
///   source + keyring the app added (unless another package from that repo
///   still needs them) and, for InfluxDB, the stack wiring (evcc.yaml block
///   BEFORE anything is removed, CLI profile after the data is gone).
///
/// Guards first: a held package, a failing apt dry run or apt wanting to take
/// other packages along print one `UNINSTALL_REFUSED: <Grund>` line and exit
/// 3 before anything changed. Idempotent — a retry after a partial run
/// finishes the job. Never autoremove, never shared packages. Every value from
/// [svc] is [shSingleQuote]d.
///
/// Throws [ArgumentError] for a footprint path too unspecific to delete.
String buildAptServiceUninstallScript(AptService svc, {required bool purge}) {
  final fp = svc.footprint;
  _checkFootprint(fp);
  final q = shSingleQuote;
  final verb = purge ? 'purge' : 'remove';
  final hasRepo =
      purge && (fp.aptSourceList != null || fp.aptKeyring != null);
  // Keep mode leaves the companions (client tools) alone.
  final targets = [...svc.packages, if (purge) ...fp.companions];
  final b = StringBuffer()
    ..write('set -e\n'
        'export DEBIAN_FRONTEND=noninteractive\n'
        'export LC_ALL=C\n'
        'NAME=${q(svc.name)}\n'
        'UNIT=${q(svc.unit)}\n'
        '# The packages to take away (candidates + final check).\n'
        'set -- ${targets.map(q).join(' ')}\n')
    ..write(_uninstallCandidates.replaceAll('@SKIP@',
        purge ? '""|not-installed' : '""|not-installed|config-files'));
  if (hasRepo) {
    b.write('# Another package from the same repo installed? Then the source '
        'stays.\nkeep_repo=0\n');
    if (fp.repoSiblings.isNotEmpty) {
      b.write('for p in ${fp.repoSiblings.map(q).join(' ')}; do\n'
          '  case "\$(pkg_status "\$p")" in\n'
          '    ""|not-installed|config-files) ;;\n'
          '    *) keep_repo=1 ;;\n'
          '  esac\n'
          'done\n');
    }
    final kr = fp.repoKeyringPackage;
    if (kr != null) {
      b.write('if [ "\$keep_repo" = 0 ]; then\n'
          '  case "\$(pkg_status ${q(kr)})" in\n'
          '    ""|not-installed) ;;\n'
          '    *) pkgs+=(${q(kr)}) ;;\n'
          '  esac\n'
          'fi\n');
    }
  }
  b.write(_uninstallGuards.replaceAll('@VERB@', verb));
  if (purge && fp.undoStackWiring) b.write(buildEvccInfluxUnwireScriptPart());
  b.write(_uninstallRemove.replaceAll('@VERB@', verb).replaceAll(
      '@WHAT@',
      purge
          ? 'endgültig'
          : '– Konfiguration und Daten bleiben erhalten'));
  if (purge) {
    b.write('echo "Lösche Konfiguration und Daten von \$NAME …"\n');
    if (fp.purgePaths.isNotEmpty) {
      b.write('rm -rf -- ${fp.purgePaths.map(q).join(' ')}\n');
    }
    if (fp.purgeLinks.isNotEmpty) {
      b.write('for l in ${fp.purgeLinks.map(q).join(' ')}; do\n'
          '  if [ -L "\$l" ]; then rm -f -- "\$l"; fi\n'
          'done\n');
    }
    if (fp.backupPrefixes.isNotEmpty) {
      // Exactly the editor's timestamp: `config-influxdb2-*` would also hit
      // the backup of a user file named influxdb2-export.sh.
      b.write('rm -f -- ${fp.backupPrefixes.map((p) => '/var/backups/pi-tool/${q(p)}$_backupTsGlob.bak').join(' ')}\n');
    }
  }
  if (hasRepo) {
    final files = [
      if (fp.aptSourceList != null) ...[
        q(fp.aptSourceList!),
        // ucf leftovers of the keyring package managing the same list.
        if (fp.repoKeyringPackage != null) '${q(fp.aptSourceList!)}.ucf-*',
      ],
      if (fp.aptKeyring != null) q(fp.aptKeyring!),
    ];
    b.write('if [ "\$keep_repo" = 1 ]; then\n'
        '  echo "Die Paketquelle bleibt: weitere Pakete aus ihr sind '
        'installiert."\n'
        'else\n'
        '  rm -f -- ${files.join(' ')}\n'
        'fi\n');
  }
  if (purge && fp.undoStackWiring) {
    b.write(buildInfluxCliProfileCleanupScriptPart());
  }
  final key = fp.evccConfigKey;
  if (key != null) {
    b.write('if [ -f /etc/evcc.yaml ] && grep -q ${q('^$key:')} '
        '/etc/evcc.yaml; then\n'
        '  echo "Hinweis: /etc/evcc.yaml verweist weiterhin auf \$NAME – '
        'diese Verbindung bleibt bis zu einer Neuinstallation ohne '
        'Gegenstelle."\n'
        'fi\n');
  }
  b
    ..write(purge ? _uninstallVerifyPurge : _uninstallVerifyKeep)
    ..write(_uninstallVerifyUnit)
    ..write(purge
        ? 'echo "\$NAME samt Konfiguration und Daten entfernt."\n'
        : 'echo "\$NAME entfernt – Konfiguration und Daten sind erhalten, '
            'eine Neuinstallation übernimmt sie."\n')
    ..write('echo $aptServiceRemovedMarker\n');
  return b.toString();
}

/// Rejects footprint entries an `rm` could hit too broadly with.
void _checkFootprint(AptUninstallFootprint fp) {
  bool specific(String p) {
    final segs = p.split('/');
    return p.startsWith('/') &&
        segs.length >= 3 &&
        !segs.skip(1).any((s) => s.isEmpty || s == '.' || s == '..');
  }

  for (final p in [...fp.purgePaths, ...fp.purgeLinks]) {
    if (!specific(p)) {
      throw ArgumentError.value(p, 'purgePaths', 'not a specific absolute path');
    }
  }
  for (final p in [fp.aptSourceList, fp.aptKeyring]) {
    if (p != null && !(p.startsWith('/etc/apt/') && specific(p))) {
      throw ArgumentError.value(p, 'aptSource', 'not a file under /etc/apt');
    }
  }
  for (final p in fp.backupPrefixes) {
    if (p.isEmpty || p.contains('/')) {
      throw ArgumentError.value(p, 'backupPrefixes', 'not a file-name prefix');
    }
  }
}

/// The config editor's backup timestamp (`date +%Y%m%d-%H%M%S`) as a glob.
const String _backupTsGlob = '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-'
    '[0-9][0-9][0-9][0-9][0-9][0-9]';

// Constant script parts (raw: full of shell `$`). @SKIP@/@VERB@/@WHAT@ are
// filled by the builder with constants only.

const String _uninstallCandidates = r'''
# dpkg status / selection of one package; "" when dpkg never heard of it.
pkg_status() { dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true; }
pkg_want() { dpkg-query -W -f='${db:Status-Want}' "$1" 2>/dev/null || true; }

# --- guards: nothing changes until every check passed -----------------------
pkgs=()
for p in "$@"; do
  case "$(pkg_status "$p")" in
    @SKIP@) ;;
    *) pkgs+=("$p") ;;
  esac
done
''';

const String _uninstallGuards = r'''
for p in "${pkgs[@]}"; do
  if [ "$(pkg_want "$p")" = hold ]; then
    echo "UNINSTALL_REFUSED: Das Paket $p ist mit apt-mark hold festgehalten – bitte zuerst freigeben (sudo apt-mark unhold $p), nichts geändert."
    exit 3
  fi
done
# Dry run: apt may take exactly these packages, nothing that depends on them.
if [ "${#pkgs[@]}" -gt 0 ]; then
  if ! sim=$(apt-get -o DPkg::Lock::Timeout=120 -s @VERB@ "${pkgs[@]}" </dev/null 2>&1); then
    printf '%s\n' "$sim" | tail -n 5
    echo "UNINSTALL_REFUSED: Der apt-Probelauf ist fehlgeschlagen (Details oben) – nichts geändert."
    exit 3
  fi
  extra=""
  for r in $(printf '%s\n' "$sim" | awk '$1 == "Remv" || $1 == "Purg" { sub(/:.*/, "", $2); print $2 }'); do
    case " ${pkgs[*]} " in
      *" $r "*) ;;
      *) extra="$extra $r" ;;
    esac
  done
  if [ -n "$extra" ]; then
    echo "UNINSTALL_REFUSED: apt würde zusätzlich andere Pakete entfernen:$extra – nichts geändert."
    exit 3
  fi
fi
''';

const String _uninstallRemove = r'''
# --- uninstall ------------------------------------------------------------------
# Disable while the unit file still exists: influxdb2 leaves its links behind on
# Debian, Mosquitto and Grafana keep a SysV script (conffile) after a remove.
# No --now: the prerm stops the service, and apt failing (lock) must not leave
# it stopped; the autostart comes back in that case.
was_enabled=$(systemctl is-enabled "$UNIT" 2>/dev/null || true)
systemctl disable "$UNIT" >/dev/null 2>&1 || true
if [ "${#pkgs[@]}" -gt 0 ]; then
  echo "Entferne ${pkgs[*]} @WHAT@ …"
  if ! apt-get -o DPkg::Lock::Timeout=120 -o Dpkg::Use-Pty=0 @VERB@ -y "${pkgs[@]}" </dev/null; then
    if [ "$was_enabled" = enabled ]; then systemctl enable "$UNIT" >/dev/null 2>&1 || true; fi
    echo "apt konnte $NAME nicht entfernen (Details oben) – bitte erneut versuchen."
    exit 1
  fi
fi
# Stop explicitly, while systemd still has the unit loaded: not every package
# stops its daemon on remove, which would keep running from the deleted binary.
systemctl stop "$UNIT" >/dev/null 2>&1 || true
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
''';

// The card disappears once no card package is `installed` (rc is enough).
const String _uninstallVerifyKeep = r'''
# --- verify before the marker ------------------------------------------------
for p in "$@"; do
  if [ "$(pkg_status "$p")" = installed ]; then
    echo "$p ist weiterhin installiert – bitte erneut versuchen."
    exit 1
  fi
done
''';

const String _uninstallVerifyPurge = r'''
# --- verify before the marker ------------------------------------------------
for p in "$@"; do
  case "$(pkg_status "$p")" in
    ""|not-installed) ;;
    *)
      echo "$p ist noch nicht vollständig entfernt – bitte erneut versuchen."
      exit 1
      ;;
  esac
done
''';

// A leftover enable link / SysV script would make the health alerts report
// "Dienst aus" for a service that is gone (alerts.dart checks is-enabled).
const String _uninstallVerifyUnit = r'''
if [ "$(systemctl is-enabled "$UNIT" 2>/dev/null || true)" = enabled ]; then
  echo "$UNIT startet weiterhin automatisch – bitte erneut versuchen."
  exit 1
fi
if systemctl is-active --quiet "$UNIT"; then
  echo "$UNIT läuft noch – bitte erneut versuchen."
  exit 1
fi
''';
