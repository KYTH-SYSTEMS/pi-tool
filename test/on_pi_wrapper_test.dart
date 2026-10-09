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

/// The wrapper fragment of the status probes of v0.71.0, character for
/// character (`git show v0.71.0:lib/src/on_pi_wrapper.dart`: wrapperProbeHead,
/// the unit, wrapperProbeTail with its stamp line). Phones on that version go
/// on sending it.
String _probeV071(String unit) =>
    'echo "WRAPPER \$(f=/usr/local/lib/$unit.sh; if [ -f "\$f" ]; then '
    'grep -qxF \'# pi-tool-wrapper 2\' "\$f" && echo current || echo old; '
    'else echo none; fi)"';

/// What v0.71.0 makes of the answer (its parseWrapperOutdated).
bool _outdatedV071(String statusOutput) =>
    statusOutput.split('\n').any((line) => line.trim() == 'WRAPPER old');

/// The first lines of the three wrappers v0.71.0 wrote (its install scripts,
/// `git show v0.71.0:lib/src/…`), each cut short — no test runs them.
const Map<String, String> _wrapperHeadV071 = {
  scheduledBackupUnit: '#!/bin/sh\n'
      '# pi-tool-wrapper 2\n'
      'mkdir -p /var/lib/pi-tool /var/backups/pi-tool\n',
  autoUpdateUnit: '#!/bin/bash\n'
      '# pi-tool-wrapper 2\n'
      'export DEBIAN_FRONTEND=noninteractive\n',
  alertsUnit: '#!/bin/sh\n'
      '# pi-tool-wrapper 2\n'
      'mkdir -p /var/lib/pi-tool\n'
      "URL='https://ntfy.sh'\n"
      "TOPIC='pi-tool-abc'\n",
};

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
  bool isStampLine(String line) => line.startsWith('# pi-tool-wrapper');

  group('wrapper stamp', () {
    test('every wrapper carries its own as its second line', () {
      for (final MapEntry(key: unit, value: script) in wrappers.entries) {
        final lines = _firstHeredoc(script).split('\n');
        expect(lines.first, startsWith('#!/bin/'), reason: unit);
        expect(lines[1], '# pi-tool-wrapper ${generations[unit]}',
            reason: unit);
        expect(stamps[unit]!.split('\n').first, lines[1], reason: unit);
      }
    });

    // v0.71.0 accepts no other line. A wrapper of generation 2 has it as its
    // own stamp, every later one right after its own.
    test('every wrapper carries the stamp line of v0.71.0, once', () {
      expect(wrapperStampOfV071, '# pi-tool-wrapper 2');
      for (final MapEntry(key: unit, value: script) in wrappers.entries) {
        final own = '# pi-tool-wrapper ${generations[unit]}';
        expect(_firstHeredoc(script).split('\n').where(isStampLine).toList(),
            {own, wrapperStampOfV071}.toList(),
            reason: unit);
        expect(stamps[unit]!.split('\n'), {own, wrapperStampOfV071}.toList(),
            reason: unit);
      }
    });

    test('every status probe asks for its own wrapper', () {
      final asked = RegExp(r'echo "WRAPPER \$\(f=/usr/local/lib/([\w-]+)\.sh;');
      for (final MapEntry(key: unit, value: probe) in probes.entries) {
        expect(asked.allMatches(probe).map((m) => m[1]), [unit], reason: unit);
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
    test('only a generation below the app\'s own counts', () {
      expect(parseWrapperOutdated('ENABLED enabled\nWRAPPER 2\n', 3), isTrue);
      // A wrapper without a stamp.
      expect(parseWrapperOutdated('WRAPPER 0\n', 2), isTrue);
      expect(parseWrapperOutdated('WRAPPER 3\n', 3), isFalse);
      expect(parseWrapperOutdated('WRAPPER 3\r\n', 3), isFalse);
      // Written by a newer app: this one has nothing to renew it with.
      expect(parseWrapperOutdated('WRAPPER 4\n', 3), isFalse);
      expect(parseWrapperOutdated('WRAPPER 10\n', 9), isFalse);
      expect(parseWrapperOutdated('WRAPPER 9\n', 10), isTrue);
      // No wrapper: nothing to renew.
      expect(parseWrapperOutdated('WRAPPER none\n', 3), isFalse);
      // A probe from before the line existed, or a cut-off answer.
      expect(parseWrapperOutdated('ENABLED enabled\nNEXT \n', 3), isFalse);
      expect(parseWrapperOutdated('WRAPPER \n', 3), isFalse);
      expect(parseWrapperOutdated('WRAPPER', 3), isFalse);
      expect(parseWrapperOutdated('', 3), isFalse);
      // Only a whole line with nothing but the number counts.
      expect(parseWrapperOutdated('STATUS WRAPPER 2 stuff\n', 3), isFalse);
      expect(parseWrapperOutdated('WRAPPER 2 x\n', 3), isFalse);
      expect(parseWrapperOutdated('WRAPPER -1\n', 3), isFalse);
      expect(parseWrapperOutdated('WRAPPER 2.5\n', 3), isFalse);
    });

    test('all three status parsers compare with the generation of their own '
        'wrapper', () {
      String out(int generation) => 'ENABLED enabled\nWRAPPER $generation\n';
      final parsers = <String, bool Function(String)>{
        scheduledBackupUnit: (o) =>
            parseScheduledBackupStatus(o).wrapperOutdated,
        autoUpdateUnit: (o) => parseAutoUpdateStatus(o).wrapperOutdated,
        alertsUnit: (o) => parseAlertsStatus(o).wrapperOutdated,
      };
      for (final MapEntry(key: unit, value: outdated) in parsers.entries) {
        final own = generations[unit]!;
        expect(outdated(out(own - 1)), isTrue, reason: unit);
        expect(outdated(out(own)), isFalse, reason: unit);
        expect(outdated(out(own + 1)), isFalse, reason: unit);
        expect(outdated('ENABLED enabled\nWRAPPER none\n'), isFalse,
            reason: unit);
      }
    });
  });

  // The probe in a real shell against the wrapper the install script writes —
  // the stamp and the grep have to agree to the character.
  group('status probe in bash', () {
    late Directory tmp;
    late String dir; // as bash sees it

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('wrapperprobe');
      // A stub for systemctl, put first in PATH inside the shell: the status
      // commands ask it as well (is-enabled, list-timers), and that must not
      // be this machine's.
      Directory('${tmp.path}/stubs').createSync();
      File('${tmp.path}/stubs/systemctl')
          .writeAsStringSync('#!/bin/sh\necho "\$*" >> "\$0.calls"\nexit 1\n');
      dir = (Process.runSync(
                  _bash!, ['-c', r'cd "$0" && chmod +x stubs/* && pwd', tmp.path])
              .stdout as String)
          .trim();
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    /// The WRAPPER line [command] prints when its wrappers lie in [tmp].
    Future<String> wrapperLine(String command) async {
      final r = await Process.run(_bash!, [
        '-c',
        'PATH="$dir/stubs:\$PATH"; '
            '${command.replaceAll('/usr/local/lib/', '$dir/')}',
      ]);
      return (r.stdout as String)
          .split('\n')
          .firstWhere((l) => l.startsWith('WRAPPER'), orElse: () => '');
    }

    Future<String> probe(String unit) => wrapperLine(probes[unit]!);
    Future<String> probeV071(String unit) => wrapperLine(_probeV071(unit));
    void put(String unit, String wrapper) =>
        File('${tmp.path}/$unit.sh').writeAsStringSync(wrapper);

    test('the status commands ask the stub, not this machine\'s systemd',
        () async {
      await probe(autoUpdateUnit);
      await probe(alertsUnit);
      expect(File('${tmp.path}/stubs/systemctl.calls').readAsLinesSync(), [
        'is-enabled $autoUpdateUnit.timer',
        'list-timers --all $autoUpdateUnit.timer --no-legend',
        'is-enabled $alertsUnit.timer',
      ]);
    });

    for (final unit in [scheduledBackupUnit, autoUpdateUnit, alertsUnit]) {
      final own = generations[unit]!;

      test('$unit: the freshly installed wrapper has the app\'s generation',
          () async {
        put(unit, '${_firstHeredoc(wrappers[unit]!)}\n');
        expect(await probe(unit), 'WRAPPER $own');
        expect(parseWrapperOutdated(await probe(unit), own), isFalse);
      });

      test('$unit: a wrapper without the stamp is generation 0, outdated',
          () async {
        put(unit, '#!/bin/sh\nmkdir -p /var/lib/pi-tool\n');
        expect(await probe(unit), 'WRAPPER 0');
        expect(parseWrapperOutdated(await probe(unit), own), isTrue);
      });

      test('$unit: every earlier generation is reported as it is, outdated',
          () async {
        for (var g = 1; g < own; g++) {
          put(unit, '#!/bin/sh\n# pi-tool-wrapper $g\n');
          expect(await probe(unit), 'WRAPPER $g');
          expect(parseWrapperOutdated(await probe(unit), own), isTrue,
              reason: 'generation $g');
        }
      });

      // The mistake behind the compatibility line: v0.71.0 asked for its own
      // stamp and called everything else old — also what came after it.
      test('$unit: a wrapper of a later generation is not outdated', () async {
        put(unit,
            '#!/bin/sh\n# pi-tool-wrapper ${own + 1}\n$wrapperStampOfV071\n');
        expect(await probe(unit), 'WRAPPER ${own + 1}');
        expect(parseWrapperOutdated(await probe(unit), own), isFalse);
      });

      test('$unit: the highest stamp counts, as a number and wherever it '
          'stands', () async {
        put(unit, '#!/bin/sh\n# pi-tool-wrapper 2\n# pi-tool-wrapper 10\n'
            '# pi-tool-wrapper 9\nexit 0\n');
        expect(await probe(unit), 'WRAPPER 10');
      });

      test('$unit: a stamp that is not the whole line does not count',
          () async {
        const stamp = '# pi-tool-wrapper 7';
        for (final line in [
          ' $stamp',
          '$stamp x',
          '$stamp ',
          'x$stamp',
          '$stamp.1',
          '# pi-tool-wrapper',
          '# pi-tool-wrapper ',
          '# pi-tool-wrapper x7',
          '#pi-tool-wrapper 7',
        ]) {
          put(unit, '#!/bin/sh\n$line\n');
          expect(await probe(unit), 'WRAPPER 0', reason: '"$line"');
        }
      });

      test('$unit: no wrapper at all', () async {
        expect(await probe(unit), 'WRAPPER none');
        expect(parseWrapperOutdated(await probe(unit), own), isFalse);
      });
    }

    // ---- a phone still on v0.71.0 next to one on this version ----

    // The premise: the probe of v0.71.0 as quoted above does tell wrappers
    // apart, by exactly one line.
    test('the probe of v0.71.0 knows its own stamp and nothing else', () async {
      const unit = autoUpdateUnit;
      expect(await probeV071(unit), 'WRAPPER none');
      put(unit, _wrapperHeadV071[unit]!);
      expect(await probeV071(unit), 'WRAPPER current');
      for (final other in [
        '#!/bin/sh\nmkdir -p /var/lib/pi-tool\n',
        '#!/bin/bash\n# pi-tool-wrapper 3\n',
        '#!/bin/bash\n# pi-tool-wrapper 20\n',
      ]) {
        put(unit, other);
        expect(await probeV071(unit), 'WRAPPER old', reason: other);
        expect(_outdatedV071(await probeV071(unit)), isTrue);
      }
    });

    // Otherwise that phone shows its hint, and following it writes the
    // wrapper of v0.71.0 back over this one.
    for (final unit in [scheduledBackupUnit, autoUpdateUnit, alertsUnit]) {
      test('$unit: v0.71.0 calls the wrapper this version installs current',
          () async {
        put(unit, '${_firstHeredoc(wrappers[unit]!)}\n');
        expect(await probeV071(unit), 'WRAPPER current');
        expect(_outdatedV071(await probeV071(unit)), isFalse);
      });
    }

    // What v0.71.0 wrote: generation 2 in all three.
    for (final (unit, outdated) in [
      (scheduledBackupUnit, false),
      (autoUpdateUnit, true),
      (alertsUnit, true),
    ]) {
      test('$unit: the wrapper v0.71.0 installed is generation 2 — '
          '${outdated ? 'outdated' : 'the one of this version'}', () async {
        put(unit, _wrapperHeadV071[unit]!);
        expect(await probe(unit), 'WRAPPER 2');
        expect(parseWrapperOutdated(await probe(unit), generations[unit]!),
            outdated);
        // And v0.71.0 itself has nothing to renew there.
        expect(await probeV071(unit), 'WRAPPER current');
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
                'ENABLED enabled\nONCALENDAR $onCalendar\nWRAPPER 3\n'),
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

    // A wrapper that is running keeps reading the file it opened. Rewritten in
    // place, its shell would go on at the old offset in the new text — as
    // root, in the middle of some other line. Put into place as a new file,
    // the run in progress keeps the old one to its end.
    for (final t in timers) {
      test('${t.unit}: setting up again replaces the wrapper instead of '
          'rewriting the file a run in progress reads', () async {
        final wrapper = '/usr/local/lib/${t.unit}.sh';
        Future<String> inode() async =>
            (await pi.run("stat -c %i '${pi.root}$wrapper'", rebase: false))
                .out
                .trim();
        pi.put(wrapper, '#!/bin/sh\n# the wrapper of an earlier setup\n');
        final before = await inode();
        expect(before, matches(r'^\d+$'));

        // Under a root umask that keeps files to their owner: the status
        // probes read wrapper and timer unit without sudo.
        final r = await pi.run('umask 077\n${t.install}');
        expect(r.code, 0, reason: r.err);
        expect(r.lines.last, t.installed);

        expect(await inode(), isNot(before));
        expect(pi.read(wrapper).split('\n')[1],
            '# pi-tool-wrapper ${generations[t.unit]}');
        expect(pi.exists('$wrapper.new'), isFalse);
        // Git Bash does not keep POSIX modes; the Linux run does.
        if (!Platform.isWindows) {
          expect(await pi.mode(wrapper), '755');
          expect(await pi.mode('/etc/systemd/system/${t.unit}.timer'), '644');
          expect(await pi.mode('/etc/systemd/system/${t.unit}.service'), '644');
        }
      });
    }

    // Two phones, one Pi. The whole way: the wrapper v0.71.0 left behind, the
    // install script as this version sends it, then the probes as either
    // phone sends them — plain commands, no sudo.
    for (final t in timers) {
      test('${t.unit}: set up over the wrapper of v0.71.0, neither this '
          'version nor v0.71.0 has anything to renew', () async {
        final own = generations[t.unit]!;
        pi.put('/usr/local/lib/${t.unit}.sh', _wrapperHeadV071[t.unit]!);
        var probe = await pi.run(probes[t.unit]!);
        expect(probe.lines, contains('WRAPPER 2'));
        expect(parseWrapperOutdated(probe.out, own), own > 2);

        final r = await pi.run(t.install);
        expect(r.lines.last, t.installed, reason: r.err);

        probe = await pi.run(probes[t.unit]!);
        expect(probe.lines, contains('WRAPPER $own'));
        expect(parseWrapperOutdated(probe.out, own), isFalse);
        final probeOfV071 = await pi.run(_probeV071(t.unit));
        expect(probeOfV071.lines, ['WRAPPER current']);
        expect(_outdatedV071(probeOfV071.out), isFalse);
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
