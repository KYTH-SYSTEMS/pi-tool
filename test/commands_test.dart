import 'package:flutter_test/flutter_test.dart';
import 'package:evcc_updater/src/commands.dart';

void main() {
  group('buildUpdateSteps', () {
    test('evcc-only real run produces the validated SSH sequence in order', () {
      final steps = buildUpdateSteps(fullUpgrade: false, dryRun: false);

      expect(steps.map((s) => s.command).toList(), [
        r"dpkg-query -W -f='${db:Status-Status} ${Version}' evcc",
        'LC_ALL=C sudo -S apt-get update -qq',
        'LC_ALL=C sudo -S apt-get -o Dpkg::Use-Pty=0 install --only-upgrade -y evcc',
        'systemctl is-active evcc',
        r"dpkg-query -W -f='${db:Status-Status} ${Version}' evcc",
      ]);
    });

    test('only the two apt-get steps require the sudo password on stdin', () {
      final steps = buildUpdateSteps(fullUpgrade: false, dryRun: false);

      expect(steps.map((s) => s.needsSudoPassword).toList(),
          [false, true, true, false, false]);
    });

    test('full upgrade swaps the upgrade step for apt-get full-upgrade -y', () {
      final steps = buildUpdateSteps(fullUpgrade: true, dryRun: false);

      expect(steps[2].command,
          'LC_ALL=C sudo -S apt-get -o Dpkg::Use-Pty=0 full-upgrade -y');
    });

    test('dry-run (evcc-only) adds --dry-run and drops -y', () {
      final steps = buildUpdateSteps(fullUpgrade: false, dryRun: true);

      expect(steps[2].command,
          'LC_ALL=C sudo -S apt-get install --only-upgrade --dry-run evcc');
    });

    test('dry-run (full upgrade) uses full-upgrade --dry-run', () {
      final steps = buildUpdateSteps(fullUpgrade: true, dryRun: true);

      expect(steps[2].command, 'LC_ALL=C sudo -S apt-get full-upgrade --dry-run');
    });

    test('every step carries a non-empty human label', () {
      final steps = buildUpdateSteps(fullUpgrade: false, dryRun: false);

      expect(steps.every((s) => s.label.trim().isNotEmpty), isTrue);
    });
  });

  group('buildInstallScript', () {
    final script = buildInstallScript();

    test('installs the evcc package', () {
      expect(script, contains('install -y evcc'));
    });

    test('adds the official evcc apt repo via the setup script', () {
      expect(
        script,
        contains('https://dl.evcc.io/public/evcc/stable/setup.deb.sh'),
      );
    });

    test('uses the unstable (nightly) repo when channel is unstable', () {
      final nightly = buildInstallScript(channel: 'unstable');
      expect(
        nightly,
        contains('https://dl.evcc.io/public/evcc/unstable/setup.deb.sh'),
      );
    });

    test('enables and starts the service', () {
      expect(script, contains('systemctl enable --now evcc'));
    });

    test('installs prerequisites including curl', () {
      expect(script, contains('curl'));
    });

    test('aborts on the first error', () {
      expect(script, contains('set -e'));
    });

    test('runs non-interactively (no apt prompts)', () {
      expect(script, contains('DEBIAN_FRONTEND=noninteractive'));
    });
  });

  group('buildBackupScript', () {
    final script = buildBackupScript();
    test('backs up config + detected DB into a timestamped archive', () {
      expect(script, contains('/etc/evcc.yaml'));
      expect(script, contains('/var/backups/evcc'));
      expect(script, contains('tar -czf'));
    });
    test('detects the DB via the config dsn, with default-location fallbacks',
        () {
      expect(script, contains('dsn:'));
      expect(script, contains('/root/.evcc/evcc.db'));
      expect(script, contains('/var/lib/evcc'));
    });
    test('emits machine-readable result markers', () {
      expect(script, contains('EVCC_BACKUP_OK'));
      expect(script, contains('EVCC_BACKUP_EMPTY'));
      expect(script, contains('EVCC_BACKUP_FAIL'));
    });
  });

  group('buildRootStdin', () {
    test('sends the password only when sudo actually asks for it', () {
      expect(
        buildRootStdin(
            sudoNeedsPassword: true, password: 'geheim', script: 'echo hi'),
        'geheim\necho hi\n',
      );
    });

    test('NOPASSWD sudo gets the script alone — never the password', () {
      // Otherwise sudo consumes nothing, the line falls through to `bash -s`
      // and the password is executed as a command:
      //   bash: line 1: <password>: command not found
      final out = buildRootStdin(
          sudoNeedsPassword: false, password: 'geheim', script: 'echo hi');
      expect(out, 'echo hi\n');
      expect(out, isNot(contains('geheim')));
    });
  });

  group('apt without a pty', () {
    // apt hands dpkg a pty even with no terminal attached (Debian #860931), and
    // dpkg then repaints "(Reading database ... N%" ~20× per package. Over SSH
    // that is pure log flooding, so every call that runs dpkg turns it off.
    bool runsDpkg(String line) =>
        line.contains('apt-get') &&
        RegExp(r'\b(install|full-upgrade|upgrade|remove|purge|autoremove)\b')
            .hasMatch(line);

    test('the real upgrade commands carry the flag', () {
      for (final full in [true, false]) {
        final cmd = buildUpdateSteps(fullUpgrade: full, dryRun: false)[2].command;
        expect(cmd, contains(aptNoPty));
      }
    });

    test('a dry run stays untouched — it never reaches dpkg', () {
      for (final full in [true, false]) {
        final cmd = buildUpdateSteps(fullUpgrade: full, dryRun: true)[2].command;
        expect(cmd, contains('--dry-run'));
        expect(cmd, isNot(contains(aptNoPty)));
      }
    });

    test('install and cleanup scripts carry it on every dpkg-running line', () {
      for (final script in [buildInstallScript(), buildCleanupScript()]) {
        for (final line in script.split('\n')) {
          if (!runsDpkg(line)) continue;
          expect(line, contains('-o Dpkg::Use-Pty=0'),
              reason: '"$line" would flood the log');
        }
      }
    });

    test('plain `apt-get update` is left alone (no dpkg, nothing to paint)', () {
      final refresh = buildUpdateSteps(fullUpgrade: true, dryRun: false)[1];
      expect(refresh.command, contains('apt-get update'));
      expect(refresh.command, isNot(contains(aptNoPty)));
    });
  });
}
