/// Scheduled automatic updates via a systemd timer installed ON THE PI (no
/// Android background service — deliberately, see the v0.20.0 lesson). The app
/// installs/removes the timer + reads its status; the Pi runs autonomously.
/// Pure builders + parser so everything is unit-testable.
library;

import 'on_pi_wrapper.dart';
import 'pi_job.dart' show aptBuildingBlocks;

const String autoUpdateUnit = 'pi-tool-autoupdate';

/// Epoch seconds of the last (re)setup, written by the install script. The
/// wrapper does nothing when it is started within five minutes of that time —
/// see [buildAutoUpdateInstallScript].
const String autoUpdateSetupPath = '/var/lib/pi-tool/autoupdate.setup';

/// systemd `OnCalendar` for the schedule. [weekday]: 1=Mon … 7=Sun (weekly).
String autoUpdateOnCalendar(
    {required bool weekly, required int hour, int weekday = 7}) {
  final hh = hour.toString().padLeft(2, '0');
  if (!weekly) return '*-*-* $hh:00:00';
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final d = days[(weekday - 1).clamp(0, 6)];
  return '$d *-*-* $hh:00:00';
}

/// Root script (sudo shell) that installs the wrapper + service + timer and
/// enables it. The wrapper backs up evcc, then upgrades with the building
/// blocks of a Pi-Job payload ([aptBuildingBlocks] — bash, hence the bash
/// shebang): dead sources of EOL releases repointed, an interrupted dpkg run
/// finished, foreign apt locks waited for, then the package lists and a full
/// apt upgrade. If evcc was running but died during the upgrade it is brought
/// back (self-heal). One line goes to /var/lib/pi-tool/autoupdate.status:
/// `<time> ok` or `<time> fehler(rc=N)` for the upgrade, plus
/// `; paketlisten-fehler(rc=N)` when the package lists did not (all) load,
/// `; evcc-neustart` after a self-heal and `; backup-fehler(rc=N)` when the
/// evcc backup before the upgrade could not be written. What apt printed is
/// kept in /var/lib/pi-tool/autoupdate.log (root only, the last 200 lines of
/// the latest run).
///
/// Setting the timer up must never start an upgrade the moment the user taps.
/// A `Persistent=true` timer does trigger at once when a run was due since
/// its last one — after a pause, or when the new time of day lies between the
/// last run and now. So the script drops systemd's stamp ([timerStampPath])
/// and stops the timer before the reload, to make systemd count from now.
/// What systemd then really does differs between its versions and was not
/// measured on a device — so the script also notes its own time in
/// [autoUpdateSetupPath], and the wrapper ends without doing anything when it
/// is started within five minutes of it (enough for a start that first waits
/// for network-online). A run scheduled inside those minutes is skipped too.
///
/// [onCalendar] must be a schedule from [autoUpdateOnCalendar]
/// ([checkOnCalendar]).
String buildAutoUpdateInstallScript({required String onCalendar}) {
  checkOnCalendar(onCalendar);
  return '''
set -e
mkdir -p /var/lib/pi-tool /var/backups/pi-tool
cat > /usr/local/lib/$autoUpdateUnit.sh <<'WRAP'
#!/bin/bash
$wrapperStampLine
# Set up or re-scheduled a moment ago: then this start is systemd catching up
# on the timer, not a scheduled run.
setup=\$(cat $autoUpdateSetupPath 2>/dev/null)
if [[ \$setup =~ ^[0-9]{1,12}\$ ]]; then
  age=\$(( \$(date +%s) - 10#\$setup ))
  if [ "\$age" -ge 0 ] && [ "\$age" -lt 300 ]; then
    echo 'Pi-Tool: Zeitplan gerade erst eingerichtet – dieser Start zählt nicht als geplanter Lauf.'
    exit 0
  fi
fi
# systemd stops this unit with SIGTERM to this process alone (KillMode=mixed)
# and then waits (TimeoutStopSec): note it and run to the end instead of
# leaving dpkg half-done. A handler, not '': an ignored signal would be passed
# on to apt, dpkg and whatever a maintainer script starts.
trap 'echo "Pi-Tool: Stopp angefordert – das Update läuft zu Ende."' TERM
export DEBIAN_FRONTEND=noninteractive
mkdir -p /var/lib/pi-tool /var/backups/pi-tool
ts=\$(date '+%Y-%m-%d %H:%M:%S')
was=\$(systemctl is-active evcc 2>/dev/null)
bak=""
if dpkg-query -W evcc >/dev/null 2>&1; then
  # Only what is present: the package ships no /etc/evcc.yaml (an evcc set up
  # in its web UI never has one), and ONE path tar cannot stat fails the whole
  # archive.
  set --
  [ -f /etc/evcc.yaml ] && set -- "\$@" /etc/evcc.yaml
  [ -d /var/lib/evcc ] && set -- "\$@" /var/lib/evcc
  if [ "\$#" -gt 0 ]; then
    # Atomic: a failed/partial tar must not become the newest file and evict a
    # good pre-upgrade backup on rotation.
    bout="/var/backups/pi-tool/autoupdate-evcc-\$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "\$bout.part" "\$@" 2>/dev/null
    brc=\$?
    # Exit 1 = "file changed as we read it" (evcc keeps running): the archive
    # is written, so it counts. Only exit >= 2 is a failure.
    if [ "\$brc" -le 1 ] && mv "\$bout.part" "\$bout"; then
      ls -1t /var/backups/pi-tool/autoupdate-evcc-*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm -f -- || true
    else
      rm -f "\$bout.part"
      bak="; backup-fehler(rc=\$brc)"
    fi
  fi
fi
# What apt says in this run — the cause behind a "fehler(rc=N)": its last 200
# lines, replaced with every run. Root only: apt names the package sources,
# and a source may carry credentials.
log=/var/lib/pi-tool/autoupdate.log
(umask 077; : > "\$log.new")
{
${aptBuildingBlocks()}
pitool_repair
echo 'Pi-Tool: Lade die Paketlisten …'
pitool_wait_apt_locks
# Error-Mode=any: without it apt-get update exits 0 when a download failed and
# the old lists stay in use — "ok" would then hide that nothing new was
# checked. An apt too old to know the key ignores it.
apt-get -o APT::Update::Error-Mode=any -o Acquire::AllowReleaseInfoChange::Suite=true -o Acquire::Retries=3 update -qq
urc=\$?
pitool_wait_apt_locks
echo 'Pi-Tool: Installiere alle Updates (apt-get full-upgrade) …'
# Unattended: O holds --force-confdef/--force-confold, so dpkg never blocks on
# a conffile prompt (it would hang forever holding the apt lock) and keeps the
# existing config on conflicts.
apt-get "\${O[@]}" full-upgrade -y
rc=\$?
} >> "\$log.new" 2>&1
heal=""
if [ "\$was" = "active" ] && [ "\$(systemctl is-active evcc 2>/dev/null)" != "active" ]; then
  systemctl restart evcc >/dev/null 2>&1
  heal="; evcc-neustart"
fi
if [ "\$rc" = "0" ]; then res="ok"; else res="fehler(rc=\$rc)"; fi
# The upgrade ran against package lists that did not (all) load: say so.
[ "\$urc" = "0" ] || res="\$res; paketlisten-fehler(rc=\$urc)"
echo "\$ts \$res\$heal\$bak" > /var/lib/pi-tool/autoupdate.status
(umask 077; tail -n 200 "\$log.new" > "\$log")
rm -f "\$log.new"
WRAP
chmod +x /usr/local/lib/$autoUpdateUnit.sh
# network-online: a run caught up right after boot (Persistent=true) would
# otherwise start before the network is there. KillMode/TimeoutStopSec: a
# reboot or "systemctl stop" during a run signals the wrapper alone and gives
# it 30 minutes to finish, instead of killing apt and dpkg at once.
cat > /etc/systemd/system/$autoUpdateUnit.service <<'SVC'
[Unit]
Description=Pi-Tool automatische Updates
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/lib/$autoUpdateUnit.sh
KillMode=mixed
TimeoutStopSec=30min
SVC
cat > /etc/systemd/system/$autoUpdateUnit.timer <<'TMR'
[Unit]
Description=Pi-Tool automatische Updates (Timer)
[Timer]
OnCalendar=$onCalendar
Persistent=true
[Install]
WantedBy=timers.target
TMR
# The stamp first: if it cannot be removed (set -e), the old timer keeps
# running.
rm -f ${timerStampPath(autoUpdateUnit)}
systemctl stop $autoUpdateUnit.timer 2>/dev/null || true
date +%s > $autoUpdateSetupPath
systemctl daemon-reload
systemctl enable --now $autoUpdateUnit.timer
echo AUTOUPDATE_INSTALLED
''';
}

