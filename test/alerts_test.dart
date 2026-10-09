// The real-bash tests start a dozen shells and stubs each; under Git Bash on a
// busy PC that alone has taken more than the default 30 s.
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:evcc_updater/src/alerts.dart';
import 'package:flutter_test/flutter_test.dart';

import 'on_pi_sandbox.dart';

/// The shell for the real-bash group: `bash` on Linux/macOS (CI). On Windows
/// `bash` may be the WSL launcher, so it only runs with an explicit Git Bash
/// (PITOOL_TEST_BASH=C:\Program Files\Git\bin\bash.exe).
final String? _bash =
    Platform.isWindows ? Platform.environment['PITOOL_TEST_BASH'] : 'bash';

/// What `sh` gets to run from a `sh -c '<argument>'` command line.
String _shC(String command) {
  expect(command, startsWith("sh -c '"));
  return command.substring(7, command.length - 1).replaceAll(r"'\''", "'");
}

/// A path the sandbox bash understands (Git Bash wants /c/... on Windows).
String _posix(String p) {
  final s = p.replaceAll(r'\', '/');
  final m = RegExp(r'^([A-Za-z]):/').firstMatch(s);
  return m == null ? s : '/${m.group(1)!.toLowerCase()}/${s.substring(3)}';
}

// ---- stubs of the wrapper sandbox; each reads its scenario from $S ---------

/// `df /`: root usage in percent from `$S/disk` (50 without).
const String _df = r'''
echo "Filesystem 1K-blocks Used Available Use% Mounted on"
echo "/dev/root 100 0 0 $(cat "$S/disk" 2>/dev/null || echo 50)% /"''';

/// `journalctl -k`: as many I/O error lines as `$S/ioerr` says (none without).
const String _journalctl = r'''
n=$(cat "$S/ioerr" 2>/dev/null || echo 0)
i=0
while [ "$i" -lt "$n" ]; do
  echo "kernel: blk_update_request: I/O error, dev mmcblk0, sector $i"
  i=$((i + 1))
done''';

/// systemd as the wrapper asks it: a service is enabled when
/// `$S/enabled-<name>` exists, `is-active` prints `$S/active-<name>` (active
/// without) and `show -p SubState` prints `$S/sub-<name>` (running without).
const String _systemctl = r'''
case "$1" in
  is-enabled) [ -e "$S/enabled-$2" ]; exit $? ;;
  is-active)
    st=$(cat "$S/active-$2" 2>/dev/null || echo active)
    echo "$st"
    [ "$st" = active ]; exit $? ;;
  show) echo "SubState=$(cat "$S/sub-$4" 2>/dev/null || echo running)" ;;
esac
exit 0''';

/// apt-get: the simulation lists `$S/pending` packages; `update` behaves as
/// `$S/apt-update` says (clean without) and never touches the lists
/// directory — like apt when every source answers "Hit". Message texts as in
/// apt-pkg (acquire.cc, update.cc).
const String _aptGet = r'''
case " $* " in
  *" -s upgrade "*)
    n=$(cat "$S/pending" 2>/dev/null || echo 0)
    i=0
    while [ "$i" -lt "$n" ]; do
      echo "Inst pkg$i [1.0] (1.1 Debian:stable [arm64])"
      i=$((i + 1))
    done ;;
  *" update "*)
    [ -e "$R/var/lib/pi-tool/alerts.status" ] && : > "$S/status-before-update"
    case "$(cat "$S/apt-update" 2>/dev/null)" in
      locked)
        echo "E: Could not get lock /var/lib/apt/lists/lock. It is held by process 4711 (apt-get)" >&2
        echo "E: Unable to lock directory /var/lib/apt/lists/" >&2
        exit 100 ;;
      transient)
        echo "W: Failed to fetch http://deb.debian.org/debian/dists/bookworm/InRelease  Temporary failure resolving 'deb.debian.org'" >&2
        echo "W: Some index files failed to download. They have been ignored, or old ones used instead." >&2 ;;
    esac ;;
esac
exit 0''';

/// timeout: drops `-k N` and the duration, then runs the command.
const String _timeout = r'''
[ "$1" = -k ] && shift 2
shift
exec "$@"''';

/// curl: keeps its arguments (one per line) and the message it was piped;
/// fails like "could not resolve host" while `$S/curl-fails` exists.
const String _curl = r'''
for a; do printf '%s\n' "$a"; done > "$S/curl-args"
cat > "$S/push-body"
[ -e "$S/curl-fails" ] && exit 6
exit 0''';

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
    // Only where the last report is kept. That an unchanged problem is not
    // pushed again is run in bash below ('the same problems twice are one
    // push …').
    test('keeps what it last reported in a state file', () {
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
    test('one `sh -c` with one argument, whatever the login shell is', () {
      final c = buildTestAlertCommand(
          ntfyServer: 'https://ntfy.sh', ntfyTopic: "a';reboot;'");
      expect(c, startsWith("sh -c '"));
      expect(c, endsWith("'"));
      // Every quote inside is escaped: nothing ends the argument early.
      final body = c.substring(7, c.length - 1);
      expect(body.replaceAll(r"'\''", ''), isNot(contains("'")));
    });
    test('sends a test push to server/topic, shell-quoted', () {
      final c = _shC(buildTestAlertCommand(
          ntfyServer: 'https://ntfy.sh', ntfyTopic: 'my-pi-42'));
      expect(c, contains('curl'));
      expect(c, contains("'https://ntfy.sh/my-pi-42'"));
    });
    test('quotes a hostile topic', () {
      final c = _shC(buildTestAlertCommand(
          ntfyServer: 'https://ntfy.sh', ntfyTopic: "a';reboot;'"));
      expect(c, contains(r"'\''"));
      expect(c, isNot(contains("/a';reboot")));
    });
    test('fails on an HTTP error and names the reason, within a time limit',
        () {
      final c = _shC(buildTestAlertCommand(
          ntfyServer: 'https://ntfy.sh', ntfyTopic: 'my-pi-42'));
      // -f: HTTP >= 400 is an exit code, not a silent success. -sS: no
      // progress meter, but the error text. --max-time: a dead server cannot
      // hang the action. Last on the line: its exit code is the command's.
      expect(c.split('; ').last, startsWith('curl -fsS --max-time 15 '));
    });
    test('strips whitespace like the install script does', () {
      // A pasted server with a trailing blank or a topic with a line break
      // must test the destination the timer will really use.
      final c = _shC(buildTestAlertCommand(
          ntfyServer: ' https://ntfy.sh \n', ntfyTopic: ' my-pi\t-42\n'));
      expect(c, endsWith(" 'https://ntfy.sh/my-pi-42'"));
      final s = buildAlertsInstallScript(
          ntfyServer: ' https://ntfy.sh \n', ntfyTopic: ' my-pi\t-42\n');
      expect(s, contains("URL='https://ntfy.sh'"));
      expect(s, contains("TOPIC='my-pi-42'"));
    });
  });

  // The server is free text in the sheet. Only http(s) may reach curl — and a
  // destination that works today must keep working.
  group('ntfy server', () {
    String installed(String server) => heredocBody(
            buildAlertsInstallScript(ntfyServer: server, ntfyTopic: 't'),
            'WRAP',
            1)
        .split('\n')
        .first;
    String tested(String server) =>
        _shC(buildTestAlertCommand(ntfyServer: server, ntfyTopic: 't'))
            .split(' -- ')
            .last;

    test('http and https are taken as typed, whatever the case', () {
      for (final server in [
        'https://ntfy.sh',
        'http://ntfy.lan:8080',
        'HTTPS://Ntfy.Example',
      ]) {
        expect(installed(server), "URL='$server'");
        expect(tested(server), "'$server/t'");
      }
    });

    test('a server typed without a scheme gets http:// — what curl assumes '
        'for it anyway', () {
      expect(installed('ntfy.sh'), "URL='http://ntfy.sh'");
      expect(tested('ntfy.sh'), "'http://ntfy.sh/t'");
      expect(installed('ntfy.lan:8080'), "URL='http://ntfy.lan:8080'");
      // Never an option for curl, even without the `--` in front.
      expect(installed('-K/etc/shadow'), "URL='http://-K/etc/shadow'");
    });

    test('any other scheme, or no server at all, is refused by both builders',
        () {
      for (final bad in ['ftp://ntfy.sh', 'file:///etc/shadow', 'x://', '', ' \n']) {
        expect(
            () => buildAlertsInstallScript(ntfyServer: bad, ntfyTopic: 't'),
            throwsArgumentError,
            reason: bad);
        expect(() => buildTestAlertCommand(ntfyServer: bad, ntfyTopic: 't'),
            throwsArgumentError,
            reason: bad);
      }
    });

    test('the refusal does not repeat the value: the error text is logged, '
        'and the field may hold credentials or a pasted ntfy:// link with '
        'the topic', () {
      for (final bad in [
        'ntfy://ntfy.example/pi-tool-k7m2q9x4vb3dwz',
        'htps://anna:geheim@ntfy.example',
      ]) {
        for (final build in [
          () => buildAlertsInstallScript(ntfyServer: bad, ntfyTopic: 't'),
          () => buildTestAlertCommand(ntfyServer: bad, ntfyTopic: 't'),
        ]) {
          Object? error;
          try {
            build();
          } on ArgumentError catch (e) {
            error = e;
          }
          expect('$error', contains('kein http(s)-Server'), reason: bad);
          for (final part in ['ntfy.example', 'k7m2q9x4vb3dwz', 'geheim']) {
            expect('$error', isNot(contains(part)), reason: bad);
          }
        }
      }
    });

    // The sheet asks before it tests or switches on, so that a refused value
    // is marked at its field — and never saved. It must say exactly what the
    // builders will do.
    test('isNtfyServerUsable says what the builders take', () {
      bool builds(String server) {
        try {
          buildAlertsInstallScript(ntfyServer: server, ntfyTopic: 't');
          buildTestAlertCommand(ntfyServer: server, ntfyTopic: 't');
          return true;
        } on ArgumentError {
          return false;
        }
      }

      for (final good in [
        'https://ntfy.sh',
        'http://ntfy.lan:8080',
        'HTTPS://Ntfy.Example',
        'ntfy.sh',
        'ntfy.lan:8080',
        ' https://ntfy.sh ',
        'https://anna:geheim@ntfy.example',
      ]) {
        expect(isNtfyServerUsable(good), isTrue, reason: good);
        expect(builds(good), isTrue, reason: good);
      }
      for (final bad in [
        // A link pasted from the ntfy app.
        'ntfy://ntfy.sh/pi-tool-k7m2q9x4vb3dwz',
        'ftp://ntfy.sh',
        'file:///etc/shadow',
        'htps://ntfy.sh',
        'x://',
        '',
        ' \n',
      ]) {
        expect(isNtfyServerUsable(bad), isFalse, reason: bad);
        expect(builds(bad), isFalse, reason: bad);
      }
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
      // The command runs through `sh -c`; PATH stays the stub directory.
      File('${tmp.path}/bin/sh')
          .writeAsStringSync('#!/bin/sh\nexec /bin/sh "\$@"\n');
      if (!Platform.isWindows) {
        Process.runSync('chmod', [
          '+x',
          '${tmp.path}/bin/curl',
          '${tmp.path}/bin/reboot',
          '${tmp.path}/bin/sh',
        ]);
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

    /// The Pi answers `hostname` with [output] (single-quoted for the stub).
    void hostname(String output) {
      final f = File('${tmp.path}/bin/hostname')
        ..writeAsStringSync('#!/bin/sh\n'
            "printf '%s\\n' '${output.replaceAll("'", "'\\''")}'\n");
      if (!Platform.isWindows) Process.runSync('chmod', ['+x', f.path]);
    }

    test('curl gets the flags, the title, the message and ONE url argument',
        () async {
      hostname('zirkel');
      final r = await run(buildTestAlertCommand(
          ntfyServer: 'https://ntfy.sh', ntfyTopic: 'my-pi-42'));
      expect(r.code, 0, reason: r.err);
      final a = args();
      // Which Pi: several can push to one topic.
      expect(a.sublist(0, 5),
          ['-fsS', '--max-time', '15', '-H', 'Title: Pi-Tool (zirkel)']);
      expect(a[5], '-d');
      expect(a[6], startsWith('Test-Benachrichtigung'));
      // `--` ends the options: whatever the URL starts with, it is the URL.
      expect(a[7], '--');
      expect(a.last, 'https://ntfy.sh/my-pi-42');
      expect(a, hasLength(9));
    });

    test('a Pi without a `hostname` command: the plain title, nothing on '
        'stderr', () async {
      final r = await run(buildTestAlertCommand(
          ntfyServer: 'https://ntfy.sh', ntfyTopic: 'my-pi-42'));
      expect(r.code, 0, reason: r.err);
      expect(r.err, isEmpty);
      expect(args()[4], 'Title: Pi-Tool');
      expect(args(), hasLength(9));
    });

    // The title is an HTTP header. Whatever the Pi answers, it stays ONE
    // argument of one line, and the shell runs nothing of it.
    test('a hostname that is none stays out of the title and runs nothing',
        () async {
      for (final answer in [
        '',
        'mein pi',
        'pi\nPriority: max',
        "x';reboot;'",
        r'$(reboot)',
        '`reboot`',
        'pi"; reboot; "',
        'zirkel;reboot',
        'büro-pi',
      ]) {
        hostname(answer);
        final r = await run(buildTestAlertCommand(
            ntfyServer: 'https://ntfy.sh', ntfyTopic: 'my-pi-42'));
        expect(r.code, 0, reason: '$answer: ${r.err}');
        expect(args()[4], 'Title: Pi-Tool', reason: answer);
        expect(args(), hasLength(9), reason: answer);
        expect(File('${tmp.path}/rebooted').existsSync(), isFalse,
            reason: answer);
      }
    });

    test('every character a hostname may have gets through', () async {
      hostname('Pi-4.fritz.box_2');
      await run(buildTestAlertCommand(
          ntfyServer: 'https://ntfy.sh', ntfyTopic: 'my-pi-42'));
      expect(args()[4], 'Title: Pi-Tool (Pi-4.fritz.box_2)');
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

  // The wrapper as the install script writes it, run under its own shebang on
  // a sandboxed Pi: what it pushes, remembers and refreshes is checked.
  group('health-alerts wrapper in bash', () {
    late PiSandbox pi;
    const wrapper = '/usr/local/lib/$alertsUnit.sh';
    const destination = '/usr/local/lib/$alertsUnit.conf';
    const last = '/var/lib/pi-tool/alerts.last';
    const lists = '/var/lib/apt/lists';

    Future<void> install({
      String server = 'https://ntfy.example',
      String topic = 'pi-tool-test',
    }) async {
      final r = await pi.run(
          buildAlertsInstallScript(ntfyServer: server, ntfyTopic: topic));
      expect(r.code, 0, reason: r.err);
      expect(r.lines.last, 'ALERTS_INSTALLED');
      pi.clearCalls();
    }

    setUp(() async {
      pi = PiSandbox();
      pi.stub('systemctl', _systemctl, log: false);
      pi.stub('journalctl', _journalctl, log: false);
      pi.stub('df', _df, log: false);
      pi.stub('apt-get', _aptGet);
      pi.stub('timeout', _timeout);
      pi.stub('curl', _curl);
      // The Pi's name: `$S/hostname` as it is, "zirkel" without the file.
      pi.stub('hostname', r'cat "$S/hostname" 2>/dev/null || echo zirkel',
          log: false);
      // A healthy Pi: root mounted read-write, 45 °C.
      pi.put('/proc/mounts', '/dev/root / ext4 rw,noatime 0 0\n');
      pi.put('/sys/class/thermal/thermal_zone0/temp', '45000\n');
      await install();
    });
    tearDown(() => pi.dispose());

    /// One run of the timer — under the wrapper's shebang, or under [shell].
    /// The wrapper has every tool it uses, so anything on stderr is a defect
    /// of the script.
    Future<void> check({String? shell}) async {
      final r = await pi.run(
          "${shell == null ? '' : "'$shell' "}'${pi.root}$wrapper'",
          rebase: false);
      expect(r.code, 0, reason: r.err);
      expect(r.err, isEmpty);
    }

    void disk(int percent) => pi.put('/state/disk', '$percent');
    void pending(int n) => pi.put('/state/pending', '$n');
    void service(String name, String state, {String sub = 'running'}) {
      pi.put('/state/enabled-$name', '');
      pi.put('/state/active-$name', state);
      pi.put('/state/sub-$name', sub);
    }

    List<String> pushes() =>
        pi.calls.where((c) => c.startsWith('curl ')).toList();
    List<String> listUpdates() => pi.calls
        .where((c) => c.startsWith('apt-get ') && c.contains(' update'))
        .toList();
    String message() => pi.read('/state/push-body');

    test('a healthy Pi: nothing is pushed, the check is noted', () async {
      await check();
      expect(pushes(), isEmpty);
      expect(pi.read('/var/lib/pi-tool/alerts.status'),
          matches(RegExp(r'^\d{4}-\d\d-\d\d \d\d:\d\d checked\n$')));
    });

    test('curl fails: the alert stays pending and goes out with a later check',
        () async {
      disk(95);
      pi.put('/state/curl-fails', '');
      await check();
      expect(pushes(), hasLength(1));
      expect(pi.exists(last), isFalse);
      await check();
      expect(pushes(), hasLength(2));
      pi.remove('/state/curl-fails');
      await check();
      expect(pushes(), hasLength(3));
      expect(pi.read(last), matches(RegExp(r'^[0-9a-f]{32}$')));
      await check();
      expect(pushes(), hasLength(3));
    });

    test('the same problems twice are one push — and so are their values '
        'moving above the threshold', () async {
      disk(95);
      pending(3);
      pi.put('/state/ioerr', '7');
      pi.put('/sys/class/thermal/thermal_zone0/temp', '76000\n');
      await check();
      expect(pushes(), hasLength(1));
      expect(message().split('\n'), [
        'Pi-Tool hat Probleme erkannt:',
        'Speicher: 95% belegt',
        'Temperatur: 76 Grad',
        'SD-Karte: 7 I/O-Fehler im Kernel-Log',
        '3 Updates verfuegbar',
      ]);
      await check();
      expect(pushes(), hasLength(1));
      disk(97);
      pending(5);
      pi.put('/state/ioerr', '9');
      pi.put('/sys/class/thermal/thermal_zone0/temp', '81000\n');
      await check();
      expect(pushes(), hasLength(1));
    });

    test('a further problem pushes once more, with everything that is wrong',
        () async {
      disk(95);
      await check();
      pending(4);
      await check();
      expect(pushes(), hasLength(2));
      expect(message().split('\n').skip(1),
          ['Speicher: 95% belegt', '4 Updates verfuegbar']);
      pending(6);
      await check();
      expect(pushes(), hasLength(2));
    });

    test('a problem that went away and comes back is reported again',
        () async {
      disk(95);
      await check();
      disk(60);
      await check();
      expect(pushes(), hasLength(1));
      expect(pi.read(last), isEmpty);
      disk(96);
      await check();
      expect(pushes(), hasLength(2));
      expect(message(), contains('Speicher: 96% belegt'));
    });

    test('a read-only root is a problem of its own', () async {
      pi.put('/proc/mounts', '/dev/root / ext4 ro,noatime 0 0\n');
      await check();
      expect(pushes(), hasLength(1));
      expect(message().split('\n').skip(1),
          ['SD-Karte: Dateisystem nur-lesend']);
    });

    test('an enabled service is reported when it is down — not while it '
        'starts, reloads or stops', () async {
      for (final (state, sub, reported) in [
        ('active', 'running', false),
        ('failed', 'failed', true),
        ('inactive', 'dead', true),
        // Starting (a restart, the Pi booting) is not an outage …
        ('activating', 'start', false),
        ('activating', 'start-pre', false),
        // … but systemd restarting a service that keeps dying is one.
        ('activating', 'auto-restart', true),
        ('reloading', 'reload', false),
        ('deactivating', 'stop-sigterm', false),
      ]) {
        service('evcc', state, sub: sub);
        pi.remove(last);
        pi.clearCalls();
        await check();
        expect(pushes(), hasLength(reported ? 1 : 0), reason: '$state/$sub');
        if (reported) {
          expect(message().split('\n').skip(1), ['Dienst aus: evcc'],
              reason: '$state/$sub');
        }
      }
    });

    test('failed and inactive are the same problem of a service; another '
        'service is a new one', () async {
      service('evcc', 'failed', sub: 'failed');
      await check();
      service('evcc', 'inactive', sub: 'dead');
      await check();
      expect(pushes(), hasLength(1));
      service('mosquitto', 'failed', sub: 'failed');
      await check();
      expect(pushes(), hasLength(2));
      expect(message().split('\n').skip(1),
          ['Dienst aus: evcc', 'Dienst aus: mosquitto']);
    });

    test('a service that is not enabled is never reported', () async {
      pi.put('/state/active-evcc', 'inactive');
      await check();
      expect(pushes(), isEmpty);
    });

    test('under dash — the /bin/sh of a Pi — the wrapper does the same',
        () async {
      await pi.setAge(lists, '2 days ago');
      disk(95);
      pending(3);
      service('evcc', 'failed', sub: 'failed');
      service('influxdb', 'activating', sub: 'start');
      service('mosquitto', 'activating', sub: 'auto-restart');
      await check(shell: sandboxDash);
      expect(pushes(), hasLength(1));
      expect(message().split('\n'), [
        'Pi-Tool hat Probleme erkannt:',
        'Speicher: 95% belegt',
        'Dienst aus: evcc',
        'Dienst aus: mosquitto',
        '3 Updates verfuegbar',
      ]);
      expect(listUpdates(), hasLength(1));
      expect(await pi.ageSeconds(lists), lessThan(3600));
      disk(97);
      pending(4);
      await check(shell: sandboxDash);
      expect(pushes(), hasLength(1));
      expect(listUpdates(), hasLength(1));
    }, skip: needsDash);

    // "N Updates verfuegbar" is counted against the local package lists, and
    // on a stock Pi nothing refreshes those.
    test('package lists older than 24 h: exactly one apt-get update — bounded, '
        'not queueing behind another apt run — and the lists are stamped',
        () async {
      await pi.setAge(lists, '2 days ago');
      await check();
      expect(listUpdates(),
          ['apt-get -o DPkg::Lock::Timeout=0 update -qq']);
      expect(
          pi.calls.where((c) => c.startsWith('timeout ')),
          ['timeout -k 10 120 apt-get -o DPkg::Lock::Timeout=0 update -qq']);
      // The stamp "Paketlisten aktualisieren" sets: the app's cards read the
      // age of this directory.
      expect(await pi.ageSeconds(lists), lessThan(3600));
      await check();
      expect(listUpdates(), hasLength(1));
    });

    test('fresh package lists: no apt-get update', () async {
      await pi.setAge(lists, '23 hours ago');
      await check();
      await check();
      expect(listUpdates(), isEmpty);
      expect(pi.calls.where((c) => c.startsWith('timeout ')), isEmpty);
    });

    test('the refresh comes last: after the push and the status line',
        () async {
      await pi.setAge(lists, '2 days ago');
      disk(95);
      await check();
      final order = pi.calls
          .where((c) => c.startsWith('curl ') || c.startsWith('timeout '))
          .map((c) => c.split(' ').first);
      expect(order, ['curl', 'timeout']);
      expect(pi.exists('/state/status-before-update'), isTrue);
    });

    test('another apt run holds the lock (apt exit 100): the push still goes '
        'out, the lists stay unstamped, no second try within 24 h', () async {
      await pi.setAge(lists, '2 days ago');
      pi.put('/state/apt-update', 'locked');
      disk(95);
      await check();
      expect(pushes(), hasLength(1));
      expect(listUpdates(), hasLength(1));
      expect(await pi.ageSeconds(lists), greaterThan(86400));
      await check();
      expect(listUpdates(), hasLength(1));
    });

    test('a try older than 24 h is repeated', () async {
      await pi.setAge(lists, '3 days ago');
      pi.put('/state/apt-update', 'locked');
      await check();
      await pi.setAge('/var/lib/pi-tool/alerts.aptupdate', '25 hours ago');
      await check();
      expect(listUpdates(), hasLength(2));
    });

    test('sources not reachable (apt exits 0 all the same): the lists are not '
        'stamped as fresh', () async {
      await pi.setAge(lists, '2 days ago');
      pi.put('/state/apt-update', 'transient');
      await check();
      expect(listUpdates(), hasLength(1));
      expect(await pi.ageSeconds(lists), greaterThan(86400));
    });

    test('the updates found after a refresh are pushed with the next check',
        () async {
      await pi.setAge(lists, '2 days ago');
      await check();
      expect(pushes(), isEmpty);
      pending(12); // what the refreshed lists now show
      await check();
      expect(pushes(), hasLength(1));
      expect(message(), contains('12 Updates verfuegbar'));
    });

    test('curl gets `--` and the destination as its last two arguments',
        () async {
      disk(95);
      await check();
      final args = pi.read('/state/curl-args').trim().split('\n');
      expect(args.sublist(args.length - 2),
          ['--', 'https://ntfy.example/pi-tool-test']);
      expect(args, contains('--max-time'));
    });

    /// What curl got for the one push of a check, one argument per line.
    List<String> pushArgs() => pi.read('/state/curl-args').trim().split('\n');

    /// The arguments of a push titled [title]; nothing else may vary.
    List<String> argsWith(String title) => [
          '-fsS',
          '--connect-timeout',
          '10',
          '--max-time',
          '30',
          '-H',
          'Title: $title',
          '-H',
          'Priority: high',
          '--data-binary',
          '@-',
          '--',
          'https://ntfy.example/pi-tool-test',
        ];

    // Several Pis can push to one topic: "Dienst aus: evcc" alone names none.
    test('the push names the Pi in its title — one header, one argument',
        () async {
      disk(95);
      await check();
      expect(pushArgs(), argsWith('Pi-Tool (zirkel)'));
      // The message itself is unchanged.
      expect(message().split('\n'),
          ['Pi-Tool hat Probleme erkannt:', 'Speicher: 95% belegt']);
    });

    test('a hostname that is none stays out of the title and runs nothing',
        () async {
      for (final answer in [
        '',
        'mein pi\n',
        'pi\nPriority: max\n',
        "x';touch ${pi.root}/state/pwned1;'\n",
        '\$(touch ${pi.root}/state/pwned2)\n',
        '`touch ${pi.root}/state/pwned3`\n',
        'pi"; touch ${pi.root}/state/pwned4; "\n',
        'büro-pi\n',
      ]) {
        pi.put('/state/hostname', answer);
        pi.remove(last);
        disk(95);
        await check();
        expect(pushArgs(), argsWith('Pi-Tool'), reason: answer);
      }
      expect(pi.ls('/state').where((n) => n.startsWith('pwned')), isEmpty);
    });

    test('a Pi without a `hostname` command pushes with the plain title',
        () async {
      pi.remove('/bin/hostname');
      disk(95);
      await check();
      expect(pushArgs(), argsWith('Pi-Tool'));
    });

    test('the Pi\'s name does not go into what makes a problem new: a renamed '
        'Pi pushes nothing for the same problem', () async {
      disk(95);
      await check();
      pi.put('/state/hostname', 'garage\n');
      await check();
      expect(pushes(), hasLength(1));
    });

    test('under dash the title is built the same way', () async {
      disk(95);
      await check(shell: sandboxDash);
      expect(pushArgs(), argsWith('Pi-Tool (zirkel)'));
      pi.put('/state/hostname', 'mein pi\n');
      pi.remove(last);
      await check(shell: sandboxDash);
      expect(pushArgs(), argsWith('Pi-Tool'));
    }, skip: needsDash);

    // Switched off, nothing of the timer's runs stays: turned on again later,
    // the sheet would otherwise show a check from before as its last one.
    test('removing takes the state of the checks along', () async {
      await pi.setAge(lists, '2 days ago');
      disk(95);
      await check();
      pi.put('/var/lib/pi-tool/job.status', 'other state of the app\n');
      expect(pi.ls('/var/lib/pi-tool'),
          ['alerts.aptupdate', 'alerts.last', 'alerts.status', 'job.status']);
      expect(parseAlertsStatus((await pi.run(alertsStatusCommand)).out).lastCheck,
          isNotNull);

      final r = await pi.run(buildAlertsRemoveScript());
      expect(r.code, 0, reason: r.err);
      expect(r.lines.last, 'ALERTS_REMOVED');
      expect(pi.ls('/var/lib/pi-tool'), ['job.status']);
      final st = parseAlertsStatus((await pi.run(alertsStatusCommand)).out);
      expect(st.enabled, isFalse);
      expect(st.lastCheck, isNull);
      expect(st.wrapperOutdated, isFalse);
    });

    test('the ntfy destination lies in a file only root reads, not in the '
        'wrapper — whose stamp the status probe therefore still reads without '
        'sudo', () async {
      pi.stub('chmod', r'exec "$REAL_CHMOD" "$@"');
      final r = await pi.run(buildAlertsInstallScript(
          ntfyServer: 'https://ntfy.example', ntfyTopic: 'pi-tool-test'));
      expect(r.lines.last, 'ALERTS_INSTALLED', reason: r.err);
      expect(pi.read(wrapper), isNot(contains('pi-tool-test')));
      expect(pi.read(wrapper), isNot(contains('ntfy.example')));
      expect(pi.read(destination).trim().split('\n'),
          ["URL='https://ntfy.example'", "TOPIC='pi-tool-test'"]);
      expect(pi.calls, contains('chmod 600 ${pi.root}$destination'));
      if (!Platform.isWindows) {
        expect(await pi.mode(destination), '600');
        // Readable for the SSH user the probe runs as.
        expect(await pi.mode(wrapper), endsWith('5'));
      }
      // The probe exactly as the app sends it — a plain command, no sudo.
      final probe = await pi.run(alertsStatusCommand);
      expect(probe.lines, contains('WRAPPER 3'));
      expect(parseAlertsStatus(probe.out).wrapperOutdated, isFalse);
      // And the wrapper still finds its destination.
      disk(95);
      await check();
      expect(pi.read('/state/curl-args').trim().split('\n').last,
          'https://ntfy.example/pi-tool-test');
    });

    test('a wrapper of the previous generation, destination inside: the probe '
        'says so, and setting up again takes the topic out of it', () async {
      pi.put(
          wrapper,
          '#!/bin/sh\n# pi-tool-wrapper 2\n'
          "URL='https://ntfy.example'\nTOPIC='pi-tool-old'\n");
      final probe = await pi.run(alertsStatusCommand);
      expect(probe.lines, contains('WRAPPER 2'));
      expect(parseAlertsStatus(probe.out).wrapperOutdated, isTrue);
      await install();
      expect(pi.read(wrapper), isNot(contains('pi-tool-old')));
      final after = await pi.run(alertsStatusCommand);
      expect(after.lines, contains('WRAPPER 3'));
      expect(parseAlertsStatus(after.out).wrapperOutdated, isFalse);
    });

    test('removing takes the destination file along', () async {
      expect(pi.exists(destination), isTrue);
      final r = await pi.run(buildAlertsRemoveScript());
      expect(r.code, 0, reason: r.err);
      expect(r.lines.last, 'ALERTS_REMOVED');
      expect(pi.exists(destination), isFalse);
      expect(pi.exists(wrapper), isFalse);
    });

    test('a hostile topic and server stay data — at install and at run time',
        () async {
      // No blank survives the builder, hence ${IFS}.
      final topic = "x';touch\${IFS}${pi.root}/state/pwned1;'"
          "\$(touch\${IFS}${pi.root}/state/pwned2)";
      final server =
          "https://ntfy.example/`touch\${IFS}${pi.root}/state/pwned3`";
      await install(server: server, topic: topic);
      disk(95);
      await check();
      expect(pi.read('/state/curl-args').trim().split('\n').last,
          '$server/$topic');
      expect(pi.ls('/state').where((n) => n.startsWith('pwned')), isEmpty);
    });
  }, skip: needsBash);

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
