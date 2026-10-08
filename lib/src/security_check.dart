/// Security audit of the Pi: a single read-only sudo probe + a pure parser that
/// turns its output into traffic-light findings — and, since v0.66.0, one-tap
/// fixes for the findings that are safe to automate. The check itself never
/// mutates; a fix only runs when the user taps "Beheben" on a finding. Pure
/// logic here (unit-testable); the orchestration runs probe/fix over SSH.
library;

import 'commands.dart' show shSingleQuote;

enum SecurityLevel { ok, warn, info }

/// One audited aspect: a title, a traffic-light [level] and a human explanation.
typedef SecurityFinding = ({String title, SecurityLevel level, String detail});

/// Builds the read-only probe. One `sudo sh -c` gathers everything with section
/// markers so [parseSecurityReport] can split it. sudo is needed to read the
/// effective sshd config; nothing is changed.
String buildSecurityProbe() {
  const script = r'''
echo __SEC_SSHD__
sshd -T 2>/dev/null | grep -iE '^(permitrootlogin|passwordauthentication) ' || grep -rhiE '^[[:space:]]*(PermitRootLogin|PasswordAuthentication)[[:space:]]' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null
echo __SEC_UNATT__
systemctl is-enabled unattended-upgrades 2>/dev/null || true
systemctl is-active unattended-upgrades 2>/dev/null || true
# The unit alone proves nothing: it is the shutdown helper and is enabled by
# the package. What actually gates the daily run is APT::Periodic, so read the
# EFFECTIVE value (apt-config folds in every apt.conf.d snippet).
apt-config dump APT::Periodic::Unattended-Upgrade 2>/dev/null | head -1 || true
# 32-bit Raspberry Pi OS takes its packages from the origin "Raspbian", but
# its unattended-upgrades is the unchanged Debian package: the Origins-Pattern
# names origin=Debian only, so it runs and installs nothing. Said only when
# that origin is in use AND apt-config could be read AND no pattern lets
# Raspbian in — on every other system this prints nothing at all.
if apt-cache policy 2>/dev/null | grep -Eq '[ ,]o=Raspbian(,|$)'; then
  if d=$(apt-config dump 2>/dev/null) && ! printf '%s\n' "$d" | grep -E '^Unattended-Upgrade::(Origins-Pattern|Allowed-Origins)::' | grep -q Raspbian; then
    echo raspbian-origin-uncovered
  fi
fi
echo __SEC_F2B__
systemctl is-active fail2ban 2>/dev/null || true
echo __SEC_PORTS__
ss -H -tln 2>/dev/null | awk '{print $4}'
echo __SEC_PIHOLE__
# Pi-hole v6 asks for no login while no password is set. Only the verdict is
# printed, never the hash.
if command -v pihole-FTL >/dev/null 2>&1; then
  if h=$(pihole-FTL --config -q webserver.api.pwhash 2>/dev/null); then
    case "$h" in ""|'""') echo pwhash-empty ;; *) echo pwhash-set ;; esac
  else
    echo pwhash-unknown
  fi
fi
''';
  return 'LC_ALL=C sudo -S sh -c ${shSingleQuote(script)}';
}

/// The findings the app can remedy with one tap. Deliberately NOT on the list:
/// turning SSH password auth off — without a proven key login that locks the
/// user out, so it stays a recommendation.
enum SecurityFix { fail2ban, autoUpdates, rootLogin, piholePassword }

/// Maps a finding to its one-tap fix, or null when there is nothing safe to
/// offer (finding is ok, undetermined, or intentionally manual).
SecurityFix? securityFixFor(SecurityFinding f) {
  // "Konnte nicht ermittelt werden" — don't offer to fix unknown state.
  if (f.detail.startsWith('Konnte nicht')) return null;
  if (f.title == 'SSH-Root-Login' && f.level == SecurityLevel.warn) {
    return SecurityFix.rootLogin;
  }
  if (f.title == 'Automatische Sicherheitsupdates' &&
      f.level == SecurityLevel.warn) {
    return SecurityFix.autoUpdates;
  }
  if (f.title == piholeWebFindingTitle && f.level == SecurityLevel.warn) {
    return SecurityFix.piholePassword;
  }
  if (f.title.startsWith('fail2ban') &&
      f.level != SecurityLevel.ok &&
      f.detail.contains('nicht aktiv')) {
    return SecurityFix.fail2ban;
  }
  return null;
}

/// Title of the Pi-hole web-login finding (only present when Pi-hole is).
const String piholeWebFindingTitle = 'Pi-hole-Weboberfläche';

