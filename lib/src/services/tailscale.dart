/// Tailscale (VPN/mesh) as a managed service. Pure command strings + parsers;
/// SSH orchestration lives in evcc_updater.dart. Runs as a SYSTEM service
/// (tailscaled) — simpler over SSH than a user service. Works on any OS.
library;

import 'dart:convert';

import '../commands.dart' show shSingleQuote;

/// Root script: installs Tailscale via the official installer (adds the apt
/// repo + installs) and ensures the daemon is enabled. `pipefail`: without it
/// `curl … | sh` reports sh's exit code — a missing curl or a failed download
/// fed sh an empty script, it exited 0 and the marker claimed success. The
/// marker also waits for the binary itself. Dead sources of EOL releases are
/// repaired beforehand by the caller (eol_sources.dart), since the installer's
/// `apt-get update` fails on them.
const String tailscaleInstallScript = '''
set -e
set -o pipefail
export DEBIAN_FRONTEND=noninteractive
curl -fsSL https://tailscale.com/install.sh | sh
command -v tailscale >/dev/null || { echo "tailscale fehlt nach der Installation."; exit 1; }
systemctl enable --now tailscaled 2>/dev/null || true
echo TAILSCALE_INSTALLED
''';

/// `tailscale up` prints a login URL then blocks until you authenticate; run it
/// DETACHED (setsid + &) so the SSH call returns, wait briefly, print the log
/// so the app can read the URL out. Runs as root (via the sudo shell).
final String tailscaleUpScript = buildTailscaleUpScript(const []);

/// [tailscaleUpScript] with [flags] restated, each one quoted on its own. Only
/// ever fed the flags `tailscale up` itself asked for (see
/// [parseTailscaleUpRestateFlags]), so the node's settings stay as they are.
String buildTailscaleUpScript(List<String> flags) {
  final args = [for (final f in flags) ' ${shSingleQuote(f)}'].join();
  return '''
f=\$(mktemp)
setsid tailscale up$args >"\$f" 2>&1 &
sleep 5
cat "\$f" 2>/dev/null
rm -f "\$f"
# The detached `up` always exits 0, so emit an explicit connectivity marker:
# TS_UP_OK once the tailnet is actually up. Absent (and no login URL printed) =
# a real failure the app must surface, not report as "connected".
tailscale status >/dev/null 2>&1 && echo TS_UP_OK
''';
}

/// The flags a refused bare `tailscale up` wants restated, or null.
///
/// A node that has to log in again (key expired, device removed in the
/// console) but still carries non-default settings (our subnet route, for
/// one) makes a bare `up` fail with "requires mentioning all non-default
/// flags", followed by the full command it expects. Restating exactly those
/// values changes nothing and lets the login go ahead. Anything that is not a
/// plain `--flag[=value]` token (quotes, spaces, shell syntax) yields null:
/// the app then reports the refusal instead of guessing.
List<String>? parseTailscaleUpRestateFlags(String out) {
  if (!out.contains('requires mentioning all')) return null;
  final line = RegExp(r'^\s*tailscale up (.+)$', multiLine: true)
      .allMatches(out)
      .lastOrNull
      ?.group(1);
  if (line == null) return null;
  final tokens = line.trim().split(RegExp(r'\s+'));
  final plain = RegExp(r'^--[a-z][a-z0-9-]*(=[A-Za-z0-9._:/,@+=-]*)?$');
  if (!tokens.every(plain.hasMatch)) return null;
  return tokens;
}

/// No-sudo probe: status + the tailnet IPv4.
const String tailscaleStatusCommand =
    'tailscale status 2>&1; tailscale ip -4 2>/dev/null';

// LC_ALL=C so isSudoPasswordFailure (English-only) can detect a rejected
// password on a localized Pi.
const String tailscaleDownCommand =
    "LC_ALL=C sudo -S -p '' tailscale down 2>&1";
/// Logout resets the node's prefs, shared home network included — so the
/// app's forwarding file goes with it instead of switching IPv4 forwarding on
/// at every boot for nothing.
const String tailscaleLogoutCommand = "LC_ALL=C sudo -S -p '' sh -c "
    "'tailscale logout && rm -f $tailscaleForwardingConf' 2>&1";

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

