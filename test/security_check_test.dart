import 'package:evcc_updater/src/security_check.dart';
import 'package:flutter_test/flutter_test.dart';

import 'on_pi_sandbox.dart';

/// `apt-cache policy` release lines of a 64-bit Raspberry Pi OS (Debian
/// origins plus the Raspberry Pi archive) …
const _policyDebian = '''
 500 http://archive.raspberrypi.com/debian bookworm/main arm64 Packages
     release o=Raspberry Pi Foundation,a=stable,n=bookworm,l=Raspberry Pi Foundation,c=main,b=arm64
     origin archive.raspberrypi.com
 500 http://deb.debian.org/debian-security bookworm-security/main arm64 Packages
     release v=12,o=Debian,a=stable-security,n=bookworm-security,l=Debian-Security,c=main,b=arm64
     origin deb.debian.org
 500 http://deb.debian.org/debian bookworm/main arm64 Packages
     release v=12.11,o=Debian,a=stable,n=bookworm,l=Debian,c=main,b=arm64
     origin deb.debian.org
''';

/// … and of the 32-bit one, whose packages come from Raspbian.
const _policyRaspbian = '''
 500 http://archive.raspberrypi.com/debian bookworm/main armhf Packages
     release o=Raspberry Pi Foundation,a=stable,n=bookworm,l=Raspberry Pi Foundation,c=main,b=armhf
     origin archive.raspberrypi.com
 500 http://raspbian.raspberrypi.com/raspbian bookworm/main armhf Packages
     release o=Raspbian,a=stable,n=bookworm,l=Raspbian,c=main,b=armhf
     origin raspbian.raspberrypi.com
''';

/// The Origins-Pattern block of the unattended-upgrades package — the same
/// file on Debian and on Raspbian.
const _stockOrigins = r'''
Unattended-Upgrade::Origins-Pattern {
        // Codename based matching:
        "origin=Debian,codename=${distro_codename},label=Debian";
        "origin=Debian,codename=${distro_codename},label=Debian-Security";
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
''';

