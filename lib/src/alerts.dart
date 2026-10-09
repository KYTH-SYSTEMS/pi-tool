/// Health-Alerts: an on-Pi systemd timer that checks health (disk, temp, dead
/// services, pending updates) and pushes a notification via **ntfy** when a
/// problem appears — backend-free, no Android background service (see the
/// v0.20.0 lesson). Pure builders + parser so it's unit-testable. Debounced via
/// a state file so it never spams the same alert.
library;

import 'dart:math';

import 'commands.dart' show shSingleQuote;
import 'on_pi_wrapper.dart';

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

/// Where the wrapper reads its ntfy destination from: a file of its own that
/// only root can read. The topic is the password — and the wrapper has to stay
/// world-readable, because the status probe looks for its stamp line as the
/// SSH user, without sudo (on_pi_wrapper.dart).
const String alertsDestinationPath = '/usr/local/lib/$alertsUnit.conf';

final RegExp _httpRe = RegExp(r'^https?://', caseSensitive: false);
final RegExp _schemeRe = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*://');

/// The ntfy server as curl gets it: without whitespace and with an explicit
/// http(s) scheme. A server typed without one ("ntfy.sh") gets `http://` —
/// what curl assumes for such a value, so a destination that works today
/// keeps working. Any other scheme (and no server at all) is refused: the
/// field is free text, and curl speaks more protocols than ntfy.
String _ntfyServer(String server) {
  final s = server.replaceAll(RegExp(r'\s'), '');
  if (_httpRe.hasMatch(s)) return s;
  if (s.isEmpty || _schemeRe.hasMatch(s)) {
    // Without the value: the text of this error is logged, and the field may
    // hold credentials (user:password@…) or a pasted ntfy:// link — which
    // names the topic.
    throw ArgumentError('kein http(s)-Server für ntfy', 'ntfyServer');
  }
  return 'http://$s';
}

