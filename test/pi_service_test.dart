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
}
