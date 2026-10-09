/// Scheduled backups via a systemd timer installed ON THE PI (no Android
/// background service — same rationale as [auto_update.dart]). The wrapper backs
/// up evcc (config + state) and Pi-hole (teleporter), both presence-gated, with
/// rotation, and writes a status line that names what was saved and what
/// failed. Pure builders + parser (unit-testable).
///
/// Security: the wrapper heredoc is QUOTED (`<<'WRAP'`) so nothing expands at
/// install time; only [onCalendar] and [keep] are app-controlled and validated
/// numeric/calendar values. Success requires the BACKUP_TIMER_INSTALLED marker.
library;

import 'on_pi_wrapper.dart';

const String scheduledBackupUnit = 'pi-tool-backup';

/// Daily `OnCalendar` at [hour] (0–23).
String scheduledBackupOnCalendar({required int hour}) =>
    '*-*-* ${hour.clamp(0, 23).toString().padLeft(2, '0')}:00:00';

final RegExp _dailyRe = RegExp(r'^\*-\*-\* ([01][0-9]|2[0-3]):00:00$');

/// The inverse of [scheduledBackupOnCalendar]: the hour of [onCalendar]. Null
/// for anything the sheet's picker cannot produce, and for no schedule.
int? scheduledBackupHourOf(String? onCalendar) {
  final m = onCalendar == null ? null : _dailyRe.firstMatch(onCalendar);
  return m == null ? null : int.parse(m.group(1)!);
}

/// The retentions the sheet offers — the same in every app version so far.
const List<int> scheduledBackupKeepChoices = [3, 5, 7, 14, 30];

/// Root script: installs the wrapper + service + timer and enables it. [keep] =
/// how many backups per service to retain (older ones are pruned each run).
/// [onCalendar] must be a schedule from [scheduledBackupOnCalendar]
/// ([checkOnCalendar]).
String buildScheduledBackupInstallScript({
  required String onCalendar,
  required int keep,
}) {
  checkOnCalendar(onCalendar);
  final drop = keep.clamp(1, 999) + 1; // `tail -n +drop` prunes from the drop-th
  return '''
set -e
mkdir -p /var/lib/pi-tool /var/backups/pi-tool
# Written next to the wrapper and moved into place: a backup that is running
# keeps reading the file it opened. Rewritten in place, its shell would go on
# at the old offset in the new text.
cat > /usr/local/lib/$scheduledBackupUnit.sh.new <<'WRAP'
#!/bin/sh
$scheduledBackupWrapperStamp
mkdir -p /var/lib/pi-tool /var/backups/pi-tool
ts=\$(date '+%Y-%m-%d %H:%M:%S')
stamp=\$(date +%Y%m%d-%H%M%S)
done=""
failed=""
# evcc (config + state), only what is present: the package ships no
# /etc/evcc.yaml (an evcc set up in its web UI never has one), and ONE path tar
# cannot stat fails the whole archive. Write atomically: a failed/partial tar
# must NEVER become the newest file and evict a good backup on rotation.
set --
[ -f /etc/evcc.yaml ] && set -- "\$@" /etc/evcc.yaml
[ -d /var/lib/evcc ] && set -- "\$@" /var/lib/evcc
if [ "\$#" -gt 0 ]; then
  out="/var/backups/pi-tool/sched-evcc-\$stamp.tar.gz"
  tar -czf "\$out.part" "\$@" 2>/dev/null
  rc=\$?
  # Exit 1 = "file changed as we read it" (evcc keeps running): the archive is
  # written, so it counts. Only exit >= 2 is a failure.
  if [ "\$rc" -le 1 ] && mv "\$out.part" "\$out"; then
    done="\$done evcc"
    # Rotate ONLY after a real success; the glob excludes the .part temp.
    ls -1t /var/backups/pi-tool/sched-evcc-*.tar.gz 2>/dev/null | tail -n +$drop | xargs -r rm -f -- || true
  else
    rm -f "\$out.part"
    failed="\$failed evcc(tar-rc=\$rc)"
  fi
fi
# Pi-hole teleporter, only if present. Teleporter writes into a temp dir; we only
# move a produced file into place, and rotate only after that success.
if command -v pihole >/dev/null 2>&1 || command -v pihole-FTL >/dev/null 2>&1; then
  d=\$(mktemp -d)
  # Not picked by exit code: v6 dropped `-a` and answers it with its help text
  # and exit 0, writing nothing. So v5's CLI first, and v6's teleporter only
  # when that left no archive behind.
  ( cd "\$d" && {
    pihole -a -t >/dev/null 2>&1
    ls *.tar.gz >/dev/null 2>&1 || pihole-FTL --teleporter >/dev/null 2>&1
  } )
  f=\$(ls -1t "\$d"/*.tar.gz "\$d"/*.zip 2>/dev/null | head -n1)
  if [ -z "\$f" ]; then
    failed="\$failed pihole(kein-archiv)"
  else
    case "\$f" in *.zip) ext=zip ;; *) ext=tar.gz ;; esac
    if mv "\$f" "/var/backups/pi-tool/sched-pihole-\$stamp.\$ext"; then
      done="\$done pihole"
      ls -1t /var/backups/pi-tool/sched-pihole-*.tar.gz /var/backups/pi-tool/sched-pihole-*.zip 2>/dev/null | tail -n +$drop | xargs -r rm -f -- || true
    else
      failed="\$failed pihole(nicht-gespeichert)"
    fi
  fi
  rm -rf "\$d"
fi
# One line the app shows as is: "ok: evcc pihole", "ok: nichts" (nothing to
# back up), or the failures first — "fehler: evcc(tar-rc=2); ok: pihole".
if [ -n "\$failed" ]; then
  res="fehler:\$failed"
  [ -n "\$done" ] && res="\$res; ok:\$done"
else
  [ -z "\$done" ] && done=" nichts"
  res="ok:\$done"
fi
echo "\$ts \$res" > /var/lib/pi-tool/backup.status
WRAP
# Modes by number, not "+x": the status probe reads the wrapper's stamp, its
# retention and the timer unit without sudo, whatever root's umask is.
chmod 755 /usr/local/lib/$scheduledBackupUnit.sh.new
mv -f /usr/local/lib/$scheduledBackupUnit.sh.new /usr/local/lib/$scheduledBackupUnit.sh
cat > /etc/systemd/system/$scheduledBackupUnit.service <<'SVC'
[Unit]
Description=Pi-Tool geplante Backups
[Service]
Type=oneshot
ExecStart=/usr/local/lib/$scheduledBackupUnit.sh
SVC
cat > /etc/systemd/system/$scheduledBackupUnit.timer <<'TMR'
[Unit]
Description=Pi-Tool geplante Backups (Timer)
[Timer]
OnCalendar=$onCalendar
Persistent=true
[Install]
WantedBy=timers.target
TMR
chmod 644 /etc/systemd/system/$scheduledBackupUnit.service /etc/systemd/system/$scheduledBackupUnit.timer
systemctl daemon-reload
systemctl enable --now $scheduledBackupUnit.timer
echo BACKUP_TIMER_INSTALLED
''';
}

