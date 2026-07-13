import 'package:evcc_updater/src/systemd_services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseSystemdState', () {
    test('loaded + active', () {
      final s = parseSystemdState('LoadState=loaded\nActiveState=active\n');
      expect(s.installed, isTrue);
      expect(s.active, isTrue);
    });

    test('loaded but stopped = installed, inactive', () {
      final s =
          parseSystemdState('LoadState=loaded\nActiveState=inactive\n');
      expect(s.installed, isTrue);
      expect(s.active, isFalse);
    });

    test('not-found = not installed', () {
      final s = parseSystemdState('LoadState=not-found\nActiveState=inactive\n');
      expect(s.installed, isFalse);
    });

    test('garbled → not installed, no crash', () {
      expect(parseSystemdState('nonsense').installed, isFalse);
    });
  });

  group('knownSystemdServices', () {
    test('covers the three services with unit + web port', () {
      final ids = knownSystemdServices.map((s) => s.id).toList();
      expect(ids, containsAll(['adguard', 'nodered', 'zigbee2mqtt']));
      final ag = knownSystemdServices.firstWhere((s) => s.id == 'adguard');
      expect(ag.unit, 'AdGuardHome');
      expect(ag.webPort, 3000);
    });

    test('systemdStateCommand queries LoadState + ActiveState (no sudo)', () {
      final c = systemdStateCommand('nodered');
      expect(c, contains('systemctl show'));
      expect(c, contains('LoadState'));
      expect(c, contains('ActiveState'));
      expect(c, contains('nodered'));
      expect(c, isNot(contains('sudo')));
    });
  });
}