/// Shell that sets `title` to the title of a push: `Pi-Tool (<hostname>)`.
/// Several Pis can push to one ntfy topic — a profile without a topic of its
/// own uses the app-wide one — and "Dienst aus: evcc" alone names none of
/// them.
///
/// The hostname is whatever the Pi answers. It goes into the title only when
/// it consists of the characters of a hostname; with anything else in it (a
/// blank, a line break, a quote) the title stays `Pi-Tool`. The characters
/// are listed one by one: what a range like `a-z` covers depends on the
/// locale. All ASCII, the brackets included — the title travels as an HTTP
/// header, and what a server makes of other bytes there was not measured.
const String _titleSh = r'''host=$(hostname 2>/dev/null); case "$host" in ''|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*) title='Pi-Tool' ;; *) title="Pi-Tool ($host)" ;; esac''';

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
  final url = shSingleQuote(_ntfyServer(ntfyServer));
  final topic = shSingleQuote(ntfyTopic.replaceAll(RegExp(r'\s'), ''));
  return '''
set -e
mkdir -p /var/lib/pi-tool
# A new destination has not heard of the current problems yet: forget what the
# previous one was sent, so the first run pushes them again.
rm -f /var/lib/pi-tool/alerts.last
# Written next to the wrapper and moved into place at the end: a check that is
# running keeps reading the file it opened. Rewritten in place, its shell
# would go on at the old offset in the new text.
cat > /usr/local/lib/$alertsUnit.sh.new <<'WRAP'
#!/bin/sh
$alertsWrapperStamp
mkdir -p /var/lib/pi-tool
WRAP
# The destination gets a file of its own that only root can read; the wrapper
# sources it. URL/TOPIC are Dart-substituted (shell-quoted) BEFORE the shell
# sees them, so a QUOTED heredoc lands them verbatim — no install-time shell
# expansion of a hostile topic like \$(reboot). They assign as literals at
# wrapper runtime.
rm -f $alertsDestinationPath
(umask 077; cat > $alertsDestinationPath <<'WRAP'
URL=$url
TOPIC=$topic
WRAP
)
chmod 600 $alertsDestinationPath
cat >> /usr/local/lib/$alertsUnit.sh.new <<'WRAP'
URL="" TOPIC=""
[ -r $alertsDestinationPath ] && . $alertsDestinationPath
problems=""
classes=""
# One problem. Its class goes into the debounce hash, its text — with the
# measured value — only into the message: a value that moves above its
# threshold (91 to 93 percent, 3 to 5 updates) is the same problem and must
# not push again.
problem() {
  classes="\$classes \$1"
  problems="\$problems"'\\n'"\$2"
}
use=\$(df / | awk 'NR==2{gsub("%","",\$5); print \$5}')
[ -n "\$use" ] && [ "\$use" -ge 90 ] && problem disk "Speicher: \${use}% belegt"
if [ -r /sys/class/thermal/thermal_zone0/temp ]; then
  t=\$(( \$(cat /sys/class/thermal/thermal_zone0/temp) / 1000 ))
  [ "\$t" -ge 75 ] && problem temp "Temperatur: \${t} Grad"
fi
# Dying-SD symptoms: a read-only-remounted root, or piling I/O errors in the
# kernel log. /proc/mounts always lists rw/ro as the FIRST option.
grep -qE '^\\S+ / \\S+ ro[, ]' /proc/mounts && problem ro "SD-Karte: Dateisystem nur-lesend"
ioerr=\$(journalctl -k --no-pager -q 2>/dev/null | grep -icE 'i/o error|ext4-fs error|mmc[0-9]+: error')
[ -n "\$ioerr" ] && [ "\$ioerr" -ge 5 ] && problem ioerr "SD-Karte: \$ioerr I/O-Fehler im Kernel-Log"
for s in evcc pihole-FTL grafana-server influxdb mosquitto; do
  if systemctl is-enabled "\$s" >/dev/null 2>&1; then
    # Down means failed or inactive. "activating" is a service that starts (a
    # restart, the Pi booting) and no outage — unless systemd is restarting it
    # because it keeps dying (SubState auto-restart).
    case "\$(systemctl is-active "\$s" 2>/dev/null)" in
      failed|inactive) problem "svc:\$s" "Dienst aus: \$s" ;;
      activating)
        systemctl show -p SubState "\$s" 2>/dev/null | grep -q '^SubState=auto-restart' &&
          problem "svc:\$s" "Dienst aus: \$s" ;;
    esac
  fi
done
pend=\$(LC_ALL=C apt-get -s upgrade 2>/dev/null | grep -c '^Inst ')
[ "\$pend" -gt 0 ] && problem updates "\$pend Updates verfuegbar"
hash=\$(printf '%s' "\$classes" | md5sum | awk '{print \$1}')
last=\$(cat /var/lib/pi-tool/alerts.last 2>/dev/null)
if [ -n "\$problems" ] && [ "\$hash" != "\$last" ]; then
  # Which Pi this is goes into the title — not into the hash above: a renamed
  # Pi has no new problem.
  $_titleSh
  # Remember the hash only once the push went out: a failed one (no DNS or
  # internet, an HTTP error — hence -f) is tried again at the next run instead
  # of counting as sent. The timeouts bound the oneshot unit, which has no
  # start timeout of its own.
  if printf 'Pi-Tool hat Probleme erkannt:%b' "\$problems" | \\
    curl -fsS --connect-timeout 10 --max-time 30 -H "Title: \$title" -H 'Priority: high' --data-binary @- -- "\$URL/\$TOPIC" >/dev/null 2>&1; then
    printf '%s' "\$hash" > /var/lib/pi-tool/alerts.last
  fi
elif [ -z "\$problems" ]; then
  : > /var/lib/pi-tool/alerts.last
fi
echo "\$(date '+%Y-%m-%d %H:%M') checked" > /var/lib/pi-tool/alerts.status
rc=\$?
# Last, so it can neither delay nor lose a push. "N Updates verfuegbar" is
# counted against the local package lists, and on a stock Pi nothing refreshes
# those. So do it here once they are older than a day — at most once per 24 h
# (alerts.aptupdate marks the try, whatever came of it); the next check then
# counts against the new lists. Bounded by timeout, and with a lock timeout of
# 0, so it gives up at once instead of queueing behind another apt run. A clean
# run stamps /var/lib/apt/lists like "Paketlisten aktualisieren" in the app
# does (apt leaves the mtime alone while every source answers "Hit"), so the
# app's cards see the refresh too.
now=\$(date +%s)
age() { m=\$(stat -c %Y "\$1" 2>/dev/null) || m=0; echo \$((now - m)); }
if [ "\$(age /var/lib/apt/lists)" -ge 86400 ] && [ "\$(age /var/lib/pi-tool/alerts.aptupdate)" -ge 86400 ]; then
  touch /var/lib/pi-tool/alerts.aptupdate
  if out=\$(LC_ALL=C timeout -k 10 120 apt-get -o DPkg::Lock::Timeout=0 update -qq 2>&1); then
    case "\$out" in
      *"Failed to fetch"*|*"failed to download"*) ;;
      *) touch /var/lib/apt/lists ;;
    esac
  fi
fi
exit "\$rc"
WRAP
# Modes by number, not "+x": the status probe reads the wrapper's stamp and
# the timer unit without sudo, whatever root's umask is.
chmod 755 /usr/local/lib/$alertsUnit.sh.new
mv -f /usr/local/lib/$alertsUnit.sh.new /usr/local/lib/$alertsUnit.sh
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
chmod 644 /etc/systemd/system/$alertsUnit.service /etc/systemd/system/$alertsUnit.timer
systemctl daemon-reload
systemctl enable --now $alertsUnit.timer
echo ALERTS_INSTALLED
''';
}

