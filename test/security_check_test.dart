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
}
