import 'package:evcc_updater/src/on_pi_wrapper.dart'
    show scheduledBackupWrapperStamp;
import 'package:evcc_updater/src/scheduled_backup.dart';
import 'package:flutter_test/flutter_test.dart';

import 'on_pi_sandbox.dart';

/// systemd for the status probe: a timer is enabled when its unit file is
/// there, and `list-timers` names its next run.
const String _systemctlForProbe = r'''
case "$1" in
  is-enabled)
    [ -e "$R/etc/systemd/system/$2" ] && { echo enabled; exit 0; }
    exit 1 ;;
  list-timers)
    [ -e "$R/etc/systemd/system/$3" ] &&
      echo "Sat 2026-10-10 03:00:00 CEST 9h left n/a n/a $3 pi-tool.service" ;;
esac
exit 0''';

/// The install script of v0.55.0 up to v0.70.0 as it went over the wire:
/// the wrapper from before the stamps. `@ONCALENDAR@` stands for the schedule
/// and `@DROP@` for the retention + 1.
const String _installV070 = r'''
set -e
mkdir -p /var/lib/pi-tool /var/backups/pi-tool
cat > /usr/local/lib/pi-tool-backup.sh <<'WRAP'
#!/bin/sh
mkdir -p /var/lib/pi-tool /var/backups/pi-tool
ts=$(date '+%Y-%m-%d %H:%M:%S')
stamp=$(date +%Y%m%d-%H%M%S)
done=""
# evcc (config + state), only if present. Write atomically: a failed/partial
# tar must NEVER become the newest file and evict a good backup on rotation.
if [ -f /etc/evcc.yaml ] || [ -d /var/lib/evcc ]; then
  out="/var/backups/pi-tool/sched-evcc-$stamp.tar.gz"
  if tar -czf "$out.part" /etc/evcc.yaml /var/lib/evcc 2>/dev/null; then
    mv "$out.part" "$out"
    done="$done evcc"
    # Rotate ONLY after a real success; the glob excludes the .part temp.
    ls -1t /var/backups/pi-tool/sched-evcc-*.tar.gz 2>/dev/null | tail -n +@DROP@ | xargs -r rm -f -- || true
  else
    rm -f "$out.part"
  fi
fi
# Pi-hole teleporter, only if present. Teleporter writes into a temp dir; we only
# move a produced file into place, and rotate only after that success.
if command -v pihole >/dev/null 2>&1 || command -v pihole-FTL >/dev/null 2>&1; then
  d=$(mktemp -d)
  ( cd "$d" && { pihole -a -t >/dev/null 2>&1 || pihole-FTL --teleporter >/dev/null 2>&1 || true; } )
  f=$(ls -1t "$d"/*.tar.gz "$d"/*.zip 2>/dev/null | head -n1)
  if [ -n "$f" ]; then
    case "$f" in *.zip) ext=zip ;; *) ext=tar.gz ;; esac
    if mv "$f" "/var/backups/pi-tool/sched-pihole-$stamp.$ext"; then
      done="$done pihole"
      ls -1t /var/backups/pi-tool/sched-pihole-*.tar.gz /var/backups/pi-tool/sched-pihole-*.zip 2>/dev/null | tail -n +@DROP@ | xargs -r rm -f -- || true
    fi
  fi
  rm -rf "$d"
fi
[ -z "$done" ] && done=" nichts"
echo "$ts ok:$done" > /var/lib/pi-tool/backup.status
WRAP
chmod +x /usr/local/lib/pi-tool-backup.sh
cat > /etc/systemd/system/pi-tool-backup.service <<'SVC'
[Unit]
Description=Pi-Tool geplante Backups
[Service]
Type=oneshot
ExecStart=/usr/local/lib/pi-tool-backup.sh
SVC
cat > /etc/systemd/system/pi-tool-backup.timer <<'TMR'
[Unit]
Description=Pi-Tool geplante Backups (Timer)
[Timer]
OnCalendar=@ONCALENDAR@
Persistent=true
[Install]
WantedBy=timers.target
TMR
systemctl daemon-reload
systemctl enable --now pi-tool-backup.timer
echo BACKUP_TIMER_INSTALLED
''';