/// Root script that removes the timer, service and wrapper again — and
/// systemd's stamp of the timer: left behind, turning the updates on again
/// later would start a full upgrade on the spot ([timerStampPath]).
/// `set -e`: a failing `rm` (read-only root) must end without the marker.
String buildAutoUpdateRemoveScript() {
  return '''
set -e
systemctl disable --now $autoUpdateUnit.timer 2>/dev/null || true
rm -f /etc/systemd/system/$autoUpdateUnit.timer \\
  /etc/systemd/system/$autoUpdateUnit.service \\
  /usr/local/lib/$autoUpdateUnit.sh \\
  ${timerStampPath(autoUpdateUnit)}
systemctl daemon-reload
echo AUTOUPDATE_REMOVED
''';
}

/// No-sudo command that reports the timer state, next run and last result in a
/// marker format parsed by [parseAutoUpdateStatus].
const String autoUpdateStatusCommand =
    'echo "ENABLED \$(systemctl is-enabled $autoUpdateUnit.timer 2>/dev/null || echo disabled)"; '
    'echo "NEXT \$(systemctl list-timers --all $autoUpdateUnit.timer --no-legend 2>/dev/null | awk \'{print \$1, \$2, \$3}\')"; '
    'echo "STATUS \$(cat /var/lib/pi-tool/autoupdate.status 2>/dev/null)"; '
    '$wrapperProbeHead$autoUpdateUnit$wrapperProbeTail';

/// Parsed auto-update status. [wrapperOutdated]: the wrapper on the Pi is from
/// an older app release (see on_pi_wrapper.dart).
typedef AutoUpdateStatus = ({
  bool enabled,
  String? nextRun,
  String? lastResult,
  bool wrapperOutdated,
});

/// Parses [autoUpdateStatusCommand] output.
AutoUpdateStatus parseAutoUpdateStatus(String out) {
  var enabled = false;
  String? nextRun;
  String? lastResult;
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
    }
  }
  return (
    enabled: enabled,
    nextRun: nextRun,
    lastResult: lastResult,
    wrapperOutdated: parseWrapperOutdated(out),
  );
}
