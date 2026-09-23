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

// ---- Deinstallieren ----

/// Printed as the last line of [buildTailscaleUninstallScript]'s happy path.
/// Shares no substring with `TAILSCALE_INSTALLED`.
const String tailscaleRemovedMarker = 'TAILSCALE_REMOVED_OK';

/// Why Tailscale cannot be removed while the SSH session itself runs over the
/// tailnet ([isTailnetClient], and the script's own backstop). Covers the
/// case a user cannot see from the host field: the phone reaches the Pi's
/// home address through the Pi's own subnet route, so the session goes
/// through Tailscale although the home address is in use. Plain text without
/// `"`, `$`, `` ` `` or `\`: the script prints it inside double quotes.
const String tailscaleSessionRefusal =
    'Die Verbindung zum Pi läuft über Tailscale (auch unter der '
    'Heimnetz-Adresse, wenn der Pi das Heimnetz freigibt) und würde beim '
    'Entfernen abreißen – bitte im Heimnetz mit ausgeschaltetem Tailscale '
    'auf dem Handy erneut versuchen.';

/// No-sudo probe for [isTailnetClient]: sudo's env_reset hides the variable
/// from a root script, the login shell still has it.
const String tailscaleSessionProbe = r'printf "%s\n" "$SSH_CONNECTION"';

/// True when the SSH session described by [sshConnection] (the login shell's
/// `$SSH_CONNECTION`: `<client-ip> <client-port> <server-ip> <server-port>`)
/// runs over the tailnet: client or server address in 100.64.0.0/10 or
/// fd7a:115c:a1e0::/48. Removing Tailscale would cut that session halfway
/// through apt. Catches what [isTailnetHost] cannot: a phone in the tailnet
/// that reaches the Pi's LAN address through this Pi's own subnet route
/// arrives with a 100.x source.
bool isTailnetClient(String sshConnection) {
  final f = sshConnection.trim().split(RegExp(r'\s+'));
  return [f.first, if (f.length > 2) f[2]].any(_isTailnetAddress);
}

