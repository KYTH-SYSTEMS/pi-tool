import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:evcc_updater/src/alerts.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shell for the real-bash group: `bash` on Linux/macOS (CI). On Windows
/// `bash` may be the WSL launcher, so it only runs with an explicit Git Bash
/// (PITOOL_TEST_BASH=C:\Program Files\Git\bin\bash.exe).
final String? _bash =
    Platform.isWindows ? Platform.environment['PITOOL_TEST_BASH'] : 'bash';

/// A path the sandbox bash understands (Git Bash wants /c/... on Windows).
String _posix(String p) {
  final s = p.replaceAll(r'\', '/');
  final m = RegExp(r'^([A-Za-z]):/').firstMatch(s);
  return m == null ? s : '/${m.group(1)!.toLowerCase()}/${s.substring(3)}';
}

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
    test('the .timer heredoc is QUOTED (no install-time shell expansion)', () {
      expect(s, contains("<<'TMR'"));
    });
    test('only alerts on a CHANGE (debounced via a state file, no spam)', () {
      expect(s, contains('/var/lib/pi-tool/alerts.last'));
    });
    test('checks for dying-SD symptoms (ro root + kernel I/O errors)', () {
      expect(s, contains('/proc/mounts')); // read-only-remount check
      expect(s, contains('nur-lesend'));
      expect(s, contains('journalctl -k')); // kernel-log error count
      expect(s, contains('I/O-Fehler'));
      // Runtime expansion, not install-time: the vars stay escaped in the
      // quoted heredoc (the Dart string carries them as literal $ for sh).
      expect(s, contains(r'$ioerr'));
    });
    test('single-quotes a hostile topic (no injection)', () {
      final bad = buildAlertsInstallScript(
          ntfyServer: 'https://ntfy.sh', ntfyTopic: "x';reboot;'");
      expect(bad, contains(r"'\''"));
      expect(bad, isNot(contains("TOPIC='x';reboot")));
    });
    test('newline-laden topic cannot break out of the quoted heredoc', () {
      // A value carrying a line == the heredoc terminator ('WRAP') plus a
      // command would close the heredoc early and run as root. Newlines are
      // stripped, so no bare terminator line and no injected command appear.
      final bad = buildAlertsInstallScript(
          ntfyServer: 'https://ntfy.sh', ntfyTopic: 'x\nWRAP\nreboot\n');
      expect(bad, contains("TOPIC='xWRAPreboot'"));
      // The only bare 'WRAP' lines are the 3 real heredoc terminators, none
      // injected from the value (the 3 openers are `cat … <<'WRAP'`).
      final wrapLines =
          '\n$bad\n'.split('\n').where((l) => l.trim() == 'WRAP').length;
      expect(wrapLines, 3);
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
    test('fails on an HTTP error and names the reason, within a time limit',
        () {
      final c = buildTestAlertCommand(
          ntfyServer: 'https://ntfy.sh', ntfyTopic: 'my-pi-42');
      // -f: HTTP >= 400 is an exit code, not a silent success. -sS: no
      // progress meter, but the error text. --max-time: a dead server cannot
      // hang the action.
      expect(c, startsWith('curl -fsS --max-time 15 '));
    });
    test('strips whitespace like the install script does', () {
      // A pasted server with a trailing blank or a topic with a line break
      // must test the destination the timer will really use.
      final c = buildTestAlertCommand(
          ntfyServer: ' https://ntfy.sh \n', ntfyTopic: ' my-pi\t-42\n');
      expect(c, endsWith(" 'https://ntfy.sh/my-pi-42'"));
      final s = buildAlertsInstallScript(
          ntfyServer: ' https://ntfy.sh \n', ntfyTopic: ' my-pi\t-42\n');
      expect(s, contains("URL='https://ntfy.sh'"));
      expect(s, contains("TOPIC='my-pi-42'"));
    });
  });

  // The real command in a real bash; `curl` is a stub that records its
  // arguments one per line. PATH is the stub directory alone (set inside the
  // shell — Git Bash's launcher prepends its own, with a real curl), so
  // nothing leaves the machine.
  group('buildTestAlertCommand in bash', () {
    late Directory tmp;
    late String root; // posix form of tmp

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('ntfytest');
      root = _posix(tmp.path);
      Directory('${tmp.path}/bin').createSync();
      File('${tmp.path}/bin/curl').writeAsStringSync('#!/bin/sh\n'
          'for a; do printf \'%s\\n\' "\$a"; done > "\$STUB/args"\n'
          'if [ -f "\$STUB/fail" ]; then\n'
          '  echo "curl: (22) The requested URL returned error: 404" >&2\n'
          '  exit 22\n'
          'fi\n');
      File('${tmp.path}/bin/reboot')
          .writeAsStringSync('#!/bin/sh\n: > "\$STUB/rebooted"\n');
      if (!Platform.isWindows) {
        Process.runSync(
            'chmod', ['+x', '${tmp.path}/bin/curl', '${tmp.path}/bin/reboot']);
      }
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<({int code, String err})> run(String command) async {
      final p = await Process.start(_bash!, ['-s']);
      final err = p.stderr.transform(utf8.decoder).join();
      final out = p.stdout.drain<void>();
      p.stdin.add(utf8
          .encode("export PATH='$root/bin' STUB='$root'\n$command\n"));
      await p.stdin.close();
      final code = await p.exitCode;
      await out;
      return (code: code, err: await err);
    }

    List<String> args() => File('${tmp.path}/args').readAsLinesSync();

    test('curl gets the flags, the title, the message and ONE url argument',
        () async {
      final r = await run(buildTestAlertCommand(
          ntfyServer: 'https://ntfy.sh', ntfyTopic: 'my-pi-42'));
      expect(r.code, 0, reason: r.err);
      final a = args();
      expect(a.sublist(0, 5),
          ['-fsS', '--max-time', '15', '-H', 'Title: Pi-Tool']);
      expect(a[5], '-d');
      expect(a[6], startsWith('Test-Benachrichtigung'));
      expect(a.last, 'https://ntfy.sh/my-pi-42');
      expect(a, hasLength(8));
    });

    test('a hostile topic stays one argument and runs nothing', () async {
      final r = await run(buildTestAlertCommand(
          ntfyServer: 'https://ntfy.sh', ntfyTopic: "a';reboot;'"));
      expect(r.code, 0, reason: r.err);
      expect(args().last, "https://ntfy.sh/a';reboot;'");
      expect(File('${tmp.path}/rebooted').existsSync(), isFalse);
    });

    test('curl\'s exit code and reason come through', () async {
      File('${tmp.path}/fail').writeAsStringSync('');
      final r = await run(buildTestAlertCommand(
          ntfyServer: 'https://ntfy.sh', ntfyTopic: 'my-pi-42'));
      expect(r.code, 22);
      expect(r.err, contains('curl: (22)'));
    });
  }, skip: _bash == null ? 'needs bash (PITOOL_TEST_BASH on Windows)' : false);

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

  // An ntfy topic IS the password (no auth on ntfy.sh): whoever knows or
  // guesses the name reads every health message. So the generated name has to
  // be long, valid for ntfy, and unguessable.
  group('generateNtfyTopic', () {
    test('prefixed + long random tail, only ntfy-legal characters', () {
      final t = generateNtfyTopic(Random(42));
      expect(t, matches(RegExp(r'^pi-tool-[a-z0-9]{14}$')));
      // ntfy: "Topic names may only contain letters, numbers, underscores and
      // dashes ([-_A-Za-z0-9]), and may be up to 64 characters long."
      expect(t, matches(RegExp(r'^[-_A-Za-z0-9]+$')));
      expect(t.length, lessThanOrEqualTo(64));
    });

    test('avoids look-alike characters (0/o, 1/l/i) so it can be re-typed', () {
      for (var seed = 0; seed < 50; seed++) {
        final tail = generateNtfyTopic(Random(seed)).substring(8);
        expect(tail, isNot(matches(RegExp('[01oli]'))));
      }
    });

    test('different draws yield different topics', () {
      final drawn = {for (var i = 0; i < 200; i++) generateNtfyTopic()};
      expect(drawn.length, 200);
    });

    test('a generated topic never trips the weak-topic warning', () {
      for (var seed = 0; seed < 50; seed++) {
        expect(isWeakNtfyTopic(generateNtfyTopic(Random(seed))), isFalse);
      }
    });

    test('survives the install script unchanged (no quoting surprises)', () {
      final t = generateNtfyTopic(Random(7));
      final s = buildAlertsInstallScript(
          ntfyServer: 'https://ntfy.sh', ntfyTopic: t);
      expect(s, contains("TOPIC='$t'"));
    });
  });

  group('isWeakNtfyTopic', () {
    test('flags short names — the realistic guessing target', () {
      expect(isWeakNtfyTopic('pi'), isTrue);
      expect(isWeakNtfyTopic('evcc'), isTrue);
      expect(isWeakNtfyTopic('mein-pi'), isTrue);
      expect(isWeakNtfyTopic('mein-pi-a7Xk'), isTrue); // 12 chars
    });

    test('flags long but repetitive names', () {
      expect(isWeakNtfyTopic('aaaaaaaaaaaaaaaaaaaaaa'), isTrue);
      expect(isWeakNtfyTopic('ab-ab-ab-ab-ab-ab-ab'), isTrue);
    });

    test('accepts a long, varied name', () {
      expect(isWeakNtfyTopic('pi-tool-k7m2q9x4vb3dwz'), isFalse);
      expect(isWeakNtfyTopic('wohnzimmer-pi-7fq2mx'), isFalse);
    });

    test('an empty topic is not "weak" — there is nothing to warn about yet',
        () {
      expect(isWeakNtfyTopic(''), isFalse);
      expect(isWeakNtfyTopic('   '), isFalse);
    });

    test('ignores surrounding whitespace', () {
      expect(isWeakNtfyTopic('  pi-tool-k7m2q9x4vb3dwz  '), isFalse);
      expect(isWeakNtfyTopic('  pi  '), isTrue);
    });
  });
}
