// Real-bash tests of the Pi-Job scripts (launcher, wrapper, follower, power
// guard). Linux only: they need flock, setsid and /proc, which Git Bash on
// Windows lacks — CI (ubuntu) runs them. Every on-Pi path is rebased into a
// temp root via JobScriptOptions; systemd-run is a stub that records its argv
// and starts the wrapper with setsid -f, like the no-systemd fallback does.
//
// The groups at the end need none of that and run in any bash (Git Bash
// included): a sandboxed Pi (on_pi_sandbox.dart) whose PATH holds stubs only.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:evcc_updater/src/commands.dart';
import 'package:evcc_updater/src/pi_job.dart';
import 'package:evcc_updater/src/services/system_service.dart'
    show isAptIndexFresh;
import 'package:flutter_test/flutter_test.dart';

import 'on_pi_sandbox.dart';

final Object _linuxOnly =
    Platform.isLinux ? false : 'braucht flock/setsid/proc – läuft in Linux-CI';

class _Box {
  _Box() : dir = Directory.systemTemp.createTempSync('pitool-job') {
    root = dir.path;
    Directory('$root/bin').createSync();
    // The launcher only uses systemd-run when this directory exists.
    Directory('$root/run/systemd/system').createSync(recursive: true);
    _stub('systemd-run', r'''
echo "$*" >>"$ROOTDIR/systemd-run.argv"
while [ $# -gt 0 ]; do
  case "$1" in
    -p) shift 2 ;;
    --*) shift ;;
    *) break ;;
  esac
done
exec setsid -f "$@" </dev/null >/dev/null 2>&1
''');
    // Not active / unit unknown: no auto-update, no systemd fallback games.
    _stub('systemctl', r'''
case "$*" in
  *"show -p LoadState"*) echo not-found ;;
esac
exit 3
''');
    _stub('dpkg-divert', r'''
[ -e "$ROOTDIR/diverted" ] && echo "local diversion of /boot/kernel7.img to /usr/share/rpikernelhack/kernel7.img by rpikernelhack"
exit 0
''');
    options = JobScriptOptions(
      root: root,
      path: '$root/bin:/usr/bin:/bin',
      pollSeconds: '0.2',
      hbEvery: 5,
      startWait: 50,
      startSleep: '0.2',
    );
  }

  final Directory dir;
  late final String root;
  late final JobScriptOptions options;

  Map<String, String> get env => {
        'PATH': '$root/bin:/usr/bin:/bin',
        'ROOTDIR': root,
        'LC_ALL': 'C',
      };

  void _stub(String name, String body) {
    final f = File('$root/bin/$name')
      ..writeAsStringSync('#!/bin/bash\n$body');
    Process.runSync('chmod', ['+x', f.path]);
  }

  String jobDir(String id) => '${options.base}/$id';

  Future<Process> start(String id, String payload,
      {String kind = 'e2e-test', String password = 'sekret'}) async {
    final p = await Process.start(
        'bash', ['-c', jobBootstrap, 'pitool', 'pitool-job-start', id],
        environment: env);
    p.stdin.add(utf8.encode(buildJobStartStdin(
        password: password,
        id: id,
        kind: kind,
        payload: buildJobPayload(payload),
        options: options)));
    await p.stdin.close();
    return p;
  }

  Future<ProcessResult> follow(String id) async {
    final p = await Process.start(
        'bash', ['-c', jobBootstrap, 'pitool', 'pitool-job-follow', id],
        environment: env);
    p.stdin.add(utf8.encode(
        buildJobFollowStdin(password: 'sekret', id: id, options: options)));
    await p.stdin.close();
    final out = p.stdout.transform(utf8.decoder).join();
    final err = p.stderr.transform(utf8.decoder).join();
    final code = await p.exitCode.timeout(const Duration(seconds: 60));
    return ProcessResult(p.pid, code, await out, await err);
  }