bool _isTailnetAddress(String ip) {
  final a = ip.split('%').first; // link-local zone (fe80::1%eth0)
  bool cgnat(int o1, int o2) => o1 == 100 && (o2 & 0xC0) == 0x40;
  try {
    if (!a.contains(':')) {
      final b = Uri.parseIPv4Address(a);
      return cgnat(b[0], b[1]);
    }
    final b = Uri.parseIPv6Address(a);
    // IPv4-mapped (::ffff:a.b.c.d): the IPv4 rule on the last four bytes.
    if (b.take(10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff) {
      return cgnat(b[12], b[13]);
    }
    const ula = [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0];
    return [for (var i = 0; i < ula.length; i++) b[i] == ula[i]].every((x) => x);
  } on FormatException {
    return false;
  }
}

/// Root script: removes Tailscale — only the apt package the official
/// installer set up ([tailscaleInstallScript]).
///
/// [purge] false (keep): `apt-get remove`. The node state in
/// /var/lib/tailscale stays, so a reinstall comes back as the same node (same
/// 100.x IP, same approved routes) without a browser login; the apt source
/// and the keyring package stay too. No `tailscale logout`: it would expire
/// the node key and delete the profile.
///
/// [purge] true: logs out first while tailscaled still runs (expires the node
/// key; an ephemeral node leaves the tailnet, a regular one stays listed until
/// removed in the console), then purges both packages and deletes the node
/// state, the cache, /etc/default/tailscaled, the apt source + keyring (on
/// Buster installs only Tailscale's key from the shared trusted.gpg) and the
/// app's config-editor backups of Tailscale files.
///
/// Only purge removes the app's forwarding file [tailscaleForwardingConf]
/// (runtime value untouched — Docker and others may rely on it, as in
/// [buildTailscaleAdvertiseScript]). Keep leaves it with the rest of the
/// configuration: the kept prefs still advertise the shared home network, so
/// a reinstall resumes the sharing — without the file, forwarding would be off
/// after the next reboot while the card claims the route is active.
///
/// Refuses with one `UNINSTALL_REFUSED: …` line and exit 3, before anything
/// changes (so before a purge's logout), when the session itself runs over
/// the tailnet ([tailscaleSessionRefusal]; backstop for the app's
/// [isTailnetClient] check: the caller's SSH_CONNECTION is read from an
/// ancestor process), when a tailscale binary is not the package's (static
/// build, snap: the card would stay), when a package to remove is held
/// (`apt-mark hold`: the dry run passes, `-y` does not), when the apt dry
/// run fails (its last lines come first), or when apt would take another
/// package along.
///
/// `systemctl disable` only, no `--now`: the package's prerm stops tailscaled
/// while the binary is still there, so `ExecStopPost=tailscaled --cleanup`
/// restores DNS and drops routes and firewall rules. Should apt fail (lock),
/// the enablement is restored and remote access keeps running. A retry after
/// a partial run succeeds: an rc or missing package counts as removed.
String buildTailscaleUninstallScript({required bool purge}) {
  final b = StringBuffer(_tsUninstallPrelude)
    ..write(purge ? _tsPurgeSelect : _tsRemoveSelect)
    ..write(_tsUninstallGuards)
    ..write(_tsAptFailed);
  if (purge) b.write(_tsLogout);
  b.write(_tsDisableAndApt);
  if (purge) {
    b
      ..writeln('rm -f ${shSingleQuote(tailscaleForwardingConf)}')
      ..write(_tsPurgeLeftovers);
  }
  b
    ..write(_tsVerifyStopped)
    ..write(purge ? _tsVerifyPurged : _tsVerifyRemoved)
    ..write(_tsVerifyGone)
    ..writeln('echo $tailscaleRemovedMarker');
  return b.toString();
}

const String _tsUninstallPrelude = r'''
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
ts_status() {
  dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null </dev/null || true
}
# "hold" after `apt-mark hold`.
ts_want() {
  dpkg-query -W -f='${db:Status-Want}' "$1" 2>/dev/null </dev/null || true
}
# Every tailscale CLI on the usual paths, symlinks resolved: usrmerge's
# /bin/tailscale is /usr/bin/tailscale, a snap's leads to snapd.
ts_bins() {
  for f in /usr/local/sbin/tailscale /usr/local/bin/tailscale \
    /usr/sbin/tailscale /usr/bin/tailscale /sbin/tailscale /bin/tailscale \
    /snap/bin/tailscale "$(command -v tailscale 2>/dev/null || true)"; do
    if [ -n "$f" ] && [ -e "$f" ]; then readlink -f "$f"; fi
  done | sort -u
}
''';

// Keep: an rc package (config files only) is already removed.
const String _tsRemoveSelect = r'''
act=remove
pkgs=tailscale
case "$(ts_status tailscale)" in ""|not-installed|config-files) pkgs="" ;; esac
''';

// Purge: rc counts, so a purge after a keep still clears it.
const String _tsPurgeSelect = r'''
act=purge
pkgs=""
for p in tailscale tailscale-archive-keyring; do
  case "$(ts_status "$p")" in ""|not-installed) ;; *) pkgs="$pkgs $p" ;; esac
done
''';

// The session refusal is spliced in from [tailscaleSessionRefusal], so the app
// can show the very same text when it catches the case itself.
const String _tsUninstallGuards = r'''
# ---- Guards: nothing has been changed yet ----
# Over the tailnet, removing Tailscale cuts this very session halfway through
# apt. sudo hides SSH_CONNECTION from this shell; the caller's copy is still
# in an ancestor's environment.
conn=""
p=$PPID
for i in 1 2 3 4 5 6 7 8; do
  case "$p" in ""|0|1) break ;; esac
  conn=$(tr '\0' '\n' 2>/dev/null </proc/"$p"/environ | sed -n 's/^SSH_CONNECTION=//p')
  if [ -n "$conn" ]; then break; fi
  p=$(sed -n 's/^PPid:[[:space:]]*//p' /proc/"$p"/status 2>/dev/null || true)
done
sip=${conn#* * }
for ip in "${conn%% *}" "${sip%% *}"; do
  case "${ip#::ffff:}" in
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*|[Ff][Dd]7[Aa]:115[Cc]:[Aa]1[Ee]0:*)
'''
    '      echo "UNINSTALL_REFUSED: $tailscaleSessionRefusal"\n'
    r'''
      exit 3
      ;;
  esac
done
# A tailscale the package does not own (static build, snap) would keep the
# card, and its state is not the package's to delete.
for f in $(ts_bins); do
  if ! dpkg-query -S "$f" 2>/dev/null </dev/null | grep -q '^tailscale[,:]'; then
    echo "UNINSTALL_REFUSED: Tailscale ist hier nicht über apt installiert ($f) – bitte von Hand entfernen."
    exit 3
  fi
done
# A held package passes the dry run (no -y) but fails the real run — after a
# purge has already logged the node out.
for pk in $pkgs; do
  if [ "$(ts_want "$pk")" = hold ]; then
    echo "UNINSTALL_REFUSED: Das Paket $pk ist mit apt-mark hold festgehalten – bitte zuerst freigeben (sudo apt-mark unhold $pk), nichts geändert."
    exit 3
  fi
done
# apt must not take anything else along (a package that depends on tailscale).
# A failed dry run (interrupted dpkg, lock) refuses too: the real run would
# fail the same way, and a purge logs out before it. stderr is kept for the
# reason.
if [ -n "$pkgs" ]; then
  if ! sim=$(apt-get -s -o DPkg::Lock::Timeout=120 -o Dpkg::Use-Pty=0 "$act" $pkgs </dev/null 2>&1); then
    printf '%s\n' "$sim" | tail -n 5
    echo "UNINSTALL_REFUSED: Der apt-Probelauf ist fehlgeschlagen (Details oben) – nichts geändert."
    exit 3
  fi
  for x in $(printf '%s\n' "$sim" | sed -n 's/^\(Remv\|Purg\) \([^ :]*\).*/\2/p'); do
    case " $pkgs " in
      *" $x "*) ;;
      *)
        echo "UNINSTALL_REFUSED: apt würde auch $x entfernen – bitte von Hand prüfen."
        exit 3
        ;;
    esac
  done
fi
''';

const String _tsAptFailed = r'''
# ---- Removal ----
was=$(systemctl is-enabled tailscaled 2>/dev/null </dev/null || true)
# apt failed (lock, network): the package stays, so its service does too.
ts_apt_failed() {
  if [ "$was" = enabled ]; then systemctl enable tailscaled </dev/null 2>&1 || true; fi
  echo "Tailscale ließ sich nicht entfernen (apt ist gescheitert)."
  exit 1
}
''';

const String _tsLogout = r'''
# Log out while tailscaled still runs: expires the node key at the control
# server. Needs the internet, hence the timeout.
if command -v tailscale >/dev/null 2>&1; then
  timeout 30 tailscale logout </dev/null 2>&1 || echo "Hinweis: Abmelden bei Tailscale nicht möglich – das Gerät bitte in der Tailscale-Konsole entfernen."
fi
''';

const String _tsDisableAndApt = r'''
# disable only: the package's prerm stops tailscaled while the binary is still
# there, so its ExecStopPost cleanup restores DNS, routes and firewall rules.
if [ "$was" = enabled ]; then systemctl disable tailscaled </dev/null 2>&1 || true; fi
if [ -n "$pkgs" ]; then
  apt-get -o DPkg::Lock::Timeout=120 -o Dpkg::Use-Pty=0 "$act" -y $pkgs </dev/null || ts_apt_failed
fi
''';

const String _tsPurgeLeftovers = r'''
# What dpkg leaves behind (the state goes with postrm purge only when
# deb-systemd-helper is present) and what the installer wrote.
rm -rf /var/lib/tailscale /var/cache/tailscale
rm -f /etc/default/tailscaled
rm -f /etc/apt/sources.list.d/tailscale.list
rm -f /usr/share/keyrings/tailscale-archive-keyring.gpg
rm -f /var/lib/apt/lists/pkgs.tailscale.com_*
# Buster installs put the key into the shared trusted.gpg: only that key goes.
if [ -s /etc/apt/trusted.gpg ] && command -v apt-key >/dev/null 2>&1; then
  apt-key --keyring /etc/apt/trusted.gpg del 2596A99EAAB33821893C0A79458CA832957F5868 </dev/null >/dev/null 2>&1 || true
fi
# The app's config-editor backups of Tailscale files.
rm -f /var/backups/pi-tool/config-tailscaled-[0-9]*.bak
rm -f /var/backups/pi-tool/config-tailscale.list-[0-9]*.bak
rm -f /var/backups/pi-tool/config-99-pi-tool-tailscale.conf-[0-9]*.bak
''';

const String _tsVerifyStopped = r'''
# ---- Verification ----
# prerm stopped it; should it still run, stop it now: the tunnel must not
# outlive the card.
if systemctl is-active --quiet tailscaled </dev/null; then
  systemctl stop tailscaled </dev/null 2>&1 || true
fi
if systemctl is-active --quiet tailscaled </dev/null; then
  echo "tailscaled läuft noch."
  exit 1
fi
''';

const String _tsVerifyRemoved = r'''
case "$(ts_status tailscale)" in
  ""|not-installed|config-files) ;;
  *)
    echo "Das Paket tailscale ist noch installiert."
    exit 1
    ;;
esac
''';

const String _tsVerifyPurged = r'''
for p in tailscale tailscale-archive-keyring; do
  case "$(ts_status "$p")" in
    ""|not-installed) ;;
    *)
      echo "Das Paket $p ist noch registriert."
      exit 1
      ;;
  esac
done
if [ -e /var/lib/tailscale ]; then
  echo "/var/lib/tailscale ist noch vorhanden."
  exit 1
fi
''';

const String _tsVerifyGone = r'''
hash -r
left=$(ts_bins)
if [ -n "$left" ]; then
  echo "tailscale ist weiterhin vorhanden: $left"
  exit 1
fi
if [ -e /etc/resolv.pre-tailscale-backup.conf ]; then
  echo "Hinweis: /etc/resolv.pre-tailscale-backup.conf ist noch da – bitte die DNS-Einstellung in /etc/resolv.conf prüfen."
fi
''';
