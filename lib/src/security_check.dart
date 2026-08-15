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
echo __SEC_F2B__
systemctl is-active fail2ban 2>/dev/null || true
echo __SEC_PORTS__
ss -H -tln 2>/dev/null | awk '{print $4}'
''';
  return 'LC_ALL=C sudo -S sh -c ${shSingleQuote(script)}';
}

/// The findings the app can remedy with one tap. Deliberately NOT on the list:
/// turning SSH password auth off — without a proven key login that locks the
/// user out, so it stays a recommendation.
enum SecurityFix { fail2ban, autoUpdates, rootLogin }

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
  if (f.title.startsWith('fail2ban') &&
      f.level != SecurityLevel.ok &&
      f.detail.contains('nicht aktiv')) {
    return SecurityFix.fail2ban;
  }
  return null;
}

/// Root script for one [SecurityFix]. Success marker `SECFIX_OK` (run via
/// `_runRootScriptExpectMarker` — success only with the marker).
String buildSecurityFixScript(SecurityFix fix) {
  switch (fix) {
    case SecurityFix.fail2ban:
      return '''
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
apt-get update -qq 2>&1 || true
apt-get -o Dpkg::Use-Pty=0 install -y fail2ban
systemctl enable --now fail2ban
echo SECFIX_OK
''';
    case SecurityFix.autoUpdates:
      return '''
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
apt-get update -qq 2>&1 || true
apt-get -o Dpkg::Use-Pty=0 install -y unattended-upgrades
printf 'APT::Periodic::Update-Package-Lists "1";\\nAPT::Periodic::Unattended-Upgrade "1";\\n' > /etc/apt/apt.conf.d/20auto-upgrades
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

/// Parses the probe output. Always returns the same five findings; anything it
/// cannot determine degrades to [SecurityLevel.info] (never a false ok/warn).
List<SecurityFinding> parseSecurityReport(String output) {
  final sections = <String, List<String>>{
    'SSHD': [],
    'UNATT': [],
    'F2B': [],
    'PORTS': [],
  };
  const markers = {
    '__SEC_SSHD__': 'SSHD',
    '__SEC_UNATT__': 'UNATT',
    '__SEC_F2B__': 'F2B',
    '__SEC_PORTS__': 'PORTS',
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
    updates = (
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

  return [root, pw, updates, f2b, openPorts];
}