// ---- Heimnetz freigeben (subnet router) ----

/// Our sysctl drop-in for IPv4 forwarding. Own file name, so "stop sharing"
/// removes only what the app wrote. IPv4 only: the routes are IPv4, and IPv6
/// forwarding makes the kernel ignore router advertisements on setups that
/// rely on them.
const String tailscaleForwardingConf =
    '/etc/sysctl.d/99-pi-tool-tailscale.conf';

/// Printed at the end of [buildTailscaleAdvertiseScript]'s happy path.
const String tailscaleRoutesMarker = 'TS_ROUTES_SET';

/// No-sudo probes read by the detection (and again right before a change):
/// the Pi's routing table, the node's prefs and its own status. `debug prefs`
/// and `status` only need read access to tailscaled, which every local user
/// has; `--peers=false` keeps the other devices of the tailnet out of it.
const String lanRoutesCommand = 'ip -4 route show 2>/dev/null';
const String tailscalePrefsCommand = 'tailscale debug prefs 2>/dev/null';
const String tailscaleSelfCommand =
    'tailscale status --json --peers=false 2>/dev/null';

/// The app's forwarding file (world-readable, like everything in sysctl.d).
/// Its `# routes=` line records which advertised routes the app added.
const String tailscaleForwardingProbe =
    'cat $tailscaleForwardingConf 2>/dev/null';

/// Root script: sets the advertised routes to exactly [routes]. While routes
/// remain (or [keepForwarding], for an exit node set by hand), IPv4
/// forwarding is switched on for good first — without it the route is
/// announced but nothing passes — and the app's forwarding file records in
/// [mine] which of them the app added, so they stay recognisable (and
/// removable) after the Pi moves to another network. With nothing left, the
/// file goes; the runtime value stays, since Docker and others may rely on it,
/// and falls back at the next reboot unless something else sets it.
///
/// [routes] may carry routes set by hand (IPv6, public ranges) — they only
/// need to look like a prefix; Tailscale validates them itself. [mine] is
/// only ever the app's own private IPv4 networks.
///
/// `tailscale set`, not `tailscale up`: `up` insists on every non-default
/// setting being restated and would fail or reset them.
String buildTailscaleAdvertiseScript(List<String> routes,
    {List<String> mine = const [], bool keepForwarding = false}) {
  for (final r in routes) {
    if (!_prefixShape.hasMatch(r)) {
      throw ArgumentError.value(r, 'routes', 'kein Netzpräfix');
    }
  }
  for (final r in mine) {
    if (!isPrivateIpv4Prefix(r)) {
      throw ArgumentError.value(r, 'mine', 'kein privates IPv4-Netz');
    }
  }
  final arg = shSingleQuote(routes.join(','));
  final b = StringBuffer('set -e\n');
  if (routes.isEmpty && !keepForwarding) {
    b.writeln('tailscale set --advertise-routes=$arg');
    b.writeln('rm -f $tailscaleForwardingConf');
  } else {
    final note = shSingleQuote('# routes=${mine.join(',')}');
    b.writeln(r"printf '%s\n' '# Pi-Tool: Tailscale-Heimnetz (Subnet Router)' "
        "$note 'net.ipv4.ip_forward = 1' > $tailscaleForwardingConf");
    b.writeln('sysctl -p $tailscaleForwardingConf');
    b.writeln(r'[ "$(sysctl -n net.ipv4.ip_forward)" = 1 ] || '
        '{ echo "IP-Weiterleitung ließ sich nicht einschalten."; exit 1; }');
    b.writeln('tailscale set --advertise-routes=$arg');
    // A route approved before (or covered by autoApprovers) comes back within
    // a moment — give the control plane that moment, so the app's follow-up
    // read does not ask for an approval that has already happened.
    if (routes.isNotEmpty) b.writeln('sleep 3');
  }
  b.writeln('echo $tailscaleRoutesMarker');
  return b.toString();
}

/// Anything that looks like an IPv4/IPv6 prefix — hex digits, dots, colons,
/// one slash. Keeps shell syntax out even before [shSingleQuote].
final RegExp _prefixShape = RegExp(r'^[0-9A-Fa-f:.]+/\d{1,3}$');

