/// Scheduled backups via a systemd timer installed ON THE PI (no Android
/// background service — same rationale as [auto_update.dart]). The wrapper backs
/// up evcc (config + state) and Pi-hole (teleporter), both presence-gated, with
/// rotation, and writes a status line. Pure builders + parser (unit-testable).
///
/// Security: the wrapper heredoc is QUOTED (`<<'WRAP'`) so nothing expands at
/// install time; only [onCalendar] and [keep] are app-controlled and validated
/// numeric/calendar values. Success requires the BACKUP_TIMER_INSTALLED marker.
library;

const String scheduledBackupUnit = 'pi-tool-backup';

/// Daily `OnCalendar` at [hour] (0–23).
String scheduledBackupOnCalendar({required int hour}) =>
    '*-*-* ${hour.clamp(0, 23).toString().padLeft(2, '0')}:00:00';

/// Root script: installs the wrapper + service + timer and enables it. [keep] =
/// how many backups per service to retain (older ones are pruned each run).
String buildScheduledBackupInstallScript({
  required String onCalendar,
  required int keep,
}) {
  final drop = keep.clamp(1, 999) + 1; // `tail -n +drop` prunes from the drop-th
  return '''
set -e
mkdir -p /var/lib/pi-tool /var/backups/pi-tool
cat > /usr/local/lib/$scheduledBackupUnit.sh <<'WRAP'
#!/bin/sh
mkdir -p /var/lib/pi-tool /var/backups/pi-tool
ts=\$(date '+%Y-%m-%d %H:%M:%S')
stamp=\$(date +%Y%m%d-%H%M%S)
done=""
# evcc (config + state), only if present. Write atomically: a failed/partial
# tar must NEVER become the newest file and evict a good backup on rotation.
if [ -f /etc/evcc.yaml ] || [ -d /var/lib/evcc ]; then
  out="/var/backups/pi-tool/sched-evcc-\$stamp.tar.gz"
  if tar -czf "\$out.part" /etc/evcc.yaml /var/lib/evcc 2>/dev/null; then
    mv "\$out.part" "\$out"
    done="\$done evcc"
    # Rotate ONLY after a real success; the glob excludes the .part temp.
    ls -1t /var/backups/pi-tool/sched-evcc-*.tar.gz 2>/dev/null | tail -n +$drop | xargs -r rm -f -- || true
  else
    rm -f "\$out.part"
  fi
fi
# Pi-hole teleporter, only if present. Teleporter writes into a temp dir; we only
# move a produced file into place, and rotate only after that success.
if command -v pihole >/dev/null 2>&1 || command -v pihole-FTL >/dev/null 2>&1; then
  d=\$(mktemp -d)
  ( cd "\$d" && { pihole -a -t >/dev/null 2>&1 || pihole-FTL --teleporter >/dev/null 2>&1 || true; } )
  f=\$(ls -1t "\$d"/*.tar.gz "\$d"/*.zip 2>/dev/null | head -n1)
  if [ -n "\$f" ]; then
    case "\$f" in *.zip) ext=zip ;; *) ext=tar.gz ;; esac
    if mv "\$f" "/var/backups/pi-tool/sched-pihole-\$stamp.\$ext"; then
      done="\$done pihole"
      ls -1t /var/backups/pi-tool/sched-pihole-*.tar.gz /var/backups/pi-tool/sched-pihole-*.zip 2>/dev/null | tail -n +$drop | xargs -r rm -f -- || true
    fi
  fi
  rm -rf "\$d"
fi
[ -z "\$done" ] && done=" nichts"
echo "\$ts ok:\$done" > /var/lib/pi-tool/backup.status
WRAP
chmod +x /usr/local/lib/$scheduledBackupUnit.sh
cat > /etc/systemd/system/$scheduledBackupUnit.service <<'SVC'
[Unit]
Description=Pi-Tool geplante Backups
[Service]
Type=oneshot
ExecStart=/usr/local/lib/$scheduledBackupUnit.sh
SVC
cat > /etc/systemd/system/$scheduledBackupUnit.timer <<TMR
[Unit]
Description=Pi-Tool geplante Backups (Timer)
[Timer]
OnCalendar=$onCalendar
Persistent=true
[Install]
WantedBy=timers.target
TMR
systemctl daemon-reload
systemctl enable --now $scheduledBackupUnit.timer
echo BACKUP_TIMER_INSTALLED
''';
}

/// Root script: removes the timer, service and wrapper again.
String buildScheduledBackupRemoveScript() {
  return '''
systemctl disable --now $scheduledBackupUnit.timer 2>/dev/null || true
rm -f /etc/systemd/system/$scheduledBackupUnit.timer \\
  /etc/systemd/system/$scheduledBackupUnit.service \\
  /usr/local/lib/$scheduledBackupUnit.sh
systemctl daemon-reload
echo BACKUP_TIMER_REMOVED
''';
}

/// No-sudo status probe (enabled / next run / last result).
const String scheduledBackupStatusCommand =
    'echo "ENABLED \$(systemctl is-enabled $scheduledBackupUnit.timer 2>/dev/null || echo disabled)"; '
    'echo "NEXT \$(systemctl list-timers --all $scheduledBackupUnit.timer --no-legend 2>/dev/null | awk \'{print \$1, \$2, \$3}\')"; '
    'echo "STATUS \$(cat /var/lib/pi-tool/backup.status 2>/dev/null)"';

typedef ScheduledBackupStatus = ({
  bool enabled,
  String? nextRun,
  String? lastResult,
});

ScheduledBackupStatus parseScheduledBackupStatus(String out) {
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