/// [_installV070] for [hour] and [keep] — or, with [unquoted], as v0.51.0 up
/// to v0.54 sent it: the same, the timer unit in an unquoted heredoc.
String _oldInstall(
    {required int hour, required int keep, bool unquoted = false}) {
  final s = _installV070
      .replaceAll('@ONCALENDAR@', scheduledBackupOnCalendar(hour: hour))
      .replaceAll('@DROP@', '${keep + 1}');
  return unquoted ? s.replaceFirst("<<'TMR'", '<<TMR') : s;
}

void main() {
  group('scheduledBackupOnCalendar', () {
    test('daily at the given hour', () {
      expect(scheduledBackupOnCalendar(hour: 3), '*-*-* 03:00:00');
      expect(scheduledBackupOnCalendar(hour: 23), '*-*-* 23:00:00');
    });
  });

  group('scheduledBackupHourOf', () {
    test('is the inverse of scheduledBackupOnCalendar', () {
      for (var hour = 0; hour < 24; hour++) {
        expect(scheduledBackupHourOf(scheduledBackupOnCalendar(hour: hour)),
            hour);
      }
    });

    test('a schedule the picker cannot show, or none: null', () {
      for (final other in [
        null,
        '',
        'daily',
        '*-*-* 03:30:00',
        '*-*-* 03:00:30',
        // The backup sheet has no weekday.
        'Sun *-*-* 03:00:00',
      ]) {
        expect(scheduledBackupHourOf(other), isNull, reason: '$other');
      }
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

  // The probe exactly as the app sends it — one command line, no sudo —
  // against the files an install script left in the sandbox. What it reads
  // decides what "Zeitplan ändern" writes back: a retention read too low
  // deletes archives at the next run.
  group('scheduled backup status probe in bash', () {
    late PiSandbox pi;

    setUp(() {
      pi = PiSandbox();
      pi.stub('systemctl', _systemctlForProbe, log: false);
    });
    tearDown(() => pi.dispose());

    Future<ScheduledBackupStatus> probe() async {
      final r = await pi.run(scheduledBackupStatusCommand);
      expect(r.code, 0, reason: r.err);
      expect(r.err, isEmpty);
      return parseScheduledBackupStatus(r.out);
    }

    Future<void> install(String script) async {
      final r = await pi.run(script);
      expect(r.code, 0, reason: r.err);
      expect(r.lines.last, 'BACKUP_TIMER_INSTALLED');
    }

    test('no timer on the Pi: off, nothing installed, nothing to renew',
        () async {
      final st = await probe();
      expect(st.enabled, isFalse);
      expect(st.nextRun, isNull);
      expect(st.lastResult, isNull);
      expect(st.hour, isNull);
      expect(st.keep, isNull);
      expect(st.wrapperOutdated, isFalse);
    });

    test('every time and retention the sheet can set comes back as it was '
        'set', () async {
      for (final keep in scheduledBackupKeepChoices) {
        final hour = keep % 24;
        await install(buildScheduledBackupInstallScript(
            onCalendar: scheduledBackupOnCalendar(hour: hour), keep: keep));
        final st = await probe();
        expect(st.hour, hour, reason: 'keep $keep');
        expect(st.keep, keep);
        expect(st.enabled, isTrue);
        expect(st.nextRun, 'Sat 2026-10-10 03:00:00');
        // The wrapper v0.71.0 wrote is this one: nothing to renew.
        expect(st.wrapperOutdated, isFalse);
      }
    });

    test('a timer from before the stamps (v0.55.0 to v0.70.0): time and '
        'retention are read from its unit and its wrapper', () async {
      await install(_oldInstall(hour: 1, keep: 30));
      final st = await probe();
      expect(st.hour, 1);
      expect(st.keep, 30);
      expect(st.enabled, isTrue);
      expect(st.wrapperOutdated, isTrue);
    });

    test('the oldest form (v0.51.0, unquoted unit heredoc): the same',
        () async {
      await install(_oldInstall(hour: 22, keep: 14, unquoted: true));
      final st = await probe();
      expect(st.hour, 22);
      expect(st.keep, 14);
      expect(st.wrapperOutdated, isTrue);
    });

    test('setting the old timer up again with what the probe read keeps the '
        'schedule and the retention', () async {
      await install(_oldInstall(hour: 1, keep: 30));
      final before = await probe();
      await install(buildScheduledBackupInstallScript(
          onCalendar: scheduledBackupOnCalendar(hour: before.hour!),
          keep: before.keep!));
      final after = await probe();
      expect(after.hour, 1);
      expect(after.keep, 30);
      expect(after.wrapperOutdated, isFalse);
    });

    test('a wrapper the probe cannot make sense of: no retention, the rest '
        'of the status stands', () async {
      await install(buildScheduledBackupInstallScript(
          onCalendar: '*-*-* 03:00:00', keep: 7));
      pi.put('/usr/local/lib/$scheduledBackupUnit.sh',
          '#!/bin/sh\n$scheduledBackupWrapperStamp\nexit 0\n');
      final st = await probe();
      expect(st.keep, isNull);
      expect(st.hour, 3);
      expect(st.enabled, isTrue);
    });
  }, skip: needsBash);

  // Switched off, the sheet must not go on showing the last run of a timer
  // that is no longer there. The archives are the user's and stay.
  group('scheduled backup remove script in bash', () {
    late PiSandbox pi;

    setUp(() {
      pi = PiSandbox();
      pi.stub('systemctl', _systemctlForProbe, log: false);
    });
    tearDown(() => pi.dispose());

    test('takes the status line along — and leaves the archives', () async {
      final r = await pi.run(buildScheduledBackupInstallScript(
          onCalendar: '*-*-* 03:00:00', keep: 7));
      expect(r.lines.last, 'BACKUP_TIMER_INSTALLED', reason: r.err);
      pi.put('/var/lib/pi-tool/backup.status',
          '2026-10-08 03:00:01 ok: evcc pihole\n');
      pi.put('/var/lib/pi-tool/job.status', 'other state of the app\n');
      pi.put('/var/backups/pi-tool/sched-evcc-20261008-030001.tar.gz');
      pi.put('/var/backups/pi-tool/sched-pihole-20261008-030001.zip');

      final off = await pi.run(buildScheduledBackupRemoveScript());
      expect(off.code, 0, reason: off.err);
      expect(off.lines.last, 'BACKUP_TIMER_REMOVED');
      expect(pi.ls('/var/lib/pi-tool'), ['job.status']);
      expect(pi.ls('/var/backups/pi-tool'), [
        'sched-evcc-20261008-030001.tar.gz',
        'sched-pihole-20261008-030001.zip',
      ]);

      final st = parseScheduledBackupStatus(
          (await pi.run(scheduledBackupStatusCommand)).out);
      expect(st.enabled, isFalse);
      expect(st.lastResult, isNull);
      expect(st.hour, isNull);
      expect(st.keep, isNull);
    });
  }, skip: needsBash);

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
      expect(st.hour, isNull);
      expect(st.keep, isNull);
    });

    test('the installed time and retention are handed on', () {
      const head = 'ENABLED enabled\nNEXT Sat 2026-10-10 05:00:00\nSTATUS \n'
          'WRAPPER current\n';
      // `tail -n +15` deletes from the 15th newest on: 14 are kept.
      final st = parseScheduledBackupStatus(
          '${head}ONCALENDAR *-*-* 05:00:00\nDROP 15\n');
      expect(st.hour, 5);
      expect(st.keep, 14);
      // A retention the picker does not offer is still what is installed.
      expect(parseScheduledBackupStatus('${head}DROP 11\n').keep, 10);
    });

    test('not known, or not something the install script writes: null', () {
      const head = 'ENABLED enabled\nNEXT \nSTATUS \nWRAPPER current\n';
      expect(parseScheduledBackupStatus(head).hour, isNull);
      expect(parseScheduledBackupStatus(head).keep, isNull);
      for (final drop in ['', 'x', '0', '1', '-3', '8 9', '1001', '8x']) {
        expect(parseScheduledBackupStatus('${head}DROP $drop\n').keep, isNull,
            reason: drop);
      }
      expect(
          parseScheduledBackupStatus('${head}ONCALENDAR Sun *-*-* 03:00:00\n')
              .hour,
          isNull);
      // The rest of the status does not depend on it.
      final st = parseScheduledBackupStatus(
          '${head}ONCALENDAR hourly\nDROP x\n');
      expect(st.enabled, isTrue);
      expect(st.wrapperOutdated, isFalse);
    });

    test('the picker offers the retentions every app version offered', () {
      expect(scheduledBackupKeepChoices, [3, 5, 7, 14, 30]);
    });
  });
}
