/// Scheduled automatic updates via a systemd timer installed ON THE PI (no
/// Android background service — deliberately, see the v0.20.0 lesson). The app
/// installs/removes the timer + reads its status; the Pi runs autonomously.
/// Pure builders + parser so everything is unit-testable.
library;

const String autoUpdateUnit = 'pi-tool-autoupdate';

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
/// enables it. The wrapper backs up evcc, runs a full apt upgrade, and — if
/// evcc was running but died during the upgrade — brings it back (self-heal),
/// writing a one-line result to /var/lib/pi-tool/autoupdate.status.
String buildAutoUpdateInstallScript({required String onCalendar}) {
  return '''
set -e
mkdir -p /var/lib/pi-tool /var/backups/pi-tool
cat > /usr/local/lib/$autoUpdateUnit.sh <<'WRAP'
#!/bin/sh
export DEBIAN_FRONTEND=noninteractive
mkdir -p /var/lib/pi-tool /var/backups/pi-tool
ts=\$(date '+%Y-%m-%d %H:%M:%S')
was=\$(systemctl is-active evcc 2>/dev/null)
if dpkg-query -W evcc >/dev/null 2>&1; then
  tar -czf "/var/backups/pi-tool/autoupdate-evcc-\$(date +%Y%m%d-%H%M%S).tar.gz" \\
    /etc/evcc.yaml /var/lib/evcc 2>/dev/null || true
  ls -1t /var/backups/pi-tool/autoupdate-evcc-* 2>/dev/null | tail -n +6 | xargs -r rm -f -- || true
fi
apt-get update >/dev/null 2>&1
# Unattended: never block on a dpkg conffile prompt (would hang forever holding
# the apt lock); keep the existing config on conflicts.
apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade >/dev/null 2>&1
rc=\$?
heal=""
if [ "\$was" = "active" ] && [ "\$(systemctl is-active evcc 2>/dev/null)" != "active" ]; then
  systemctl restart evcc >/dev/null 2>&1
  heal="; evcc-neustart"
fi
if [ "\$rc" = "0" ]; then res="ok"; else res="fehler(rc=\$rc)"; fi
echo "\$ts \$res\$heal" > /var/lib/pi-tool/autoupdate.status
WRAP
chmod +x /usr/local/lib/$autoUpdateUnit.sh
cat > /etc/systemd/system/$autoUpdateUnit.service <<'SVC'
[Unit]
Description=Pi-Tool automatische Updates
[Service]
Type=oneshot
ExecStart=/usr/local/lib/$autoUpdateUnit.sh
SVC
cat > /etc/systemd/system/$autoUpdateUnit.timer <<TMR
[Unit]
Description=Pi-Tool automatische Updates (Timer)
[Timer]
OnCalendar=$onCalendar
Persistent=true
[Install]
WantedBy=timers.target
TMR
systemctl daemon-reload
systemctl enable --now $autoUpdateUnit.timer
echo AUTOUPDATE_INSTALLED
''';
}

/// Root script that removes the timer, service and wrapper again.
String buildAutoUpdateRemoveScript() {
  return '''
systemctl disable --now $autoUpdateUnit.timer 2>/dev/null || true
rm -f /etc/systemd/system/$autoUpdateUnit.timer \\
  /etc/systemd/system/$autoUpdateUnit.service \\
  /usr/local/lib/$autoUpdateUnit.sh
systemctl daemon-reload
echo AUTOUPDATE_REMOVED
''';
}

/// No-sudo command that reports the timer state, next run and last result in a
/// marker format parsed by [parseAutoUpdateStatus].
const String autoUpdateStatusCommand =
    'echo "ENABLED \$(systemctl is-enabled $autoUpdateUnit.timer 2>/dev/null || echo disabled)"; '
    'echo "NEXT \$(systemctl list-timers --all $autoUpdateUnit.timer --no-legend 2>/dev/null | awk \'{print \$1, \$2, \$3}\')"; '
    'echo "STATUS \$(cat /var/lib/pi-tool/autoupdate.status 2>/dev/null)"';

/// Parsed auto-update status.
typedef AutoUpdateStatus = ({bool enabled, String? nextRun, String? lastResult});

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
  return (enabled: enabled, nextRun: nextRun, lastResult: lastResult);
}
