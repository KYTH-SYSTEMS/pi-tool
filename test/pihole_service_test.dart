import 'dart:math';

import 'package:evcc_updater/src/services/pihole_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parsePiholeVersion', () {
    test('reads the v5 "Pi-hole version is" line', () {
      const out = 'Pi-hole version is v5.18.2 (Latest: v5.18.2)\n'
          'AdminLTE version is v5.21 (Latest: v5.21)\n'
          'FTL version is v5.25.2 (Latest: v5.25.2)';
      final v = parsePiholeVersion(out);
      expect(v, isNotNull);
      expect(v!.version, 'v5.18.2');
      expect(v.updateAvailable, isFalse);
    });

    test('reads the v6 "Core version is" line', () {
      const out = 'Core version is v6.0.4 (Latest: v6.0.4)\n'
          'Web version is v6.0.1 (Latest: v6.0.1)\n'
          'FTL version is v6.0.4 (Latest: v6.0.4)';
      expect(parsePiholeVersion(out)!.version, 'v6.0.4');
    });

    test('flags an available update when current != latest', () {
      const out = 'Core version is v6.0.4 (Latest: v6.1.0)';
      final v = parsePiholeVersion(out);
      expect(v!.updateAvailable, isTrue);
    });

    test('flags an update when only FTL/Web is behind (not just Core)', () {
      const out = 'Core version is v6.0.4 (Latest: v6.0.4)\n'
          'Web version is v6.0.1 (Latest: v6.0.1)\n'
          'FTL version is v6.0.4 (Latest: v6.0.6)';
      final v = parsePiholeVersion(out);
      expect(v!.version, 'v6.0.4'); // Core still drives the shown version
      expect(v.updateAvailable, isTrue); // …but FTL is behind
    });

    test('keeps a pre-release tag and still flags the update', () {
      final v = parsePiholeVersion('Core version is v6.0.4-beta (Latest: v6.0.5)');
      expect(v!.version, 'v6.0.4-beta');
      expect(v.updateAvailable, isTrue);
    });

    test('no "(Latest: …)" field → latestKnown false, so currency is unknown',
        () {
      final v = parsePiholeVersion('Core version is v6.0.4');
      expect(v!.version, 'v6.0.4');
      expect(v.latestKnown, isFalse);
      expect(v.updateAvailable, isFalse);
    });

    test('with "(Latest: …)" → latestKnown true', () {
      final v = parsePiholeVersion('Core version is v6.0.4 (Latest: v6.0.4)');
      expect(v!.latestKnown, isTrue);
    });

    test('null when Pi-hole is not installed (no version line)', () {
      expect(parsePiholeVersion(''), isNull);
      expect(parsePiholeVersion('bash: pihole: command not found'), isNull);
    });
  });

  group('Web-Passwort', () {
    // Pi-hole v6 verlangt ohne Passwort KEINE Anmeldung (Doku, api/auth). Der
    // offizielle Installer setzt eins nur bei einer Frischinstallation — die
    // vorbelegte setupVars.conf der App macht daraus aber immer eine
    // „Aktualisierung" (basic-install.sh: check_fresh_install). Ergebnis bis
    // v0.69.0: eine offene Weboberfläche für das ganze Heimnetz.
    test('generateWebPassword: 16 Zeichen, eindeutig lesbares Alphabet', () {
      final pw = generateWebPassword(Random(1));
      expect(pw, hasLength(16));
      expect(pw, matches(RegExp(r'^[a-km-zA-HJ-NP-Z2-9]+$')));
      expect(generateWebPassword(Random(2)), isNot(pw));
    });

    test('Installation setzt das Passwort nur, wenn keins gesetzt ist', () {
      final s = buildPiholeInstallScript(webPassword: 'Abc234xyz');
      expect(s, contains("pihole setpassword 'Abc234xyz'"));
      expect(s, contains('pihole-FTL --config -q webserver.api.pwhash'));
      // Nur wenn die Abfrage gelingt: eine unlesbare Konfiguration darf nie
      // ein vorhandenes Passwort überschreiben.
      expect(s, contains('if h=\$(pihole-FTL --config -q webserver.api.pwhash'));
      expect(s, contains(piholePasswordSetMarker));
      expect(s.indexOf('bash "\$setup" --unattended'),
          lessThan(s.indexOf('pihole setpassword')));
    });

    test('scheitert das Setzen, bricht die Installation nicht ab', () {
      final s = buildPiholeInstallScript(webPassword: 'Abc234xyz');
      expect(s, contains("if pihole setpassword 'Abc234xyz' >/dev/null 2>&1; then"));
    });

    test('Passwort gelangt nie ungequotet ins Skript', () {
      expect(() => buildPiholeInstallScript(webPassword: "x'; reboot; '"),
          throwsArgumentError);
      expect(() => buildPiholeSetPasswordScript(''), throwsArgumentError);
    });

    test('Nachträglich setzen: nur bei leerem Passwort, Marker zuletzt', () {
      final s = buildPiholeSetPasswordScript('Abc234xyz');
      expect(s, contains('set -e'));
      expect(s, contains("pihole setpassword 'Abc234xyz'"));
      expect(s, contains(piholePasswordSetMarker));
      expect(s.trimRight().split('\n').last, 'echo $piholePasswordDoneMarker');
      // Unlesbar (v5, kaputt): Fehler statt Raten.
      expect(s, contains('exit 1'));
    });
  });

  group('buildPiholeInstallScript', () {
    final s = buildPiholeInstallScript(webPassword: 'Abc234xyz');
    test('keine Vorbelegung, wenn schon eine v6-Konfiguration existiert', () {
      // Sonst migriert FTL aus der frischen setupVars.conf und überschreibt die
      // vorhandene pihole.toml mit Standardwerten (FTL migrate_config_v6).
      expect(
          s,
          contains('if [ ! -f /etc/pihole/setupVars.conf ] && '
              '[ ! -f /etc/pihole/pihole.toml ]; then'));
    });
    test('unattended install: fetched installer (-f) + pre-seeded setupVars', () {
      expect(s, contains('--unattended'));
      expect(s, contains('curl -fsSL https://install.pi-hole.net'));
      expect(s, contains('setupVars.conf'));
      expect(s, contains('mktemp'));
    });

    test('hands /etc/pihole back to the pihole user AFTER the installer', () {
      // We create /etc/pihole as root to pre-seed setupVars.conf, and the
      // official installer adopts an existing directory without fixing its
      // ownership. FTL then runs as `pihole` and cannot write its own config —
      // a customer had to chown it by hand (Rückmeldung 12.08.2026).
      expect(s, contains('chown'), reason: 'ownership is never handed over');
      expect(s, contains('id -u pihole'),
          reason: 'chown must be guarded — the user only exists after a '
              'successful install');
      // Order matters: fixing ownership before the installer runs is pointless.
      expect(s.indexOf('chown'), greaterThan(s.indexOf('--unattended')));
    });
  });

  group('isPiholeBlocking', () {
    test('true when blocking is enabled', () {
      expect(isPiholeBlocking('[✓] Pi-hole blocking is enabled'), isTrue);
      expect(isPiholeBlocking('Pi-hole blocking is enabled'), isTrue);
    });
    test('false when disabled / unknown', () {
      expect(isPiholeBlocking('[✗] Pi-hole blocking is disabled'), isFalse);
      expect(isPiholeBlocking(''), isFalse);
    });
  });

  // Pi-hole v6 removed the `restartdns` subcommand; its dispatcher sends every
  // unknown subcommand to helpFunc, which exits **0**. A plain
  // `pihole restartdns` therefore prints the help text and reports SUCCESS
  // while flushing nothing — the app showed a green "DNS neu gestartet" and
  // the stale cache survived. v5 in turn has no `reloaddns`, so neither name
  // works everywhere and the exit code cannot be used to pick between them.
  group('piholeRestartCommand across v5 and v6', () {
    test('uses the v6 name (reloaddns), which actually flushes the cache', () {
      expect(piholeRestartCommand, contains('pihole reloaddns'));
    });

    test('keeps the v5 name (restartdns) as the fallback', () {
      expect(piholeRestartCommand, contains('pihole restartdns'));
    });

    test('picks by probing what the CLI offers, never by exit code', () {
      // v6's help lists "reloaddns" verbatim, v5's does not.
      expect(piholeRestartCommand, contains('--help'));
      expect(piholeRestartCommand, contains('grep'));
    });

    test('still runs through sudo with a stable locale', () {
      expect(piholeRestartCommand, startsWith('LC_ALL=C sudo -S '));
    });
  });
}
