import 'package:evcc_updater/src/scheduled_backup.dart';
import 'package:flutter_test/flutter_test.dart';

import 'on_pi_sandbox.dart';

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

    test('every schedule the sheet can produce is accepted', () {
      for (var hour = 0; hour < 24; hour++) {
        buildScheduledBackupInstallScript(
            onCalendar: scheduledBackupOnCalendar(hour: hour), keep: 7);
      }
    });

    test('anything else is refused: the value lands in a unit file inside a '
        'root heredoc', () {
      for (final bad in [
        'x',
        '',
        '*-*-* 3:00',
        '*-*-* 03:00:00\nTMR\nreboot',
      ]) {
        expect(
            () => buildScheduledBackupInstallScript(onCalendar: bad, keep: 7),
            throwsArgumentError,
            reason: bad);
      }
    });
  });

  // The wrapper as the install script writes it, run under its own shebang on
  // a sandboxed Pi. More cases (tar failures, rotation, the Pi-hole
  // generations) are in backup_scripts_test.dart.
  group('scheduled backup wrapper in bash', () {
    late PiSandbox pi;
    const wrapper = '/usr/local/lib/$scheduledBackupUnit.sh';
    const dir = '/var/backups/pi-tool';

    setUp(() async {
      pi = PiSandbox();
      pi.stub('systemctl', 'exit 0');
      final r = await pi.run(buildScheduledBackupInstallScript(
          onCalendar: '*-*-* 03:00:00', keep: 2));
      expect(r.code, 0, reason: r.err);
      expect(r.lines.last, 'BACKUP_TIMER_INSTALLED');
      pi.clearCalls();
    });
    tearDown(() => pi.dispose());

    /// One run of the timer — under the wrapper's shebang, or under [shell];
    /// returns the status line it left.
    Future<String> runWrapper({String? shell}) async {
      final r = await pi.run(
          "${shell == null ? '' : "'$shell' "}'${pi.root}$wrapper'",
          rebase: false);
      expect(r.code, 0, reason: r.err);
      expect(r.err, isEmpty);
      return pi.read('/var/lib/pi-tool/backup.status').trim();
    }

    test('no /etc/evcc.yaml (evcc set up in the web UI): the state is archived',
        () async {
      pi.put('/var/lib/evcc/evcc.db', 'DB');
      final st = await runWrapper();
      expect(pi.ls(dir),
          [matches(RegExp(r'^sched-evcc-\d{8}-\d{6}\.tar\.gz$'))]);
      expect(st, matches(RegExp('^$statusTime ok: evcc\$')));
    });

    test('neither evcc nor Pi-hole: nothing is written, the status says so',
        () async {
      final st = await runWrapper();
      expect(pi.ls(dir), isEmpty);
      expect(st, matches(RegExp('^$statusTime ok: nichts\$')));
      // The wrapper asked for nothing beyond its plain tools.
      expect(pi.calls, isEmpty);
    });

    test('Pi-hole is there but exports nothing: named as a failure, evcc is '
        'saved all the same', () async {
      pi.put('/etc/evcc.yaml', 'site: x\n');
      pi.stub('pihole', 'echo "Usage: pihole [options]"');
      pi.stub('pihole-FTL', 'exit 1');
      final st = await runWrapper();
      expect(pi.ls(dir), hasLength(1));
      expect(
          st,
          matches(RegExp(
              '^$statusTime fehler: pihole\\(kein-archiv\\); ok: evcc\$')));
    });

    test('under dash — the /bin/sh of a Pi — the wrapper does the same',
        () async {
      pi.put('/etc/evcc.yaml', 'site: x\n');
      pi.put('/var/lib/evcc/evcc.db', 'DB');
      pi.stub('pihole', 'echo "Usage: pihole [options]"');
      pi.stub('pihole-FTL',
          r'[ "$1" = --teleporter ] && echo ZIP > "pi-hole_teleporter.zip"');
      final st = await runWrapper(shell: sandboxDash);
      expect(pi.ls(dir), [
        matches(RegExp(r'^sched-evcc-\d{8}-\d{6}\.tar\.gz$')),
        matches(RegExp(r'^sched-pihole-\d{8}-\d{6}\.zip$')),
      ]);
      expect(st, matches(RegExp('^$statusTime ok: evcc pihole\$')));
    }, skip: needsDash);
  }, skip: needsBash);

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
