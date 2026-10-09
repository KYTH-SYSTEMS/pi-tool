import 'dart:io';

import 'package:evcc_updater/src/auto_update.dart';
import 'package:evcc_updater/src/pi_job.dart'
    show jobKindSystemUpgrade, jobRuntimeLimit;
import 'package:flutter_test/flutter_test.dart';

import 'on_pi_sandbox.dart';

// ---- stubs of the wrapper sandbox; each reads its scenario from $S ---------

/// `systemctl is-active evcc`: the n-th call prints line n of `$S/evcc-states`
/// (its last line once there are fewer; "active" without the file).
const String _systemctl = r'''
if [ "$1" = is-active ]; then
  n=$(cat "$S/is-active-n" 2>/dev/null || echo 0)
  n=$((n + 1))
  echo "$n" > "$S/is-active-n"
  st=$(sed -n "${n}p" "$S/evcc-states" 2>/dev/null)
  [ -n "$st" ] || st=$(tail -n 1 "$S/evcc-states" 2>/dev/null)
  [ -n "$st" ] || st=active
  echo "$st"
  [ "$st" = active ]
  exit $?
fi
exit 0''';

/// apt-get: `update` and `full-upgrade` print `$S/<step>-out` and exit with
/// `$S/<step>-rc` (0 without). During the upgrade it notes how it inherited
/// SIGTERM and, when `$S/term-parent` exists, sends one to the wrapper — like
/// systemd stopping the unit with KillMode=mixed.
const String _aptGet = r'''
step=
case " $* " in
  *" update "*) step=update ;;
  *" full-upgrade "*) step=upgrade ;;
esac
[ -n "$step" ] || exit 0
if [ "$step" = upgrade ]; then
  trap -p TERM > "$S/apt-term-trap"
  [ -e "$S/term-parent" ] && kill -TERM "$PPID"
fi
cat "$S/$step-out" 2>/dev/null
exit "$(cat "$S/$step-rc" 2>/dev/null || echo 0)"''';

/// fuser: another process holds the apt locks for the first two probes.
const String _fuserBusyTwice = r'''
n=$(cat "$S/fuser-n" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$S/fuser-n"
[ "$n" -le 2 ]''';

/// The apt options of a Pi-Job payload (pi_job.dart), as the calls show them.
const String _o = '-o Dpkg::Use-Pty=0 -o DPkg::Lock::Timeout=300 '
    '-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold';

/// systemd for the status probe: a timer is enabled when its unit file is
/// there, and `list-timers` names its next run.
const String _systemctlForProbe = r'''
case "$1" in
  is-enabled)
    [ -e "$R/etc/systemd/system/$2" ] && { echo enabled; exit 0; }
    exit 1 ;;
  list-timers)
    [ -e "$R/etc/systemd/system/$3" ] &&
      echo "Sun 2026-10-11 04:00:00 CEST 2 days left n/a n/a $3 pi-tool.service" ;;
esac
exit 0''';

/// The install script of v0.71.0 (wrapper generation 2) as it went over the
/// wire, the wrapper cut short after its first lines — nothing here runs it.
/// `@ONCALENDAR@` stands for the schedule.
const String _installV071 = r'''
set -e
mkdir -p /var/lib/pi-tool /var/backups/pi-tool
cat > /usr/local/lib/pi-tool-autoupdate.sh <<'WRAP'
#!/bin/bash
# pi-tool-wrapper 2
export DEBIAN_FRONTEND=noninteractive
mkdir -p /var/lib/pi-tool /var/backups/pi-tool
ts=$(date '+%Y-%m-%d %H:%M:%S')
was=$(systemctl is-active evcc 2>/dev/null)
WRAP
chmod +x /usr/local/lib/pi-tool-autoupdate.sh
cat > /etc/systemd/system/pi-tool-autoupdate.service <<'SVC'
[Unit]
Description=Pi-Tool automatische Updates
[Service]
Type=oneshot
ExecStart=/usr/local/lib/pi-tool-autoupdate.sh
SVC
cat > /etc/systemd/system/pi-tool-autoupdate.timer <<'TMR'
[Unit]
Description=Pi-Tool automatische Updates (Timer)
[Timer]
OnCalendar=@ONCALENDAR@
Persistent=true
[Install]
WantedBy=timers.target
TMR
systemctl daemon-reload
systemctl enable --now pi-tool-autoupdate.timer
echo AUTOUPDATE_INSTALLED
''';

