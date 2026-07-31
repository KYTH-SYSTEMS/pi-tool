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
f=\$(mktemp)
setsid tailscale up >"\$f" 2>&1 &
sleep 5
cat "\$f" 2>/dev/null
rm -f "\$f"
# The detached `up` always exits 0, so emit an explicit connectivity marker:
# TS_UP_OK once the tailnet is actually up. Absent (and no login URL printed) =
# a real failure the app must surface, not report as "connected".
tailscale status >/dev/null 2>&1 && echo TS_UP_OK
''';

/// No-sudo probe: status + the tailnet IPv4.
const String tailscaleStatusCommand =
    'tailscale status 2>&1; tailscale ip -4 2>/dev/null';

// LC_ALL=C so isSudoPasswordFailure (English-only) can detect a rejected
// password on a localized Pi.
const String tailscaleDownCommand =
    "LC_ALL=C sudo -S -p '' tailscale down 2>&1";
const String tailscaleLogoutCommand =
    "LC_ALL=C sudo -S -p '' tailscale logout 2>&1";

/// The `https://login.tailscale.com/…` auth URL from `tailscale up` output.
String? parseTailscaleAuthUrl(String out) =>
    RegExp(r'https://login\.tailscale\.com/\S+').firstMatch(out)?.group(0);

/// The 100.x tailnet IPv4 (Tailscale's CGNAT range), or null.
String? parseTailscaleIp(String out) =>
    RegExp(r'\b100\.\d{1,3}\.\d{1,3}\.\d{1,3}\b').firstMatch(out)?.group(0);

/// True when [host] is a Tailscale address — either the numeric CGNAT range
/// (100.64.0.0/10, recognised by the `100.` prefix) or a MagicDNS name
/// (`*.ts.net`). Such hosts only route while the tailnet VPN is up, so they must
/// never be remembered as a Pi's home/LAN address.
bool isTailnetHost(String host) {
  final h = host.trim().toLowerCase();
  return h.startsWith('100.') || h.endsWith('.ts.net');
}

/// Ordered connect candidates for a Pi that has both a home address and a
/// tailnet IP. Home first — it is the fast path and needs no VPN on the phone —
/// unless the tailnet is what worked last time. A [lastGood] matching neither
/// known address is stale (the Pi moved to a new LAN IP) and is ignored.
///
/// Fewer than two known addresses are returned as-is, so a Pi without remote
/// access behaves exactly as before and never pays a fallback delay.
List<String> remoteAccessCandidates({
  required String lanHost,
  required String tailscaleIp,
  required String lastGood,
}) {
  final lan = lanHost.trim();
  final ts = tailscaleIp.trim();
  final known = [if (lan.isNotEmpty) lan, if (ts.isNotEmpty) ts];
  if (known.length < 2) return known;
  return lastGood.trim() == ts ? [ts, lan] : [lan, ts];
}

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
