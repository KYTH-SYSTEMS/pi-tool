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

    test('a successful compare restores certainty lost to a stale apt index',
        () {
      // Stale index → detection could not tell (updateKnown false). GitHub
      // answering "you are current" IS knowledge, so the card may show
      // "Aktuell ✓" instead of falling back to "Stand unbekannt".
      final stale = evccApt('0.310.0').copyWith(updateKnown: false);
      final out = applyLatestEvccVersion([stale], '0.310.0');
      expect(out.first.updateAvailable, isFalse);
      expect(out.first.updateKnown, isTrue);
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

  group('applyLatestHomeAssistantVersion', () {
    ServiceStatus ha(String? version) => ServiceStatus(
        id: 'homeassistant',
        name: 'Home Assistant',
        installed: true,
        version: version,
        active: true,
        detail: 'Docker · homeassistant');

    test('current calver → updateKnown, no update (card shows "Aktuell")', () {
      final out = applyLatestHomeAssistantVersion([ha('2026.6.3')], '2026.6.3');
      final s = out.first;
      expect(s.updateKnown, isTrue);
      expect(s.updateAvailable, isFalse);
    });

    test('older installed calver → update available', () {
      final out = applyLatestHomeAssistantVersion([ha('2026.5.1')], '2026.6.3');
      expect(out.first.updateAvailable, isTrue);
      expect(out.first.updateKnown, isTrue);
    });

    test('non-comparable tag (stable/latest) stays unknown', () {
      final out = applyLatestHomeAssistantVersion([ha('stable')], '2026.6.3');
      expect(out.first.updateKnown, isFalse);
    });

    test('no-op on null/empty latest', () {
      expect(applyLatestHomeAssistantVersion([ha('2026.6.3')], null)
          .first.updateKnown, isFalse);
      expect(applyLatestHomeAssistantVersion([ha('2026.6.3')], '')
          .first.updateKnown, isFalse);
    });
  });

  group('ServiceStatus JSON (Zwischenspeicher)', () {
    test('round-trips every field', () {
      const s = ServiceStatus(
          id: 'system',
          name: 'System (Pi)',
          installed: true,
          version: 'Debian 13',
          active: true,
          updateAvailable: true,
          updateKnown: true,
          detail: '3 Updates verfügbar',
          health: '48 °C',
          healthWarning: true,
          webPort: 3000,
          aptPackage: 'evcc',
          compatible: false);
      final b = ServiceStatus.fromJson(s.toJson());
      expect(b.id, s.id);
      expect(b.version, s.version);
      expect(b.updateAvailable, isTrue);
      expect(b.updateKnown, isTrue);
      expect(b.healthWarning, isTrue);
      expect(b.webPort, 3000);
      expect(b.aptPackage, 'evcc');
      expect(b.compatible, isFalse);
    });

    test('a half-written entry loads with safe defaults, it does not throw', () {
      final b = ServiceStatus.fromJson(const {'id': 'evcc'});
      expect(b.installed, isFalse);
      expect(b.updateAvailable, isFalse);
      expect(b.compatible, isTrue); // unbekannt heißt nicht "inkompatibel"
      expect(b.webPort, isNull);
    });
  });
}
