import 'package:flutter_test/flutter_test.dart';
import 'package:evcc_updater/src/parsing.dart';

void main() {
  group('parseInstalledVersion', () {
    test('returns the version when the status is "installed"', () {
      expect(parseInstalledVersion('installed 0.310.0\n'), '0.310.0');
      expect(parseInstalledVersion('  installed 0.311.0  '), '0.311.0');
    });

    test('null for removed-but-not-purged (config-files / rc) state', () {
      // dpkg keeps the Version for an rc-state package; it must NOT count as
      // installed, or the app would offer a no-op update for a removed evcc.
      expect(parseInstalledVersion('config-files 0.310.0'), isNull);
      expect(parseInstalledVersion('not-installed '), isNull);
    });

    test('null when the package is not installed (empty output)', () {
      expect(parseInstalledVersion(''), isNull);
      expect(parseInstalledVersion('   \n'), isNull);
    });
  });

  group('isAlreadyNewest', () {
    test('detects the "already the newest version" message', () {
      const out = 'evcc is already the newest version (0.310.0).\n'
          '0 upgraded, 0 newly installed, 0 to remove and 28 not upgraded.';
      expect(isAlreadyNewest(out), isTrue);
    });

    test('detects a "0 upgraded" summary line', () {
      expect(
        isAlreadyNewest(
            '0 upgraded, 0 newly installed, 0 to remove and 5 not upgraded.'),
        isTrue,
      );
    });

    test('false when an upgrade is actually pending', () {
      const out = 'The following packages will be upgraded:\n  evcc\n'
          '1 upgraded, 0 newly installed, 0 to remove and 27 not upgraded.';
      expect(isAlreadyNewest(out), isFalse);
    });

    test('does not misfire on a double-digit upgrade count', () {
      // "10 upgraded, ..." must NOT match the "0 upgraded, ..." marker.
      expect(
        isAlreadyNewest(
            '10 upgraded, 0 newly installed, 0 to remove and 5 not upgraded.'),
        isFalse,
      );
    });

    test('a kept-back evcc upgrade is NOT reported as already newest', () {
      const out = 'The following packages have been kept back:\n  evcc\n'
          '0 upgraded, 0 newly installed, 0 to remove and 1 not upgraded.';
      expect(isAlreadyNewest(out), isFalse);
    });
  });

  group('isServiceActive', () {
    test('"active" means active', () => expect(isServiceActive('active\n'), isTrue));
    test('"inactive" is not active',
        () => expect(isServiceActive('inactive\n'), isFalse));
    test('"failed" is not active', () => expect(isServiceActive('failed'), isFalse));
  });

  group('isSudoPasswordFailure', () {
    test('detects "incorrect password attempt"', () {
      expect(isSudoPasswordFailure('sudo: 1 incorrect password attempt'), isTrue);
    });

    test('detects "Sorry, try again."', () {
      expect(isSudoPasswordFailure('Sorry, try again.'), isTrue);
    });

    test('false for normal apt output', () {
      expect(isSudoPasswordFailure('Reading package lists...'), isFalse);
    });
  });

  group('parseBackupPath', () {
    test('extracts the path after the OK marker', () {
      const out = 'Erstelle Backup …\n'
          'EVCC_BACKUP_OK /var/backups/evcc/evcc-backup-20260629-120000.tar.gz\n';
      expect(parseBackupPath(out),
          '/var/backups/evcc/evcc-backup-20260629-120000.tar.gz');
    });
    test('null when nothing was backed up or no marker present', () {
      expect(parseBackupPath('EVCC_BACKUP_EMPTY'), isNull);
      expect(parseBackupPath('some unrelated output'), isNull);
      expect(parseBackupPath(''), isNull);
    });
  });

  group('redactPassword', () {
    test('replaces every occurrence with a fixed-length mask', () {
      expect(
        redactPassword('echo s3cret | sudo -S; s3cret', 's3cret'),
        'echo $passwordMask | sudo -S; $passwordMask',
      );
    });

    test('an empty password leaves the text untouched', () {
      expect(redactPassword('nothing to redact', ''), 'nothing to redact');
    });

    test('matches the password literally, not as a regex', () {
      expect(redactPassword('a.b matched', 'a.b'), '$passwordMask matched');
    });

    test('masks word-split fragments (NOPASSWD echo leak)', () {
      // On a NOPASSWD Pi `bash -s` echoes the unconsumed password word-split
      // ("bash: line 1: <first word>: ..."); the full literal "hunter2 pass"
      // never appears, so masking whole words is what catches the leak.
      final out = redactPassword(
          'bash: line 1: hunter2: command not found', 'hunter2 pass');
      expect(out, isNot(contains('hunter2')));
    });

    test('does not over-redact short (<3) password fragments', () {
      // Full password absent; the only present token "ab" is <3 → left alone.
      expect(redactPassword('ab only here', 'ab cd'), 'ab only here');
    });
  });

  group('summarize (evcc-only)', () {
    test('real run with a version change reports the upgrade', () {
      final r = summarize(
          before: '0.310.0',
          after: '0.311.0',
          dryRun: false,
          fullUpgrade: false,
          alreadyNewest: false);
      expect(r.status, UpdateStatus.updated);
      expect(r.message, 'evcc 0.310.0 → 0.311.0 aktualisiert.');
    });

    test('real run without a version change reports already current', () {
      final r = summarize(
          before: '0.310.0',
          after: '0.310.0',
          dryRun: false,
          fullUpgrade: false,
          alreadyNewest: true);
      expect(r.status, UpdateStatus.alreadyCurrent);
      expect(r.message, contains('war schon aktuell'));
    });

    test('dry-run with an update available names evcc', () {
      final r = summarize(
          before: '0.310.0',
          after: '0.310.0',
          dryRun: true,
          fullUpgrade: false,
          alreadyNewest: false);
      expect(r.status, UpdateStatus.dryRunWouldUpdate);
      expect(r.message, contains('Probelauf'));
      expect(r.message, contains('evcc'));
    });

    test('dry-run while already newest reports no change', () {
      final r = summarize(
          before: '0.310.0',
          after: '0.310.0',
          dryRun: true,
          fullUpgrade: false,
          alreadyNewest: true);
      expect(r.status, UpdateStatus.dryRunNoChange);
    });
  });

  group('summarize (full system upgrade)', () {
    test('dry-run with system updates talks about the system, not just evcc',
        () {
      final r = summarize(
          before: '0.310.0',
          after: '0.310.0',
          dryRun: true,
          fullUpgrade: true,
          alreadyNewest: false);
      expect(r.status, UpdateStatus.dryRunWouldUpdate);
      expect(r.message, contains('System'));
    });

    test('dry-run full-upgrade does not falsely claim evcc itself is current',
        () {
      final r = summarize(
          before: '0.310.0',
          after: '0.310.0',
          dryRun: true,
          fullUpgrade: true,
          alreadyNewest: false);
      // The whole-system summary carries no per-package info about evcc, so it
      // must not assert "evcc aktuell".
      expect(r.message, contains('installiert'));
      expect(r.message, isNot(contains('aktuell')));
    });

    test('dry-run with everything current reports the system fully up to date',
        () {
      final r = summarize(
          before: '0.310.0',
          after: '0.310.0',
          dryRun: true,
          fullUpgrade: true,
          alreadyNewest: true);
      expect(r.status, UpdateStatus.dryRunNoChange);
      expect(r.message, contains('System'));
    });

    test('real run: evcc unchanged but other system packages upgraded', () {
      final r = summarize(
          before: '0.310.0',
          after: '0.310.0',
          dryRun: false,
          fullUpgrade: true,
          alreadyNewest: false);
      expect(r.status, UpdateStatus.alreadyCurrent);
      expect(r.message, contains('System-Pakete'));
    });

    test('real run: evcc itself upgraded during a full upgrade', () {
      final r = summarize(
          before: '0.310.0',
          after: '0.311.0',
          dryRun: false,
          fullUpgrade: true,
          alreadyNewest: false);
      expect(r.status, UpdateStatus.updated);
      expect(r.message, 'evcc 0.310.0 → 0.311.0 aktualisiert.');
    });
  });

  group('stripProgressNoise', () {
    test('drops dpkg\'s read-database progress painting', () {
      // What a user reported from the log: apt hands dpkg a pty, dpkg repaints
      // the same line every 5 % — over SSH that arrives as pure noise.
      const raw = '(Reading database ... \r'
          '(Reading database ... 5%\r'
          '(Reading database ... 10%\r'
          '(Reading database ... 15%\r'
          '(Reading database ... 20%';
      expect(stripProgressNoise(raw).trim(), '');
    });

    test('keeps the informative summary line', () {
      const raw = '(Reading database ... 45%\r'
          '(Reading database ... 214428 files and directories '
          'currently installed.)';
      expect(
        stripProgressNoise(raw).trim(),
        '(Reading database ... 214428 files and directories '
        'currently installed.)',
      );
    });

    test('carriage returns become line breaks instead of one endless line', () {
      expect(stripProgressNoise('Setting up evcc ...\rDone.'),
          'Setting up evcc ...\nDone.');
      expect(stripProgressNoise('a\r\nb'), 'a\nb'); // CRLF stays one break
    });

    test('drops the other pty-only progress painters', () {
      expect(
          stripProgressNoise('Extracting templates from packages: 60%').trim(),
          '');
      expect(stripProgressNoise('Progress: [ 45%]').trim(), '');
    });

    test('real dpkg output around the noise survives intact', () {
      const raw = 'Selecting previously unselected package evcc.\r\n'
          '(Reading database ... 5%\r'
          '(Reading database ... 100%\r'
          'Preparing to unpack .../evcc_0.311.0_arm64.deb ...\n'
          'Unpacking evcc (0.311.0) ...\n'
          'Setting up evcc (0.311.0) ...';
      expect(stripProgressNoise(raw), '''
Selecting previously unselected package evcc.
Preparing to unpack .../evcc_0.311.0_arm64.deb ...
Unpacking evcc (0.311.0) ...
Setting up evcc (0.311.0) ...''');
    });

    test('leaves ordinary text (and our own log lines) untouched', () {
      expect(stripProgressNoise('Verbunden. Starte Update …'),
          'Verbunden. Starte Update …');
      expect(stripProgressNoise(''), '');
      // A line that only mentions the database is not progress painting.
      expect(stripProgressNoise('Reading database is fun'),
          'Reading database is fun');
    });
  });
}