/// Root script for one [SecurityFix]. Success marker `SECFIX_OK` (run via
/// `_runRootScriptExpectMarker` — success only with the marker).
/// [SecurityFix.piholePassword] needs a generated password and runs
/// `buildPiholeSetPasswordScript` instead.
String buildSecurityFixScript(SecurityFix fix) {
  switch (fix) {
    case SecurityFix.piholePassword:
      throw ArgumentError.value(
          fix, 'fix', 'braucht ein Passwort – buildPiholeSetPasswordScript');
    // The script arrives on stdin (`sudo -S bash -s`): every apt-get gets its
    // own </dev/null, and --force-confdef/--force-confold keep a changed
    // conffile without asking — dpkg's question would otherwise read the rest
    // of the script as its answer and abort.
    //
    // fail2ban: `enable --now` returns once the server process is forked; a
    // server that finds no log to read ends a moment later. So the unit is
    // watched for ten seconds, and only one that stays active gets the marker
    // — otherwise a journal excerpt and exit 1.
    //
    // Debian 12 / Raspberry Pi OS Bookworm without rsyslog has no
    // /var/log/auth.log, and fail2ban 1.0.2-2 there ends with "Have not found
    // any log file for sshd jail". Only in that case (not active AND no
    // auth.log) the sshd jail is pointed at the journal by a drop-in of our
    // own; a fail2ban that started is left as it is. A drop-in this run
    // wrote and that did not help is removed again.
    case SecurityFix.fail2ban:
      return '''
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
apt-get update -qq </dev/null 2>&1 || true
apt-get -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y fail2ban </dev/null
systemctl enable --now fail2ban || true
stays_up() {
  local i
  for i in 1 2 3 4 5; do
    sleep 2
    systemctl is-active --quiet fail2ban || return 1
  done
}
j=/etc/fail2ban/jail.d/pitool-sshd.local
up=0
wrote=0
stays_up && up=1
if [ "\$up" = 0 ] && [ ! -e /var/log/auth.log ]; then
  echo 'fail2ban startet nicht und /var/log/auth.log fehlt – der SSH-Schutz liest stattdessen das systemd-Journal.'
  apt-get -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y python3-systemd </dev/null
  mkdir -p /etc/fail2ban/jail.d
  [ -e "\$j" ] || wrote=1
  printf '[sshd]\\nenabled = true\\nbackend = systemd\\n' > "\$j"
  systemctl restart fail2ban || true
  stays_up && up=1
fi
if [ "\$up" = 0 ]; then
  [ "\$wrote" = 0 ] || rm -f "\$j"
  echo 'fail2ban läuft nach der Installation nicht. Auszug aus dem Journal:'
  journalctl -u fail2ban -n 20 --no-pager </dev/null 2>&1 || true
  exit 1
fi
echo SECFIX_OK
''';
    // Automatic updates, 32-bit Raspberry Pi OS only (origin Raspbian in
    // use): the package's patterns name origin=Debian alone, so a fragment of
    // our own lets Raspbian in. NOT the "Raspberry Pi Foundation" archive:
    // kernel, firmware and bootloader packages stay a manual update, on 32-
    // and 64-bit alike. `${distro_codename}` must reach the file as written
    // (unattended-upgrades expands it) — hence the quoted heredoc. apt reads
    // apt.conf.d as any user: 0644 whatever the umask. A fragment that
    // apt-config then does not list is removed again, without the marker.
    // Without that origin the script does exactly what it did before.
    case SecurityFix.autoUpdates:
      return '''
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
apt-get update -qq </dev/null 2>&1 || true
apt-get -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y unattended-upgrades </dev/null
printf 'APT::Periodic::Update-Package-Lists "1";\\nAPT::Periodic::Unattended-Upgrade "1";\\n' > /etc/apt/apt.conf.d/20auto-upgrades
if apt-cache policy 2>/dev/null | grep -Eq '[ ,]o=Raspbian(,|\$)'; then
  o=/etc/apt/apt.conf.d/51pitool-unattended-origins
  cat > "\$o" <<'ORIGINS'
Unattended-Upgrade::Origins-Pattern {
        "origin=Raspbian,codename=\${distro_codename},label=Raspbian";
};
ORIGINS
  chmod 0644 "\$o"
  if ! apt-config dump 2>/dev/null | grep -E '^Unattended-Upgrade::(Origins-Pattern|Allowed-Origins)::' | grep -q Raspbian; then
    rm -f "\$o"
    echo 'apt liest die Freigabe der Paketquelle Raspbian nicht ein – Änderung zurückgenommen.'
    exit 1
  fi
fi
systemctl enable --now unattended-upgrades
echo SECFIX_OK
''';
    case SecurityFix.rootLogin:
      // Deliberately NO `set -e`: the script must reach its own rollback
      // branches. The change lives in a drop-in (sshd_config stays untouched),
      // is validated with `sshd -t` BEFORE the reload, and the effective value
      // is re-read with `sshd -T` afterwards — if the Include didn't take
      // effect, the drop-in is removed again and the fix reports failure
      // instead of pretending. The current SSH session survives a reload.
      return r'''
export LC_ALL=C
f=/etc/ssh/sshd_config.d/60-pitool-hardening.conf
mkdir -p /etc/ssh/sshd_config.d
printf 'PermitRootLogin no\n' > "$f"
if ! sshd -t 2>/dev/null; then
  rm -f "$f"
  echo "sshd -t lehnt die Konfiguration ab - Aenderung zurueckgenommen."
  exit 1
fi
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
eff=$(sshd -T 2>/dev/null | grep -i '^permitrootlogin ' | awk '{print $2}')
if [ "$eff" != "no" ]; then
  rm -f "$f"
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  echo "PermitRootLogin blieb '$eff' (sshd_config.d greift nicht?) - Aenderung zurueckgenommen."
  exit 1
fi
echo SECFIX_OK
''';
  }
}

