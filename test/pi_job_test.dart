import 'dart:convert';
import 'dart:io';

import 'package:evcc_updater/src/commands.dart';
import 'package:evcc_updater/src/eol_sources.dart';
import 'package:evcc_updater/src/pi_job.dart';
import 'package:flutter_test/flutter_test.dart';

const _id = '0123456789abcdef';
const _other = 'fedcba9876543210';

/// The launcher output of a job that ran to the end: STARTED, the log, the
/// artificial blank line and the RC line — exactly what the follower prints.
String _done(String log, {int rc = 0, String id = _id, String kind = 'x'}) =>
    'PITOOL_JOB_STARTED $id $kind\n$log\nPITOOL_JOB_RC $id $rc\n';

void main() {
  group('ids and kinds', () {
    test('generated ids are 16 lowercase hex chars and differ', () {
      final a = generateJobId();
      final b = generateJobId();
      expect(a, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(b, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(a, isNot(b));
    });

    test('validation', () {
      expect(isValidJobId(_id), isTrue);
      for (final bad in ['', '..', '0123456789ABCDEF', '0123456789abcde',
          '0123456789abcdef0', "0123456789abcde'", '0123456789abcde/']) {
        expect(isValidJobId(bad), isFalse, reason: bad);
      }
      expect(isValidJobKind('system-upgrade'), isTrue);
      for (final bad in ['', 'A', 'a b', 'a/b', "a'", 'x' * 33]) {
        expect(isValidJobKind(bad), isFalse, reason: bad);
      }
    });

    test('builders refuse an invalid id or kind (ArgumentError)', () {
      expect(() => jobStartCommand('..'), throwsArgumentError);
      expect(() => jobFollowCommand(''), throwsArgumentError);
      expect(
          () => buildJobStartStdin(
              password: 'pw', id: '../x', kind: 'x', payload: 'true'),
          throwsArgumentError);
      expect(
          () => buildJobStartStdin(
              password: 'pw', id: _id, kind: 'Bad Kind', payload: 'true'),
          throwsArgumentError);
      expect(() => buildJobFollowStdin(password: 'pw', id: 'zz'),
          throwsArgumentError);
    });
  });

  group('transport (bootstrap + sentinel)', () {
    test('start/follow commands: constant bootstrap, id in argv, no secret',
        () {
      final start = jobStartCommand(_id);
      final follow = jobFollowCommand(_id);
      expect(start,
          "LC_ALL=C sudo -S bash -c '$jobBootstrap' pitool pitool-job-start '$_id'");
      expect(follow,
          "LC_ALL=C sudo -S bash -c '$jobBootstrap' pitool pitool-job-follow '$_id'");
      expect(start, isNot(follow));
      // The bootstrap is interpolation-free and has no single quote of its own.
      expect(jobBootstrap, isNot(contains("'")));
      expect(jobBootstrap, contains('"#PITOOL-BEGIN"'));
      expect(jobBootstrap, endsWith('exit 97'));
      expect(jobIdFromCommand(start), _id);
      expect(jobIdFromCommand(follow), _id);
      expect(isJobStartCommand(start), isTrue);
      expect(isJobStartCommand(follow), isFalse);
      expect(isJobFollowCommand(follow), isTrue);
      expect(jobIdFromCommand(installShellCommand), isNull);
    });

    test('stdin: password line, sentinel, then the function-wrapped script',
        () {
      final stdin = buildJobStartStdin(
          password: 'sekret', id: _id, kind: 'x', payload: 'echo hi');
      final lines = stdin.split('\n');
      expect(lines[0], 'sekret');
      expect(lines[1], jobSentinel);
      expect(stdin.trimRight().split('\n').last, 'pitool_job_main "\$@"');
      // The password appears exactly once: as the line sudo may consume.
      expect('sekret'.allMatches(stdin).length, 1);
    });

    test('an empty password sends no password line at all', () {
      final stdin =
          buildJobFollowStdin(password: '', id: _id);
      expect(stdin, startsWith('$jobSentinel\n'));
    });

    test('the password never reaches a script, payload or command', () {
      const pw = 'Pi>2024;\$(rm -rf /)`x`';
      final stdin = buildJobStartStdin(
          password: pw, id: _id, kind: 'x', payload: buildSystemUpgradePayload());
      final script = stdin.substring(stdin.indexOf('\n') + 1);
      expect(script, isNot(contains(pw)));
      expect(decodeJobPayload(stdin), isNot(contains(pw)));
      expect(jobStartCommand(_id), isNot(contains(pw)));
      final f = buildJobFollowStdin(password: pw, id: _id);
      expect(f.substring(f.indexOf('\n') + 1), isNot(contains(pw)));
    });
  });

  group('launcher / follower / wrapper builders', () {
    final stdin = buildJobStartStdin(
        password: 'pw', id: _id, kind: 'system-upgrade', payload: 'echo hi');
    final launcher = buildJobLauncherScript(
        id: _id, kind: 'system-upgrade', payload: 'echo hi');
    final follower = buildJobFollowerScript(id: _id);
    final wrapper = buildJobWrapperScript();

    test('every script is one function called on its LAST line', () {
      for (final s in [launcher, follower]) {
        final lines = s.trimRight().split('\n');
        expect(lines.last, 'pitool_job_main "\$@"');
        expect(s, contains('pitool_job_main() {'));
      }
      final p = buildJobPayload('echo a');
      expect(p.trimRight().split('\n').last, 'pitool_job_payload "\$@"');
      expect(p, contains('pitool_job_payload() {'));
    });

    test('payload base64 round trip, byte length embedded', () {
      const payload = 'echo "Grüße – ünïcödé"\nexit 3\n';
      final s = buildJobStartStdin(
          password: 'pw', id: _id, kind: 'x', payload: payload);
      expect(decodeJobPayload(s), payload);
      expect(jobKindFromStdin(s), 'x');
      expect(s, contains('local pl_len=${utf8.encode(payload).length}\n'));
      expect(decodeJobPayload('garbage'), isNull);
      expect(jobKindFromStdin('garbage'), isNull);
    });

    test('ids/kinds are single-quoted and validated again in the shell', () {
      expect(launcher, contains("local id='$_id'"));
      expect(launcher, contains("local kind='system-upgrade'"));
      expect(launcher, contains(r'[[ $id =~ ^[0-9a-f]{16}$'));
      expect(launcher, contains(r'$kind =~ ^[a-z0-9-]{1,32}$'));
      expect(follower, contains(r'[[ $id =~ ^[0-9a-f]{16}$ ]]'));
      expect(launcher, contains('pitool-job-start'));
      expect(follower, contains('pitool-job-follow'));
    });

    test('launcher: stdin closed first, busy checks before writing, claim',
        () {
      expect(launcher, contains('exec </dev/null'));
      expect(launcher.indexOf('exec </dev/null'),
          lessThan(launcher.indexOf('install -d')));
      expect(launcher, contains('install -d -m 0755 "\$top"'));
      expect(launcher, contains('install -d -m 0700 "\$base"'));
      expect(launcher,
          contains('systemctl is-active --quiet pi-tool-autoupdate.service'));
      expect(launcher, contains(r'flock -n -E 75 "$lock" true'));
      final busy = launcher.indexOf(r'flock -n -E 75 "$lock" true');
      expect(busy, lessThan(launcher.indexOf(r'mkdir -m 0700 "$d"')));
      expect(launcher, contains(r'install -m 0600 /dev/null "$d/log"'));
      expect(launcher, contains(r'base64 -d >"$d/payload.tmp"'));
      expect(launcher, contains(r'mv "$d/payload.tmp" "$d/payload.sh"'));
      // Claim-by-rename on the start timeout.
      expect(launcher, contains(r'mv "$d/payload.sh" "$d/payload.dead"'));
      expect(launcher, contains("<<'PITOOL_RUNSH'"));
      expect(launcher, contains('\n$wrapper'.trimRight()));
    });

    test('launcher: systemd-run with the agreed properties, no blind fallback',
        () {
      expect(launcher, contains('systemd-run --quiet --unit="\$unit"'));
      for (final p in [
        '-p KillMode=mixed',
        '-p TimeoutStopSec=30min',
        '-p IgnoreSIGPIPE=no',
        '-p RuntimeMaxSec="\$limit"',
      ]) {
        expect(launcher, contains(p));
      }
      expect(launcher, contains("local limit='6h'"));
      expect(buildJobLauncherScript(id: _id, kind: 'pihole-update', payload: ''),
          contains("local limit='2h'"));
      expect(launcher,
          contains(r'systemctl show -p LoadState --value "$unit.service"'));
      expect(launcher, contains('setsid -f /bin/bash "\$d/run.sh"'));
    });

    test('wrapper: constant, claim, locks, fixed env, umask 022, fds 8/9 closed',
        () {
      expect(buildJobWrapperScript(), wrapper); // constant content
      expect(wrapper, startsWith('#!/bin/bash\n'));
      for (final s in [
        r'mv "$d/payload.sh" "$d/payload.run" 2>/dev/null || exit 0',
        r'exec </dev/null >>"$d/log" 2>&1 || exit 74',
        r'exec 9>"$base/lock" || exit 74',
        'flock -w 5 9',
        r'exec 8>"$d/alive" || exit 74',
        'DEBIAN_FRONTEND=noninteractive',
        'APT_LISTCHANGES_FRONTEND=none',
        'NEEDRESTART_MODE=l',
        'UCF_FORCE_CONFFOLD=1',
        'HOME=/root',
        'umask 022',
        r'bash "$d/payload.run" 8>&- 9>&-',
        "trap '",
        'chmod 0644',
        "rundir='/run'",
        r'"$rundir/pi-tool-job-$id.rc"',
        'exit 0',
      ]) {
        expect(wrapper, contains(s), reason: s);
      }
      expect(wrapper.indexOf('umask 022'),
          lessThan(wrapper.indexOf(r'bash "$d/payload.run"')));
      // The wrapper's heredoc terminator never occurs inside it.
      expect(wrapper.split('\n'), isNot(contains('PITOOL_RUNSH')));
    });

    test('follower: log from offset 0, RC/LOST on stdout, HB on stderr', () {
      expect(follower, contains(' off=0 '));
      expect(follower, contains(r"printf '\nPITOOL_JOB_RC %s %s\n'"));
      expect(follower, contains(r"printf '\nPITOOL_JOB_LOST %s\n'"));
      expect(follower, contains(r"printf 'PITOOL_JOB_HB %s\n' "));
      expect(follower, contains(r"'PITOOL_JOB_HB %s\n' " '"\$id" >&2'));
      expect(follower, contains(r"printf 'PITOOL_JOB_UNKNOWN %s\n'"));
      expect(follower, contains(r'flock -n -E 75 "$d/alive" true'));
      expect(follower, contains(r'^[0-9]{1,3}$'));
      expect(follower, isNot(contains('tee ')));
    });

    test('options rebase every path and validate their input', () {
      const o = JobScriptOptions(root: '/tmp/sb', pollSeconds: '0.2', hbEvery: 2);
      final l = buildJobLauncherScript(
          id: _id, kind: 'x', payload: 'true', options: o);
      expect(l, contains("'/tmp/sb/var/lib/pi-tool/jobs'"));
      expect(l, contains("'/tmp/sb/run'"));
      expect(l, isNot(contains("'/var/lib/pi-tool")));
      expect(() => JobScriptOptions(root: "/tmp/a'b").validate(),
          throwsArgumentError);
      expect(() => JobScriptOptions(pollSeconds: '1; rm').validate(),
          throwsArgumentError);
      expect(
          () => buildJobFollowerScript(
              id: _id, options: const JobScriptOptions(root: 'relative')),
          throwsArgumentError);
    });

    test('stdin carries the whole launcher', () {
      expect(stdin, endsWith(launcher));
    });
  });

  group('payloads', () {
    final sys = buildSystemUpgradePayload();
    final evccOnly = buildEvccUpdatePayload(fullUpgrade: false);
    final evccFull = buildEvccUpdatePayload(fullUpgrade: true);
    final pkg = buildPackageUpdatePayload('grafana');
    final repair = buildPackageRepairPayload();
    final pihole = buildPiholeUpdatePayload();

    test('all are function-wrapped', () {
      for (final p in [sys, evccOnly, evccFull, pkg, repair, pihole]) {
        expect(p.trimRight().split('\n').last, 'pitool_job_payload "\$@"');
      }
    });

    test('apt runs non-interactively with confold, after the EOL fix', () {
      for (final p in [sys, evccOnly, evccFull, pkg]) {
        expect(p, contains('--force-confold'));
        expect(p, contains('--force-confdef'));
        expect(p, contains('Dpkg::Use-Pty=0'));
        expect(p, contains('DPkg::Lock::Timeout=300'));
        expect(p, contains('pitool_fix_eol_sources'));
        expect(p.indexOf('pitool_fix_eol_sources'),
            lessThan(p.indexOf('apt-get')));
        expect(p, contains(eolSourcesFixScript.trim()));
        // Repair chain before the lists refresh, before the upgrade.
        expect(p.indexOf('pitool_repair\n'),
            lessThan(p.indexOf('pitool_update_lists\n')));
        expect(p, contains('Acquire::AllowReleaseInfoChange::Suite=true'));
        expect(p, contains(r'echo "PITOOL_APT_UPDATE_RC=$?"'));
        expect(p, contains(jobUpgradeMarker));
      }
      expect(sys, contains(r'apt-get "${O[@]}" full-upgrade -y'));
      expect(evccFull, contains(r'apt-get "${O[@]}" full-upgrade -y'));
      expect(evccOnly,
          contains(r'apt-get "${O[@]}" install --only-upgrade -y evcc'));
      expect(pkg,
          contains(r'''apt-get "${O[@]}" install --only-upgrade -y 'grafana' '''
              .trimRight()));
    });

    test('the repair chain: configure, fix-broken, configure', () {
      expect(repair, contains('dpkg --force-confdef --force-confold --configure -a'));
      expect(repair, contains(r'apt-get "${O[@]}" -f install -y'));
      expect(repair, isNot(contains('pitool_fix_eol_sources')));
      expect(repair, isNot(contains(' update')));
      for (final p in [sys, evccOnly, pkg]) {
        expect(p, contains('dpkg --force-confdef --force-confold --configure -a || true'));
        expect(p, contains(r'apt-get "${O[@]}" -f install -y || true'));
      }
    });

    test('lock wait is bounded and uses fuser only when present', () {
      expect(sys, contains('command -v fuser'));
      expect(sys, contains('/var/lib/dpkg/lock-frontend'));
      expect(sys, contains('/var/lib/apt/lists/lock'));
      expect(sys, contains('-ge 120'));
    });

    test('evcc-update reports service state and version, exits the apt rc',
        () {
      expect(evccOnly, contains('PITOOL_EVCC_ACTIVE='));
      expect(evccOnly, contains('PITOOL_EVCC_VERSION='));
      expect(evccOnly, contains(r'exit "$rc"'));
      expect(evccOnly, contains(versionQuery));
    });

    test('pihole-update is pihole -up and nothing else apt-ish', () {
      expect(pihole, contains('pihole -up'));
      expect(pihole, isNot(contains('apt-get')));
    });

    test('package names are validated and quoted', () {
      expect(() => buildPackageUpdatePayload("x'; rm -rf /"),
          throwsArgumentError);
      expect(() => buildPackageUpdatePayload(''), throwsArgumentError);
      expect(buildPackageUpdatePayload('rpi-connect-lite'),
          contains("'rpi-connect-lite'"));
    });

    test('no payload prints the dpkg remedy text (it would fake a cause)', () {
      for (final p in [sys, evccOnly, pkg, repair, pihole]) {
        final echoes = p
            .split('\n')
            .where((l) => l.contains('echo') || l.contains('printf'));
        for (final e in echoes) {
          expect(e, isNot(contains('dpkg --configure -a')), reason: e);
        }
      }
    });

    test('no payload leaves background processes behind', () {
      for (final p in [sys, evccOnly, evccFull, pkg, repair, pihole]) {
        for (final line in p.split('\n')) {
          final t = line.trim();
          if (t.startsWith('#')) continue;
          expect(t.endsWith('&') && !t.endsWith('&&'), isFalse, reason: t);
          expect(t, isNot(contains('nohup')));
          expect(t, isNot(startsWith('setsid')));
        }
      }
    });

    test('runtime limits per kind', () {
      expect(jobRuntimeLimit(jobKindSystemUpgrade), '6h');
      expect(jobRuntimeLimit(jobKindEvccUpdate), '6h');
      expect(jobRuntimeLimit(jobKindPackageRepair), '6h');
      expect(jobRuntimeLimit(jobKindPackageUpdate), '2h');
      expect(jobRuntimeLimit(jobKindPiholeUpdate), '2h');
    });
  });

  group('classifyJobRun', () {
    JobRun c(String out, {String err = '', int? exit = 0}) =>
        classifyJobRun(stdout: out, stderr: err, exitCode: exit, id: _id);

    test('RC 0 with the log in between', () {
      final r = c(_done('line 1\nline 2'));
      expect(r, isA<JobRunRc>());
      r as JobRunRc;
      expect(r.rc, 0);
      expect(r.log, 'line 1\nline 2');
      expect(r.kind, 'x');
    });

    test('the artificial blank line before RC is removed, nothing else', () {
      final r = c('PITOOL_JOB_STARTED $_id x\nA\n\nB\n\nPITOOL_JOB_RC $_id 3\n')
          as JobRunRc;
      expect(r.log, 'A\n\nB\n');
      expect(r.rc, 3);
    });

    test('trailing log without newline is split cleanly', () {
      final r = c('PITOOL_JOB_STARTED $_id x\nno newline\nPITOOL_JOB_RC $_id 1\n')
          as JobRunRc;
      expect(r.log, 'no newline');
      expect(r.rc, 1);
    });

    test('empty log', () {
      final r = c('PITOOL_JOB_STARTED $_id x\n\nPITOOL_JOB_RC $_id 0\n')
          as JobRunRc;
      expect(r.log, '');
    });

    test('exit 0 without RC is never success', () {
      expect(c('PITOOL_JOB_STARTED $_id x\nhalf a log\n'),
          isA<JobRunDetached>().having((d) => d.started, 'started', isTrue));
      expect(c(''), isA<JobRunDetached>()
          .having((d) => d.started, 'started', isFalse));
      expect(c('', exit: null), isA<JobRunDetached>()
          .having((d) => d.started, 'started', isFalse));
    });

    test('detached keeps the partial log', () {
      final r = c('PITOOL_JOB_STARTED $_id x\npart 1\npart 2\n', exit: null)
          as JobRunDetached;
      expect(r.log, 'part 1\npart 2\n');
      expect(r.kind, 'x');
    });

    test('a foreign id counts for nothing', () {
      expect(c(_done('x', id: _other)), isA<JobRunDetached>()
          .having((d) => d.started, 'started', isFalse));
      final r = c('PITOOL_JOB_STARTED $_id x\nPITOOL_JOB_RC $_other 0\n');
      expect(r, isA<JobRunDetached>());
    });

    test('a non-numeric or empty RC is a failure (255), never 0', () {
      for (final bad in ['', ' ', 'abc', '1x', '-1', '1234']) {
        final r = c('PITOOL_JOB_STARTED $_id x\nlog\nPITOOL_JOB_RC $_id $bad\n');
        expect(r, isA<JobRunRc>().having((x) => x.rc, 'rc', 255),
            reason: '"$bad"');
      }
      final bare = c('PITOOL_JOB_STARTED $_id x\nlog\nPITOOL_JOB_RC $_id\n');
      expect(bare, isA<JobRunRc>().having((x) => x.rc, 'rc', 255));
    });

    test('the last terminal line wins', () {
      final r = c('PITOOL_JOB_STARTED $_id x\n'
          'PITOOL_JOB_RC $_id 0\n'
          'more\n'
          '\nPITOOL_JOB_RC $_id 100\n') as JobRunRc;
      expect(r.rc, 100);
    });

    test('a control line must match exactly (prefix/suffix garbage ignored)',
        () {
      expect(c('xPITOOL_JOB_STARTED $_id x\n'), isA<JobRunDetached>()
          .having((d) => d.started, 'started', isFalse));
      expect(c(' PITOOL_JOB_RC $_id 0\n'), isA<JobRunDetached>());
    });

    test('LOST, with the log', () {
      final r = c('PITOOL_JOB_STARTED $_id x\nA\n\nPITOOL_JOB_LOST $_id\n');
      expect(r, isA<JobRunLost>().having((l) => l.log, 'log', 'A\n'));
    });

    test('UNKNOWN (follower found no such job)', () {
      expect(c('PITOOL_JOB_UNKNOWN $_id\n'), isA<JobRunUnknown>());
    });

    test('BUSY with the running job, or with the autoupdate', () {
      final r = c('PITOOL_JOB_BUSY $_id $_other system-upgrade 1790000000\n');
      expect(r, isA<JobRunBusy>());
      r as JobRunBusy;
      expect(r.otherId, _other);
      expect(r.kind, 'system-upgrade');
      expect(r.since,
          DateTime.fromMillisecondsSinceEpoch(1790000000 * 1000));

      final a = c('PITOOL_JOB_BUSY $_id - autoupdate -\n') as JobRunBusy;
      expect(a.otherId, isNull);
      expect(a.kind, 'autoupdate');
      expect(a.since, isNull);

      final g = c('PITOOL_JOB_BUSY $_id ../x Bad 12x\n') as JobRunBusy;
      expect(g.otherId, isNull);
      expect(g.kind, isNull);
      expect(g.since, isNull);
    });

    test('BUSY/NOSTART only count before STARTED', () {
      final r = c('PITOOL_JOB_STARTED $_id x\n'
          'PITOOL_JOB_BUSY $_id - autoupdate -\n');
      expect(r, isA<JobRunDetached>());
    });

    test('NOSTART', () {
      expect(c('PITOOL_JOB_NOSTART $_id payload\n'),
          isA<JobRunNoStart>().having((n) => n.reason, 'reason', 'payload'));
      expect(c('PITOOL_JOB_NOSTART $_id\n', exit: 1), isA<JobRunNoStart>());
    });

    test('sudo failure', () {
      expect(
          c('',
              err: '[sudo] password for pi: Sorry, try again.\n'
                  'sudo: 3 incorrect password attempts\n',
              exit: 1),
          isA<JobRunSudoFailure>());
    });

    test('a sudo-looking line inside the job log is just log', () {
      expect(c(_done('sudo: 1 incorrect password attempt')), isA<JobRunRc>());
    });

    test('exit 97 without any PITOOL line is a missing header', () {
      expect(c('', exit: 97), isA<JobRunBadHeader>());
      expect(c('PITOOL_JOB_NOSTART $_id setup\n', exit: 97),
          isA<JobRunNoStart>());
    });

    test('HB lines on stderr never reach the log', () {
      final r = classifyJobRun(
          stdout: _done('A'),
          stderr: 'PITOOL_JOB_HB $_id\nPITOOL_JOB_HB $_id\n',
          exitCode: 0,
          id: _id) as JobRunRc;
      expect(r.log, 'A');
    });

    test('stripJobHeartbeats removes exactly this job\'s HB lines', () {
      expect(
          stripJobHeartbeats(
              'A\nPITOOL_JOB_HB $_id\nB\nPITOOL_JOB_HB $_other\n', _id),
          'A\nB\nPITOOL_JOB_HB $_other\n');
    });

    test('isJobControlLine', () {
      expect(isJobControlLine('PITOOL_JOB_HB $_id', _id), isTrue);
      expect(isJobControlLine('PITOOL_JOB_RC $_id 0', _id), isTrue);
      expect(isJobControlLine('PITOOL_JOB_STARTED $_id x', _id), isTrue);
      expect(isJobControlLine('PITOOL_JOB_RC $_other 0', _id), isFalse);
      expect(isJobControlLine('Setting up evcc', _id), isFalse);
    });
  });

  group('parseJobStatus', () {
    const boot = '6f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b';
    const other = '11111111-2222-3333-4444-555555555555';

    test('missing file / garbage → null', () {
      expect(parseJobStatus(''), isNull);
      expect(parseJobStatus('BOOT $boot'), isNull);
      expect(parseJobStatus('garbage\nBOOT $boot'), isNull);
      expect(parseJobStatus('$_id x running - 12 - $boot extra\nBOOT $boot'),
          isNull);
      expect(parseJobStatus('../etc x running - 12 - $boot\nBOOT $boot'),
          isNull);
      expect(parseJobStatus('$_id x weird - 12 - $boot\nBOOT $boot'), isNull);
      expect(parseJobStatus('$_id x done - 12 13 $boot\nBOOT $boot'), isNull);
      expect(parseJobStatus('$_id x done abc 12 13 $boot\nBOOT $boot'), isNull);
      expect(parseJobStatus('$_id x running - abc - $boot\nBOOT $boot'),
          isNull);
    });

    test('running on the same boot', () {
      final s = parseJobStatus(
          '$_id system-upgrade running - 1790000000 - $boot\nBOOT $boot')!;
      expect(s.id, _id);
      expect(s.kind, 'system-upgrade');
      expect(s.state, PiJobState.running);
      expect(s.rc, isNull);
      expect(s.start, DateTime.fromMillisecondsSinceEpoch(1790000000 * 1000));
      expect(s.end, isNull);
      expect(s.ref, const JobRef(id: _id, kind: 'system-upgrade'));
    });

    test('running from an earlier boot → interrupted (rebooted)', () {
      final s = parseJobStatus(
          '$_id system-upgrade running - 1790000000 - $other\nBOOT $boot')!;
      expect(s.state, PiJobState.interrupted);
    });

    test('running without a readable current boot stays running', () {
      final s =
          parseJobStatus('$_id x running - 1790000000 - $other\nBOOT ')!;
      expect(s.state, PiJobState.running);
    });

    test('done with rc and end', () {
      final s = parseJobStatus(
          '$_id package-update done 100 1790000000 1790000600 $boot\nBOOT $boot')!;
      expect(s.state, PiJobState.done);
      expect(s.rc, 100);
      expect(s.end, DateTime.fromMillisecondsSinceEpoch(1790000600 * 1000));
    });

    test('lost', () {
      final s = parseJobStatus(
          '$_id x lost - 1790000000 - $boot\nBOOT $boot')!;
      expect(s.state, PiJobState.lost);
    });

    test('explicit current boot id overrides the section', () {
      final s = parseJobStatus('$_id x running - 1 - $boot\nBOOT $boot',
          currentBootId: other)!;
      expect(s.state, PiJobState.interrupted);
    });

    test('probe is read-only and needs no sudo', () {
      expect(jobStatusProbe, contains('cat /var/lib/pi-tool/job.status'));
      expect(jobStatusProbe, contains('/proc/sys/kernel/random/boot_id'));
      expect(jobStatusProbe, isNot(contains('sudo')));
    });
  });

  group('evaluateJob', () {
    String evccLog({String active = 'active', String version = 'installed 0.311.0',
            String upgrade = '1 upgraded, 0 newly installed'}) =>
        'Pi-Tool: Schließe unterbrochene Paketinstallationen ab …\n'
        '0 upgraded, 0 newly installed, 0 to remove and 3 not upgraded.\n'
        'PITOOL_APT_UPDATE_RC=0\n'
        '$jobUpgradeMarker\n'
        '$upgrade\n'
        'PITOOL_EVCC_ACTIVE=$active\n'
        'PITOOL_EVCC_VERSION=$version\n';

    test('system-upgrade: rc 0 is success, lists state reported', () {
      final ok = evaluateJob(jobKindSystemUpgrade, 0,
          'PITOOL_APT_UPDATE_RC=0\n$jobUpgradeMarker\n12 upgraded\n');
      expect(ok.success, isTrue);
      expect(ok.listsIncomplete, isFalse);
      expect(ok.message, 'System aktualisiert.');
      expect(ok.kind, jobKindSystemUpgrade);

      final partial = evaluateJob(jobKindSystemUpgrade, 0,
          'PITOOL_APT_UPDATE_RC=100\n$jobUpgradeMarker\n0 upgraded\n');
      expect(partial.success, isTrue);
      expect(partial.listsIncomplete, isTrue);
      expect(partial.message, contains('Paketlisten'));
    });

    test('system-upgrade: rc ≠ 0 names the cause or the exit code', () {
      final locked = evaluateJob(jobKindSystemUpgrade, 100,
          '$jobUpgradeMarker\nE: Could not get lock /var/lib/dpkg/lock-frontend\n');
      expect(locked.success, isFalse);
      expect(locked.message, startsWith('System-Upgrade fehlgeschlagen — '));
      expect(locked.message, contains('andere Paketinstallation'));

      final bare = evaluateJob(jobKindSystemUpgrade, 2, 'whatever\n');
      expect(bare.success, isFalse);
      expect(bare.message,
          'System-Upgrade fehlgeschlagen (Exit 2). Details im Log.');

      final dpkg = evaluateJob(jobKindSystemUpgrade, 100,
          "E: dpkg was interrupted, you must manually run 'dpkg --configure -a'\n");
      expect(dpkg.message, contains('reparieren'));
    });

    test('evcc-update: active + version from the markers', () {
      final o = evaluateJob(jobKindEvccUpdate, 0, evccLog());
      expect(o.success, isTrue);
      expect(o.evccActive, isTrue);
      expect(o.evccVersion, '0.311.0');
      expect(o.alreadyNewest, isFalse,
          reason: 'the fix-broken summary before the marker must not count');
    });

    test('evcc-update: already newest from the upgrade output only', () {
      final o = evaluateJob(jobKindEvccUpdate, 0,
          evccLog(upgrade: 'evcc is already the newest version (0.311.0).'));
      expect(o.alreadyNewest, isTrue);
    });

    test('evcc-update: inactive service is a failure even with rc 0', () {
      final o = evaluateJob(jobKindEvccUpdate, 0, evccLog(active: 'failed'));
      expect(o.success, isFalse);
      expect(o.evccActive, isFalse);
      expect(o.message, contains('nicht aktiv'));
    });

    test('evcc-update: a removed package has no version', () {
      final o = evaluateJob(
          jobKindEvccUpdate, 0, evccLog(version: 'config-files 0.311.0'));
      expect(o.evccVersion, isNull);
    });

    test('evcc-update: rc ≠ 0', () {
      final o = evaluateJob(jobKindEvccUpdate, 100, evccLog());
      expect(o.success, isFalse);
      expect(o.message, contains('fehlgeschlagen'));
    });

    test('evcc-update without markers: not active, no version', () {
      final o = evaluateJob(jobKindEvccUpdate, 0, '');
      expect(o.success, isFalse);
      expect(o.evccActive, isFalse);
      expect(o.evccVersion, isNull);
    });

    test('package-update names the package', () {
      final ok = evaluateJob(jobKindPackageUpdate, 0, 'PITOOL_PACKAGE=grafana\n');
      expect(ok.success, isTrue);
      expect(ok.message, 'grafana ist aktuell.');
      final bad = evaluateJob(jobKindPackageUpdate, 100,
          "PITOOL_PACKAGE=grafana\nE: The repository 'http://x/y buster Release' "
          'no longer has a Release file.\n');
      expect(bad.success, isFalse);
      expect(bad.message, startsWith('grafana-Update fehlgeschlagen — '));
      expect(bad.message, contains('http://x/y buster'));
    });

    test('package-repair', () {
      expect(evaluateJob(jobKindPackageRepair, 0, '').message,
          'Paketzustand repariert.');
      final bad = evaluateJob(jobKindPackageRepair, 1, 'x');
      expect(bad.success, isFalse);
      expect(bad.message, 'Reparatur fehlgeschlagen (Exit 1). Details im Log.');
    });

    test('pihole-update', () {
      expect(evaluateJob(jobKindPiholeUpdate, 0, '[✓] Update complete').success,
          isTrue);
      expect(evaluateJob(jobKindPiholeUpdate, 1, '').message,
          'Pi-hole-Update fehlgeschlagen (Exit 1). Details im Log.');
      final dpkg = evaluateJob(jobKindPiholeUpdate, 0,
          "E: dpkg was interrupted, you must manually run 'dpkg --configure -a'");
      expect(dpkg.success, isFalse);
      expect(dpkg.message, contains('reparieren'));
    });

    test('unknown kind: rc decides', () {
      expect(evaluateJob('something', 0, '').success, isTrue);
      expect(evaluateJob('something', 3, '').success, isFalse);
    });

    test('aptFailureCause keeps its behaviour', () {
      expect(aptFailureCause('nothing'), isNull);
      expect(aptFailureCause('E: Could not get lock /var/lib/dpkg/lock'),
          contains('andere Paketinstallation'));
      expect(aptFailureCause('dpkg was interrupted'), dpkgInterruptedMessage);
    });

    test('kind labels are German and exist for every Tier-1 kind', () {
      for (final k in [
        jobKindSystemUpgrade,
        jobKindEvccUpdate,
        jobKindPackageUpdate,
        jobKindPackageRepair,
        jobKindPiholeUpdate,
        'autoupdate',
      ]) {
        expect(jobKindLabel(k), isNot(k));
      }
      expect(jobKindLabel('zzz'), 'Pi-Job');
    });
  });

  // Syntax check of every generated script with a real bash (Linux, or Git
  // Bash on Windows) — catches quoting slips without running anything.
  group('bash -n', () {
    final scripts = <String, String>{
      'launcher': buildJobLauncherScript(
          id: _id, kind: 'system-upgrade', payload: buildSystemUpgradePayload()),
      'follower': buildJobFollowerScript(id: _id),
      'wrapper': buildJobWrapperScript(),
      'system-upgrade': buildSystemUpgradePayload(),
      'evcc-only': buildEvccUpdatePayload(fullUpgrade: false),
      'evcc-full': buildEvccUpdatePayload(fullUpgrade: true),
      'package-update': buildPackageUpdatePayload('grafana'),
      'package-repair': buildPackageRepairPayload(),
      'pihole-update': buildPiholeUpdatePayload(),
      'bootstrap': jobBootstrap,
    };
    for (final e in scripts.entries) {
      test(e.key, () {
        final dir = Directory.systemTemp.createTempSync('pitool-n');
        try {
          final f = File('${dir.path}/s.sh')..writeAsStringSync(e.value);
          final res = Process.runSync(_bash!, ['-n', _posix(f.path)]);
          expect(res.exitCode, 0, reason: '${res.stderr}');
        } finally {
          dir.deleteSync(recursive: true);
        }
      });
    }
  }, skip: _bash == null ? 'braucht bash (Linux oder Git Bash)' : false);
}

const String _gitBash = r'C:\Program Files\Git\bin\bash.exe';

final String? _bash = Platform.isLinux
    ? 'bash'
    : Platform.isWindows && File(_gitBash).existsSync()
        ? _gitBash
        : null;

String _posix(String p) => p.replaceAll(r'\', '/');
