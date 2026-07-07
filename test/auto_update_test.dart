import 'package:evcc_updater/src/auto_update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('autoUpdateOnCalendar', () {
    test('daily at a padded hour', () {
      expect(autoUpdateOnCalendar(weekly: false, hour: 4), '*-*-* 04:00:00');
      expect(autoUpdateOnCalendar(weekly: false, hour: 22), '*-*-* 22:00:00');
    });
    test('weekly maps the weekday to a systemd day name', () {
      expect(autoUpdateOnCalendar(weekly: true, hour: 3, weekday: 7),
          'Sun *-*-* 03:00:00');
      expect(autoUpdateOnCalendar(weekly: true, hour: 5, weekday: 1),
          'Mon *-*-* 05:00:00');
    });
  });

  group('buildAutoUpdateInstallScript', () {
    final s = buildAutoUpdateInstallScript(onCalendar: '*-*-* 04:00:00');
    test('installs a timer with the given schedule + enables it', () {
      expect(s, contains('OnCalendar=*-*-* 04:00:00'));
      expect(s, contains('systemctl daemon-reload'));
      expect(s, contains('enable --now pi-tool-autoupdate.timer'));
      expect(s, contains('AUTOUPDATE_INSTALLED'));
    });
    test('the wrapper updates apt, self-heals evcc, and logs a result', () {
      expect(s, contains('apt-get update'));
      expect(s, contains('full-upgrade'));
      // Unattended: must not hang on a dpkg conffile prompt.
      expect(s, contains('DEBIAN_FRONTEND=noninteractive'));
      expect(s, contains('force-confold'));
      // backup evcc before + bring it back if it dies during the upgrade
      expect(s, contains('systemctl is-active evcc'));
      expect(s, contains('/var/backups/pi-tool'));
      expect(s, contains('/var/lib/pi-tool/autoupdate.status'));
    });
  });

  group('buildAutoUpdateRemoveScript', () {
    final s = buildAutoUpdateRemoveScript();
    test('disables + removes the timer and reloads', () {
      expect(s, contains('disable --now pi-tool-autoupdate.timer'));
      expect(s, contains('rm -f'));
      expect(s, contains('systemctl daemon-reload'));
      expect(s, contains('AUTOUPDATE_REMOVED'));
    });
  });

  group('parseAutoUpdateStatus', () {
    test('reads enabled state, next run and last result', () {
      const out = 'ENABLED enabled\n'
          'NEXT Sun 2026-07-12 04:00:00\n'
          'STATUS 2026-07-05 04:00:12 ok\n';
      final st = parseAutoUpdateStatus(out);
      expect(st.enabled, isTrue);
      expect(st.nextRun, contains('2026-07-12'));
      expect(st.lastResult, '2026-07-05 04:00:12 ok');
    });
    test('disabled / never-run yields sensible defaults', () {
      final st = parseAutoUpdateStatus('ENABLED disabled\nNEXT \nSTATUS \n');
      expect(st.enabled, isFalse);
      expect(st.nextRun, isNull);
      expect(st.lastResult, isNull);
    });
    test('empty output → disabled, nothing known', () {
      final st = parseAutoUpdateStatus('');
      expect(st.enabled, isFalse);
      expect(st.nextRun, isNull);
      expect(st.lastResult, isNull);
    });
  });
}
