/// Tailscale (VPN/mesh) as a managed service. Pure command strings + parsers;
/// SSH orchestration lives in evcc_updater.dart. Runs as a SYSTEM service
/// (tailscaled) — simpler over SSH than a user service. Works on any OS.
library;

/// Root script: installs Tailscale via the official installer (adds the apt
/// repo + installs) and ensures the daemon is enabled.
const String tailscaleInstallScript = '''
set -e
export DEBIAN_FRONTEND=noninteractive
curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled 2>/dev/null || true
echo TAILSCALE_INSTALLED
''';

/// `tailscale up` prints a login URL then blocks until you authenticate; run it
/// DETACHED (setsid + &) so the SSH call returns, wait briefly, print the log
/// so the app can read the URL out. Runs as root (via the sudo shell).
const String tailscaleUpScript = '''
setsid tailscale up >/tmp/pi-tool-tailscale 2>&1 &
sleep 5
cat /tmp/pi-tool-tailscale 2>/dev/null
''';

/// No-sudo probe: status + the tailnet IPv4.
const String tailscaleStatusCommand =
    'tailscale status 2>&1; tailscale ip -4 2>/dev/null';

const String tailscaleDownCommand = "sudo -S -p '' tailscale down 2>&1";
const String tailscaleLogoutCommand = "sudo -S -p '' tailscale logout 2>&1";

/// The `https://login.tailscale.com/…` auth URL from `tailscale up` output.
String? parseTailscaleAuthUrl(String out) =>
    RegExp(r'https://login\.tailscale\.com/\S+').firstMatch(out)?.group(0);

/// The 100.x tailnet IPv4 (Tailscale's CGNAT range), or null.
String? parseTailscaleIp(String out) =>
    RegExp(r'\b100\.\d{1,3}\.\d{1,3}\.\d{1,3}\b').firstMatch(out)?.group(0);

typedef TailscaleStatus = ({bool installed, bool up, String? ip});

/// Parses [tailscaleStatusCommand] output. "up" = has a tailnet IP.
TailscaleStatus parseTailscaleStatus(String out) {
  final o = out.toLowerCase();
  if (o.contains('command not found') || o.contains(': not found')) {
    return (installed: false, up: false, ip: null);
  }
  final ip = parseTailscaleIp(out);
  return (installed: true, up: ip != null, ip: ip);
}
