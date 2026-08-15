import 'package:evcc_updater/src/security_check.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildSecurityProbe', () {
    test('is a single read-only sudo probe with all section markers', () {
      final cmd = buildSecurityProbe();
      expect(cmd, startsWith('LC_ALL=C sudo -S sh -c '));
      // The inner script is single-quoted as one argument.
      for (final m in [
        '__SEC_SSHD__',
        '__SEC_UNATT__',
        '__SEC_F2B__',
        '__SEC_PORTS__',
      ]) {
        expect(cmd, contains(m));
      }
      // Read-only: no mutating verbs.
      expect(cmd, isNot(contains('systemctl start')));
      expect(cmd, isNot(contains('rm ')));
    });
  });

  group('parseSecurityReport', () {
    SecurityFinding by(List<SecurityFinding> f, String needle) =>
        f.firstWhere((x) => x.title.toLowerCase().contains(needle));

    test('a hardened Pi reports all-clear', () {
      const out = '''
__SEC_SSHD__
permitrootlogin no
passwordauthentication no
__SEC_UNATT__
enabled
active
__SEC_F2B__
active
__SEC_PORTS__
0.0.0.0:22
[::]:22
''';
      final r = parseSecurityReport(out);
      expect(by(r, 'root').level, SecurityLevel.ok);
      expect(by(r, 'passwort').level, SecurityLevel.ok);
      expect(by(r, 'updates').level, SecurityLevel.ok);
      expect(by(r, 'fail2ban').level, SecurityLevel.ok);
      // Overall: no warnings.
      expect(r.any((f) => f.level == SecurityLevel.warn), isFalse);
    });

    test('a weak Pi flags root login + missing auto-updates', () {
      const out = '''
__SEC_SSHD__
permitrootlogin yes
passwordauthentication yes
__SEC_UNATT__
disabled
inactive
__SEC_F2B__
inactive
__SEC_PORTS__
0.0.0.0:22
0.0.0.0:80
''';
      final r = parseSecurityReport(out);
      expect(by(r, 'root').level, SecurityLevel.warn); // root SSH login = warn
      expect(by(r, 'updates').level, SecurityLevel.warn); // no auto-updates
      // Password auth on is a recommendation, not a hard warning.
      expect(by(r, 'passwort').level, SecurityLevel.info);
      // fail2ban absent = info (recommendation), not a warning.
      expect(by(r, 'fail2ban').level, SecurityLevel.info);
      // Open ports are listed for the user.
      expect(by(r, 'ports').detail, contains('22'));
      expect(by(r, 'ports').detail, contains('80'));
    });

    test('missing/garbled sections degrade to info, never crash', () {
      final r = parseSecurityReport('nonsense without markers');
      expect(r, isNotEmpty);
      // Nothing can be asserted → no false "ok"/"warn"; unknowns are info.
      expect(r.every((f) => f.level == SecurityLevel.info), isTrue);
    });
  });

  group('securityFixFor', () {
    test('warn findings map to their fix', () {
      expect(
          securityFixFor((
            title: 'SSH-Root-Login',
            level: SecurityLevel.warn,
            detail: 'Root darf sich per SSH anmelden.'
          )),
          SecurityFix.rootLogin);
      expect(
          securityFixFor((
            title: 'Automatische Sicherheitsupdates',
            level: SecurityLevel.warn,
            detail: 'Keine automatischen Sicherheitsupdates.'
          )),
          SecurityFix.autoUpdates);
    });

    test('inactive fail2ban is fixable even though it is only info', () {
      expect(
          securityFixFor((
            title: 'fail2ban (Brute-Force-Schutz)',
            level: SecurityLevel.info,
            detail: 'fail2ban nicht aktiv — optionaler Schutz.'
          )),
          SecurityFix.fail2ban);
    });

    test('ok and undetermined findings offer no fix', () {
      expect(
          securityFixFor((
            title: 'SSH-Root-Login',
            level: SecurityLevel.ok,
            detail: 'Root-Login per SSH ist deaktiviert.'
          )),
          isNull);
      expect(
          securityFixFor((
            title: 'fail2ban (Brute-Force-Schutz)',
            level: SecurityLevel.info,
            detail: 'Konnte nicht ermittelt werden.'
          )),
          isNull);
      // Password auth off is NOT a one-tap fix: without a working key login
      // it would lock the user out. Never offered.
      expect(
          securityFixFor((
            title: 'SSH-Passwort-Login',
            level: SecurityLevel.info,
            detail: 'Passwort-Login ist an.'
          )),
          isNull);
      expect(
          securityFixFor((
            title: 'Offene Ports',
            level: SecurityLevel.info,
            detail: 'Lauschende TCP-Ports: 22'
          )),
          isNull);
    });
  });

  group('buildSecurityFixScript', () {
    test('every fix ends in the success marker', () {
      for (final fix in SecurityFix.values) {
        expect(buildSecurityFixScript(fix), contains('SECFIX_OK'));
      }
    });

    test('installs run apt without a pty (log noise)', () {
      for (final fix in [SecurityFix.fail2ban, SecurityFix.autoUpdates]) {
        final s = buildSecurityFixScript(fix);
        for (final line in s.split('\n')) {
          if (line.contains('apt-get') && line.contains('install')) {
            expect(line, contains('-o Dpkg::Use-Pty=0'));
          }
        }
      }
    });

    test('fail2ban: install + enable now', () {
      final s = buildSecurityFixScript(SecurityFix.fail2ban);
      expect(s, contains('install -y fail2ban'));
      expect(s, contains('systemctl enable --now fail2ban'));
    });

    test('auto updates: package + the two periodic switches', () {
      final s = buildSecurityFixScript(SecurityFix.autoUpdates);
      expect(s, contains('install -y unattended-upgrades'));
      expect(s, contains('20auto-upgrades'));
      expect(s, contains('APT::Periodic::Update-Package-Lists "1"'));
      expect(s, contains('APT::Periodic::Unattended-Upgrade "1"'));
      expect(s, contains('systemctl enable --now unattended-upgrades'));
    });

    test('root login: drop-in + sshd -t gate + verified effect + rollback', () {
      final s = buildSecurityFixScript(SecurityFix.rootLogin);
      // Change goes into a drop-in, never edits sshd_config itself.
      expect(s, contains('/etc/ssh/sshd_config.d/'));
      expect(s, contains('PermitRootLogin no'));
      // Config validated BEFORE reload; a bad config removes the drop-in.
      expect(s.indexOf('sshd -t'), lessThan(s.indexOf('reload')));
      expect(s, contains('rm -f'));
      // And the effective value is verified afterwards (Include might miss).
      expect(s, contains('sshd -T'));
      expect(s, contains('permitrootlogin'));
      // No set -e: the script must reach its own rollback branches.
      expect(s.split('\n').first.trim(), isNot('set -e'));
    });
  });
}