/// Parses the probe output. Always returns the same five findings (plus the
/// Pi-hole web login when Pi-hole is installed); anything it
/// cannot determine degrades to [SecurityLevel.info] (never a false ok/warn).
List<SecurityFinding> parseSecurityReport(String output) {
  final sections = <String, List<String>>{
    'SSHD': [],
    'UNATT': [],
    'F2B': [],
    'PORTS': [],
    'PIHOLE': [],
  };
  const markers = {
    '__SEC_SSHD__': 'SSHD',
    '__SEC_UNATT__': 'UNATT',
    '__SEC_F2B__': 'F2B',
    '__SEC_PORTS__': 'PORTS',
    '__SEC_PIHOLE__': 'PIHOLE',
  };
  String? cur;
  for (final raw in output.split('\n')) {
    final line = raw.trim();
    final m = markers[line];
    if (m != null) {
      cur = m;
      continue;
    }
    if (cur != null && line.isNotEmpty) sections[cur]!.add(line);
  }

  final sshd = sections['SSHD']!.join('\n').toLowerCase();

  // 1) Root SSH login.
  SecurityFinding root;
  final rootM = RegExp(r'permitrootlogin\s+(\S+)').firstMatch(sshd);
  if (rootM == null) {
    root = (
      title: 'SSH-Root-Login',
      level: SecurityLevel.info,
      detail: 'Konnte nicht ermittelt werden.'
    );
  } else {
    final v = rootM.group(1)!;
    // `without-password` is the legacy alias of `prohibit-password` — Debian
    // 13's sshd -T reports it (seen on the real test Pi 2026-08-15).
    if (v == 'no' || v == 'prohibit-password' || v == 'without-password') {
      root = (
        title: 'SSH-Root-Login',
        level: SecurityLevel.ok,
        detail: 'Root-Login per SSH ist deaktiviert.'
      );
    } else if (v == 'yes') {
      root = (
        title: 'SSH-Root-Login',
        level: SecurityLevel.warn,
        detail: 'Root darf sich per SSH anmelden — abschalten empfohlen '
            '(PermitRootLogin no).'
      );
    } else {
      root = (
        title: 'SSH-Root-Login',
        level: SecurityLevel.info,
        detail: 'PermitRootLogin: $v'
      );
    }
  }

  // 2) SSH password auth.
  SecurityFinding pw;
  final pwM = RegExp(r'passwordauthentication\s+(\S+)').firstMatch(sshd);
  if (pwM == null) {
    pw = (
      title: 'SSH-Passwort-Login',
      level: SecurityLevel.info,
      detail: 'Konnte nicht ermittelt werden.'
    );
  } else if (pwM.group(1) == 'no') {
    pw = (
      title: 'SSH-Passwort-Login',
      level: SecurityLevel.ok,
      detail: 'Nur Key-Login — Passwort-Login ist aus.'
    );
  } else {
    pw = (
      title: 'SSH-Passwort-Login',
      level: SecurityLevel.info,
      detail: 'Passwort-Login ist an — SSH-Key-Login ist sicherer '
          '(Brute-Force-resistent).'
    );
  }

  // 3) Automatic security updates.
  SecurityFinding updates;
  final unatt = sections['UNATT']!.map((l) => l.toLowerCase()).toList();
  if (unatt.isEmpty) {
    updates = (
      title: 'Automatische Sicherheitsupdates',
      level: SecurityLevel.info,
      detail: 'Konnte nicht ermittelt werden.'
    );
  } else if (unatt.contains('enabled') && unatt.contains('active')) {
    // APT::Periodic::Unattended-Upgrade "0" means the package is installed and
    // the unit enabled, but nothing is ever installed automatically. Only the
    // explicit "0" downgrades the verdict — an unreadable value must not turn
    // a healthy Pi red (fail-safe in the other direction than usual, because
    // the default on Debian/Raspberry Pi OS after install is "1").
    final periodicOff = unatt.any((l) =>
        l.contains('apt::periodic::unattended-upgrade') && l.contains('"0"'));
    // 32-bit Raspberry Pi OS: the daily run happens, but no pattern lets the
    // origin Raspbian in (the probe prints this line in that case only).
    final raspbianLeftOut = unatt.contains('raspbian-origin-uncovered');
    updates = periodicOff
        ? (
            title: 'Automatische Sicherheitsupdates',
            level: SecurityLevel.warn,
            detail: 'unattended-upgrades ist installiert, aber abgeschaltet '
                '(APT::Periodic::Unattended-Upgrade "0") — es wird nichts '
                'automatisch installiert.'
          )
        : raspbianLeftOut
            ? (
                title: 'Automatische Sicherheitsupdates',
                level: SecurityLevel.warn,
                detail: 'unattended-upgrades läuft, installiert aber keine '
                    'Updates aus der Paketquelle Raspbian (32-Bit Raspberry Pi '
                    'OS) — sie fehlt in Unattended-Upgrade::Origins-Pattern.'
              )
            : (
                title: 'Automatische Sicherheitsupdates',
                level: SecurityLevel.ok,
                detail: 'unattended-upgrades läuft.'
              );
  } else {
    updates = (
      title: 'Automatische Sicherheitsupdates',
      level: SecurityLevel.warn,
      detail: 'Keine automatischen Sicherheitsupdates — unattended-upgrades '
          'aktivieren empfohlen.'
    );
  }

  // 4) fail2ban (optional brute-force protection).
  SecurityFinding f2b;
  final f2bLines = sections['F2B']!.map((l) => l.toLowerCase()).toList();
  if (f2bLines.isEmpty) {
    f2b = (
      title: 'fail2ban (Brute-Force-Schutz)',
      level: SecurityLevel.info,
      detail: 'Konnte nicht ermittelt werden.'
    );
  } else if (f2bLines.contains('active')) {
    f2b = (
      title: 'fail2ban (Brute-Force-Schutz)',
      level: SecurityLevel.ok,
      detail: 'fail2ban ist aktiv.'
    );
  } else {
    f2b = (
      title: 'fail2ban (Brute-Force-Schutz)',
      level: SecurityLevel.info,
      detail: 'fail2ban nicht aktiv — optionaler Schutz gegen Login-Angriffe.'
    );
  }

  // 5) Open (listening) ports — informational.
  final ports = sections['PORTS']!
      .map((l) => l.split(':').last.trim())
      .where((p) => int.tryParse(p) != null)
      .toSet()
      .toList()
    ..sort((a, b) => int.parse(a).compareTo(int.parse(b)));
  final openPorts = (
    title: 'Offene Ports',
    level: SecurityLevel.info,
    detail: ports.isEmpty
        ? 'Keine ermittelt.'
        : 'Lauschende TCP-Ports: ${ports.join(', ')}'
  );

  // 6) Pi-hole web login — only when Pi-hole is there.
  final ph = sections['PIHOLE']!;
  final SecurityFinding? pihole = ph.isEmpty
      ? null
      : ph.contains('pwhash-empty')
          ? (
              title: piholeWebFindingTitle,
              level: SecurityLevel.warn,
              detail: 'Kein Passwort gesetzt – jeder im Heimnetz kann Pi-hole '
                  'ohne Anmeldung umkonfigurieren (Upstream-DNS, Blocklisten, '
                  'lokale DNS-Einträge).'
            )
          : ph.contains('pwhash-set')
              ? (
                  title: piholeWebFindingTitle,
                  level: SecurityLevel.ok,
                  detail: 'Die Weboberfläche ist passwortgeschützt.'
                )
              : (
                  title: piholeWebFindingTitle,
                  level: SecurityLevel.info,
                  detail: 'Konnte nicht ermittelt werden (Pi-hole v6 nötig).'
                );

  return [root, pw, updates, f2b, openPorts, ?pihole];
}