/// Root script: removes the timer, service and wrapper again — and systemd's
/// stamp of the timer ([timerStampPath]). The status line of the last run
/// goes too: the sheet must not show the last run of a timer that is off. The
/// archives in /var/backups/pi-tool stay. `set -e`: a failing `rm` (read-only
/// root) must end without the marker.
String buildScheduledBackupRemoveScript() {
  return '''
set -e
systemctl disable --now $scheduledBackupUnit.timer 2>/dev/null || true
rm -f /etc/systemd/system/$scheduledBackupUnit.timer \\
  /etc/systemd/system/$scheduledBackupUnit.service \\
  /usr/local/lib/$scheduledBackupUnit.sh \\
  ${timerStampPath(scheduledBackupUnit)} \\
  /var/lib/pi-tool/backup.status
systemctl daemon-reload
echo BACKUP_TIMER_REMOVED
''';
}

/// No-sudo status probe (enabled / next run / last result / installed
/// schedule and retention).
///
/// `DROP <n>`: the retention is nowhere but in the wrapper, as the `n` of the
/// `tail -n +n` that prunes the evcc archives — written like this by every
/// app version, so the probe reads it from there (the wrappers are
/// world-readable). Empty without a wrapper.
const String scheduledBackupStatusCommand =
    'echo "ENABLED \$(systemctl is-enabled $scheduledBackupUnit.timer 2>/dev/null || echo disabled)"; '
    'echo "NEXT \$(systemctl list-timers --all $scheduledBackupUnit.timer --no-legend 2>/dev/null | awk \'{print \$1, \$2, \$3}\')"; '
    'echo "STATUS \$(cat /var/lib/pi-tool/backup.status 2>/dev/null)"; '
    '$wrapperProbeHead$scheduledBackupUnit$wrapperProbeMid$scheduledBackupWrapperStamp$wrapperProbeTail; '
    '$onCalendarProbeHead$scheduledBackupUnit$onCalendarProbeTail; '
    'echo "DROP \$(grep -m 1 \'sched-evcc-.*tail -n +[0-9]\' /usr/local/lib/$scheduledBackupUnit.sh 2>/dev/null | sed \'s/.*tail -n +//; s/[^0-9].*//\')"';

/// [lastResult] is the wrapper's status line as written, shown to the user
/// unchanged: `<time> ok: evcc pihole`, `<time> ok: nichts` (nothing to back
/// up) or, failures first, `<time> fehler: evcc(tar-rc=2); ok: pihole`.
///
/// [wrapperOutdated]: the wrapper on the Pi is from an older app release, so
/// fixes made since only apply once the timer is set up again.
///
/// [hour] and [keep]: what is installed on the Pi, for the sheet to open
/// with. Null when there is no timer or the probe could not read it; [hour]
/// also when the schedule is not a daily one on the hour. [keep] is the
/// installed number even where the picker does not offer it
/// ([scheduledBackupKeepChoices]).
typedef ScheduledBackupStatus = ({
  bool enabled,
  String? nextRun,
  String? lastResult,
  bool wrapperOutdated,
  int? hour,
  int? keep,
});

ScheduledBackupStatus parseScheduledBackupStatus(String out) {
  var enabled = false;
  String? nextRun;
  String? lastResult;
  int? keep;
  for (final line in out.split('\n')) {
    final t = line.trim();
    if (t.startsWith('ENABLED ')) {
      enabled = t.substring(8).trim() == 'enabled';
    } else if (t.startsWith('NEXT ')) {
      final v = t.substring(5).trim();
      nextRun = v.isEmpty ? null : v;
    } else if (t.startsWith('STATUS ')) {
      final v = t.substring(7).trim();
      lastResult = v.isEmpty ? null : v;
    } else if (t.startsWith('DROP ')) {
      // `tail -n +n` deletes from the n-th newest on: n - 1 are kept. The
      // install script writes 2 to 1000.
      final n = int.tryParse(t.substring(5).trim());
      if (n != null && n >= 2 && n <= 1000) keep = n - 1;
    }
  }
  return (
    enabled: enabled,
    nextRun: nextRun,
    lastResult: lastResult,
    wrapperOutdated: parseWrapperOutdated(out),
    hour: scheduledBackupHourOf(parseInstalledOnCalendar(out)),
    keep: keep,
  );
}