void main() {
  group('buildSecurityProbe', () {
    test('is a single sudo probe with all section markers', () {
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
      // That it changes nothing is run in bash below ("the probe only asks");
      // these two only catch the obvious where there is no bash.
      expect(cmd, isNot(contains('systemctl start')));
      expect(cmd, isNot(contains('rm ')));
    });
  });

  group('Pi-hole-Weboberfläche', () {
    test('die Probe prüft den Passwort-Hash, ohne ihn auszugeben', () {
      final probe = buildSecurityProbe();
      expect(probe, contains('__SEC_PIHOLE__'));
      expect(probe, contains('webserver.api.pwhash'));
      expect(probe, contains('pwhash-empty'));
      expect(probe, contains('pwhash-set'));
    });

    test('ohne Passwort: Warnung mit Ein-Tipp-Fix', () {
      final r = parseSecurityReport('__SEC_PIHOLE__\npwhash-empty\n');
      final f = r.firstWhere((x) => x.title == 'Pi-hole-Weboberfläche');
      expect(f.level, SecurityLevel.warn);
      expect(securityFixFor(f), SecurityFix.piholePassword);
    });

    test('mit Passwort: ok, kein Fix', () {
      final r = parseSecurityReport('__SEC_PIHOLE__\npwhash-set\n');
      final f = r.firstWhere((x) => x.title == 'Pi-hole-Weboberfläche');
      expect(f.level, SecurityLevel.ok);
      expect(securityFixFor(f), isNull);
    });

    test('nicht ermittelbar (z. B. Pi-hole v5): Info, kein Fix', () {
      final r = parseSecurityReport('__SEC_PIHOLE__\npwhash-unknown\n');
      final f = r.firstWhere((x) => x.title == 'Pi-hole-Weboberfläche');
      expect(f.level, SecurityLevel.info);
      expect(securityFixFor(f), isNull);
    });

    test('kein Pi-hole: kein Befund', () {
      final r = parseSecurityReport('__SEC_PIHOLE__\n');
      expect(r.any((x) => x.title == 'Pi-hole-Weboberfläche'), isFalse);
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

    test('without-password (Debian 13 wording) counts as ok, like '
        'prohibit-password', () {
      // Seen on the real test Pi 2026-08-15: sshd -T on Debian 13/trixie
      // reports the legacy alias `without-password`. Same meaning (root only
      // with key) — must be green, not an "info" shrug.
      final r = parseSecurityReport(
          '__SEC_SSHD__\npermitrootlogin without-password\n');
      final root = r.firstWhere((f) => f.title.contains('Root'));
      expect(root.level, SecurityLevel.ok);
      // And correctly no fix offered — it is already safe.
      expect(securityFixFor(root), isNull);
    });

    test('missing/garbled sections degrade to info, never crash', () {
      final r = parseSecurityReport('nonsense without markers');
      expect(r, isNotEmpty);
      // Nothing can be asserted → no false "ok"/"warn"; unknowns are info.
      expect(r.every((f) => f.level == SecurityLevel.info), isTrue);
    });

    // Without an answer from `sshd -T` the probe greps the configuration
    // files: the keywords as written there — any case, indented, and the same
    // one from sshd_config and from a drop-in.
    test('grep fallback: keywords as the files spell them are read', () {
      final r = parseSecurityReport('__SEC_SSHD__\n'
          'PermitRootLogin yes\n'
          '\tPasswordAuthentication no\n');
      expect(by(r, 'root').level, SecurityLevel.warn);
      expect(securityFixFor(by(r, 'root')), SecurityFix.rootLogin);
      expect(by(r, 'passwort').level, SecurityLevel.ok);
    });

    test('grep fallback: a keyword found twice is still one finding', () {
      final r = parseSecurityReport('__SEC_SSHD__\n'
          'PermitRootLogin prohibit-password\n'
          'PasswordAuthentication yes\n'
          '  permitrootlogin prohibit-password\n');
      expect(r.where((f) => f.title == 'SSH-Root-Login'), hasLength(1));
      expect(by(r, 'root').level, SecurityLevel.ok);
      expect(by(r, 'passwort').level, SecurityLevel.info);
      expect(by(r, 'passwort').detail, startsWith('Passwort-Login ist an'));
    });

    test('grep fallback without a hit: undetermined, no fix on offer', () {
      // Debian ships both keywords commented out; grep then prints nothing.
      final r = parseSecurityReport('__SEC_SSHD__\n__SEC_UNATT__\n');
      for (final needle in ['root', 'passwort']) {
        expect(by(r, needle).level, SecurityLevel.info, reason: needle);
        expect(by(r, needle).detail, 'Konnte nicht ermittelt werden.');
        expect(securityFixFor(by(r, needle)), isNull);
      }
    });

    test('open ports: each port once, in numeric order', () {
      // The fourth column of `ss -H -tln`. By text, 443 would sort before 53.
      final r = parseSecurityReport('__SEC_PORTS__\n'
          '0.0.0.0:8080\n'
          '[::]:22\n'
          '0.0.0.0:22\n'
          '127.0.0.1:53\n'
          '*:443\n'
          '[::1]:53\n'
          '192.168.178.64%eth0:7070\n');
      expect(by(r, 'ports').detail,
          'Lauschende TCP-Ports: 22, 53, 443, 7070, 8080');
      expect(by(r, 'ports').level, SecurityLevel.info);
    });

    test('open ports: a line without a port number is left out', () {
      final some = parseSecurityReport('__SEC_PORTS__\n'
          'Local Address:Port\n'
          '*:*\n'
          '0.0.0.0:22\n');
      expect(by(some, 'ports').detail, 'Lauschende TCP-Ports: 22');
      final none = parseSecurityReport('__SEC_PORTS__\n*:*\n');
      expect(by(none, 'ports').detail, 'Keine ermittelt.');
    });
  });

  group('automatic updates: unit vs. APT::Periodic', () {
    SecurityFinding updatesOf(String out) => parseSecurityReport(out)
        .firstWhere((f) => f.title.contains('Sicherheitsupdates'));

    test('enabled unit + Periodic "0" is a warning, not green', () {
      // Audit 2026-08-15: the unit is the shutdown helper and is enabled by
      // the package — it proves nothing about updates actually being installed.
      const out = '__SEC_UNATT__\nenabled\nactive\n'
          'APT::Periodic::Unattended-Upgrade "0";\n';
      final f = updatesOf(out);
      expect(f.level, SecurityLevel.warn);
      expect(f.detail, contains('abgeschaltet'));
      expect(securityFixFor(f), SecurityFix.autoUpdates); // and it is fixable
    });

    test('enabled unit + Periodic "1" stays green', () {
      const out = '__SEC_UNATT__\nenabled\nactive\n'
          'APT::Periodic::Unattended-Upgrade "1";\n';
      expect(updatesOf(out).level, SecurityLevel.ok);
    });

    test('an unreadable Periodic value does not turn a healthy Pi red', () {
      // apt-config missing/silent: keep the previous verdict (default is "1"
      // right after installing the package).
      const out = '__SEC_UNATT__\nenabled\nactive\n';
      expect(updatesOf(out).level, SecurityLevel.ok);
    });
  });

  // 32-bit Raspberry Pi OS: unattended-upgrades is the unchanged Debian
  // package, its Origins-Pattern names origin=Debian only — it runs and
  // installs nothing from Raspbian. The probe says so in one line.
  group('automatic updates: origin Raspbian left out', () {
    SecurityFinding updatesOf(String out) => parseSecurityReport(out)
        .firstWhere((f) => f.title.contains('Sicherheitsupdates'));
    const running = '__SEC_UNATT__\nenabled\nactive\n'
        'APT::Periodic::Unattended-Upgrade "1";\n';

    test('running, but Raspbian is in no pattern: not green, own text, fixable',
        () {
      final f = updatesOf('${running}raspbian-origin-uncovered\n');
      expect(f.level, SecurityLevel.warn);
      expect(
          f.detail,
          'unattended-upgrades läuft, installiert aber keine Updates aus der '
          'Paketquelle Raspbian (32-Bit Raspberry Pi OS) — sie fehlt in '
          'Unattended-Upgrade::Origins-Pattern.');
      expect(securityFixFor(f), SecurityFix.autoUpdates);
      expect(securityFixLetsRaspbianIn(f), isTrue);
    });

    test('without that line the verdict is the one from before', () {
      final f = updatesOf(running);
      expect(f.level, SecurityLevel.ok);
      expect(f.detail, 'unattended-upgrades läuft.');
      expect(securityFixFor(f), isNull);
      expect(securityFixLetsRaspbianIn(f), isFalse);
    });

    test('switched off or not installed: that finding comes first', () {
      final off = updatesOf('__SEC_UNATT__\nenabled\nactive\n'
          'APT::Periodic::Unattended-Upgrade "0";\n'
          'raspbian-origin-uncovered\n');
      expect(off.level, SecurityLevel.warn);
      expect(off.detail, contains('abgeschaltet'));
      final missing = updatesOf(
          '__SEC_UNATT__\ndisabled\ninactive\nraspbian-origin-uncovered\n');
      expect(missing.level, SecurityLevel.warn);
      expect(missing.detail, startsWith('Keine automatischen'));
      // Either way the same fix, which also lets Raspbian in.
      expect(securityFixFor(off), SecurityFix.autoUpdates);
      expect(securityFixFor(missing), SecurityFix.autoUpdates);
    });

    // The fix then installs ALL updates of Raspbian (it has no security suite
    // of its own). The finding names the origin, and the confirmation of the
    // fix is chosen by it — in each of the three warnings, the one of a Pi
    // without unattended-upgrades (the state Raspberry Pi OS ships in) first.
    test('each warning on Raspbian names the origin; its fix lets Raspbian in',
        () {
      const note = ' Dieser Pi bezieht seine Pakete aus der Paketquelle '
          'Raspbian (32-Bit Raspberry Pi OS).';
      final missing = updatesOf(
          '__SEC_UNATT__\ndisabled\ninactive\nraspbian-origin-uncovered\n');
      expect(
          missing.detail,
          'Keine automatischen Sicherheitsupdates — unattended-upgrades '
          'aktivieren empfohlen.$note');
      final off = updatesOf('__SEC_UNATT__\nenabled\nactive\n'
          'APT::Periodic::Unattended-Upgrade "0";\n'
          'raspbian-origin-uncovered\n');
      expect(
          off.detail,
          'unattended-upgrades ist installiert, aber abgeschaltet '
          '(APT::Periodic::Unattended-Upgrade "0") — es wird nichts '
          'automatisch installiert.$note');
      final uncovered = updatesOf('${running}raspbian-origin-uncovered\n');
      for (final f in [missing, off, uncovered]) {
        expect(securityFixLetsRaspbianIn(f), isTrue, reason: f.detail);
      }
    });

    test('Debian origins: the warnings and their fix are what they were', () {
      final missing = updatesOf('__SEC_UNATT__\ndisabled\ninactive\n');
      expect(
          missing.detail,
          'Keine automatischen Sicherheitsupdates — unattended-upgrades '
          'aktivieren empfohlen.');
      final off = updatesOf('__SEC_UNATT__\nenabled\nactive\n'
          'APT::Periodic::Unattended-Upgrade "0";\n');
      expect(
          off.detail,
          'unattended-upgrades ist installiert, aber abgeschaltet '
          '(APT::Periodic::Unattended-Upgrade "0") — es wird nichts '
          'automatisch installiert.');
      for (final f in [missing, off]) {
        expect(securityFixFor(f), SecurityFix.autoUpdates);
        expect(securityFixLetsRaspbianIn(f), isFalse, reason: f.detail);
      }
    });

    test('only the automatic-updates fix can let Raspbian in', () {
      // Another finding that happened to name the origin changes nothing.
      expect(
          securityFixLetsRaspbianIn((
            title: 'fail2ban (Brute-Force-Schutz)',
            level: SecurityLevel.info,
            detail: 'fail2ban nicht aktiv — Paketquelle Raspbian (32-Bit '
                'Raspberry Pi OS).'
          )),
          isFalse);
    });

    // systemctl gave no answer at all: the line says which origin is in use,
    // not whether unattended-upgrades runs — unknown stays unknown.
    test('that line alone determines nothing', () {
      final f = updatesOf('__SEC_UNATT__\nraspbian-origin-uncovered\n');
      expect(f.level, SecurityLevel.info);
      expect(f.detail, 'Konnte nicht ermittelt werden.');
      expect(securityFixFor(f), isNull);
      expect(securityFixLetsRaspbianIn(f), isFalse);
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
        if (fix == SecurityFix.piholePassword) continue; // own builder, below
        final lines = buildSecurityFixScript(fix)
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .toList();
        // The last command prints it, and nothing before that does: a branch
        // that left early has said nothing that reads like success. (That a
        // failing branch really leaves is run in bash below.)
        expect(lines.last, 'echo SECFIX_OK', reason: '$fix');
        expect(lines.where((l) => l.contains('SECFIX_OK')), hasLength(1),
            reason: '$fix');
      }
    });

    test('the Pi-hole fix needs a password — its own builder', () {
      expect(() => buildSecurityFixScript(SecurityFix.piholePassword),
          throwsArgumentError);
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

    // The script arrives on stdin (`sudo -S bash -s`). A conffile question
    // from dpkg would read the rest of it as the answer and abort — so apt
    // never gets the script's stdin and never asks.
    test('no apt call can read the script from stdin', () {
      for (final (fix, calls) in [
        // update, fail2ban, and python3-systemd for the journal backend
        (SecurityFix.fail2ban, 3),
        (SecurityFix.autoUpdates, 2),
      ]) {
        final lines = buildSecurityFixScript(fix)
            .split('\n')
            .where((l) => l.contains('apt-get'))
            .toList();
        expect(lines, hasLength(calls), reason: '$fix');
        for (final line in lines) {
          expect(line, contains('</dev/null'), reason: '$fix: "$line"');
        }
      }
    });

    test('no unquoted heredoc', () {
      for (final fix in [SecurityFix.fail2ban, SecurityFix.autoUpdates]) {
        expect(RegExp(r'<<-?\s*[A-Za-z_]').hasMatch(buildSecurityFixScript(fix)),
            isFalse,
            reason: '$fix');
      }
    });

    // "Fixed" and "green" must mean the same: probe and fix ask apt in the
    // same words whether Raspbian is in use and whether a pattern lets it in.
    test('probe and fix share the Raspbian conditions', () {
      const inUse =
          r"apt-cache policy 2>/dev/null | grep -Eq '[ ,]o=Raspbian(,|$)'";
      const letIn = r"grep -E '^Unattended-Upgrade::(Origins-Pattern|"
          r"Allowed-Origins)::' | grep -q Raspbian";
      final fix = buildSecurityFixScript(SecurityFix.autoUpdates);
      // The probe is one single-quoted `sh -c` argument.
      final probe = buildSecurityProbe().replaceAll(r"'\''", "'");
      for (final s in [fix, probe]) {
        expect(s, contains(inUse));
        expect(s, contains(letIn));
      }
    });

    test('apt installs keep changed conffiles without asking', () {
      for (final fix in [SecurityFix.fail2ban, SecurityFix.autoUpdates]) {
        for (final line in buildSecurityFixScript(fix).split('\n')) {
          if (!line.contains('apt-get') || !line.contains(' install ')) {
            continue;
          }
          expect(line, contains('-o Dpkg::Options::=--force-confdef'),
              reason: '$fix: "$line"');
          expect(line, contains('-o Dpkg::Options::=--force-confold'),
              reason: '$fix: "$line"');
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
      // No set -e, on no line and in no spelling: the script must reach its
      // own rollback branches.
      expect(
          RegExp(r'\bset\s+(-\w*e\w*|-o\s+errexit)\b').hasMatch(s), isFalse);
    });
  });

  // The probe and the fix scripts on a sandboxed Pi (on_pi_sandbox.dart): the
  // probe as the app sends it, the fixes fed to `bash -s` on stdin exactly
  // like the sudo shell does. PATH holds stubs only. The apt-get stub drains
  // its stdin the way dpkg's conffile prompt would — a call without its own
  // </dev/null swallows the rest of the script, and the marker never comes.
  // systemctl, apt-cache and apt-config answer from a small model of the Pi:
  //  - fail2ban stays up when it has a log to read: /var/log/auth.log, or the
  //    journal (the jail's `backend = systemd` plus python3-systemd); without
  //    one it is down at once, or — /state/f2b-dies-after — still "active"
  //    for that many samples, like a server that was forked and then ends;
  //  - apt-config lists what the files in /etc/apt/apt.conf.d hold as
  //    Origins-Pattern entries, one `Key:: "value";` line each, like apt.
  // How fail2ban and apt themselves behave is taken from their sources and
  // documentation, not measured on a Pi.
  group('security probe and fixes in bash', () {
    late PiSandbox pi;
    const confDir = '/etc/apt/apt.conf.d';
    const originsFile = '$confDir/51pitool-unattended-origins';
    const jailFile = '/etc/fail2ban/jail.d/pitool-sshd.local';
    const noLogFile = 'fail2ban-server[812]: ERROR   Failed during '
        'configuration: Have not found any log file for sshd jail';

    setUp(() {
      pi = PiSandbox();
      pi.stub('apt-get', r'''
"$REAL_CAT" >/dev/null
case " $* " in *" install -y python3-systemd "*) : > "$S/python3-systemd" ;; esac
exit 0''');
      pi.stub('systemctl', r'''
f2b_has_a_log() {
  [ -e "$S/f2b-broken" ] && return 1
  [ -e "$R/var/log/auth.log" ] && return 0
  [ -e "$S/f2b-reads-journal" ] && return 0
  [ -e "$S/python3-systemd" ] &&
    "$REAL_GREP" -qx 'backend = systemd' "$R/etc/fail2ban/jail.d/pitool-sshd.local" 2>/dev/null
}
case "$*" in
  "enable --now fail2ban"|"restart fail2ban")
    "$REAL_RM" -f "$S/f2b-active" "$S/f2b-samples-left"
    if f2b_has_a_log; then
      : > "$S/f2b-active"
    elif [ -e "$S/f2b-dies-after" ]; then
      "$REAL_CAT" "$S/f2b-dies-after" > "$S/f2b-samples-left"
    fi ;;
  "is-active --quiet fail2ban")
    [ -e "$S/f2b-active" ] && exit 0
    left=$("$REAL_CAT" "$S/f2b-samples-left" 2>/dev/null)
    [ "${left:-0}" -gt 0 ] || exit 3
    echo $((left - 1)) > "$S/f2b-samples-left" ;;
  "is-active fail2ban")
    if [ -e "$S/f2b-active" ]; then echo active; else echo inactive; exit 3; fi ;;
  "enable --now unattended-upgrades") : > "$S/unattended-on" ;;
  "is-enabled unattended-upgrades")
    if [ -e "$S/unattended-on" ]; then echo enabled; else echo disabled; exit 1; fi ;;
  "is-active unattended-upgrades")
    if [ -e "$S/unattended-on" ]; then echo active; else echo inactive; exit 3; fi ;;
esac
exit 0''');
      pi.stub('journalctl', 'echo "$noLogFile"');
      pi.stub('apt-cache', r'[ "$*" = policy ] && "$REAL_CAT" "$S/policy"',
          log: false);
      pi.stub('apt-config', r'''
[ "$1" = dump ] || exit 1
if [ -e "$S/apt-config-broken" ]; then
  echo "E: Syntax error $R/etc/apt/apt.conf.d/x:2: Extra junk at end of file" >&2
  exit 100
fi
dump() {
  echo 'APT::Periodic::Unattended-Upgrade "1";'
  for f in "$R"/etc/apt/apt.conf.d/*; do
    [ -f "$f" ] || continue
    "$REAL_AWK" '
      /^Unattended-Upgrade::Origins-Pattern[ \t]*[{]/ { on = 1; next }
      /^[}];/ { on = 0 }
      on && /^[ \t]*"/ { sub(/^[ \t]*/, ""); print "Unattended-Upgrade::Origins-Pattern:: " $0 }
    ' "$f"
  done
}
if [ -n "$2" ]; then dump | "$REAL_GREP" -F -- "$2"; else dump; fi''',
          log: false);
      pi.stub('sudo', r'while [ "${1#-}" != "$1" ]; do shift; done; exec "$@"',
          log: false);
      // The probe runs under `sh -c`: dash where there is one, as on a Pi
      // (the /bin/sh of Git Bash is a bash).
      pi.stub('sh', 'exec ${sandboxDash ?? '/bin/sh'} "\$@"', log: false);
      pi.stub('sshd', 'echo "permitrootlogin no"; echo "passwordauthentication no"',
          log: false);
      pi.stub('ss', 'echo "LISTEN 0 128 0.0.0.0:22 0.0.0.0:*"', log: false);
      // A 64-bit Raspberry Pi OS with the package's own patterns, nothing
      // installed or switched on yet.
      pi.put('/state/policy', _policyDebian);
      pi.put('$confDir/50unattended-upgrades', _stockOrigins);
    });
    tearDown(() => pi.dispose());

    Future<SandboxRun> fix(SecurityFix f) => pi.run(buildSecurityFixScript(f));

    /// The probe's raw lines between [marker] and the next section.
    Future<List<String>> section(String marker) async {
      final r = await pi.run(buildSecurityProbe());
      expect(r.code, 0, reason: r.err);
      final lines = r.lines;
      final from = lines.indexOf(marker);
      expect(from, greaterThanOrEqualTo(0), reason: r.out);
      return lines
          .skip(from + 1)
          .takeWhile((l) => !l.startsWith('__SEC_'))
          .toList();
    }

    /// The finding whose title contains [needle], from a fresh probe run.
    Future<SecurityFinding> finding(String needle) async {
      final r = await pi.run(buildSecurityProbe());
      expect(r.code, 0, reason: r.err);
      return parseSecurityReport(r.out)
          .firstWhere((f) => f.title.contains(needle));
    }

    /// What the scripts did to the system: every stub call but the waits.
    List<String> changes() =>
        pi.calls.where((c) => !c.startsWith('sleep ')).toList();

    const aptInstall = 'apt-get -o Dpkg::Use-Pty=0 '
        '-o Dpkg::Options::=--force-confdef '
        '-o Dpkg::Options::=--force-confold install -y';

    group('the probe', () {
      /// Every entry below the Pi's own directories with size and mtime. The
      /// stubs' state directory — the call log grows there — is left out.
      Future<String> tree() async {
        final r = await pi.run(
            "ls -lRA --time-style=full-iso '${pi.root}/etc' '${pi.root}/var' "
            "'${pi.root}/usr' '${pi.root}/tmp' '${pi.root}/bin'",
            rebase: false);
        expect(r.code, 0, reason: r.err);
        return r.out;
      }

      // "Read-only" as behaviour: questions are all that reaches the stubs,
      // and the files are the ones the probe found.
      test('only asks, and leaves the Pi as it found it', () async {
        // Raspbian and a Pi-hole: the branches with the most commands.
        pi.put('/state/policy', _policyRaspbian);
        pi.put('/state/unattended-on');
        pi.stub('sshd', 'echo "permitrootlogin yes"');
        pi.stub('ss', 'echo "LISTEN 0 128 0.0.0.0:22 0.0.0.0:*"');
        pi.stub('pihole-FTL',
            r"echo '$BALLOON-SHA256$v=1$s=1024,t=32$c2FsdA==$aGFzaA=='");
        final before = await tree();

        final r = await pi.run(buildSecurityProbe());
        expect(r.code, 0, reason: r.err);
        expect(r.err, isEmpty);
        expect(pi.calls, [
          'sshd -T',
          'systemctl is-enabled unattended-upgrades',
          'systemctl is-active unattended-upgrades',
          'systemctl is-active fail2ban',
          'ss -H -tln',
          'pihole-FTL --config -q webserver.api.pwhash',
        ]);
        expect(await tree(), before);
        // The Pi-hole section is the verdict alone, never the hash.
        expect(r.lines.sublist(r.lines.indexOf('__SEC_PIHOLE__')),
            ['__SEC_PIHOLE__', 'pwhash-set']);
        expect(r.out, isNot(contains('BALLOON')));
      });

      test('no answer from sshd -T: the keywords are read from sshd_config '
          'and its drop-ins', () async {
        pi.stub('sshd', 'echo "sshd: no hostkeys available -- exiting." >&2\n'
            'exit 1');
        pi.put(
            '/etc/ssh/sshd_config',
            '# This is the sshd server system-wide configuration file.\n'
            'Include /etc/ssh/sshd_config.d/*.conf\n'
            '#PermitRootLogin prohibit-password\n'
            'PermitRootLogin yes\n'
            '#PasswordAuthentication yes\n'
            'UsePAM yes\n');
        pi.put('/etc/ssh/sshd_config.d/50-cloud-init.conf',
            '  PasswordAuthentication no\n');
        // As the files spell them; a commented-out line is no setting.
        expect(await section('__SEC_SSHD__'),
            ['PermitRootLogin yes', 'PasswordAuthentication no']);
        final root = await finding('Root');
        expect(root.level, SecurityLevel.warn);
        expect(securityFixFor(root), SecurityFix.rootLogin);
        expect((await finding('Passwort')).level, SecurityLevel.ok);
      });

      test('listening ports: the local address column of ss, each port once, '
          'sorted', () async {
        pi.stub('ss', r'''
echo "LISTEN 0      4096       127.0.0.1:8080       0.0.0.0:*"
echo "LISTEN 0      128          0.0.0.0:22         0.0.0.0:*"
echo "LISTEN 0      511                *:80               *:*"
echo "LISTEN 0      128             [::]:22            [::]:*"''',
            log: false);
        expect(await section('__SEC_PORTS__'),
            ['127.0.0.1:8080', '0.0.0.0:22', '*:80', '[::]:22']);
        expect((await finding('Ports')).detail,
            'Lauschende TCP-Ports: 22, 80, 8080');
      });
    });

    group('automatic updates', () {
      const periodic = 'APT::Periodic::Update-Package-Lists "1";\n'
          'APT::Periodic::Unattended-Upgrade "1";\n';

      test('Debian origins: the fix runs what it ran before, and no more',
          () async {
        final r = await fix(SecurityFix.autoUpdates);
        expect(r.code, 0, reason: r.err);
        expect(r.err, isEmpty);
        expect(r.lines, ['SECFIX_OK']);
        expect(changes(), [
          'apt-get update -qq',
          '$aptInstall unattended-upgrades',
          'systemctl enable --now unattended-upgrades',
        ]);
        expect(pi.ls(confDir), ['20auto-upgrades', '50unattended-upgrades']);
        expect(pi.read('$confDir/20auto-upgrades'), periodic);
        expect(pi.read('$confDir/50unattended-upgrades'), _stockOrigins);
      });

      test('Debian origins: the probe prints the section it printed before',
          () async {
        expect(await section('__SEC_UNATT__'), [
          'disabled',
          'inactive',
          'APT::Periodic::Unattended-Upgrade "1";',
        ]);
        expect(securityFixLetsRaspbianIn(await finding('Sicherheitsupdates')),
            isFalse);
        await fix(SecurityFix.autoUpdates);
        expect(await section('__SEC_UNATT__'), [
          'enabled',
          'active',
          'APT::Periodic::Unattended-Upgrade "1";',
        ]);
        final f = await finding('Sicherheitsupdates');
        expect(f.level, SecurityLevel.ok);
        expect(f.detail, 'unattended-upgrades läuft.');
      });

      test('Raspbian with the package\'s patterns: not green although it runs',
          () async {
        pi.put('/state/policy', _policyRaspbian);
        pi.put('/state/unattended-on');
        expect(await section('__SEC_UNATT__'), [
          'enabled',
          'active',
          'APT::Periodic::Unattended-Upgrade "1";',
          'raspbian-origin-uncovered',
        ]);
        final f = await finding('Sicherheitsupdates');
        expect(f.level, SecurityLevel.warn);
        expect(f.detail, contains('Raspbian'));
        expect(securityFixFor(f), SecurityFix.autoUpdates);
        expect(securityFixLetsRaspbianIn(f), isTrue);
      });

      test('Raspbian without unattended-upgrades, as shipped: the warning '
          'names the origin, and its fix is the one that lets Raspbian in',
          () async {
        pi.put('/state/policy', _policyRaspbian);
        expect(await section('__SEC_UNATT__'), [
          'disabled',
          'inactive',
          'APT::Periodic::Unattended-Upgrade "1";',
          'raspbian-origin-uncovered',
        ]);
        final f = await finding('Sicherheitsupdates');
        expect(f.level, SecurityLevel.warn);
        expect(f.detail, startsWith('Keine automatischen'));
        expect(securityFixFor(f), SecurityFix.autoUpdates);
        expect(securityFixLetsRaspbianIn(f), isTrue);
        // What the confirmation then says is what the fix does here.
        final r = await fix(SecurityFix.autoUpdates);
        expect(r.code, 0, reason: r.err);
        expect(r.lines.last, 'SECFIX_OK');
        expect(pi.read(originsFile), contains('origin=Raspbian,'));
        expect((await finding('Sicherheitsupdates')).level, SecurityLevel.ok);
      });

      test('Raspbian: the fix lets that origin in, and only that one', () async {
        pi.put('/state/policy', _policyRaspbian);
        pi.put('/state/unattended-on');
        final r = await fix(SecurityFix.autoUpdates);
        expect(r.code, 0, reason: r.err);
        expect(r.lines.last, 'SECFIX_OK');
        // ${distro_codename} as written: unattended-upgrades expands it.
        expect(
            pi.read(originsFile),
            'Unattended-Upgrade::Origins-Pattern {\n'
            r'        "origin=Raspbian,codename=${distro_codename},label=Raspbian";'
            '\n'
            '};\n');
        expect(pi.read('$confDir/20auto-upgrades'), periodic);
        expect(pi.read('$confDir/50unattended-upgrades'), _stockOrigins);
        // Now the check is green.
        expect(await section('__SEC_UNATT__'),
            isNot(contains('raspbian-origin-uncovered')));
        expect((await finding('Sicherheitsupdates')).level, SecurityLevel.ok);
      });

      test('Raspbian with a pattern of the user\'s own: green as it is',
          () async {
        pi.put('/state/policy', _policyRaspbian);
        pi.put('/state/unattended-on');
        pi.put(
            '$confDir/52local',
            'Unattended-Upgrade::Origins-Pattern {\n'
            '        "o=Raspbian,n=bookworm";\n'
            '};\n');
        expect((await finding('Sicherheitsupdates')).level, SecurityLevel.ok);
      });

      test('Raspbian, apt-config unreadable: the verdict from before', () async {
        pi.put('/state/policy', _policyRaspbian);
        pi.put('/state/unattended-on');
        pi.put('/state/apt-config-broken');
        expect(await section('__SEC_UNATT__'), ['enabled', 'active']);
        expect((await finding('Sicherheitsupdates')).level, SecurityLevel.ok);
      });

      test('Raspbian: a fragment apt does not take is removed, no marker',
          () async {
        pi.put('/state/policy', _policyRaspbian);
        pi.put('/state/apt-config-broken');
        final r = await fix(SecurityFix.autoUpdates);
        expect(r.code, 1);
        expect(r.out, isNot(contains('SECFIX_OK')));
        expect(r.out, contains('zurückgenommen'));
        expect(pi.exists(originsFile), isFalse);
      });
    });

    group('fail2ban', () {
      test('with /var/log/auth.log: installed, started, watched — no drop-in',
          () async {
        pi.put('/var/log/auth.log', '');
        final r = await fix(SecurityFix.fail2ban);
        expect(r.code, 0, reason: r.err);
        expect(r.err, isEmpty);
        expect(r.lines, ['SECFIX_OK']);
        expect(changes(), [
          'apt-get update -qq',
          '$aptInstall fail2ban',
          'systemctl enable --now fail2ban',
          for (var i = 0; i < 5; i++) 'systemctl is-active --quiet fail2ban',
        ]);
        // Two seconds before each sample: ten seconds of watching.
        expect(pi.calls.where((c) => c.startsWith('sleep ')),
            List.filled(5, 'sleep 2'));
        expect(pi.exists(jailFile), isFalse);
        expect((await finding('fail2ban')).level, SecurityLevel.ok);
      });

      test('without auth.log, but it reads the journal by itself: no drop-in',
          () async {
        pi.put('/state/f2b-reads-journal');
        final r = await fix(SecurityFix.fail2ban);
        expect(r.code, 0, reason: r.err);
        expect(r.lines, ['SECFIX_OK']);
        expect(pi.exists(jailFile), isFalse);
        expect(changes().where((c) => c.contains('python3-systemd')), isEmpty);
      });

      test('without auth.log and not starting: sshd jail on the journal',
          () async {
        final r = await fix(SecurityFix.fail2ban);
        expect(r.code, 0, reason: r.err);
        expect(r.lines.last, 'SECFIX_OK');
        expect(pi.read(jailFile),
            '[sshd]\nenabled = true\nbackend = systemd\n');
        final c = changes();
        expect(
            c.sublist(c.indexOf('systemctl enable --now fail2ban') + 1), [
          'systemctl is-active --quiet fail2ban',
          '$aptInstall python3-systemd',
          'systemctl restart fail2ban',
          for (var i = 0; i < 5; i++) 'systemctl is-active --quiet fail2ban',
        ]);
        expect((await finding('fail2ban')).level, SecurityLevel.ok);
      });

      // What the finding is about: `enable --now` returns with the server
      // forked, and a server without a log to read ends a moment later. One
      // look right after the start would take it for running.
      test('started, gone within the watch, no auth.log: sshd jail on the '
          'journal', () async {
        pi.put('/state/f2b-dies-after', '2');
        final r = await fix(SecurityFix.fail2ban);
        expect(r.code, 0, reason: r.err);
        expect(r.lines.last, 'SECFIX_OK');
        expect(pi.read(jailFile),
            '[sshd]\nenabled = true\nbackend = systemd\n');
        final c = changes();
        expect(
            c.sublist(c.indexOf('systemctl enable --now fail2ban') + 1), [
          // Up at two samples, gone at the third.
          for (var i = 0; i < 3; i++) 'systemctl is-active --quiet fail2ban',
          '$aptInstall python3-systemd',
          'systemctl restart fail2ban',
          for (var i = 0; i < 5; i++) 'systemctl is-active --quiet fail2ban',
        ]);
      });

      test('started, gone at the last sample, auth.log there: exit 1, no marker',
          () async {
        pi.put('/var/log/auth.log', '');
        pi.put('/state/f2b-broken');
        pi.put('/state/f2b-dies-after', '4');
        final r = await fix(SecurityFix.fail2ban);
        expect(r.code, 1);
        expect(r.out, isNot(contains('SECFIX_OK')));
        expect(r.out, contains(noLogFile));
        expect(pi.exists(jailFile), isFalse);
        expect(changes().where((c) => c.contains('python3-systemd')), isEmpty);
      });

      test('not starting although auth.log is there: journal, exit 1, no marker',
          () async {
        pi.put('/var/log/auth.log', '');
        pi.put('/state/f2b-broken');
        final r = await fix(SecurityFix.fail2ban);
        expect(r.code, 1);
        expect(r.out, isNot(contains('SECFIX_OK')));
        expect(r.out, contains(noLogFile));
        expect(pi.exists(jailFile), isFalse);
        expect(changes().where((c) => c.contains('python3-systemd')), isEmpty);
        expect(changes().last, 'journalctl -u fail2ban -n 20 --no-pager');
      });

      test('still not starting with the drop-in: it goes again, no marker',
          () async {
        pi.put('/state/f2b-broken');
        final r = await fix(SecurityFix.fail2ban);
        expect(r.code, 1);
        expect(r.out, isNot(contains('SECFIX_OK')));
        expect(r.out, contains(noLogFile));
        expect(pi.exists(jailFile), isFalse);
        final f = await finding('fail2ban');
        expect(securityFixFor(f), SecurityFix.fail2ban);
      });

      test('a drop-in from an earlier run is not taken away on failure',
          () async {
        pi.put(jailFile, '[sshd]\nenabled = true\nbackend = systemd\n');
        pi.put('/state/f2b-broken');
        final r = await fix(SecurityFix.fail2ban);
        expect(r.code, 1);
        expect(pi.read(jailFile),
            '[sshd]\nenabled = true\nbackend = systemd\n');
      });
    });

    // sshd and systemd as the root-login fix asks them:
    //  - `sshd -t` takes the configuration unless /state/sshd-rejects exists;
    //  - `sshd -T` reports `permitrootlogin no` when the drop-in says so —
    //    unless /state/sshd-ignores-dropins exists (an sshd_config without
    //    the Include line) — and nothing at all with /state/sshd-T-silent;
    //  - the unit is called `ssh`, or with /state/unit-is-sshd `sshd`.
    // How sshd itself reads its drop-ins is not measured on a Pi here.
    group('root login', () {
      const dropIn = '/etc/ssh/sshd_config.d/60-pitool-hardening.conf';

      setUp(() {
        pi.stub('sshd', r'''
f="$R/etc/ssh/sshd_config.d/60-pitool-hardening.conf"
case "$1" in
  -t)
    if [ -e "$S/sshd-rejects" ]; then
      echo "$f: line 1: Bad configuration option" >&2
      exit 255
    fi ;;
  -T)
    [ -e "$S/sshd-T-silent" ] && exit 255
    echo "port 22"
    if [ ! -e "$S/sshd-ignores-dropins" ] &&
      "$REAL_GREP" -qx 'PermitRootLogin no' "$f" 2>/dev/null; then
      echo "permitrootlogin no"
    else
      echo "permitrootlogin yes"
    fi
    echo "passwordauthentication yes" ;;
esac
exit 0''');
        pi.stub('systemctl', r'''
case "$*" in
  "reload ssh") [ ! -e "$S/unit-is-sshd" ] || exit 5 ;;
  "reload sshd") [ -e "$S/unit-is-sshd" ] || exit 5 ;;
esac
exit 0''');
      });

      test('sshd takes it: drop-in written, checked before the reload, the '
          'effect read back', () async {
        final open = await finding('Root');
        expect(open.level, SecurityLevel.warn);
        expect(securityFixFor(open), SecurityFix.rootLogin);
        pi.clearCalls();

        final r = await fix(SecurityFix.rootLogin);
        expect(r.code, 0, reason: r.err);
        expect(r.err, isEmpty);
        expect(r.lines, ['SECFIX_OK']);
        expect(pi.read(dropIn), 'PermitRootLogin no\n');
        expect(changes(), ['sshd -t', 'systemctl reload ssh', 'sshd -T']);

        final fixed = await finding('Root');
        expect(fixed.level, SecurityLevel.ok);
        expect(securityFixFor(fixed), isNull);
      });

      test('a unit called sshd: the second reload is tried, then the same',
          () async {
        pi.put('/state/unit-is-sshd');
        final r = await fix(SecurityFix.rootLogin);
        expect(r.code, 0, reason: r.err);
        expect(r.lines, ['SECFIX_OK']);
        expect(changes(), [
          'sshd -t',
          'systemctl reload ssh',
          'systemctl reload sshd',
          'sshd -T',
        ]);
      });

      test('sshd -t refuses the configuration: drop-in gone, nothing '
          'reloaded, exit 1, no marker', () async {
        pi.put('/state/sshd-rejects');
        final r = await fix(SecurityFix.rootLogin);
        expect(r.code, 1);
        expect(r.lines, [
          'sshd -t lehnt die Konfiguration ab - Aenderung zurueckgenommen.',
        ]);
        expect(pi.exists(dropIn), isFalse);
        // The script ends there: sshd was never told to load anything.
        expect(changes(), ['sshd -t']);
      });

      test('the effective value stays yes: drop-in gone, reloaded once more, '
          'exit 1, no marker', () async {
        pi.put('/state/sshd-ignores-dropins');
        final r = await fix(SecurityFix.rootLogin);
        expect(r.code, 1);
        expect(r.lines, [
          "PermitRootLogin blieb 'yes' (sshd_config.d greift nicht?) - "
              'Aenderung zurueckgenommen.',
        ]);
        expect(pi.exists(dropIn), isFalse);
        expect(changes(), [
          'sshd -t',
          'systemctl reload ssh',
          'sshd -T',
          'systemctl reload ssh',
        ]);
        // Still the finding it was, with its fix on offer.
        final f = await finding('Root');
        expect(f.level, SecurityLevel.warn);
        expect(securityFixFor(f), SecurityFix.rootLogin);
      });

      test('no effective value to read back: taken back just the same',
          () async {
        pi.put('/state/sshd-T-silent');
        final r = await fix(SecurityFix.rootLogin);
        expect(r.code, 1);
        expect(r.lines, [
          "PermitRootLogin blieb '' (sshd_config.d greift nicht?) - "
              'Aenderung zurueckgenommen.',
        ]);
        expect(pi.exists(dropIn), isFalse);
      });

      test('a drop-in directory that is not there yet is made', () async {
        expect(pi.exists('/etc/ssh'), isFalse);
        final r = await fix(SecurityFix.rootLogin);
        expect(r.lines, ['SECFIX_OK']);
        expect(pi.ls('/etc/ssh/sshd_config.d'), ['60-pitool-hardening.conf']);
      });
    });
  }, skip: needsBash);
}