/// Routes the app itself advertised, from [tailscaleForwardingProbe] (its
/// `# routes=` line). Private IPv4 only; anything else is ignored.
List<String> parseAppRoutes(String out) {
  final m = RegExp(r'^# routes=(\S*)$', multiLine: true).firstMatch(out);
  if (m == null) return const [];
  final routes = m.group(1)!.split(',');
  if (!routes.every(isPrivateIpv4Prefix)) return const [];
  return routes;
}

/// True when the prefs advertise the node as an exit node — which needs IPv4
/// forwarding just like a subnet route.
bool parseAdvertisesExitNode(String prefsOut) =>
    _stringList(_jsonObject(prefsOut)?['AdvertiseRoutes']).any(_isExitRoute);

final RegExp _ipv4Prefix =
    RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$');

/// True for a canonical IPv4 prefix (no host bits set) inside one of the
/// RFC 1918 private ranges — the only thing the app ever advertises.
bool isPrivateIpv4Prefix(String prefix) {
  final m = _ipv4Prefix.firstMatch(prefix);
  if (m == null) return false;
  final o = [for (var i = 1; i <= 4; i++) int.parse(m.group(i)!)];
  final len = int.parse(m.group(5)!);
  if (o.any((x) => x > 255) || len > 32) return false;
  final addr = (o[0] << 24) | (o[1] << 16) | (o[2] << 8) | o[3];
  int maskOf(int l) => l == 0 ? 0 : (0xFFFFFFFF << (32 - l)) & 0xFFFFFFFF;
  if (addr & maskOf(len) != addr) return false; // host bits set
  bool within(int net, int netLen) =>
      len >= netLen && (addr & maskOf(netLen)) == net;
  return within(0x0A000000, 8) || // 10.0.0.0/8
      within(0xAC100000, 12) || // 172.16.0.0/12
      within(0xC0A80000, 16); // 192.168.0.0/16
}

/// Interfaces whose networks are never "the home network".
final RegExp _virtualDev =
    RegExp(r'^(lo|tailscale|docker|br-|veth|virbr|wg|tun|tap|zt)');

/// The Pi's home network(s) from [lanRoutesCommand]: the on-link routes of the
/// interface(s) carrying a default route; without one, those of every real
/// interface. Private IPv4 only, deduplicated, in routing-table order.
List<String> parseLanSubnets(String out) {
  final lines = [
    for (final l in out.split('\n'))
      if (l.trim().isNotEmpty) l.trim(),
  ];
  String? devOf(String line) =>
      RegExp(r'\bdev (\S+)').firstMatch(line)?.group(1);
  final defaultDevs = {
    for (final l in lines)
      if (l.startsWith('default ')) ?devOf(l),
  };
  final result = <String>[];
  for (final l in lines) {
    final prefix = l.split(' ').first;
    final dev = devOf(l);
    if (!prefix.contains('/') || dev == null || !l.contains('scope link')) {
      continue;
    }
    final fromLan = defaultDevs.isNotEmpty
        ? defaultDevs.contains(dev)
        : !_virtualDev.hasMatch(dev);
    if (fromLan && isPrivateIpv4Prefix(prefix) && !result.contains(prefix)) {
      result.add(prefix);
    }
  }
  return result;
}

/// The JSON object in [out], tolerating a warning line before it.
Map<String, dynamic>? _jsonObject(String out) {
  final start = out.indexOf('{');
  final end = out.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    final v = jsonDecode(out.substring(start, end + 1));
    return v is Map<String, dynamic> ? v : null;
  } on FormatException {
    return null;
  }
}

bool _isExitRoute(String r) => r == '0.0.0.0/0' || r == '::/0';

List<String> _stringList(Object? v) =>
    v is List ? [for (final e in v) e.toString()] : const [];

/// Subnet routes the node offers, from [tailscalePrefsCommand]. Exit-node
/// routes are not subnet routes and fall out. Null when the prefs could not
/// be read at all — unknown, not "none".
List<String>? parseAdvertisedRoutes(String out) {
  final j = _jsonObject(out);
  if (j == null) return null;
  return [
    for (final r in _stringList(j['AdvertiseRoutes']))
      if (!_isExitRoute(r)) r,
  ];
}