  Future<ProcessResult> collect(Process p) async {
    final out = p.stdout.transform(utf8.decoder).join();
    final err = p.stderr.transform(utf8.decoder).join();
    final code = await p.exitCode.timeout(const Duration(seconds: 60));
    return ProcessResult(p.pid, code, await out, await err);
  }

  Future<void> waitFor(bool Function() cond,
      {Duration timeout = const Duration(seconds: 20)}) async {
    final end = DateTime.now().add(timeout);
    while (!cond()) {
      if (DateTime.now().isAfter(end)) fail('Zeitüberschreitung beim Warten');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  String mode(String path) =>
      (Process.runSync('stat', ['-c', '%a', path]).stdout as String).trim();

  void dispose() {
    // A wrapper still running would keep writing into the tree.
    Process.runSync('pkill', ['-KILL', '-f', '$root/']);
    dir.deleteSync(recursive: true);
  }
}

void main() {
  test('Linux-CI hat die Werkzeuge der Pi-Job-Skripte', () {
    for (final tool in ['flock', 'setsid', 'stat', 'tail', 'head', 'base64']) {
      final r = Process.runSync('bash', ['-c', 'command -v $tool']);
      expect(r.exitCode, 0, reason: '$tool fehlt');
    }
  }, skip: _linuxOnly);

  group('Pi-Job in echtem bash', () {
    late _Box box;
    setUp(() => box = _Box());
    tearDown(() => box.dispose());

    test('Start → Mitlesen → RC; Rechte; Passwortzeile wird nie ausgeführt',
        () async {
      const id = '0123456789abcdef';
      final pwned = '${box.root}/pwned';
      final p = await box.start(id, 'echo hello\numask\nexit 7',
          password: 'touch $pwned');
      final r = await box.collect(p);
      final run = classifyJobRun(
          stdout: r.stdout as String,
          stderr: r.stderr as String,
          exitCode: r.exitCode,
          id: id);
      expect(run, isA<JobRunRc>());
      run as JobRunRc;
      expect(run.rc, 7);
      expect(run.kind, 'e2e-test');
      expect(run.log, contains('hello'));
      // The payload gets umask 022, not the wrapper's 077.
      expect(run.log, contains('0022'));
      expect(File(pwned).existsSync(), isFalse);
      expect('${r.stdout}${r.stderr}', isNot(contains('touch $pwned')));
      final d = box.jobDir(id);
      expect(box.mode(d), '700');
      expect(box.mode('$d/log'), '600');
      expect(box.mode(box.options.status), '644');
      expect(File('$d/payload.sh').existsSync(), isFalse);
      // Written before the rc — so it must already be there with the RC line.
      expect(File(box.options.status).readAsStringSync(),
          startsWith('$id e2e-test done 7 '));
      expect(File('${box.root}/systemd-run.argv').readAsStringSync(),
          contains('--unit=pi-tool-job-$id'));
    }, skip: _linuxOnly);

    test('App weg (Launcher getötet): der Job läuft zu Ende, Mitlesen liefert '
        'dasselbe Log und den RC', () async {
      const id = '1111111111111111';
      final p = await box.start(id, 'echo A\nsleep 2\necho B\nexit 5');
      final seen = StringBuffer();
      final sub = p.stdout.transform(utf8.decoder).listen(seen.write);
      p.stderr.drain<void>();
      await box.waitFor(() => seen.toString().contains('A'));
      p.kill(ProcessSignal.sigkill);
      await sub.cancel();
      await box.waitFor(() => File('${box.jobDir(id)}/rc').existsSync());
      expect(File('${box.jobDir(id)}/rc').readAsStringSync().trim(), '5');

      final r = await box.follow(id);
      final run = classifyJobRun(
          stdout: r.stdout as String,
          stderr: r.stderr as String,
          exitCode: r.exitCode,
          id: id);
      expect(run, isA<JobRunRc>());
      run as JobRunRc;
      expect(run.rc, 5);
      expect(run.log.trim().split('\n'), ['A', 'B']);
    }, skip: _linuxOnly);

    test('zweiter Job während der erste läuft → BUSY, nichts gestartet',
        () async {
      const first = '2222222222222222', second = '3333333333333333';
      final p1 = await box.start(first, 'sleep 3');
      final seen = StringBuffer();
      p1.stdout.transform(utf8.decoder).listen(seen.write);
      p1.stderr.drain<void>();
      await box.waitFor(() => seen.toString().contains('PITOOL_JOB_STARTED'));

      final r = await box.collect(await box.start(second, 'echo nope'));
      final run = classifyJobRun(
          stdout: r.stdout as String,
          stderr: r.stderr as String,
          exitCode: r.exitCode,
          id: second);
      expect(run, isA<JobRunBusy>());
      expect((run as JobRunBusy).otherId, first);
      expect(Directory(box.jobDir(second)).existsSync(), isFalse);
      await p1.exitCode.timeout(const Duration(seconds: 30));
    }, skip: _linuxOnly);

    test('ein im Hintergrund zurückgelassener Prozess hält keine Sperre',
        () async {
      const first = '4444444444444444', second = '5555555555555555';
      final r1 = await box.collect(
          await box.start(first, 'setsid sleep 30 </dev/null >/dev/null 2>&1 &\necho done'));
      expect(r1.stdout, contains('PITOOL_JOB_RC $first 0'));
      final r2 = await box.collect(await box.start(second, 'echo second'));
      expect(r2.stdout, contains('PITOOL_JOB_RC $second 0'));
    }, skip: _linuxOnly);

    test('Wrapper getötet (Absturz/Neustart) → LOST, job.status lost',
        () async {
      const id = '6666666666666666';
      final p = await box.start(id, 'echo A\nsleep 30');
      final seen = StringBuffer();
      p.stdout.transform(utf8.decoder).listen(seen.write);
      p.stderr.drain<void>();
      await box.waitFor(() => seen.toString().contains('A'));
      Process.runSync('pkill', ['-KILL', '-f', '${box.jobDir(id)}/run.sh']);
      await p.exitCode.timeout(const Duration(seconds: 30));
      final run = classifyJobRun(
          stdout: seen.toString(), stderr: '', exitCode: 0, id: id);
      expect(run, isA<JobRunLost>());
      expect(File(box.options.status).readAsStringSync(),
          contains('$id e2e-test lost '));
    }, skip: _linuxOnly);

    test('abgeschnittener Launcher führt nichts aus', () async {
      const id = '7777777777777777';
      final full = buildJobStartStdin(
          password: '',
          id: id,
          kind: 'e2e-test',
          payload: buildJobPayload('echo x'),
          options: box.options);
      final p = await Process.start(
          'bash', ['-c', jobBootstrap, 'pitool', 'pitool-job-start', id],
          environment: box.env);
      p.stdin.add(utf8.encode(full.substring(0, full.length * 2 ~/ 3)));
      await p.stdin.close();
      final r = await box.collect(p);
      expect(r.stdout, isNot(contains('PITOOL_JOB_')));
      expect(Directory(box.options.base).existsSync(), isFalse);
    }, skip: _linuxOnly);

    test('Neustart-Sperre: ohne Job erlaubt, während eines Jobs und bei '
        'halbem Kernel-Update abgelehnt', () async {
      final guard = jobPowerGuard.replaceAll(
          '/var/lib/pi-tool/jobs/lock', box.options.lock);
      Future<ProcessResult> check() => Process.run(
          'sh', ['-c', '$guard; echo ALLOWED'],
          environment: box.env);

      var r = await check();
      expect(r.stdout, contains('ALLOWED'));

      const id = '8888888888888888';
      final p = await box.start(id, 'sleep 3');
      final seen = StringBuffer();
      p.stdout.transform(utf8.decoder).listen(seen.write);
      p.stderr.drain<void>();
      await box.waitFor(() => seen.toString().contains('PITOOL_JOB_STARTED'));
      r = await check();
      expect(r.exitCode, 75);
      expect(r.stdout, contains(jobRefusedRunningMarker));
      await p.exitCode.timeout(const Duration(seconds: 30));
      // The wrapper frees the lock right after writing the outcome (before
      // its sync) — give that moment, then a reboot is allowed again.
      var free = false;
      for (var i = 0; i < 50 && !free; i++) {
        free = (await check()).stdout.toString().contains('ALLOWED');
        if (!free) await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(free, isTrue, reason: 'Sperre nach Jobende nicht frei');

      File('${box.root}/diverted').writeAsStringSync('');
      r = await check();
      expect(r.exitCode, 75);
      expect(r.stdout, contains(jobRefusedBootMarker));
    }, skip: _linuxOnly);
  });

  // The on-Pi auto-update is a oneshot unit: "activating" for its whole run,
  // which `systemctl is-active` answers with exit 3. Launcher and power guard
  // read the unit's ActiveState instead. The systemctl stub answers both
  // questions the way systemd does, from the state a test sets.
  group('laufendes Auto-Update (ActiveState) in bash', () {
    late PiSandbox pi;
    const id = '9999999999999999';
    const lock = '/var/lib/pi-tool/jobs/lock';

    /// [state] as `systemctl show -p ActiveState --value` prints it; `-` is a
    /// systemctl that cannot answer (prints nothing, exit 1).
    void autoUpdate(String state) => pi.put('/state/autoupdate', '$state\n');

    setUp(() {
      pi = PiSandbox();
      pi.stub('systemctl', r'''
state=$("$REAL_CAT" "$S/autoupdate" 2>/dev/null)
[ "$state" = - ] && exit 1
case "$*" in
  "show -p ActiveState --value pi-tool-autoupdate.service") echo "${state:-inactive}" ;;
  "is-active --quiet pi-tool-autoupdate.service") [ "$state" = active ] || exit 3 ;;
  *) exit 1 ;;
esac''');
      // The job lock is held whenever a test puts the lock file there.
      pi.stub('flock', 'exit 75');
      pi.stub('install', r'for a; do d=$a; done; exec "$REAL_MKDIR" -p "$d"',
          log: false);
      pi.stub('dpkg-divert', r'''
[ -e "$S/diverted" ] && echo "local diversion of /boot/kernel7.img to /usr/share/rpikernelhack/kernel7.img by rpikernelhack"
exit 0''', log: false);
      pi.stub('sudo', r'while [ "${1#-}" != "$1" ]; do shift; done; exec "$@"',
          log: false);
      // The power guard runs under `sh -c`: dash where there is one, as on a
      // Pi (the /bin/sh of Git Bash is a bash).
      pi.stub('sh', 'exec ${sandboxDash ?? '/bin/sh'} "\$@"', log: false);
      pi.stub('reboot', r': > "$S/rebooted"');
      pi.stub('poweroff', r': > "$S/powered-off"');
    });
    tearDown(() => pi.dispose());

    /// The launcher as `bash -s` gets it, with the arguments the bootstrap
    /// hands on. The stubbed flock reports the job lock as held, so a launcher
    /// that gets past the auto-update check ends there — nothing is started.
    Future<JobRun> launch() async {
      final launcher = buildJobLauncherScript(
          id: id,
          kind: jobKindSystemUpgrade,
          payload: buildJobPayload('echo x'),
          options: JobScriptOptions(root: pi.root, path: '${pi.root}/bin'));
      final r = await pi.run('set -- pitool-job-start $id\n$launcher',
          rebase: false);
      return classifyJobRun(
          stdout: r.out, stderr: r.err, exitCode: r.code, id: id);
    }

    List<String> lockProbes() =>
        pi.calls.where((c) => c.startsWith('flock ')).toList();

    for (final state in ['activating', 'active', 'deactivating', 'reloading']) {
      test('Launcher: ActiveState $state → BUSY autoupdate, nichts angelegt',
          () async {
        autoUpdate(state);
        final run = await launch();
        expect(run,
            isA<JobRunBusy>().having((b) => b.kind, 'kind', 'autoupdate'));
        expect(lockProbes(), isEmpty);
        expect(pi.exists('/var/lib/pi-tool/jobs/$id'), isFalse);
      });
    }

    for (final state in ['inactive', 'failed', '-']) {
      test('Launcher: ActiveState "$state" → weiter zur Job-Sperre', () async {
        autoUpdate(state);
        final run = await launch();
        // Held by the stub: BUSY, but not because of the auto-update.
        expect(
            run,
            isA<JobRunBusy>()
                .having((b) => b.kind, 'kind', isNot('autoupdate')));
        expect(lockProbes(), hasLength(1));
      });
    }

    test('Launcher: ohne systemctl (kein systemd) → weiter zur Job-Sperre',
        () async {
      pi.remove('/bin/systemctl');
      final run = await launch();
      expect(run,
          isA<JobRunBusy>().having((b) => b.kind, 'kind', isNot('autoupdate')));
      expect(lockProbes(), hasLength(1));
    });

    for (final state in ['activating', 'active', 'deactivating', 'reloading']) {
      test('Neustart: ActiveState $state → abgelehnt, kein reboot', () async {
        autoUpdate(state);
        final r = await pi.run(rebootCommand);
        expect(r.code, 75, reason: r.err);
        expect(r.lines, [jobRefusedAutoUpdateMarker]);
        expect(pi.exists('/state/rebooted'), isFalse);
      });
    }

    test('Herunterfahren: während des Auto-Updates abgelehnt', () async {
      autoUpdate('activating');
      final r = await pi.run(shutdownCommand);
      expect(r.code, 75, reason: r.err);
      expect(r.lines, [jobRefusedAutoUpdateMarker]);
      expect(pi.exists('/state/powered-off'), isFalse);
    });

    for (final state in ['inactive', 'failed', '-']) {
      test('Neustart: ActiveState "$state" → wie bisher erlaubt', () async {
        autoUpdate(state);
        final r = await pi.run(rebootCommand);
        expect(r.code, 0, reason: r.err);
        expect(r.out, isEmpty);
        expect(r.err, isEmpty);
        expect(pi.exists('/state/rebooted'), isTrue);
      });
    }

    test('Neustart und Herunterfahren ohne systemctl: wie bisher erlaubt',
        () async {
      pi.remove('/bin/systemctl');
      var r = await pi.run(rebootCommand);
      expect(r.code, 0, reason: r.err);
      expect(r.err, isEmpty);
      expect(pi.exists('/state/rebooted'), isTrue);
      r = await pi.run(shutdownCommand);
      expect(r.code, 0, reason: r.err);
      expect(pi.exists('/state/powered-off'), isTrue);
    });

    test('ein laufender Pi-Job wird vor dem Auto-Update genannt', () async {
      autoUpdate('activating');
      pi.put(lock, '');
      final r = await pi.run(rebootCommand);
      expect(r.code, 75, reason: r.err);
      expect(r.lines, [jobRefusedRunningMarker]);
      expect(pi.exists('/state/rebooted'), isFalse);
    });

    test('das Auto-Update wird vor dem halben Kernel-Update genannt', () async {
      // The diversion is in place while the upgrade that will finish it runs.
      autoUpdate('activating');
      pi.put('/state/diverted', '');
      final r = await pi.run(rebootCommand);
      expect(r.code, 75, reason: r.err);
      expect(r.lines, [jobRefusedAutoUpdateMarker]);
    });

    test('halbes Kernel-Update ohne laufendes Auto-Update: wie bisher', () async {
      pi.put('/state/diverted', '');
      final r = await pi.run(rebootCommand);
      expect(r.code, 75, reason: r.err);
      expect(r.lines, [jobRefusedBootMarker]);
      expect(pi.exists('/state/rebooted'), isFalse);
    });
  }, skip: needsBash);

  // pitool_update_lists as part of the system-upgrade payload. apt-get answers
  // `update` the way apt does, in the mode a test sets; nothing is downloaded.
  group('Paketlisten im Job-Payload in bash', () {
    late PiSandbox pi;
    const lists = '/var/lib/apt/lists';
    const fetchFailed = "Failed to fetch "
        "http://deb.debian.org/debian/dists/bookworm/InRelease  Temporary "
        "failure resolving 'deb.debian.org'";

    setUp(() async {
      pi = PiSandbox();
      // "failed": apt ≥ 2.1.16 honours Error-Mode=any — a download that failed
      // is an error. "warned": an older apt ignores the option, the same
      // failure is a warning and the exit status 0.
      pi.stub('apt-get', '''
case " \$* " in
  *" update "*)
    case "\$("\$REAL_CAT" "\$S/update" 2>/dev/null)" in
      failed)
        echo "E: $fetchFailed" >&2
        echo "E: Some index files failed to download. They have been ignored, or old ones used instead." >&2
        exit 100 ;;
      warned)
        echo "W: $fetchFailed" >&2
        echo "W: Some index files failed to download. They have been ignored, or old ones used instead." >&2 ;;
    esac ;;
esac
exit 0''');
      pi.stub('dpkg', 'exit 0');
      await pi.setAge(lists, '10 days ago');
    });
    tearDown(() => pi.dispose());

    Future<SandboxRun> upgrade() => pi.run(buildSystemUpgradePayload());

    List<String> apt(String verb) => pi.calls
        .where((c) => c.startsWith('apt-get ') && c.contains(' $verb'))
        .toList();

    Future<bool> listsFresh() async =>
        isAptIndexFresh(await pi.ageSeconds(lists));

    test('apt-get update läuft mit Error-Mode=any', () async {
      final r = await upgrade();
      expect(r.code, 0, reason: r.err);
      expect(apt('update'), [
        'apt-get -o APT::Update::Error-Mode=any '
            '-o Acquire::AllowReleaseInfoChange::Suite=true '
            '-o Acquire::Retries=3 update -qq'
      ]);
    });

    test('Listen geladen: RC 0, und das gemessene Alter springt zurück',
        () async {
      expect(await listsFresh(), isFalse);
      final r = await upgrade();
      expect(r.code, 0, reason: r.err);
      expect(r.lines, contains('PITOOL_APT_UPDATE_RC=0'));
      expect(await listsFresh(), isTrue);
      expect(evaluateJob(jobKindSystemUpgrade, r.code, r.out).listsIncomplete,
          isFalse);
    });

    test('Download fehlgeschlagen (rc 100): nur der Marker, das Upgrade läuft',
        () async {
      pi.put('/state/update', 'failed');
      final r = await upgrade();
      expect(r.code, 0, reason: r.err);
      expect(r.lines, contains('PITOOL_APT_UPDATE_RC=100'));
      expect(r.out, contains('E: $fetchFailed'));
      // The upgrade still ran — after the lists step.
      final calls = pi.calls;
      final upgradeAt = calls.indexWhere((c) => c.endsWith(' full-upgrade -y'));
      expect(upgradeAt, greaterThan(calls.indexOf(apt('update').single)));
      final o = evaluateJob(jobKindSystemUpgrade, r.code, r.out);
      expect(o.success, isTrue);
      expect(o.listsIncomplete, isTrue);
      // Old lists stay old: nothing may pass them off as fresh.
      expect(await listsFresh(), isFalse);
    });

    test('älteres apt (Exit 0 trotz Fehlschlag): das Alter bleibt stehen',
        () async {
      pi.put('/state/update', 'warned');
      final r = await upgrade();
      expect(r.code, 0, reason: r.err);
      expect(r.lines, contains('PITOOL_APT_UPDATE_RC=0'));
      expect(r.out, contains('W: $fetchFailed'));
      expect(apt('full-upgrade'), hasLength(1));
      expect(await listsFresh(), isFalse);
    });
  }, skip: needsBash);
}
