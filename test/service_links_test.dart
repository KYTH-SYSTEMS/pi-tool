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
}
