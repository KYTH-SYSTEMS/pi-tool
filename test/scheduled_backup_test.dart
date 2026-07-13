import 'package:evcc_updater/src/scheduled_backup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('scheduledBackupOnCalendar', () {
    test('daily at the given hour', () {
      expect(scheduledBackupOnCalendar(hour: 3), '*-*-* 03:00:00');
      expect(scheduledBackupOnCalendar(hour: 23), '*-*-* 23:00:00');
    });
  });

  group('buildScheduledBackupInstallScript', () {
    final s = buildScheduledBackupInstallScript(
        onCalendar: '*-*-* 03:00:00', keep: 7);

    test('installs a timer + wrapper and ends with the marker', () {
      expect(s, contains('/etc/systemd/system/$scheduledBackupUnit.timer'));
      expect(s, contains('OnCalendar=*-*-* 03:00:00'));
      expect(s, contains('systemctl enable --now $scheduledBackupUnit.timer'));
      expect(s.trimRight(), endsWith('BACKUP_TIMER_INSTALLED'));
    });

    test('the wrapper + .timer heredocs are QUOTED (no install-time expansion)',
        () {
      expect(s, contains("<<'WRAP'"));
      expect(s, contains("<<'TMR'"));
    });

    test('backs up evcc + Pi-hole (presence-gated) with rotation by keep', () {
      expect(s, contains('sched-evcc-'));
      expect(s, contains('/etc/evcc.yaml'));
      expect(s, contains('pihole -a -t'));
      expect(s, contains('sched-pihole-'));
      // keep=7 → keep the 7 newest, delete from the 8th on.
      expect(s, contains('tail -n +8'));
    });

    test('evcc backup is atomic (.part + mv) — a failed tar cannot evict a '
        'good backup on rotation', () {
      expect(s, contains(r'"$out.part"'));
      expect(s, contains(r'mv "$out.part" "$out"'));
      // Rotation glob is specific so the .part temp is never counted.
      expect(s, contains('sched-evcc-*.tar.gz'));
      expect(s, contains(r'rm -f "$out.part"')); // dropped on failure
    });

    test('writes a status line the app can read', () {
      expect(s, contains('/var/lib/pi-tool/backup.status'));
    });
  });

  group('buildScheduledBackupRemoveScript', () {
    test('disables + removes the unit, ends with the marker', () {
      final r = buildScheduledBackupRemoveScript();
      expect(r, contains('systemctl disable --now $scheduledBackupUnit.timer'));
      expect(r.trimRight(), endsWith('BACKUP_TIMER_REMOVED'));
    });
  });

  group('parseScheduledBackupStatus', () {
    test('parses enabled/next/last', () {
      const out = 'ENABLED enabled\n'
          'NEXT Fri 2026-07-18 03:00:00\n'
          'STATUS 2026-07-17 03:00:01 ok: evcc pihole\n';
      final st = parseScheduledBackupStatus(out);
      expect(st.enabled, isTrue);
      expect(st.nextRun, contains('2026-07-18'));
      expect(st.lastResult, contains('evcc'));
    });

    test('disabled + no status', () {
      final st = parseScheduledBackupStatus('ENABLED disabled\nNEXT \nSTATUS \n');
      expect(st.enabled, isFalse);
      expect(st.nextRun, isNull);
      expect(st.lastResult, isNull);
    });
  });
}
