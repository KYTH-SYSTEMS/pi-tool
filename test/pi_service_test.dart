import 'package:evcc_updater/src/services/pi_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('orderServicesForDisplay', () {
    ServiceStatus svc(String id) =>
        ServiceStatus(id: id, name: id, installed: true);

    test('moves the System card to the front, keeps the rest in order', () {
      final ordered = orderServicesForDisplay(
          [svc('evcc'), svc('pihole'), svc('system'), svc('grafana')]);
      expect(ordered.map((s) => s.id).toList(),
          ['system', 'evcc', 'pihole', 'grafana']);
    });

    test('no-op when there is no system service', () {
      final ordered = orderServicesForDisplay([svc('evcc'), svc('pihole')]);
      expect(ordered.map((s) => s.id).toList(), ['evcc', 'pihole']);
    });

    test('already-first system stays first', () {
      final ordered = orderServicesForDisplay([svc('system'), svc('evcc')]);
      expect(ordered.map((s) => s.id).toList(), ['system', 'evcc']);
    });
  });

  group('applyLatestEvccVersion', () {
    ServiceStatus evccApt(String version, {bool updateAvailable = false}) =>
        ServiceStatus(
            id: 'evcc',
            name: 'evcc',
            installed: true,
            version: version,
            updateAvailable: updateAvailable,
            updateKnown: true,
            detail: 'apt · Dienst aktiv');

    test('marks an update when the GitHub release is newer than installed', () {
      // apt index was stale, so detection said "up to date" (false).
      final out = applyLatestEvccVersion([evccApt('0.309.0')], '0.310.0');
      final evcc = out.firstWhere((s) => s.id == 'evcc');
      expect(evcc.updateAvailable, isTrue);
      expect(evcc.updateKnown, isTrue);
    });

    test('leaves it alone when installed is current or newer', () {
      expect(applyLatestEvccVersion([evccApt('0.310.0')], '0.310.0')
          .first.updateAvailable, isFalse);
      // e.g. a nightly ahead of the stable GitHub release.
      expect(applyLatestEvccVersion([evccApt('0.311.0')], '0.310.0')
          .first.updateAvailable, isFalse);
    });

    test('never touches a Docker evcc (image tag, not a comparable version)',
        () {
      final docker = ServiceStatus(
          id: 'evcc',
          name: 'evcc',
          installed: true,
          version: 'evcc/evcc:latest',
          detail: 'docker');
      final out = applyLatestEvccVersion([docker], '9.9.9');
      expect(out.first.updateAvailable, isFalse);
    });

    test('no-op on null/empty latest version, and other services untouched', () {
      final pihole = ServiceStatus(id: 'pihole', name: 'Pi-hole', installed: true);
      expect(applyLatestEvccVersion([evccApt('0.309.0'), pihole], null)
          .first.updateAvailable, isFalse);
      expect(applyLatestEvccVersion([evccApt('0.309.0'), pihole], '')
          .first.updateAvailable, isFalse);
    });
  });
}
