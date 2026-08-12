/// Pi-hole service: command strings + pure parsers (v5 and v6). SSH
/// orchestration is wired in evcc_updater.dart. See
/// design/2026-06-30-multi-service.md.
library;

import '../commands.dart' show shSingleQuote;

/// Prints Pi-hole/Core/FTL versions if installed; empty/error if not (no sudo).
const String piholeVersionCommand = 'pihole -v 2>/dev/null';

/// Blocking status (no sudo).
const String piholeStatusCommand = 'pihole status 2>/dev/null';

/// Update Pi-hole core/web/FTL (needs sudo).
const String piholeUpdateCommand = 'LC_ALL=C sudo -S pihole -up';

/// Rebuild the blocklists / gravity database (needs sudo).
const String piholeGravityCommand = 'LC_ALL=C sudo -S pihole -g';

/// Flush the DNS cache / restart the resolver (needs sudo).
///
/// The subcommand differs between generations and **cannot** be picked by exit
/// code: v6 dropped `restartdns` and routes every unknown subcommand to
/// `helpFunc`, which exits **0** — so `pihole restartdns` prints the help text
/// and reports success while flushing nothing. v5 in turn has no `reloaddns`.
/// So we probe what the CLI actually offers (v6's help lists `reloaddns`
/// verbatim, v5's does not) and run the matching name. If Pi-hole is missing
/// entirely, the fallback fails loudly with a non-zero exit instead of
/// pretending to have worked.
const String piholeRestartCommand = "LC_ALL=C sudo -S sh -c 'if pihole --help "
    "2>&1 | grep -q reloaddns; then pihole reloaddns; else pihole restartdns; "
    "fi'";

/// The detected current version + whether a newer one is available.
class PiholeVersion {
  final String version;
  final bool updateAvailable;

  /// Whether `pihole -v` actually reported a "(Latest: …)" field. When false we
  /// couldn't determine currency (fresh install before the update-check cron,
  /// offline, format change), so [updateAvailable] being false means "unknown",
  /// not "up to date".
  final bool latestKnown;

  const PiholeVersion({
    required this.version,
    required this.updateAvailable,
    required this.latestKnown,
  });
}

// The Core/Pi-hole line drives the DISPLAYED version. Matches v5 ("Pi-hole
// version is v5.x") and v6 ("Core version is v6.x").
final _coreLine = RegExp(
    r'(?:Pi-hole|Core) version is (v[\w.\-]+)(?:\s*\(Latest:\s*(v[\w.\-]+)\))?',
    caseSensitive: false);

// Any component line (Core / Web / AdminLTE / FTL). An update in ANY of them
// means `pihole -up` has work to do, so the service isn't "aktuell".
final _componentLine = RegExp(
    r'(?:Pi-hole|Core|Web|AdminLTE|FTL) version is (v[\w.\-]+)'
    r'(?:\s*\(Latest:\s*(v[\w.\-]+)\))?',
    caseSensitive: false);

/// Parses `pihole -v`. Returns null when Pi-hole isn't installed. Currency
/// (updateAvailable/latestKnown) considers Core, Web/AdminLTE and FTL, not just
/// Core — a newer FTL/Web alone still means an update is pending.
PiholeVersion? parsePiholeVersion(String output) {
  final core = _coreLine.firstMatch(output);
  if (core == null) return null;

  var updateAvailable = false;
  var latestKnown = false;
  for (final m in _componentLine.allMatches(output)) {
    final latest = m.group(2);
    if (latest != null) {
      latestKnown = true;
      if (latest != m.group(1)!) updateAvailable = true;
    }
  }
  return PiholeVersion(
    version: core.group(1)!,
    updateAvailable: updateAvailable,
    latestKnown: latestKnown,
  );
}

