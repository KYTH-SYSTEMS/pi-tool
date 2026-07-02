import 'package:evcc_updater/src/notifications.dart';
import 'package:evcc_updater/src/profiles.dart';
import 'package:evcc_updater/src/services/pi_service.dart';
import 'package:flutter_test/flutter_test.dart';

ServiceStatus _svc(String id, String name, {bool update = false}) =>
    ServiceStatus(
        id: id,
        name: name,
        installed: true,
        updateAvailable: update,
        updateKnown: true);

void main() {
  group('summarizeUpdates', () {
    test('null when nothing has an update', () {
      expect(summarizeUpdates({}), isNull);
      expect(
        summarizeUpdates({
          'Standard': [_svc('evcc', 'evcc'), _svc('system', 'System (Pi)')]
        }),
        isNull,
      );
    });

    test('one Pi with updates → count + per-service body', () {
      final c = summarizeUpdates({
        'Standard': [
          _svc('evcc', 'evcc', update: true),
          _svc('system', 'System (Pi)', update: true),
          _svc('pihole', 'Pi-hole'),
        ]
      });
      expect(c, isNotNull);
      expect(c!.title, '2 Updates auf deinem Pi');
      expect(c.body, 'Standard: evcc, System (Pi)');
    });

    test('singular wording for exactly one update', () {
      final c = summarizeUpdates({
        'S': [_svc('evcc', 'evcc', update: true)]
      });
      expect(c!.title, '1 Update auf deinem Pi');
    });

    test('multiple Pis are summed and counted', () {
      final c = summarizeUpdates({
        'Zuhause': [_svc('evcc', 'evcc', update: true)],
        'Eltern': [
          _svc('pihole', 'Pi-hole', update: true),
          _svc('system', 'System (Pi)', update: true)
        ],
        'Büro': [_svc('evcc', 'evcc')], // no updates → not counted
      });
      expect(c!.title, '3 Updates auf 2 Pis');
      expect(c.body, contains('Zuhause: evcc'));
      expect(c.body, contains('Eltern: Pi-hole, System (Pi)'));
      expect(c.body, isNot(contains('Büro')));
    });
  });

  group('UpdateCheckRunner', () {
    test('notifies with the summary; unreachable Pis are skipped', () async {
      final shown = <NotificationContent>[];
      final runner = UpdateCheckRunner(
        loadProfiles: () async => const [
          Profile(name: 'Zuhause', host: '1.1.1.1', password: 'x'),
          Profile(name: 'Offline', host: '2.2.2.2', password: 'x'),
        ],
        detect: (p) async {
          if (p.name == 'Offline') throw Exception('unreachable');
          return [_svc('evcc', 'evcc', update: true)];
        },
        notify: (c) async => shown.add(c),
      );

      await runner.run();

      expect(shown, hasLength(1));
      expect(shown.single.title, '1 Update auf deinem Pi');
      expect(shown.single.body, 'Zuhause: evcc');
    });

    test('does not notify when nothing is pending', () async {
      var notified = false;
      final runner = UpdateCheckRunner(
        loadProfiles: () async =>
            const [Profile(name: 'S', host: '1.1.1.1', password: 'x')],
        detect: (_) async => [_svc('evcc', 'evcc')],
        notify: (_) async => notified = true,
      );
      await runner.run();
      expect(notified, isFalse);
    });
  });
}
