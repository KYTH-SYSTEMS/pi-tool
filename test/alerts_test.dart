import 'dart:math';

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
