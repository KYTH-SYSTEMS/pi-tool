/// Read-only security audit of the Pi: a single sudo probe + a pure parser that
/// turns its output into traffic-light findings. No mutation — the app only
/// reads state and recommends. Pure logic here (unit-testable); the UI renders
/// the findings and the orchestration runs the probe over SSH.
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
    if (v == 'no' || v == 'prohibit-password') {
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
