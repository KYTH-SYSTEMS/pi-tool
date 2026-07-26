/// Health-Alerts: an on-Pi systemd timer that checks health (disk, temp, dead
/// services, pending updates) and pushes a notification via **ntfy** when a
/// problem appears — backend-free, no Android background service (see the
/// v0.20.0 lesson). Pure builders + parser so it's unit-testable. Debounced via
/// a state file so it never spams the same alert.
library;

import 'dart:math';

import 'commands.dart' show shSingleQuote;

const String alertsUnit = 'pi-tool-alerts';

// ---- ntfy topic: the topic IS the password ----------------------------------
//
// ntfy.sh has no sign-up and no auth: "the topic is essentially a password, so
// pick something that's not easily guessable" (docs.ntfy.sh/publish). Whoever
// knows or guesses the name reads every health message — which services run on
// the Pi and which updates are pending. So the app generates the name instead
// of letting people type "pi".

/// Alphabet for the random part: lowercase + digits minus the look-alikes
/// (`0/o`, `1/l/i`) so the topic stays re-typable into the ntfy app. 31 chars.
const String _topicAlphabet = 'abcdefghjkmnpqrstuvwxyz23456789';

/// Length of the random part — 14 chars from 31 ≈ 69 bit, far past guessing.
const int _topicRandomLength = 14;

/// Prefix so a subscribed topic is recognisable in the ntfy app.
const String _topicPrefix = 'pi-tool-';

/// A hard-to-guess ntfy topic, e.g. `pi-tool-k7m2q9x4vb3dwz` (22 chars, well
/// under ntfy's 64 and inside its `[-_A-Za-z0-9]` charset). [random] is for
/// tests; production uses [Random.secure].
String generateNtfyTopic([Random? random]) {
  final rnd = random ?? Random.secure();
  final buf = StringBuffer(_topicPrefix);
  for (var i = 0; i < _topicRandomLength; i++) {
    buf.write(_topicAlphabet[rnd.nextInt(_topicAlphabet.length)]);
  }
  return buf.toString();
}

/// Rough guessability check behind the warning on the Health-Alerts card.
/// Deliberately crude and biased toward warning: a false warning costs one tap,
/// a miss costs a publicly readable health feed. It catches the realistic case
/// — short names ("pi", "evcc", "mein-pi") and long-but-repetitive ones. It
/// can't judge whether a long name is a guessable dictionary phrase.
/// An empty topic is not "weak": nothing is configured, so there's nothing to
/// warn about.
bool isWeakNtfyTopic(String topic) {
  final t = topic.trim();
  if (t.isEmpty) return false;
  if (t.length < 16) return true;
  return t.toLowerCase().split('').toSet().length < 8;
}

/// systemd schedule for the health check (every 30 minutes).
const String _alertsOnCalendar = '*-*-* *:00/30:00';

/// Root script that installs the health-check wrapper + timer and enables it.
/// [ntfyServer] + [ntfyTopic] are the ntfy destination; both are shell-quoted.
String buildAlertsInstallScript({
  required String ntfyServer,
  required String ntfyTopic,
}) {
  // Strip whitespace/control chars FIRST: a URL/ntfy-topic never contains any,
  // and a newline in the value could otherwise smuggle a line equal to the
  // heredoc terminator ('WRAP') into the wrapper — closing the heredoc early and
  // executing the remainder in the root install shell. (Values can arrive from
  // an imported profile, which isn't newline-filtered.) shSingleQuote handles
  // the rest of the escaping.
  final url = shSingleQuote(ntfyServer.replaceAll(RegExp(r'\s'), ''));
  final topic = shSingleQuote(ntfyTopic.replaceAll(RegExp(r'\s'), ''));
  return '''
set -e
mkdir -p /var/lib/pi-tool
cat > /usr/local/lib/$alertsUnit.sh <<'WRAP'
#!/bin/sh
mkdir -p /var/lib/pi-tool
WRAP
# URL/TOPIC are Dart-substituted (shell-quoted) BEFORE the shell sees them, so a
# QUOTED heredoc lands them verbatim — no install-time shell expansion of a
# hostile topic like \$(reboot). They assign as literals at wrapper runtime.
cat >> /usr/local/lib/$alertsUnit.sh <<'WRAP'
URL=$url
TOPIC=$topic
WRAP
cat >> /usr/local/lib/$alertsUnit.sh <<'WRAP'
problems=""
use=\$(df / | awk 'NR==2{gsub("%","",\$5); print \$5}')
[ -n "\$use" ] && [ "\$use" -ge 90 ] && problems="\$problems"'\\n'"Speicher: \${use}% belegt"
if [ -r /sys/class/thermal/thermal_zone0/temp ]; then
  t=\$(( \$(cat /sys/class/thermal/thermal_zone0/temp) / 1000 ))
  [ "\$t" -ge 75 ] && problems="\$problems"'\\n'"Temperatur: \${t} Grad"
fi
# Dying-SD symptoms: a read-only-remounted root, or piling I/O errors in the
# kernel log. /proc/mounts always lists rw/ro as the FIRST option.
grep -qE '^\\S+ / \\S+ ro[, ]' /proc/mounts && problems="\$problems"'\\n'"SD-Karte: Dateisystem nur-lesend"
ioerr=\$(journalctl -k --no-pager -q 2>/dev/null | grep -icE 'i/o error|ext4-fs error|mmc[0-9]+: error')
[ -n "\$ioerr" ] && [ "\$ioerr" -ge 5 ] && problems="\$problems"'\\n'"SD-Karte: \$ioerr I/O-Fehler im Kernel-Log"
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
    curl -s -H 'Title: Pi-Tool' -H 'Priority: high' --data-binary @- "\$URL/\$TOPIC" >/dev/null 2>&1
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
cat > /etc/systemd/system/$alertsUnit.timer <<'TMR'
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