/// Root/bash script (run via the sudo shell) that exports a Pi-hole
/// **Teleporter** backup — the official, importable format — into the backup
/// dir. Tries the v5 CLI (`pihole -a -t`) and falls back to v6's
/// `pihole-FTL --teleporter`, then moves the produced archive to a stable name.
/// Prints `BACKUP_OK <path>` on success.
String buildPiholeBackupScript() {
  return r'''
set -e
mkdir -p /var/backups/pi-tool
chmod 0755 /var/backups/pi-tool 2>/dev/null || true
d=$(mktemp -d)
cd "$d"
pihole -a -t >/dev/null 2>&1 || pihole-FTL --teleporter >/dev/null 2>&1 || true
f=$(ls -1t *.tar.gz *.zip 2>/dev/null | head -n1)
if [ -z "$f" ]; then echo "BACKUP_FAIL"; cd /; rm -rf "$d"; exit 1; fi
case "$f" in
  *.tar.gz) ext="tar.gz" ;;
  *.zip) ext="zip" ;;
  *) ext="${f##*.}" ;;
esac
out="/var/backups/pi-tool/pihole-backup-$(date +%Y%m%d-%H%M%S).$ext"
mv "$f" "$out"
chmod 0644 "$out" 2>/dev/null || true
cd /; rm -rf "$d"
ls -1t /var/backups/pi-tool/pihole-backup-* 2>/dev/null | tail -n +6 | xargs -r rm -f -- || true
echo "BACKUP_OK $out"
''';
}

/// Root script that restores a Pi-hole Teleporter backup. Only the v6 CLI can
/// import (`pihole-FTL --teleporter <zip>`, since Pi-hole v6); a v5 `.tar.gz`
/// archive can only be imported via the web UI, so it's refused with a clear
/// marker instead of attempting something unsupported. The reload uses v6's
/// `reloaddns` unconditionally — this path is v6-only, and v5's `restartdns`
/// would exit 0 on v6 without doing anything, which would also void the `set
/// -e` promise below. That promise: a reload failure is NOT swallowed — if the
/// imported settings break FTL, `set -e` aborts before RESTORE_OK so the user
/// learns DNS is down instead of getting a false "restored".
String buildPiholeRestoreScript(String archivePath) {
  if (!archivePath.endsWith('.zip')) {
    return '''
echo "RESTORE_FAIL_V5"
exit 1
''';
  }
  final a = shSingleQuote(archivePath);
  return '''
set -e
if [ ! -f $a ]; then echo "RESTORE_FAIL_MISSING"; exit 1; fi
pihole-FTL --teleporter $a
pihole reloaddns
echo "RESTORE_OK"
''';
}

/// Whether `pihole status` reports blocking as enabled.
bool isPiholeBlocking(String statusOutput) =>
    statusOutput.toLowerCase().contains('blocking is enabled');

/// Root/bash script for an UNATTENDED Pi-hole install (run via the sudo shell).
/// Pre-seeds a minimal setupVars.conf (auto-detected interface, Quad9 upstream)
/// so the official installer runs without a TTY. Experimental — not validated
/// against a fresh Pi; the user finishes setup in the web UI.
String buildPiholeInstallScript() {
  return r'''
set -e
export DEBIAN_FRONTEND=noninteractive
export PIHOLE_SKIP_OS_CHECK=true
mkdir -p /etc/pihole
if [ ! -f /etc/pihole/setupVars.conf ]; then
  IFACE=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -n1)
  {
    echo "PIHOLE_INTERFACE=${IFACE:-eth0}"
    echo "PIHOLE_DNS_1=9.9.9.9"
    echo "PIHOLE_DNS_2=149.112.112.112"
    echo "QUERY_LOGGING=true"
    echo "INSTALL_WEB_SERVER=true"
    echo "INSTALL_WEB_INTERFACE=true"
    echo "LIGHTTPD_ENABLED=true"
    echo "DNSMASQ_LISTENING=local"
    echo "BLOCKING_ENABLED=true"
  } > /etc/pihole/setupVars.conf
fi
setup=$(mktemp)
curl -fsSL https://install.pi-hole.net -o "$setup"
bash "$setup" --unattended
rm -f "$setup"
# Hand /etc/pihole back. We created it above as root to pre-seed
# setupVars.conf, and the official installer ADOPTS an existing directory
# without correcting its ownership — so FTL, which runs as the `pihole` user,
# could not write its own config directory and the user had to chown it by hand
# (customer report 2026-08-12). Guarded: the user only exists once the install
# actually succeeded, and a failure here must not fail the whole install.
if id -u pihole >/dev/null 2>&1; then
  chown -R pihole:pihole /etc/pihole 2>/dev/null \
    || chown -R pihole /etc/pihole 2>/dev/null || true
fi
chmod 0755 /etc/pihole 2>/dev/null || true
''';
}

