/// Health-Alerts: an on-Pi systemd timer that checks health (disk, temp, dead
/// services, pending updates) and pushes a notification via **ntfy** when a
/// problem appears — backend-free, no Android background service (see the
/// v0.20.0 lesson). Pure builders + parser so it's unit-testable. Debounced via
/// a state file so it never spams the same alert.
library;

import 'commands.dart' show shSingleQuote;

const String alertsUnit = 'pi-tool-alerts';

/// systemd schedule for the health check (every 30 minutes).
const String _alertsOnCalendar = '*-*-* *:00/30:00';

/// Root script that installs the health-check wrapper + timer and enables it.
/// [ntfyServer] + [ntfyTopic] are the ntfy destination; both are shell-quoted.
String buildAlertsInstallScript({
  required String ntfyServer,
  required String ntfyTopic,
}) {
  final url = shSingleQuote(ntfyServer);
  final topic = shSingleQuote(ntfyTopic);
  return '''
set -e
mkdir -p /var/lib/pi-tool
cat > /usr/local/lib/$alertsUnit.sh <<WRAP
#!/bin/sh
URL=$url
TOPIC=$topic
mkdir -p /var/lib/pi-tool
WRAP
cat >> /usr/local/lib/$alertsUnit.sh <<'WRAP'
problems=""
use=\$(df / | awk 'NR==2{gsub("%","",\$5); print \$5}')
[ -n "\$use" ] && [ "\$use" -ge 90 ] && problems="\$problems"'\\n'"Speicher: \${use}% belegt"
if [ -r /sys/class/thermal/thermal_zone0/temp ]; then
  t=\$(( \$(cat /sys/class/thermal/thermal_zone0/temp) / 1000 ))
  [ "\$t" -ge 75 ] && problems="\$problems"'\\n'"Temperatur: \${t} Grad"
fi
for s in evcc pihole-FTL grafana-server influxdb mosquitto; do
  if systemctl is-enabled "\$s" >/dev/null 2>&1; then
    [ "\$(systemctl is-active "\$s" 2>/dev/null)" != "active" ] && problems="\$problems"'\\n'"Dienst aus: \$s"
  fi
done
pend=\$(LC_ALL=C apt-get -s upgrade 2>/dev/null | grep -c '^Inst ')
[ "\$pend" -gt 0 ] && problems="\$problems"'\\n'"\$pend Updates verfuegbar"
hash=\$(printf '%s' "\$problems" | md5sum | awk '{print \$1}')
last=\$(cat /var/lib/pi-tool/alerts.last 2>/dev/null)
if [ -n "\$problems" ] && [ "\$hash" != "\$last" ]; then
  printf 'Pi-Tool hat Probleme erkannt:%b' "\$problems" | \\
    curl -s -H 'Title: Pi-Tool' -H 'Priority: high' -d @- "\$URL/\$TOPIC" >/dev/null 2>&1
  printf '%s' "\$hash" > /var/lib/pi-tool/alerts.last
elif [ -z "\$problems" ]; then
  : > /var/lib/pi-tool/alerts.last
fi
echo "\$(date '+%Y-%m-%d %H:%M') checked" > /var/lib/pi-tool/alerts.status
WRAP
chmod +x /usr/local/lib/$alertsUnit.sh
cat > /etc/systemd/system/$alertsUnit.service <<'SVC'
[Unit]
Description=Pi-Tool Health-Alerts
[Service]
Type=oneshot
ExecStart=/usr/local/lib/$alertsUnit.sh
SVC
cat > /etc/systemd/system/$alertsUnit.timer <<TMR
[Unit]
Description=Pi-Tool Health-Alerts (Timer)
[Timer]
OnCalendar=$_alertsOnCalendar
Persistent=true
[Install]
WantedBy=timers.target
TMR
systemctl daemon-reload
systemctl enable --now $alertsUnit.timer
echo ALERTS_INSTALLED
''';
}

/// Root script that removes the alerts timer, service and wrapper.
String buildAlertsRemoveScript() {
  return '''
systemctl disable --now $alertsUnit.timer 2>/dev/null || true
rm -f /etc/systemd/system/$alertsUnit.timer \\
  /etc/systemd/system/$alertsUnit.service \\
  /usr/local/lib/$alertsUnit.sh
systemctl daemon-reload
echo ALERTS_REMOVED
''';
}

/// One-off command that sends a test push, to verify the ntfy destination.
String buildTestAlertCommand({
  required String ntfyServer,
  required String ntfyTopic,
}) {
  final url = shSingleQuote('$ntfyServer/$ntfyTopic');
  final msg = shSingleQuote('Test-Benachrichtigung ✓ von Pi-Tool');
  return "curl -s -H 'Title: Pi-Tool' -d $msg $url";
}

/// No-sudo status command parsed by [parseAlertsStatus].
const String alertsStatusCommand =
    'echo "ENABLED \$(systemctl is-enabled $alertsUnit.timer 2>/dev/null || echo disabled)"; '
    'echo "LAST \$(cat /var/lib/pi-tool/alerts.status 2>/dev/null)"';

typedef AlertsStatus = ({bool enabled, String? lastCheck});

AlertsStatus parseAlertsStatus(String out) {
  var enabled = false;
  String? lastCheck;
  for (final line in out.split('\n')) {
    final t = line.trim();
    if (t.startsWith('ENABLED ')) {
      enabled = t.substring(8).trim() == 'enabled';
    } else if (t.startsWith('LAST ')) {
      final v = t.substring(5).trim();
      lastCheck = v.isEmpty ? null : v;
    }
  }
  return (enabled: enabled, lastCheck: lastCheck);
}
