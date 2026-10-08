import 'dart:io';

import 'package:evcc_updater/src/alerts.dart';
import 'package:evcc_updater/src/auto_update.dart';
import 'package:evcc_updater/src/on_pi_wrapper.dart';
import 'package:evcc_updater/src/scheduled_backup.dart';
import 'package:flutter_test/flutter_test.dart';

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

  group('wrapper stamp', () {
    test('every wrapper carries it as its second line', () {
      for (final MapEntry(key: unit, value: script) in wrappers.entries) {
        final lines = _firstHeredoc(script).split('\n');
        expect(lines.first, startsWith('#!/bin/'), reason: unit);
        expect(lines[1], wrapperStampLine, reason: unit);
      }
      expect(wrapperStampLine, '# pi-tool-wrapper $wrapperGeneration');
    });

    test('every status probe asks for its own wrapper', () {
      for (final MapEntry(key: unit, value: probe) in probes.entries) {
        expect(probe, contains('f=/usr/local/lib/$unit.sh;'), reason: unit);
        expect(probe, contains("grep -qxF '$wrapperStampLine'"), reason: unit);
      }
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

      test('$unit: an earlier generation is old', () async {
        File('${tmp.path}/$unit.sh')
            .writeAsStringSync('#!/bin/sh\n# pi-tool-wrapper 1\n');
        expect(await probe(unit), 'WRAPPER old');
      });

      test('$unit: no wrapper at all', () async {
        expect(await probe(unit), 'WRAPPER none');
      });
    }
  }, skip: _bash == null ? 'needs bash (PITOOL_TEST_BASH on Windows)' : false);
}