/// Routes the control plane approved, from [tailscaleSelfCommand]:
/// `Self.AllowedIPs` minus the node's own addresses and the exit routes —
/// the same rule tailscaled uses for its approved-routes metric. Null unless
/// the node is running (without a network map there is nothing to read).
List<String>? parseApprovedRoutes(String out) {
  final j = _jsonObject(out);
  if (j == null || j['BackendState'] != 'Running') return null;
  final self = j['Self'];
  if (self is! Map) return const [];
  final own = {
    for (final ip in _stringList(self['TailscaleIPs'])) ...['$ip/32', '$ip/128'],
  };
  return [
    for (final r in _stringList(self['AllowedIPs']))
      if (!own.contains(r) && !_isExitRoute(r)) r,
  ];
}

/// The name the Tailscale console lists this Pi under (first label of its
/// MagicDNS name, else the hostname) — so the approval hint names the row.
String? parseTailnetMachineName(String out) {
  final self = _jsonObject(out)?['Self'];
  if (self is! Map) return null;
  final label = (self['DNSName'] ?? '').toString().split('.').first.trim();
  if (label.isNotEmpty) return label;
  final host = (self['HostName'] ?? '').toString().trim();
  return host.isEmpty ? null : host;
}

/// [current] advertised routes plus the home network — never dropping a
/// route someone set by hand.
List<String> routesWithLan(List<String> current, List<String> lan) => [
      ...current,
      for (final r in lan)
        if (!current.contains(r)) r,
    ];

/// [current] advertised routes minus the home network.
List<String> routesWithoutLan(List<String> current, List<String> lan) => [
      for (final r in current)
        if (!lan.contains(r)) r,
    ];

/// Where sharing the home network stands, from the app's point of view.
enum RouteShare {
  /// No private home network found on the Pi — nothing to offer.
  unavailable,

  /// Home network known, not advertised.
  off,

  /// Advertised, but not (yet) approved in the Tailscale console.
  pending,

  /// Advertised and approved: devices at home are reachable over Tailscale.
  active,
}

/// The subnet-router state of the Pi's Tailscale node, as detected.
class SubnetRoutes {
  const SubnetRoutes({
    this.lan = const [],
    this.advertised = const [],
    this.approved = const [],
    this.mine = const [],
    this.machine = '',
  });

  /// The Pi's home network(s) ([parseLanSubnets]).
  final List<String> lan;

  /// Routes the node offers ([parseAdvertisedRoutes]).
  final List<String> advertised;

  /// Routes the control plane approved ([parseApprovedRoutes]).
  final List<String> approved;

  /// Routes the app advertised earlier ([parseAppRoutes]) — still "ours"
  /// even when the Pi has since moved to another network.
  final List<String> mine;

  /// The Pi's name in the Tailscale console ([parseTailnetMachineName]).
  final String machine;

  /// The home-network routes that are currently offered: the current home
  /// network plus whatever the app added before. Routes set by hand for
  /// other networks are not the app's business and stay out.
  List<String> get sharedLan => [
        for (final r in advertised)
          if (lan.contains(r) || mine.contains(r)) r,
      ];

  /// Whether the CURRENT home network is offered — if not, sharing it is
  /// still on the table (even next to an old route from a previous network).
  bool get lanAdvertised => lan.isNotEmpty && lan.every(advertised.contains);

  RouteShare get share {
    final shared = sharedLan;
    if (shared.isEmpty) {
      return lan.isEmpty ? RouteShare.unavailable : RouteShare.off;
    }
    return shared.every(approved.contains)
        ? RouteShare.active
        : RouteShare.pending;
  }

  Map<String, dynamic> toJson() => {
        'lan': lan,
        'advertised': advertised,
        'approved': approved,
        'mine': mine,
        'machine': machine,
      };

  static SubnetRoutes fromJson(Map<String, dynamic> j) => SubnetRoutes(
        lan: _stringList(j['lan']),
        advertised: _stringList(j['advertised']),
        approved: _stringList(j['approved']),
        mine: _stringList(j['mine']),
        machine: (j['machine'] ?? '').toString(),
      );
}
