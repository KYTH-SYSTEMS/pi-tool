import 'dart:async';
import 'dart:io';

import 'package:evcc_updater/src/network_scan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('subnetBase', () {
    test('returns the /24 prefix of a valid IPv4', () {
      expect(subnetBase('192.168.178.64'), '192.168.178.');
      expect(subnetBase('10.0.0.5'), '10.0.0.');
    });
    test('rejects non-IPv4 / malformed input', () {
      expect(subnetBase('not-an-ip'), isNull);
      expect(subnetBase('192.168.1'), isNull);
      expect(subnetBase('192.168.1.1.1'), isNull);
      expect(subnetBase('192.168.1.999'), isNull);
      expect(subnetBase(''), isNull);
    });
  });

  group('subnetHosts', () {
    test('enumerates .1–.254 and omits the device itself', () {
      final hosts = subnetHosts('192.168.178.64');
      expect(hosts, hasLength(253)); // 254 candidates minus self
      expect(hosts, contains('192.168.178.1'));
      expect(hosts, contains('192.168.178.254'));
      expect(hosts, isNot(contains('192.168.178.64'))); // self excluded
      expect(hosts, isNot(contains('192.168.178.0'))); // network address
      expect(hosts, isNot(contains('192.168.178.255'))); // broadcast
    });
    test('returns nothing for an invalid address', () {
      expect(subnetHosts('garbage'), isEmpty);
    });
  });

  group('scanHosts', () {
    test('returns only reachable hosts, in input order', () async {
      final reachable = {'10.0.0.2', '10.0.0.5'};
      final found = await scanHosts(
        ['10.0.0.1', '10.0.0.2', '10.0.0.3', '10.0.0.5'],
        (ip) async => reachable.contains(ip),
        concurrency: 2,
      );
      expect(found, ['10.0.0.2', '10.0.0.5']);
    });

    test('probes in parallel, and never exceeds the concurrency limit',
        () async {
      var active = 0;
      var peak = 0;
      var probes = 0;
      Future<bool> probe(String ip) async {
        probes++;
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        active--;
        return false;
      }

      await scanHosts(
        List.generate(20, (i) => '10.0.0.$i'),
        probe,
        concurrency: 4,
      );
      expect(peak, lessThanOrEqualTo(4));
      // One after the other would pass the line above as well.
      expect(peak, greaterThan(1));
      expect(probes, 20);
    });

    test('fewer hosts than the limit: one probe each, no more', () async {
      final probed = <String>[];
      final found = await scanHosts(['10.0.0.1', '10.0.0.2'], (ip) async {
        probed.add(ip);
        return true;
      }, concurrency: 8);
      expect(found, ['10.0.0.1', '10.0.0.2']);
      expect(probed, ['10.0.0.1', '10.0.0.2']);
      expect(await scanHosts(const [], (_) async => true), isEmpty);
    });

    test('a probe that throws is treated as unreachable, not fatal', () async {
      final found = await scanHosts(
        ['10.0.0.1', '10.0.0.2'],
        (ip) async => ip == '10.0.0.2' ? throw 'boom' : true,
        concurrency: 2,
      );
      expect(found, ['10.0.0.1']);
    });
  });

  group('lanAddresses', () {
    test('keeps Wi-Fi, Ethernet and hotspot, drops VPN and mobile data', () {
      expect(
        lanAddresses(const [
          (interface: 'wlan0', address: '192.168.178.20'),
          (interface: 'eth0', address: '10.0.0.7'),
          (interface: 'swlan0', address: '192.168.43.1'), // the phone's hotspot
          (interface: 'tun0', address: '10.8.0.2'), // OpenVPN / WireGuard app
          (interface: 'tap0', address: '10.9.0.2'),
          (interface: 'ppp0', address: '10.64.64.64'),
          (interface: 'wg0', address: '10.7.0.2'),
          (interface: 'ipsec1', address: '10.20.0.5'),
          (interface: 'rmnet_data0', address: '10.44.5.6'), // Qualcomm
          (interface: 'ccmni1', address: '10.133.7.9'), // MediaTek
          (interface: 'wwan0', address: '10.55.1.2'),
          (interface: 'v4-rmnet_data0', address: '10.1.2.3'), // CLAT
        ]),
        ['192.168.178.20', '10.0.0.7', '192.168.43.1'],
      );
    });

    test('drops CGNAT (Tailscale) and 192.0.0.0/24 whatever the name', () {
      expect(
        lanAddresses(const [
          (interface: 'wlan0', address: '192.168.178.20'),
          (interface: 'tailscale0', address: '100.101.102.103'),
          (interface: 'wlan0', address: '192.0.0.4'),
          (interface: 'unknown7', address: '100.64.0.1'),
        ]),
        ['192.168.178.20'],
      );
    });

    test('the ranges end where they should', () {
      List<String> kept(String ip) =>
          lanAddresses([(interface: 'wlan0', address: ip)]);
      // 100.64.0.0/10 = 100.64.0.0 – 100.127.255.255
      expect(kept('100.63.255.254'), ['100.63.255.254']);
      expect(kept('100.64.0.1'), isEmpty);
      expect(kept('100.127.255.254'), isEmpty);
      expect(kept('100.128.0.1'), ['100.128.0.1']);
      // 192.0.0.0/24 only — not 192.0.2.x, let alone 192.168.x.x
      expect(kept('192.0.0.2'), isEmpty);
      expect(kept('192.0.1.2'), ['192.0.1.2']);
      expect(kept('192.168.0.2'), ['192.168.0.2']);
    });

    test('an interface name is matched from its start, in any case', () {
      expect(
        lanAddresses(const [
          (interface: 'TUN0', address: '10.8.0.2'),
          // "tun" somewhere inside the name is no VPN marker.
          (interface: 'wlan-fortune0', address: '192.168.1.5'),
        ]),
        ['192.168.1.5'],
      );
    });
  });

  group('findSshHosts', () {
    test('sweeps the Wi-Fi /24 only, not the VPN or the mobile network',
        () async {
      final probed = <String>[];
      final found = await findSshHosts(
        addresses: () async => const [
          (interface: 'wlan0', address: '192.168.178.20'),
          (interface: 'tun0', address: '100.101.102.103'),
          (interface: 'rmnet_data0', address: '10.44.5.6'),
          (interface: 'v4-rmnet_data0', address: '192.0.0.4'),
        ],
        probe: (ip) async {
          probed.add(ip);
          return ip == '192.168.178.64';
        },
      );
      expect(found, ['192.168.178.64']);
      expect(probed, hasLength(253));
      expect(probed.every((ip) => ip.startsWith('192.168.178.')), isTrue);
    });

    test('with only VPN and mobile addresses nothing is probed', () async {
      var probes = 0;
      final found = await findSshHosts(
        addresses: () async => const [
          (interface: 'tun0', address: '100.101.102.103'),
          (interface: 'rmnet_data0', address: '10.44.5.6'),
        ],
        probe: (ip) async {
          probes++;
          return true;
        },
      );
      expect(found, isEmpty);
      expect(probes, 0);
    });

    test('two local networks (Wi-Fi and Ethernet) are both swept', () async {
      final probed = <String>{};
      await findSshHosts(
        addresses: () async => const [
          (interface: 'wlan0', address: '192.168.178.20'),
          (interface: 'eth0', address: '10.0.0.7'),
        ],
        probe: (ip) async {
          probed.add(ip);
          return false;
        },
      );
      expect(probed, hasLength(506));
      expect(probed, contains('10.0.0.1'));
      expect(probed, contains('192.168.178.1'));
    });
  });

  // The two functions that touch real I/O, on this machine alone: a listener
  // on 127.0.0.1 and the list of local interfaces. Nothing is sent anywhere.
  group('probeSshPort (loopback)', () {
    test('a port that accepts is reported, and the connection is given up',
        () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final accepted = Completer<Socket>();
      server.listen(accepted.complete);

      expect(
          await probeSshPort('127.0.0.1',
              port: server.port, timeout: const Duration(seconds: 5)),
          isTrue);
      // The probe only connects: it sends nothing and closes its end — the
      // listener's read ends (a reset counts as closed) instead of timing out.
      final peer = await accepted.future.timeout(const Duration(seconds: 5));
      var received = 0;
      try {
        await for (final chunk in peer.timeout(const Duration(seconds: 5))) {
          received += chunk.length;
        }
      } on SocketException {
        // closed by reset
      }
      expect(received, 0);
      peer.destroy();
    });

    test('a port nobody listens on is not reported, and nothing is thrown',
        () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();
      expect(
          await probeSshPort('127.0.0.1',
              port: port, timeout: const Duration(seconds: 5)),
          isFalse);
    });
  });

  group('localIPv4s', () {
    test('lists IPv4 addresses with their interface, never the loopback',
        () async {
      // Which interfaces this machine has is not the test's business (it may
      // have none) — only what the sweep relies on for each entry.
      for (final a in await localIPv4s()) {
        expect(a.interface, isNotEmpty);
        expect(subnetBase(a.address), isNotNull, reason: a.address);
        expect(a.address, isNot(startsWith('127.')));
      }
    });
  });
}
