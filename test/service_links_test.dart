import 'dart:io';

import 'package:evcc_updater/src/services/apt_services.dart';
import 'package:evcc_updater/src/services/service_links.dart';
import 'package:evcc_updater/src/systemd_services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('serviceLinks', () {
    test('every service that gets a card knows where its project lives', () {
      // Guard: a new service must not silently ship without a jump point.
      final ids = <String>{
        'evcc',
        'pihole',
        'homeassistant',
        'piconnect',
        'tailscale',
        ...knownAptServices.map((s) => s.id),
        ...knownSystemdServices.map((s) => s.id),
      };

      for (final id in ids) {
        final links = linksFor(id);
        expect(links, isNotNull, reason: '$id has no project link');
        expect(links!.website, startsWith('https://'),
            reason: '$id: plain http or a relative link');
        expect(links.website.trim(), links.website);
      }
    });

    test('an app entry is never half there — package AND listing, matching',
        () {
      for (final e in serviceLinks.entries) {
        final l = e.value;
        expect(l.appPackage == null, l.appUrl == null,
            reason: '${e.key}: half an app entry is a dead menu item');
        if (l.hasApp) {
          // The listing must point at the very package we try to launch,
          // otherwise "not installed" opens some other app's Play page.
          expect(l.appUrl, contains('id=${l.appPackage}'), reason: e.key);
        }
      }
    });

    test('only projects that really ship an official Android app claim one',
        () {
      final withApp = serviceLinks.entries
          .where((e) => e.value.hasApp)
          .map((e) => e.key)
          .toSet();
      // Pi-hole, Grafana, InfluxDB, Node-RED & co. have no official app; a
      // third-party one must never be presented as "the official app".
      expect(withApp, {'evcc', 'homeassistant', 'tailscale'});
    });

    test('an unknown id is a null lookup, not a crash', () {
      expect(linksFor('nope'), isNull);
      expect(linksFor(''), isNull);
    });

    test('every official app is declared in the manifest\'s <queries>', () {
      // Android 11+ package visibility: getLaunchIntentForPackage returns null
      // for a package the manifest does not name, and the launcher then falls
      // back to the Play listing although the app is installed.
      final manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      final queries =
          RegExp(r'<queries>(.*?)</queries>', dotAll: true).allMatches(manifest);
      expect(queries, hasLength(1));
      final visible = RegExp(r'<package\s+android:name="([^"]+)"\s*/>')
          .allMatches(queries.single.group(1)!)
          .map((m) => m.group(1))
          .toSet();
      for (final e in serviceLinks.entries) {
        if (!e.value.hasApp) continue;
        expect(visible, contains(e.value.appPackage), reason: e.key);
      }
    });
  });

  group('piWebUrl', () {
    test('an IPv4 address or a host name is set as typed', () {
      expect(piWebUrl(host: '192.168.178.64', port: '8123'),
          'http://192.168.178.64:8123');
      expect(piWebUrl(host: 'raspberrypi.local', path: '/admin'),
          'http://raspberrypi.local/admin');
      expect(piWebUrl(host: ' 192.168.178.64 ', scheme: 'https', port: ' 7070 '),
          'https://192.168.178.64:7070');
    });

    test('http unless a scheme is asked for', () {
      expect(piWebUrl(host: '192.168.178.64', path: '/admin'),
          startsWith('http://'));
    });

    test('an IPv6 literal gets its brackets — with a port and without', () {
      expect(piWebUrl(host: 'fd00::1', port: '8123'), 'http://[fd00::1]:8123');
      expect(piWebUrl(host: 'fd00::1', path: '/admin'),
          'http://[fd00::1]/admin');
      expect(piWebUrl(host: 'fd00::1', scheme: 'https', port: '7070'),
          'https://[fd00::1]:7070');
      // What the browser gets out of it: the address, and the port apart.
      final uri = Uri.parse(piWebUrl(host: 'fd00::1', port: '8123'));
      expect(uri.host, 'fd00::1');
      expect(uri.port, 8123);
    });

    test('brackets that are already there are not doubled', () {
      expect(piWebUrl(host: '[fd00::1]', port: '8123'),
          'http://[fd00::1]:8123');
    });

    test('a host or port Uri cannot take is passed on as typed, not thrown',
        () {
      // A host typed together with a port is no IPv6 literal.
      expect(piWebUrl(host: '192.168.178.64:8080', path: '/admin'),
          'http://192.168.178.64:8080/admin');
      expect(piWebUrl(host: '[fd00::1', port: '8123'), 'http://[fd00::1:8123');
      expect(piWebUrl(host: '192.168.178.64', port: '70x70'),
          'http://192.168.178.64:70x70');
    });
  });
}
