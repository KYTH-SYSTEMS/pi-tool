import 'dart:io';

import 'package:evcc_updater/src/alerts.dart';
import 'package:evcc_updater/src/auto_update.dart';
import 'package:evcc_updater/src/on_pi_wrapper.dart';
import 'package:evcc_updater/src/scheduled_backup.dart';
import 'package:flutter_test/flutter_test.dart';

import 'on_pi_sandbox.dart';

/// bash for the probe test. On Windows it must be named explicitly
/// (PITOOL_TEST_BASH=C:\Program Files\Git\bin\bash.exe).
final String? _bash =
    Platform.isWindows ? Platform.environment['PITOOL_TEST_BASH'] : 'bash';

/// The wrapper as the install script writes it: the body of its first heredoc.
String _firstHeredoc(String installScript) {
  const open = "<<'WRAP'\n";
  final start = installScript.indexOf(open) + open.length;
  return installScript.substring(start, installScript.indexOf('\nWRAP', start));
}

void main() {
  final wrappers = {
    scheduledBackupUnit: buildScheduledBackupInstallScript(
        onCalendar: scheduledBackupOnCalendar(hour: 3), keep: 7),
    autoUpdateUnit: buildAutoUpdateInstallScript(
        onCalendar: autoUpdateOnCalendar(weekly: false, hour: 4)),
    alertsUnit: buildAlertsInstallScript(
        ntfyServer: 'https://ntfy.sh', ntfyTopic: 'pi-tool-abc'),
  };
  final probes = {
    scheduledBackupUnit: scheduledBackupStatusCommand,
    autoUpdateUnit: autoUpdateStatusCommand,
    alertsUnit: alertsStatusCommand,
  };
  // Each wrapper has a generation of its own.
  const generations = {
    scheduledBackupUnit: scheduledBackupWrapperGeneration,
    autoUpdateUnit: autoUpdateWrapperGeneration,
    alertsUnit: alertsWrapperGeneration,
  };
  const stamps = {
    scheduledBackupUnit: scheduledBackupWrapperStamp,
    autoUpdateUnit: autoUpdateWrapperStamp,
    alertsUnit: alertsWrapperStamp,
  };

  group('wrapper stamp', () {
    test('every wrapper carries its own as its second line', () {
      for (final MapEntry(key: unit, value: script) in wrappers.entries) {
        final lines = _firstHeredoc(script).split('\n');
        expect(lines.first, startsWith('#!/bin/'), reason: unit);
        expect(lines[1], stamps[unit], reason: unit);
        expect(stamps[unit], '# pi-tool-wrapper ${generations[unit]}',
            reason: unit);
      }
    });

    test('every status probe asks for its own wrapper and its own stamp', () {
      for (final MapEntry(key: unit, value: probe) in probes.entries) {
        expect(probe, contains('f=/usr/local/lib/$unit.sh;'), reason: unit);
        expect(probe, contains("grep -qxF '${stamps[unit]}'"), reason: unit);
      }
    });

    // Compared with tag v0.71.0, which wrote generation 2 into all three: the
    // alerts and the auto-update wrapper changed since, the backup wrapper
    // did not. A hint to set the backup timer up again would change nothing.
    test('only the wrappers that changed since v0.71.0 moved on', () {
      expect(generations, {
        scheduledBackupUnit: 2,
        autoUpdateUnit: 3,
        alertsUnit: 3,
      });
    });
  });

  group('parseWrapperOutdated', () {
    test('only "old" counts', () {
      expect(parseWrapperOutdated('ENABLED enabled\nWRAPPER old\n'), isTrue);
      expect(parseWrapperOutdated('WRAPPER current\n'), isFalse);
      // No wrapper: nothing to renew.
      expect(parseWrapperOutdated('WRAPPER none\n'), isFalse);
      // A probe from before the line existed, or a cut-off answer.
      expect(parseWrapperOutdated('ENABLED enabled\nNEXT \n'), isFalse);
      expect(parseWrapperOutdated(''), isFalse);
      // Only a whole line counts, not the word in a status text.
      expect(parseWrapperOutdated('STATUS WRAPPER old stuff\n'), isFalse);
    });

    test('all three status parsers pass it on', () {
      const old = 'ENABLED enabled\nWRAPPER old\n';
      const current = 'ENABLED enabled\nWRAPPER current\n';
      expect(parseScheduledBackupStatus(old).wrapperOutdated, isTrue);
      expect(parseScheduledBackupStatus(current).wrapperOutdated, isFalse);
      expect(parseAutoUpdateStatus(old).wrapperOutdated, isTrue);
      expect(parseAutoUpdateStatus(current).wrapperOutdated, isFalse);
      expect(parseAlertsStatus(old).wrapperOutdated, isTrue);
      expect(parseAlertsStatus(current).wrapperOutdated, isFalse);
    });
  });

  // The probe in a real shell against the wrapper the install script writes —
  // the stamp and the grep have to agree to the character.
  group('status probe in bash', () {
    late Directory tmp;
    late String dir; // as bash sees it

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('wrapperprobe');
      dir = (Process.runSync(_bash!, ['-c', r'cd "$0" && pwd', tmp.path]).stdout
              as String)
          .trim();
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<String> probe(String unit) async {
      final r = await Process.run(_bash!, [
        '-c',
        probes[unit]!.replaceAll('/usr/local/lib/', '$dir/'),
      ]);
      return (r.stdout as String)
          .split('\n')
          .firstWhere((l) => l.startsWith('WRAPPER '), orElse: () => '');
    }

    for (final unit in [scheduledBackupUnit, autoUpdateUnit, alertsUnit]) {
      test('$unit: the freshly installed wrapper is current', () async {
        File('${tmp.path}/$unit.sh')
            .writeAsStringSync('${_firstHeredoc(wrappers[unit]!)}\n');
        expect(await probe(unit), 'WRAPPER current');
        expect(parseWrapperOutdated(await probe(unit)), isFalse);
      });

      test('$unit: a wrapper without the stamp is old', () async {
        File('${tmp.path}/$unit.sh')
            .writeAsStringSync('#!/bin/sh\nmkdir -p /var/lib/pi-tool\n');
        expect(await probe(unit), 'WRAPPER old');
      });

      test('$unit: every earlier generation is old', () async {
        for (var g = 1; g < generations[unit]!; g++) {
          File('${tmp.path}/$unit.sh')
              .writeAsStringSync('#!/bin/sh\n# pi-tool-wrapper $g\n');
          expect(await probe(unit), 'WRAPPER old', reason: 'generation $g');
        }
      });

      test('$unit: a stamp that is not the whole line does not count',
          () async {
        final stamp = stamps[unit]!;
        for (final line in ['${stamp}0', ' $stamp', '$stamp x', 'x$stamp']) {
          File('${tmp.path}/$unit.sh').writeAsStringSync('#!/bin/sh\n$line\n');
          expect(await probe(unit), 'WRAPPER old', reason: line);
        }
      });

      test('$unit: no wrapper at all', () async {
        expect(await probe(unit), 'WRAPPER none');
      });
    }

    // What v0.71.0 wrote into every wrapper.
    for (final (unit, state) in [
      (scheduledBackupUnit, 'current'),
      (autoUpdateUnit, 'old'),
      (alertsUnit, 'old'),
    ]) {
      test('$unit: the wrapper v0.71.0 installed (generation 2) is $state',
          () async {
        File('${tmp.path}/$unit.sh')
            .writeAsStringSync('#!/bin/sh\n# pi-tool-wrapper 2\n');
        expect(await probe(unit), 'WRAPPER $state');
        expect(parseWrapperOutdated(await probe(unit)), state == 'old');
      });
    }
  }, skip: _bash == null ? 'needs bash (PITOOL_TEST_BASH on Windows)' : false);

  group('parseInstalledOnCalendar', () {
    test('hands on every schedule the app builds, as written', () {
      for (final onCalendar in [
        '*-*-* 03:00:00',
        '*-*-* 23:00:00',
        'Mon *-*-* 05:00:00',
        'Sun *-*-* 04:00:00',
      ]) {
        expect(
            parseInstalledOnCalendar(
                'ENABLED enabled\nONCALENDAR $onCalendar\nWRAPPER current\n'),
            onCalendar);
      }
      // A unit file with DOS line ends.
      expect(parseInstalledOnCalendar('ONCALENDAR *-*-* 03:00:00\r\n'),
          '*-*-* 03:00:00');
    });

    test('nothing installed, nothing readable, nothing the app builds: null',
        () {
      for (final out in [
        '',
        'ENABLED disabled\nNEXT \nSTATUS \nWRAPPER none\n',
        // The probe ran, the unit is missing or unreadable.
        'ONCALENDAR \n',
        'ONCALENDAR\n',
        // Edited by hand.
        'ONCALENDAR daily\n',
        'ONCALENDAR *-*-* 04:00\n',
        'ONCALENDAR Mon,Thu *-*-* 04:00:00\n',
        // Only a line of its own counts.
        'STATUS ONCALENDAR *-*-* 03:00:00\n',
      ]) {
        expect(parseInstalledOnCalendar(out), isNull, reason: out);
      }
    });
  });

  group('checkOnCalendar', () {
    test('passes every schedule the app builds, unchanged', () {
      for (var hour = 0; hour < 24; hour++) {
        final daily = scheduledBackupOnCalendar(hour: hour);
        expect(checkOnCalendar(daily), daily);
        expect(checkOnCalendar(autoUpdateOnCalendar(weekly: false, hour: hour)),
            daily);
        for (var day = 1; day <= 7; day++) {
          final weekly =
              autoUpdateOnCalendar(weekly: true, hour: hour, weekday: day);
          expect(checkOnCalendar(weekly), weekly);
        }
      }
    });

    test('refuses everything else', () {
      for (final bad in [
        '',
        'x',
        'daily',
        '*-*-* 04:00',
        '*-*-* 24:00:00',
        '*-*-* 04:60:00',
        'Sonntag *-*-* 04:00:00',
        'Sun  *-*-* 04:00:00',
        ' *-*-* 04:00:00',
        '*-*-* 04:00:00 ',
        '*-*-* 04:00:00\n',
        '*-*-* 04:00:00\nTMR\nreboot',
      ]) {
        expect(() => checkOnCalendar(bad), throwsArgumentError, reason: bad);
      }
    });
  });

  // A started Persistent=true timer triggers at once when a run was due since
  // the time in its stamp file. systemd itself is a stub here: what is proven
  // is which steps the scripts take, in which order — not what systemd makes
  // of them.
  group('timer install and remove in bash', () {
    late PiSandbox pi;

    setUp(() {
      pi = PiSandbox();
      // Logs each call with whether a stamp file exists at that moment.
      pi.stub('systemctl', r'''
if ls "$R"/var/lib/systemd/timers/stamp-* >/dev/null 2>&1; then s=stamp; else s=no-stamp; fi
echo "systemctl $* [$s]" >> "$S/calls"
exit 0''', log: false);
    });
    tearDown(() => pi.dispose());

    final timers = [
      (
        unit: autoUpdateUnit,
        install: wrappers[autoUpdateUnit]!,
        remove: buildAutoUpdateRemoveScript(),
        installed: 'AUTOUPDATE_INSTALLED',
        removed: 'AUTOUPDATE_REMOVED',
      ),
      (
        unit: scheduledBackupUnit,
        install: wrappers[scheduledBackupUnit]!,
        remove: buildScheduledBackupRemoveScript(),
        installed: 'BACKUP_TIMER_INSTALLED',
        removed: 'BACKUP_TIMER_REMOVED',
      ),
      (
        unit: alertsUnit,
        install: wrappers[alertsUnit]!,
        remove: buildAlertsRemoveScript(),
        installed: 'ALERTS_INSTALLED',
        removed: 'ALERTS_REMOVED',
      ),
    ];

    for (final t in timers) {
      final stamp = '/var/lib/systemd/timers/stamp-${t.unit}.timer';

      test('${t.unit}: removing takes systemd\'s stamp along', () async {
        expect((await pi.run(t.install)).code, 0);
        pi.put(stamp, '');
        pi.clearCalls();
        final r = await pi.run(t.remove);
        expect(r.code, 0, reason: r.err);
        expect(r.lines.last, t.removed);
        expect(pi.exists(stamp), isFalse);
        expect(timerStampPath(t.unit), stamp);
        expect(pi.calls, [
          'systemctl disable --now ${t.unit}.timer [stamp]',
          'systemctl daemon-reload [no-stamp]',
        ]);
      });
    }

    // An upgrade started the moment the user taps is the one harmful case.
    test('$autoUpdateUnit: setting up drops the stamp, stops the timer and '
        'notes the time — all before the reload', () async {
      const stamp = '/var/lib/systemd/timers/stamp-$autoUpdateUnit.timer';
      pi.put(stamp, '');
      final before = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final r = await pi.run(wrappers[autoUpdateUnit]!);
      expect(r.code, 0, reason: r.err);
      expect(r.lines.last, 'AUTOUPDATE_INSTALLED');
      expect(pi.calls, [
        'systemctl stop $autoUpdateUnit.timer [no-stamp]',
        'systemctl daemon-reload [no-stamp]',
        'systemctl enable --now $autoUpdateUnit.timer [no-stamp]',
      ]);
      // Not written back by the script either: its mtime means "last run".
      expect(pi.exists(stamp), isFalse);
      final noted = int.parse(pi.read(autoUpdateSetupPath).trim());
      expect(noted, inInclusiveRange(before - 2, before + 120));
    });

    test('$autoUpdateUnit: a stamp that cannot be removed (read-only root) '
        'ends the setup without the marker — and without stopping the timer',
        () async {
      pi.stub('rm', 'exit 1');
      final r = await pi.run(wrappers[autoUpdateUnit]!);
      expect(r.code, isNot(0));
      expect(r.out, isNot(contains('AUTOUPDATE_INSTALLED')));
      expect(pi.calls.where((c) => c.startsWith('systemctl ')), isEmpty);
    });

    // A health check or one more archive at once does no harm: these two
    // timers are not stopped, and a stamp that is there stays.
    for (final t in timers.where((t) => t.unit != autoUpdateUnit)) {
      test('${t.unit}: setting up again leaves the running timer alone',
          () async {
        final stamp = '/var/lib/systemd/timers/stamp-${t.unit}.timer';
        pi.put(stamp, '');
        final r = await pi.run(t.install);
        expect(r.code, 0, reason: r.err);
        expect(r.lines.last, t.installed);
        expect(pi.calls, [
          'systemctl daemon-reload [stamp]',
          'systemctl enable --now ${t.unit}.timer [stamp]',
        ]);
        expect(pi.exists(stamp), isTrue);
      });
    }
  }, skip: needsBash);
}
