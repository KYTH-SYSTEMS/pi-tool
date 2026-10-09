/// Best-effort "Pi finden": a bounded TCP-connect sweep of the phone's local
/// /24 looking for hosts with an open SSH port (22).
///
/// This is deliberately a plain port-22 scan rather than mDNS — it needs no
/// extra plugin, no Android multicast lock, and behaves the same on every
/// device. The pure orchestration (subnet maths + bounded concurrency) is
/// unit-tested with a fake probe; only the socket probe and interface lookup
/// touch real I/O.
library;

import 'dart:async';
import 'dart:io';

/// Returns the `a.b.c.` prefix of a dotted IPv4 address, or null if [ip] is not
/// a well-formed IPv4 (four 0–255 octets).
String? subnetBase(String ip) {
  final parts = ip.split('.');
  if (parts.length != 4) return null;
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return null;
  }
  return '${parts[0]}.${parts[1]}.${parts[2]}.';
}

/// All host addresses (.1–.254) in [localIp]'s /24, excluding [localIp] itself.
/// Empty when [localIp] is not a valid IPv4.
List<String> subnetHosts(String localIp) {
  final base = subnetBase(localIp);
  if (base == null) return const [];
  final hosts = <String>[];
  for (var i = 1; i <= 254; i++) {
    final ip = '$base$i';
    if (ip != localIp) hosts.add(ip);
  }
  return hosts;
}

/// Probes whether [ip] should be reported as a candidate. Injected for tests.
typedef HostProbe = Future<bool> Function(String ip);

/// Runs [probe] over [ips] with at most [concurrency] in flight and returns the
/// reachable ones in input order. A throwing probe counts as unreachable.
Future<List<String>> scanHosts(
  List<String> ips,
  HostProbe probe, {
  int concurrency = 32,
}) async {
  final reachable = List<bool>.filled(ips.length, false);
  var next = 0;

  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= ips.length) return;
      try {
        reachable[i] = await probe(ips[i]);
      } catch (_) {
        reachable[i] = false;
      }
    }
  }

  final workers = <Future<void>>[];
  for (var i = 0; i < concurrency && i < ips.length; i++) {
    workers.add(worker());
  }
  await Future.wait(workers);

  return [
    for (var i = 0; i < ips.length; i++)
      if (reachable[i]) ips[i],
  ];
}

/// One IPv4 address of the device and the interface it sits on.
typedef LocalAddress = ({String interface, String address});

/// Lists the device's IPv4 addresses. Injected for tests.
typedef AddressLister = Future<List<LocalAddress>> Function();

/// Name prefixes of interfaces that are no local network: VPN tunnels (`tun0`
/// is what Tailscale, WireGuard and OpenVPN get on Android), mobile data
/// (`rmnet*` Qualcomm, `ccmni*` MediaTek) and the `v4-*` CLAT interface
/// Android adds on an IPv6-only network.
const List<String> _nonLanInterfacePrefixes = [
  'tun', 'tap', 'ppp', 'wg', 'ipsec', // VPN
  'rmnet', 'ccmni', 'wwan', // mobile data
  'v4-', // CLAT (464XLAT)
];

bool _isNonLanInterface(String name) {
  final n = name.toLowerCase();
  return _nonLanInterfacePrefixes.any(n.startsWith);
}

/// Whether [ip] lies in a range no home network uses: 100.64.0.0/10
/// (carrier-grade NAT — mobile networks, and every Tailscale address) or
/// 192.0.0.0/24 (reserved for protocol use, e.g. a phone's CLAT address).
bool _isNonLanAddress(String ip) {
  final parts = ip.split('.');
  if (parts.length != 4) return false;
  final a = int.tryParse(parts[0]);
  final b = int.tryParse(parts[1]);
  final c = int.tryParse(parts[2]);
  if (a == 100 && b != null && b >= 64 && b <= 127) return true;
  return a == 192 && b == 0 && c == 0;
}

/// The addresses out of [addresses] whose /24 is worth sweeping for a Pi:
/// those of a local network (Wi-Fi, Ethernet, the phone's own hotspot). VPN
/// and mobile-data addresses are left out — a sweep there costs 253 connection
/// attempts into a tailnet or a carrier network and is not what "search the
/// Wi-Fi" promises. An interface this list does not know is swept as before.
List<String> lanAddresses(List<LocalAddress> addresses) => [
      for (final a in addresses)
        if (!_isNonLanInterface(a.interface) && !_isNonLanAddress(a.address))
          a.address,
    ];

/// The phone's non-loopback IPv4 addresses (e.g. its Wi-Fi address), each with
/// the name of its interface.
Future<List<LocalAddress>> localIPv4s() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    return [
      for (final iface in interfaces)
        for (final addr in iface.addresses)
          (interface: iface.name, address: addr.address),
    ];
  } catch (_) {
    return const [];
  }
}

/// TCP-connects to [ip]:[port] within [timeout]; true if the port accepts.
Future<bool> probeSshPort(
  String ip, {
  int port = 22,
  Duration timeout = const Duration(milliseconds: 400),
}) async {
  Socket? socket;
  try {
    socket = await Socket.connect(ip, port, timeout: timeout);
    return true;
  } catch (_) {
    return false;
  } finally {
    socket?.destroy();
  }
}

/// Discovers reachable SSH hosts across every local /24 the phone sits on
/// ([lanAddresses]: not the VPN, not mobile data). Best-effort and fail-soft:
/// returns an empty list when offline or on Wi-Fi without peers. [probe] and
/// [addresses] are injectable for tests.
Future<List<String>> findSshHosts({
  HostProbe? probe,
  AddressLister? addresses,
  int concurrency = 48,
}) async {
  final locals = lanAddresses(await (addresses ?? localIPv4s)());
  final candidates = <String>{};
  for (final ip in locals) {
    candidates.addAll(subnetHosts(ip));
  }
  if (candidates.isEmpty) return const [];
  return scanHosts(
    candidates.toList(),
    probe ?? (ip) => probeSshPort(ip),
    concurrency: concurrency,
  );
}