/// The same for v0.24.0 up to v0.54: no stamp in the wrapper, and the timer
/// unit in an unquoted heredoc.
const String _installV024 = r'''
set -e
mkdir -p /var/lib/pi-tool /var/backups/pi-tool
cat > /usr/local/lib/pi-tool-autoupdate.sh <<'WRAP'
#!/bin/sh
mkdir -p /var/lib/pi-tool /var/backups/pi-tool
ts=$(date '+%Y-%m-%d %H:%M:%S')
was=$(systemctl is-active evcc 2>/dev/null)
WRAP
chmod +x /usr/local/lib/pi-tool-autoupdate.sh
cat > /etc/systemd/system/pi-tool-autoupdate.service <<'SVC'
[Unit]
Description=Pi-Tool automatische Updates
[Service]
Type=oneshot
ExecStart=/usr/local/lib/pi-tool-autoupdate.sh
SVC
cat > /etc/systemd/system/pi-tool-autoupdate.timer <<TMR
[Unit]
Description=Pi-Tool automatische Updates (Timer)
[Timer]
OnCalendar=@ONCALENDAR@
Persistent=true
[Install]
WantedBy=timers.target
TMR
systemctl daemon-reload
systemctl enable --now pi-tool-autoupdate.timer
echo AUTOUPDATE_INSTALLED
''';