/// Root script that removes the alerts timer, service, wrapper and destination
/// file — and systemd's stamp of the timer ([timerStampPath]). What the checks
/// left in /var/lib/pi-tool goes too (last check, what was last sent, the
/// last try to refresh the package lists): alerts turned on again later start
/// without a check from before. `set -e`: a failing `rm` (read-only root)
/// must end without the marker.
String buildAlertsRemoveScript() {
  return '''
set -e
systemctl disable --now $alertsUnit.timer 2>/dev/null || true
rm -f /etc/systemd/system/$alertsUnit.timer \\
  /etc/systemd/system/$alertsUnit.service \\
  /usr/local/lib/$alertsUnit.sh \\
  $alertsDestinationPath \\
  ${timerStampPath(alertsUnit)} \\
  /var/lib/pi-tool/alerts.status /var/lib/pi-tool/alerts.last \\
  /var/lib/pi-tool/alerts.aptupdate
systemctl daemon-reload
echo ALERTS_REMOVED
''';
}

/// One-off command that sends a test push, to verify the ntfy destination.
/// `-f` turns an HTTP error into an exit code and `-sS` keeps curl's reason on
/// stderr, so the caller can tell a delivered push from a failed one;
/// `--max-time` keeps an unreachable server from hanging the action.
/// Whitespace is stripped and the server checked like in
/// [buildAlertsInstallScript], so the test hits the destination the timer will
/// use — under the title the timer will use ([_titleSh]). curl comes last:
/// its exit code is the command's. The whole runs through `sh -c`: the title
/// takes a `case`, and the SSH user's login shell need not be a Bourne shell.
String buildTestAlertCommand({
  required String ntfyServer,
  required String ntfyTopic,
}) {
  final server = _ntfyServer(ntfyServer);
  final topic = ntfyTopic.replaceAll(RegExp(r'\s'), '');
  final url = shSingleQuote('$server/$topic');
  final msg = shSingleQuote('Test-Benachrichtigung ✓ von Pi-Tool');
  return 'sh -c ${shSingleQuote('$_titleSh; '
      'curl -fsS --max-time 15 -H "Title: \$title" -d $msg -- $url')}';
}

/// No-sudo status command parsed by [parseAlertsStatus].
const String alertsStatusCommand =
    'echo "ENABLED \$(systemctl is-enabled $alertsUnit.timer 2>/dev/null || echo disabled)"; '
    'echo "LAST \$(cat /var/lib/pi-tool/alerts.status 2>/dev/null)"; '
    '$wrapperProbeHead$alertsUnit$wrapperProbeMid$alertsWrapperStamp$wrapperProbeTail';

/// [wrapperOutdated]: the wrapper on the Pi is from an older app release (see
/// on_pi_wrapper.dart).
typedef AlertsStatus = ({
  bool enabled,
  String? lastCheck,
  bool wrapperOutdated,
});

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
  return (
    enabled: enabled,
    lastCheck: lastCheck,
    wrapperOutdated: parseWrapperOutdated(out),
  );
}
