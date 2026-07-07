import 'package:evcc_updater/src/alerts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildAlertsInstallScript', () {
    final s = buildAlertsInstallScript(
        ntfyServer: 'https://ntfy.sh', ntfyTopic: 'my-pi-42');
    test('installs a timer that checks health + pushes via ntfy', () {
      expect(s, contains("URL='https://ntfy.sh'"));
      expect(s, contains("TOPIC='my-pi-42'"));
      expect(s, contains('curl')); // sends the push
      expect(s, contains('df ')); // disk check
      expect(s, contains('is-active')); // service check
      expect(s, contains('thermal_zone0')); // temperature
      expect(s, contains('enable --now pi-tool-alerts.timer'));
      expect(s, contains('OnCalendar='));
      expect(s, contains('ALERTS_INSTALLED'));
    });
    test('only alerts on a CHANGE (debounced via a state file, no spam)', () {
      expect(s, contains('/var/lib/pi-tool/alerts.last'));
    });
    test('single-quotes a hostile topic (no injection)', () {
      final bad = buildAlertsInstallScript(
          ntfyServer: 'https://ntfy.sh', ntfyTopic: "x';reboot;'");
      expect(bad, contains(r"'\''"));
      expect(bad, isNot(contains("TOPIC='x';reboot")));
    });
  });

  group('buildAlertsRemoveScript', () {
    final s = buildAlertsRemoveScript();
    test('disables + removes the timer', () {
      expect(s, contains('disable --now pi-tool-alerts.timer'));
      expect(s, contains('rm -f'));
      expect(s, contains('ALERTS_REMOVED'));
    });
  });

  group('buildTestAlertCommand', () {
    test('sends a test push to server/topic, shell-quoted', () {
      final c = buildTestAlertCommand(
          ntfyServer: 'https://ntfy.sh', ntfyTopic: 'my-pi-42');
      expect(c, contains('curl'));
      expect(c, contains("'https://ntfy.sh/my-pi-42'"));
    });
    test('quotes a hostile topic', () {
      final c = buildTestAlertCommand(
          ntfyServer: 'https://ntfy.sh', ntfyTopic: "a';reboot;'");
      expect(c, contains(r"'\''"));
      expect(c, isNot(contains("/a';reboot")));
    });
  });

  group('parseAlertsStatus', () {
    test('reads enabled state + last check', () {
      const out = 'ENABLED enabled\nLAST 2026-07-07 12:00 checked\n';
      final st = parseAlertsStatus(out);
      expect(st.enabled, isTrue);
      expect(st.lastCheck, contains('2026-07-07'));
    });
    test('disabled / empty defaults', () {
      expect(parseAlertsStatus('ENABLED disabled\nLAST \n').enabled, isFalse);
      expect(parseAlertsStatus('').enabled, isFalse);
      expect(parseAlertsStatus('').lastCheck, isNull);
    });
  });
}