void main() {
  group('autoUpdateOnCalendar', () {
    test('daily at a padded hour', () {
      expect(autoUpdateOnCalendar(weekly: false, hour: 4), '*-*-* 04:00:00');
      expect(autoUpdateOnCalendar(weekly: false, hour: 22), '*-*-* 22:00:00');
    });
    test('weekly maps the weekday to a systemd day name', () {
      expect(autoUpdateOnCalendar(weekly: true, hour: 3, weekday: 7),
          'Sun *-*-* 03:00:00');
      expect(autoUpdateOnCalendar(weekly: true, hour: 5, weekday: 1),
          'Mon *-*-* 05:00:00');
    });
  });

  // The sheet opens with what is installed. Whatever it cannot show must not
  // be turned into something similar.
  group('autoUpdateScheduleOf', () {
    test('is the inverse of autoUpdateOnCalendar for every schedule the '
        'pickers can produce', () {
      for (var hour = 0; hour < 24; hour++) {
        expect(
            autoUpdateScheduleOf(
                autoUpdateOnCalendar(weekly: false, hour: hour)),
            (weekly: false, hour: hour, weekday: 7));
        for (var day = 1; day <= 7; day++) {
          expect(
              autoUpdateScheduleOf(autoUpdateOnCalendar(
                  weekly: true, hour: hour, weekday: day)),
              (weekly: true, hour: hour, weekday: day));
        }
      }
    });

    test('a schedule the pickers cannot show, or none: null', () {
      for (final other in [
        null,
        '',
        'daily',
        '*-*-* 04:30:00',
        '*-*-* 04:00:30',
        '*-*-* 4:00:00',
        '*-*-01 04:00:00',
        'Mon,Thu *-*-* 04:00:00',
        'Sun *-*-* 04:00:00 UTC',
      ]) {
        expect(autoUpdateScheduleOf(other), isNull, reason: '$other');
      }
    });
  });

  group('buildAutoUpdateInstallScript', () {
    final s = buildAutoUpdateInstallScript(onCalendar: '*-*-* 04:00:00');
    test('installs a timer with the given schedule + enables it', () {
      expect(s, contains('OnCalendar=*-*-* 04:00:00'));
      expect(s, contains('systemctl daemon-reload'));
      expect(s, contains('enable --now pi-tool-autoupdate.timer'));
      expect(s, contains('AUTOUPDATE_INSTALLED'));
    });
    test('the .timer heredoc is QUOTED (no install-time shell expansion)', () {
      expect(s, contains("<<'TMR'"));
    });
    test('the wrapper repoints dead EOL sources before refreshing apt', () {
      // Unattended Pis on Raspbian Buster would otherwise fail every night.
      expect(s, contains('pitool_fix_eol_sources'));
      expect(s.indexOf('pitool_fix_eol_sources || true'),
          lessThan(s.indexOf(' update -qq')));
      // The repair script is bash (arrays, [[ =~ ]]) — so is the wrapper.
      expect(s, contains('#!/bin/bash'));
      expect(s, isNot(contains('#!/bin/sh')));
    });
    test('the wrapper updates apt, self-heals evcc, and logs a result', () {
      expect(s, contains(' update -qq'));
      expect(s, contains('full-upgrade'));
      // Unattended: must not hang on a dpkg conffile prompt.
      expect(s, contains('DEBIAN_FRONTEND=noninteractive'));
      expect(s, contains('force-confold'));
      // backup evcc before + bring it back if it dies during the upgrade
      expect(s, contains('systemctl is-active evcc'));
      expect(s, contains('/var/backups/pi-tool'));
      expect(s, contains('/var/lib/pi-tool/autoupdate.status'));
    });

    test('every schedule the sheet can produce is accepted', () {
      for (var hour = 0; hour < 24; hour++) {
        buildAutoUpdateInstallScript(
            onCalendar: autoUpdateOnCalendar(weekly: false, hour: hour));
        for (var day = 1; day <= 7; day++) {
          buildAutoUpdateInstallScript(
              onCalendar:
                  autoUpdateOnCalendar(weekly: true, hour: hour, weekday: day));
        }
      }
    });

    test('anything else is refused: the value lands in a unit file inside a '
        'root heredoc', () {
      for (final bad in [
        'x',
        '',
        'daily',
        '*-*-* 24:00:00',
        '*-*-* 04:00:00\n',
        '*-*-* 04:00:00\nTMR\nreboot',
        '*-*-* 04:00:00\nPersistent=false',
      ]) {
        expect(() => buildAutoUpdateInstallScript(onCalendar: bad),
            throwsArgumentError,
            reason: bad);
      }
    });

    // A oneshot unit is "activating" for its whole run, and while it is, the
    // app refuses reboot and shutdown and starts no Pi-Job. RuntimeMaxSec does
    // not apply to that state; TimeoutStartSec does.
    test('the service waits for the network, is not cut off mid-run and has '
        'the runtime cap of a system-upgrade job', () {
      expect(heredocBody(s, 'SVC').split('\n'), [
        '[Unit]',
        'Description=Pi-Tool automatische Updates',
        'Wants=network-online.target',
        'After=network-online.target',
        '[Service]',
        'Type=oneshot',
        'ExecStart=/usr/local/lib/pi-tool-autoupdate.sh',
        'TimeoutStartSec=6h',
        'KillMode=mixed',
        'TimeoutStopSec=30min',
      ]);
      expect(jobRuntimeLimit(jobKindSystemUpgrade), '6h');
    });
  });

  group('buildAutoUpdateRemoveScript', () {
    final s = buildAutoUpdateRemoveScript();
    test('disables + removes the timer and reloads', () {
      expect(s, contains('disable --now pi-tool-autoupdate.timer'));
      expect(s, contains('rm -f'));
      expect(s, contains('systemctl daemon-reload'));
      expect(s, contains('AUTOUPDATE_REMOVED'));
    });
  });

  // The probe exactly as the app sends it — one command line, no sudo —
  // against the files an install script left in the sandbox.
  group('auto-update status probe in bash', () {
    late PiSandbox pi;

    setUp(() {
      pi = PiSandbox();
      pi.stub('systemctl', _systemctlForProbe, log: false);
    });
    tearDown(() => pi.dispose());

    Future<AutoUpdateStatus> probe() async {
      final r = await pi.run(autoUpdateStatusCommand);
      expect(r.code, 0, reason: r.err);
      expect(r.err, isEmpty);
      return parseAutoUpdateStatus(r.out);
    }

    Future<void> install(String script) async {
      final r = await pi.run(script);
      expect(r.code, 0, reason: r.err);
      expect(r.lines.last, 'AUTOUPDATE_INSTALLED');
    }

    test('no timer on the Pi: off, no schedule, nothing to renew', () async {
      final st = await probe();
      expect(st.enabled, isFalse);
      expect(st.nextRun, isNull);
      expect(st.lastResult, isNull);
      expect(st.schedule, isNull);
      expect(st.wrapperOutdated, isFalse);
    });

    test('every schedule the sheet can set comes back as it was set',
        () async {
      for (final wanted in [
        (weekly: false, hour: 4, weekday: 7),
        (weekly: false, hour: 23, weekday: 7),
        (weekly: true, hour: 22, weekday: 3),
        (weekly: true, hour: 0, weekday: 1),
        (weekly: true, hour: 4, weekday: 7),
      ]) {
        await install(buildAutoUpdateInstallScript(
            onCalendar: autoUpdateOnCalendar(
                weekly: wanted.weekly,
                hour: wanted.hour,
                weekday: wanted.weekday)));
        final st = await probe();
        expect(st.schedule, wanted);
        expect(st.enabled, isTrue);
        expect(st.nextRun, 'Sun 2026-10-11 04:00:00');
        expect(st.wrapperOutdated, isFalse);
      }
    });

    test('a timer set up by v0.71.0: its weekly schedule is read, and the '
        'wrapper is the one to renew', () async {
      await install(
          _installV071.replaceAll('@ONCALENDAR@', 'Sat *-*-* 02:00:00'));
      final st = await probe();
      expect(st.schedule, (weekly: true, hour: 2, weekday: 6));
      expect(st.enabled, isTrue);
      expect(st.wrapperOutdated, isTrue);
    });

    test('a timer from before the stamps (v0.24.0, unquoted unit heredoc): '
        'the same', () async {
      await install(
          _installV024.replaceAll('@ONCALENDAR@', 'Mon *-*-* 05:00:00'));
      final st = await probe();
      expect(st.schedule, (weekly: true, hour: 5, weekday: 1));
      expect(st.wrapperOutdated, isTrue);
    });

    test('a unit edited by hand to something the pickers cannot show: no '
        'schedule, the rest of the status stands', () async {
      await install(buildAutoUpdateInstallScript(onCalendar: '*-*-* 04:00:00'));
      const unit = '/etc/systemd/system/$autoUpdateUnit.timer';
      pi.put(
          unit,
          pi.read(unit).replaceFirst(
              'OnCalendar=*-*-* 04:00:00', 'OnCalendar=*-*-* 04:30:00'));
      final st = await probe();
      expect(st.schedule, isNull);
      expect(st.enabled, isTrue);
    });
  }, skip: needsBash);

  // Switched off, the sheet must not go on showing the last run of a timer
  // that is no longer there.
  group('auto-update remove script in bash', () {
    late PiSandbox pi;

    setUp(() {
      pi = PiSandbox();
      pi.stub('systemctl', _systemctlForProbe, log: false);
    });
    tearDown(() => pi.dispose());

    test('takes status, log and setup time along — and leaves the backups',
        () async {
      final r = await pi
          .run(buildAutoUpdateInstallScript(onCalendar: 'Sun *-*-* 04:00:00'));
      expect(r.lines.last, 'AUTOUPDATE_INSTALLED', reason: r.err);
      pi.put('/var/lib/pi-tool/autoupdate.status', '2026-10-04 04:00:12 ok\n');
      pi.put('/var/lib/pi-tool/autoupdate.log', 'Reading package lists...\n');
      // Left by a run that was killed before it could move the log into place.
      pi.put('/var/lib/pi-tool/autoupdate.log.new', 'Reading\n');
      pi.put('/var/lib/pi-tool/job.status', 'other state of the app\n');
      pi.put('/var/backups/pi-tool/autoupdate-evcc-20261004-040000.tar.gz');
      expect(
          parseAutoUpdateStatus((await pi.run(autoUpdateStatusCommand)).out)
              .lastResult,
          '2026-10-04 04:00:12 ok');

      final off = await pi.run(buildAutoUpdateRemoveScript());
      expect(off.code, 0, reason: off.err);
      expect(off.lines.last, 'AUTOUPDATE_REMOVED');
      expect(pi.ls('/var/lib/pi-tool'), ['job.status']);
      expect(pi.ls('/var/backups/pi-tool'),
          ['autoupdate-evcc-20261004-040000.tar.gz']);

      final st =
          parseAutoUpdateStatus((await pi.run(autoUpdateStatusCommand)).out);
      expect(st.enabled, isFalse);
      expect(st.lastResult, isNull);
      expect(st.schedule, isNull);
    });

    test('nothing of it there (never ran): still ends with the marker',
        () async {
      final off = await pi.run(buildAutoUpdateRemoveScript());
      expect(off.code, 0, reason: off.err);
      expect(off.lines.last, 'AUTOUPDATE_REMOVED');
    });
  }, skip: needsBash);

  // The wrapper as the install script writes it, run under its own shebang on
  // a sandboxed Pi.
  group('auto-update wrapper in bash', () {
    late PiSandbox pi;
    const wrapper = '/usr/local/lib/$autoUpdateUnit.sh';
    const status = '/var/lib/pi-tool/autoupdate.status';
    const log = '/var/lib/pi-tool/autoupdate.log';

    setUp(() async {
      pi = PiSandbox();
      pi.stub('systemctl', _systemctl);
      pi.stub('dpkg-query', r'[ ! -e "$S/no-evcc" ]');
      pi.stub('dpkg', 'exit 0');
      pi.stub('apt-get', _aptGet, shell: 'bash');
      // Only reached with EOL package sources, which this Pi does not have.
      pi.stub('curl', 'exit 7');
      final r = await pi
          .run(buildAutoUpdateInstallScript(onCalendar: '*-*-* 04:00:00'));
      expect(r.code, 0, reason: r.err);
      expect(r.lines.last, 'AUTOUPDATE_INSTALLED');
      // The setup was long ago: the runs below are scheduled ones.
      pi.put(autoUpdateSetupPath, '0\n');
      pi.clearCalls();
    });
    tearDown(() => pi.dispose());

    /// One run of the timer; returns the status line it left.
    Future<String> runWrapper() async {
      final r = await pi.run("'${pi.root}$wrapper'", rebase: false);
      expect(r.code, 0, reason: r.err);
      expect(r.err, isEmpty);
      return pi.read(status).trim();
    }

    List<String> packageCalls() => pi.calls
        .where((c) => c.startsWith('apt-get ') || c.startsWith('dpkg '))
        .toList();

    int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // systemd may start the job of a Persistent timer the moment it is set up
    // or re-scheduled. That must never be an upgrade.
    test('started right after the setup: nothing is touched, and the run '
        'says why', () async {
      for (final setup in [now(), now() - 240]) {
        pi.put(autoUpdateSetupPath, '$setup\n');
        final r = await pi.run("'${pi.root}$wrapper'", rebase: false);
        expect(r.code, 0, reason: r.err);
        expect(r.out, contains('zählt nicht als geplanter Lauf'));
        expect(pi.calls, isEmpty);
        expect(pi.exists(status), isFalse);
        expect(pi.exists(log), isFalse);
      }
    });

    test('the setup script itself leaves the wrapper in that state', () async {
      final r = await pi
          .run(buildAutoUpdateInstallScript(onCalendar: 'Sun *-*-* 03:00:00'));
      expect(r.lines.last, 'AUTOUPDATE_INSTALLED', reason: r.err);
      pi.clearCalls();
      await pi.run("'${pi.root}$wrapper'", rebase: false);
      expect(pi.calls, isEmpty);
      expect(pi.exists(status), isFalse);
    });

    test('more than five minutes after the setup — or with a setup time that '
        'cannot be right — it is a scheduled run', () async {
      for (final setup in [
        '${now() - 301}',
        '${now() + 3600}', // the clock was set back since
        '',
        'x',
      ]) {
        pi.put(autoUpdateSetupPath, '$setup\n');
        pi.clearCalls();
        final st = await runWrapper();
        expect(packageCalls().last, 'apt-get $_o full-upgrade -y',
            reason: setup);
        expect(st, matches(RegExp('^$statusTime ok\$')), reason: setup);
      }
      pi.remove(autoUpdateSetupPath);
      pi.clearCalls();
      await runWrapper();
      expect(packageCalls(), hasLength(5));
    });

    test('repair, package lists, upgrade — in this order, with the apt '
        'options of a Pi-Job', () async {
      final st = await runWrapper();
      expect(packageCalls(), [
        'dpkg --force-confdef --force-confold --configure -a',
        'apt-get $_o -f install -y',
        'dpkg --force-confdef --force-confold --configure -a',
        'apt-get -o APT::Update::Error-Mode=any '
            '-o Acquire::AllowReleaseInfoChange::Suite=true '
            '-o Acquire::Retries=3 update -qq',
        'apt-get $_o full-upgrade -y',
      ]);
      expect(st, matches(RegExp('^$statusTime ok\$')));
    });

    test('apt-get full-upgrade exits 100: the status names the code, the log '
        'keeps what apt said', () async {
      pi.put('/state/upgrade-rc', '100');
      pi.put(
          '/state/upgrade-out',
          'E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by '
              'process 4711 (unattended-upgr)\n');
      final st = await runWrapper();
      expect(st, matches(RegExp('^$statusTime fehler\\(rc=100\\)\$')));
      expect(pi.read(log),
          contains('E: Could not get lock /var/lib/dpkg/lock-frontend.'));
    });

    test('package lists that did not load are named next to the "ok" of the '
        'upgrade', () async {
      pi.put('/state/update-rc', '100');
      pi.put(
          '/state/update-out',
          "E: The repository 'http://deb.example/debian bookworm Release' no "
              'longer has a Release file.\n');
      final st = await runWrapper();
      expect(st,
          matches(RegExp('^$statusTime ok; paketlisten-fehler\\(rc=100\\)\$')));
      expect(pi.read(log), contains('no longer has a Release file.'));
      // The upgrade is still tried: other sources may have loaded.
      expect(packageCalls().last, 'apt-get $_o full-upgrade -y');
    });

    test('lists and upgrade both fail: both are in the status line', () async {
      pi.put('/state/update-rc', '100');
      pi.put('/state/upgrade-rc', '100');
      final st = await runWrapper();
      expect(
          st,
          matches(RegExp('^$statusTime fehler\\(rc=100\\); '
              'paketlisten-fehler\\(rc=100\\)\$')));
    });

    test('another package run holds the apt locks: the wrapper waits for it '
        'instead of failing', () async {
      pi.stub('fuser', _fuserBusyTwice);
      final st = await runWrapper();
      final firstPackageCall = pi.calls.indexOf(packageCalls().first);
      expect(
          pi.calls.sublist(0, firstPackageCall).where((c) => c == 'sleep 5'),
          hasLength(2));
      expect(pi.read(log), contains('Eine andere Paketverwaltung läuft gerade'));
      expect(st, matches(RegExp('^$statusTime ok\$')));
    });

    test('SIGTERM during the upgrade (systemd stops the unit): the run '
        'finishes and writes its status; apt does not inherit an ignored TERM',
        () async {
      pi.put('/state/term-parent', '');
      final st = await runWrapper();
      expect(st, matches(RegExp('^$statusTime ok\$')));
      expect(pi.read(log), contains('Stopp angefordert'));
      // An ignored signal would be passed on to apt, dpkg and everything a
      // maintainer script starts; a handler is not.
      expect(pi.read('/state/apt-term-trap'), isEmpty);
    });

    test('evcc ran before and is down after the upgrade: it is restarted and '
        'the status says so', () async {
      pi.put('/state/evcc-states', 'active\nfailed\n');
      final st = await runWrapper();
      expect(pi.calls, contains('systemctl restart evcc'));
      expect(st, matches(RegExp('^$statusTime ok; evcc-neustart\$')));
    });

    test('no /etc/evcc.yaml (evcc set up in the web UI): the state is archived '
        'before the upgrade', () async {
      pi.put('/var/lib/evcc/evcc.db', 'DB');
      final st = await runWrapper();
      expect(pi.ls('/var/backups/pi-tool'),
          [matches(RegExp(r'^autoupdate-evcc-\d{8}-\d{6}\.tar\.gz$'))]);
      expect(st, matches(RegExp('^$statusTime ok\$')));
    });

    test('the log holds the last run only, cut to its last 200 lines',
        () async {
      pi.put('/state/upgrade-out',
          [for (var i = 1; i <= 500; i++) 'Setting up pkg$i ...\n'].join());
      await runWrapper();
      final lines = pi.read(log).trim().split('\n');
      expect(lines, hasLength(200));
      expect(lines.last, 'Setting up pkg500 ...');
      pi.put('/state/upgrade-out', 'Setting up later ...\n');
      await runWrapper();
      expect(pi.read(log), isNot(contains('pkg500')));
      expect(pi.read(log).trim().split('\n').last, 'Setting up later ...');
      expect(pi.ls('/var/lib/pi-tool'),
          ['autoupdate.log', 'autoupdate.setup', 'autoupdate.status']);
      if (!Platform.isWindows) {
        // apt names the package sources; a source may carry credentials.
        expect(await pi.mode(log), '600');
      }
    });
  }, skip: needsBash);

  group('parseAutoUpdateStatus', () {
    test('reads enabled state, next run and last result', () {
      const out = 'ENABLED enabled\n'
          'NEXT Sun 2026-07-12 04:00:00\n'
          'STATUS 2026-07-05 04:00:12 ok\n';
      final st = parseAutoUpdateStatus(out);
      expect(st.enabled, isTrue);
      expect(st.nextRun, contains('2026-07-12'));
      expect(st.lastResult, '2026-07-05 04:00:12 ok');
    });
    test('disabled / never-run yields sensible defaults', () {
      final st = parseAutoUpdateStatus('ENABLED disabled\nNEXT \nSTATUS \n');
      expect(st.enabled, isFalse);
      expect(st.nextRun, isNull);
      expect(st.lastResult, isNull);
    });
    test('empty output → disabled, nothing known', () {
      final st = parseAutoUpdateStatus('');
      expect(st.enabled, isFalse);
      expect(st.nextRun, isNull);
      expect(st.lastResult, isNull);
      expect(st.schedule, isNull);
    });
    test('the installed schedule is handed on as the pickers show it', () {
      const head = 'ENABLED enabled\nNEXT Wed 2026-10-14 22:00:00\nSTATUS \n'
          'WRAPPER 2\n';
      expect(
          parseAutoUpdateStatus('${head}ONCALENDAR Wed *-*-* 22:00:00\n')
              .schedule,
          (weekly: true, hour: 22, weekday: 3));
      expect(
          parseAutoUpdateStatus('${head}ONCALENDAR *-*-* 05:00:00\n').schedule,
          (weekly: false, hour: 5, weekday: 7));
      // Not known (a probe answer without the line) or not one of ours.
      expect(parseAutoUpdateStatus(head).schedule, isNull);
      expect(parseAutoUpdateStatus('${head}ONCALENDAR \n').schedule, isNull);
      expect(
          parseAutoUpdateStatus('${head}ONCALENDAR *-*-* 04:30:00\n').schedule,
          isNull);
      // The rest of the status does not depend on it.
      final st = parseAutoUpdateStatus('${head}ONCALENDAR hourly\n');
      expect(st.enabled, isTrue);
      expect(st.nextRun, 'Wed 2026-10-14 22:00:00');
      expect(st.wrapperOutdated, isTrue);
    });
    test('status lines of every wrapper generation are handed on as written',
        () {
      for (final line in [
        // Generation 2 (v0.71.0) and before.
        '2026-10-08 04:00:12 ok',
        '2026-10-08 04:00:12 fehler(rc=100)',
        '2026-10-08 04:00:12 ok; evcc-neustart; backup-fehler(rc=2)',
        // Generation 3: package lists that did not load.
        '2026-10-08 04:00:12 ok; paketlisten-fehler(rc=100)',
        '2026-10-08 04:00:12 fehler(rc=100); paketlisten-fehler(rc=100); '
            'evcc-neustart; backup-fehler(rc=2)',
      ]) {
        final st = parseAutoUpdateStatus(
            'ENABLED enabled\nNEXT Sun 2026-10-11 04:00:00\nSTATUS $line\n'
            'WRAPPER 2\n');
        expect(st.lastResult, line);
        expect(st.enabled, isTrue);
      }
    });
  });
}
