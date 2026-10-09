import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:evcc_updater/src/commands.dart';
import 'package:evcc_updater/src/pi_job.dart'
    show jobKindSystemUpgrade, jobRuntimeLimit;

import 'on_pi_sandbox.dart';

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

    // Same pattern as the apt service installs (apt_services.dart): wait for a
    // held lock, keep changed conffiles without asking, and never let apt or a
    // maintainer script read the rest of the script off stdin — evcc's postinst
    // asks with `read` when it finds leftovers of a manual install.
    test('both installs carry the apt options of the service installs', () {
      const opts = 'apt-get -o DPkg::Lock::Timeout=120 -o Dpkg::Use-Pty=0 '
          '-o Dpkg::Options::=--force-confdef '
          '-o Dpkg::Options::=--force-confold install -y';
      for (final s in [script, buildInstallScript(channel: 'unstable')]) {
        final installs = s
            .split('\n')
            .where((l) => l.contains('apt-get') && l.contains(' install '))
            .toList();
        expect(installs, [
          '$opts debian-keyring debian-archive-keyring apt-transport-https '
              'curl </dev/null',
          '$opts evcc </dev/null',
        ]);
      }
    });

    test('no apt call can read the script from stdin', () {
      final apt = script.split('\n').where((l) => l.contains('apt-get'));
      expect(apt, hasLength(3));
      for (final line in apt) {
        expect(line.trimRight(), endsWith('</dev/null'),
            reason: '"$line" could swallow the script tail');
      }
      expect(script, isNot(matches(RegExp(r'exec\s*<\s*/dev/null'))));
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

  group('parseInstallRefusal', () {
    test('reads the reason from the refusal line', () {
      expect(
          parseInstallRefusal('some output\n'
              '${installRefusedPrefix}InfluxDB 2 gibt es nur für 64 Bit.\n'),
          'InfluxDB 2 gibt es nur für 64 Bit.');
    });

    test('null without a refusal line or without a reason', () {
      expect(parseInstallRefusal('E: Unable to locate package influxdb2'),
          isNull);
      expect(parseInstallRefusal(installRefusedPrefix), isNull);
      expect(parseInstallRefusal(''), isNull);
    });

    test('install and uninstall refusals do not read each other\'s line', () {
      // INSTALL_REFUSED is a substring of UNINSTALL_REFUSED — the line start
      // decides, not contains().
      expect(parseInstallRefusal('${uninstallRefusedPrefix}x'), isNull);
      expect(parseUninstallRefusal('${installRefusedPrefix}x'), isNull);
      expect(parseUninstallRefusal('${uninstallRefusedPrefix}x'), 'x');
    });

    test('the prefix cannot be mistaken for a success marker', () {
      expect(installRefusedPrefix, isNot(contains('INSTALL_OK')));
    });
  });

  group('parseConfigWriteRefusal', () {
    test('reads the reason from the refusal line of the config write', () {
      expect(
          parseConfigWriteRefusal('Speichere /etc/evcc.yaml …\n'
              '${configWriteRefusedPrefix}Der Pfad ist eine Verknüpfung.\n'),
          'Der Pfad ist eine Verknüpfung.');
    });

    test('null without a refusal line or without a reason', () {
      expect(parseConfigWriteRefusal('CONFIG_SAVED\n'), isNull);
      expect(parseConfigWriteRefusal(configWriteRefusedPrefix), isNull);
      expect(parseConfigWriteRefusal('${installRefusedPrefix}x'), isNull);
    });

    test('the prefix cannot be mistaken for the success marker', () {
      expect(configWriteRefusedPrefix, isNot(contains('CONFIG_SAVED')));
    });
  });

  // A unit set up by v0.71.0 or earlier has no runtime cap: while such a run
  // hangs, the refusal comes back for good.
  group('autoUpdateBusyWayOut', () {
    test('names both ways out, for the unit the guard asks about', () {
      final asked = RegExp(r'ActiveState --value ([\w.-]+) ')
          .firstMatch(jobPowerGuard)!
          .group(1)!;
      expect(asked, 'pi-tool-autoupdate.service');
      expect(autoUpdateBusyWayOut,
          contains('„sudo systemctl stop $asked" ausführen'));
      // The button of the auto-update sheet, as app_de.arb names it.
      expect(autoUpdateBusyWayOut, contains('(„Zeitplan ändern")'));
      expect(autoUpdateBusyWayOut, contains('Tab „Automatik"'));
    });

    // Setting the timer up again does not end a run at once: the unit then
    // has the cap of a system-upgrade job (auto_update.dart), counted from
    // the start of the run. The text names that cap instead of promising an
    // end of whatever hangs.
    test('says after which runtime the Pi ends a run by itself', () {
      expect(jobRuntimeLimit(jobKindSystemUpgrade), '6h');
      expect(
          autoUpdateBusyWayOut,
          contains('– danach beendet der Pi einen Lauf, der länger als sechs '
              'Stunden dauert, selbst –'));
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
      for (final script in [
        buildInstallScript(),
        buildCleanupScript(),
        buildEvccUninstallScript(purge: false),
        buildEvccUninstallScript(purge: true),
      ]) {
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

  group('buildEvccUninstallScript', () {
    final keep = buildEvccUninstallScript(purge: false);
    final purge = buildEvccUninstallScript(purge: true);
    final both = {'keep': keep, 'purge': purge};

    // The script without its comment lines (prose may name any command).
    String code(String s) => s
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('#'))
        .join('\n');

    // Where the first command that changes the Pi starts (-1: none). An apt
    // simulation (`apt-get … -s …`) is a read-only guard, not a change.
    int firstChange(String s) =>
        RegExp(r'(^|[\s;&|(])(apt-get(?![^\n]*\s-s\s)|dpkg|rm|rmdir|mkdir|'
                r'userdel|groupdel|pkill|touch|'
                r'systemctl (stop|daemon-reload|reset-failed))\s|'
                r':\s*>',
                multiLine: true)
            .firstMatch(s)
            ?.start ??
        -1;

    test('marker is the last line, exactly once, and not an *INSTALL_OK', () {
      expect(evccRemovedMarker, 'EVCC_REMOVED_OK');
      expect(evccRemovedMarker, isNot(contains('INSTALL_OK')));
      both.forEach((mode, s) {
        expect(s.trimRight().split('\n').last, 'echo $evccRemovedMarker',
            reason: mode);
        expect(evccRemovedMarker.allMatches(s), hasLength(1), reason: mode);
      });
    });

    test('runs as root under set -e, non-interactive', () {
      both.forEach((mode, s) {
        expect(s, startsWith('set -e\n'), reason: mode);
        expect(s, contains('export DEBIAN_FRONTEND=noninteractive'),
            reason: mode);
        expect(s, contains('export LC_ALL=C'), reason: mode);
      });
    });

    test('never cuts off its own stdin with a global exec redirect', () {
      // The script arrives on stdin (sudo -S bash -s): `exec </dev/null`
      // would end it silently after that line.
      both.forEach((mode, s) {
        expect(s, isNot(matches(RegExp(r'\bexec\s*[0-9]*<'))), reason: mode);
      });
    });

    test('apt only ever touches evcc, with lock timeout, no pty, no stdin', () {
      both.forEach((mode, s) {
        s = code(s);
        final verb = mode == 'purge' ? 'purge' : 'remove';
        final apt = s.split('\n').where((l) => l.contains('apt-get')).toList();
        expect(apt, hasLength(2), reason: '$mode: dry run + real run');
        expect(
            apt.first.trim(),
            'if ! sim=\$(apt-get -o Dpkg::Use-Pty=0 -o DPkg::Lock::Timeout=120 '
            '-s $verb evcc 2>&1 </dev/null); then',
            reason: mode);
        expect(
            apt.last.trim(),
            'apt-get -o Dpkg::Use-Pty=0 -o DPkg::Lock::Timeout=120 '
            '$verb -y evcc </dev/null',
            reason: mode);
        expect(s, isNot(contains('autoremove')), reason: mode);
        // Shared packages the install pulled in stay (curl, keyrings, …).
        for (final shared in [
          'curl',
          'gnupg',
          'ca-certificates',
          'debian-archive-keyring',
          'adduser',
          'ucf ',
          'docker rm',
          'docker volume',
          'docker rmi',
        ]) {
          expect(s, isNot(contains(shared)), reason: '$mode: $shared');
        }
      });
    });

    test('dpkg is asked for the status word, never a bare -W existence test',
        () {
      both.forEach((mode, s) {
        const probe = r"dpkg-query -W -f='${db:Status-Status}' evcc";
        expect(probe.allMatches(s).length, 2, reason: '$mode: guard + proof');
        expect(s, isNot(contains('dpkg-query -W evcc')), reason: mode);
        expect(s, contains('""|not-installed'), reason: mode);
        // Every dpkg-query call keeps its hands off the script on stdin.
        for (final l in s.split('\n').where((l) => l.contains('dpkg-query'))) {
          expect(l, contains('</dev/null'), reason: '$mode: $l');
        }
      });
    });

    test('all guards come before the first change to the Pi', () {
      both.forEach((mode, s) {
        s = code(s);
        final change = firstChange(s);
        expect(change, greaterThan(0), reason: mode);
        expect(s.lastIndexOf('exit 3'), lessThan(change), reason: mode);
        expect(s.lastIndexOf('UNINSTALL_REFUSED:'), lessThan(change),
            reason: mode);
      });
    });

    test('a held evcc and a failing dry run refuse before the first change',
        () {
      both.forEach((mode, s) {
        s = code(s);
        final change = firstChange(s);
        const want = r"dpkg-query -W -f='${db:Status-Want}' evcc";
        final hold = s.indexOf(want);
        expect(hold, greaterThan(-1), reason: mode);
        expect(s.substring(hold), startsWith('$want 2>/dev/null </dev/null'),
            reason: mode);
        expect(s, contains('sudo apt-mark unhold evcc'), reason: mode);
        final sim = s.indexOf(' -s ');
        expect(sim, greaterThan(hold), reason: mode);
        expect(sim, lessThan(change), reason: mode);
        // A failed simulation is a refusal (exit 3), and apt's reason goes to
        // stderr so stdout keeps its single refusal line.
        final fail = s.substring(sim, change);
        expect(fail, contains(r'''printf '%s\n' "$sim" >&2'''), reason: mode);
        expect(fail, contains('UNINSTALL_REFUSED: Der apt-Probelauf'),
            reason: mode);
        // Anything apt would take along besides evcc refuses as well.
        expect(fail, contains('zusätzlich'), reason: mode);
      });
    });

    test('every refusal is one German line, followed by exit 3', () {
      both.forEach((mode, s) {
        final lines = s.split('\n');
        final refusals = [
          for (var i = 0; i < lines.length; i++)
            if (lines[i].contains('UNINSTALL_REFUSED')) i
        ];
        expect(refusals, isNotEmpty, reason: mode);
        for (final i in refusals) {
          expect(lines[i].trim(),
              matches(RegExp(r'''^echo (['"])UNINSTALL_REFUSED: [^'"\n]+\1$''')),
              reason: '$mode: ${lines[i]}');
          expect(lines.skip(i + 1).take(4).join('\n'), contains('exit 3'),
              reason: '$mode: ${lines[i]}');
        }
        expect(s, contains('ä'), reason: '$mode: real umlauts');
        expect(s, isNot(contains('Ã')), reason: '$mode: no mojibake');
      });
    });

    test('the final dpkg proof sits between the last apt-get and the marker',
        () {
      both.forEach((mode, s) {
        s = code(s);
        final proof = s.lastIndexOf('dpkg-query');
        expect(proof, greaterThan(s.lastIndexOf('apt-get')), reason: mode);
        expect(proof, lessThan(s.lastIndexOf(evccRemovedMarker)),
            reason: mode);
      });
    });

    test('keep: removes the program only — config, data, source, user stay',
        () {
      expect(keep, contains('remove -y evcc'));
      expect(keep, isNot(contains('purge -y')));
      for (final kept in [
        '/etc/evcc.yaml',
        '/var/lib/evcc',
        '/var/backups',
        'sources.list.d',
        'keyrings',
      ]) {
        final touching = keep
            .split('\n')
            .where((l) => l.contains(kept) && RegExp(r'\brm\b').hasMatch(l));
        expect(touching, isEmpty, reason: kept);
      }
      expect(code(keep), isNot(contains('userdel')));
      expect(code(keep), isNot(contains('groupdel')));
      // The package's postrm masks the unit; the next install unmasks it.
      expect(keep, isNot(contains('systemctl disable')));
      expect(keep, isNot(contains('systemctl mask')));
      expect(code(keep), isNot(contains('docker')));
    });

    test('purge: program, config, data, both channels, backups and user', () {
      expect(purge, contains('purge -y evcc'));
      for (final gone in [
        'rm -f /etc/evcc.yaml',
        '/var/lib/evcc',
        'for ch in stable unstable',
        r'"/etc/apt/sources.list.d/evcc-$ch.list"',
        r'"/usr/share/keyrings/evcc-$ch-archive-keyring.gpg"',
        r'"/etc/apt/trusted.gpg.d/evcc-$ch.gpg"',
        'rm -rf /var/backups/evcc',
        '/var/backups/pi-tool/config-evcc.yaml-*.bak',
        '/var/backups/pi-tool/evcc.yaml.wire-*',
        '/var/backups/pi-tool/evcc.yaml.unwire-*',
        '/var/backups/pi-tool/sched-evcc-*.tar.gz',
        '/var/backups/pi-tool/autoupdate-evcc-*.tar.gz',
        'userdel evcc',
      ]) {
        expect(purge, contains(gone), reason: gone);
      }
      // The Pi-wide timers serve other services too — never dismantled here.
      for (final shared in ['pi-tool-autoupdate', 'pi-tool-backup', 'alerts']) {
        expect(code(purge), isNot(contains(shared)), reason: shared);
      }
    });

    test('purge: rm -rf only ever gets literal absolute paths', () {
      final rmrf = RegExp(r'rm -rf ([^\n;|&]+)').allMatches(purge).toList();
      expect(rmrf, isNotEmpty);
      for (final m in rmrf) {
        for (final arg in m.group(1)!.trim().split(RegExp(r'\s+'))) {
          expect(arg, matches(RegExp(r'^/[A-Za-z0-9._/-]+$')), reason: arg);
          expect(arg, isNot(anyOf('/', '/etc', '/var', '/var/lib', '/root')));
        }
      }
    });

    test('purge: refuses next to a Docker evcc (running or stopped)', () {
      expect(purge, contains('docker ps -aq'));
      expect(purge, contains('{{range .Mounts}}{{.Source}}'));
      // Read-only docker calls in the guard keep their hands off stdin.
      for (final l
          in code(purge).split('\n').where((l) => l.contains('docker '))) {
        if (l.contains('command -v docker')) continue;
        expect(l, contains('</dev/null'), reason: l);
      }
    });
  });

  group('buildEvccUninstallScript in bash', () {
    late _Sandbox sb;

    // A Pi with apt-evcc, Pi-Tool's evcc backups and neighbours that must
    // survive any evcc uninstall.
    const evccFiles = [
      '/usr/bin/evcc',
      '/etc/evcc.yaml',
      '/etc/evcc-userchoices.sh',
      '/var/lib/evcc/evcc.db',
      '/etc/apt/sources.list.d/evcc-stable.list',
      '/etc/apt/sources.list.d/evcc-unstable.list',
      '/usr/share/keyrings/evcc-stable-archive-keyring.gpg',
      '/etc/apt/trusted.gpg.d/evcc-unstable.gpg',
      '/etc/systemd/system/multi-user.target.wants/evcc.service',
      '/etc/systemd/system/evcc.service.d/override.conf',
      '/var/backups/evcc/evcc-backup-20260101-000000.tar.gz',
    ];
    const evccAppBackups = [
      '/var/backups/pi-tool/config-evcc.yaml-20260101-000000.bak',
      '/var/backups/pi-tool/evcc.yaml.wire-20260101-000000',
      '/var/backups/pi-tool/evcc.yaml.unwire-20260101-000000',
      '/var/backups/pi-tool/sched-evcc-20260101-000000.tar.gz',
      '/var/backups/pi-tool/sched-evcc-20260102-000000.tar.gz.part',
      '/var/backups/pi-tool/autoupdate-evcc-20260101-000000.tar.gz',
    ];
    const neighbours = [
      '/etc/apt/sources.list.d/grafana.list',
      '/usr/share/keyrings/grafana.gpg',
      '/var/backups/pi-tool/sched-pihole-20260101-000000.tar.gz',
      '/var/backups/pi-tool/pihole-backup-20260101-000000.tar.gz',
      '/var/backups/pi-tool/config-mosquitto.conf-20260101-000000.bak',
      '/var/backups/pi-tool/apt-sources/sources.list.20260101',
      '/var/lib/pi-tool/autoupdate.status',
      '/usr/local/lib/pi-tool-backup.sh',
      '/root/.ssh/authorized_keys',
    ];

    setUp(() {
      sb = _Sandbox();
      final s = sb.stateDir, r = sb.root;
      // dpkg: state `dpkg` is the status word, `want` the selection (hold).
      sb.stub(
          'dpkg-query',
          '''
if [ ! -s "$s/dpkg" ]; then
  echo "dpkg-query: no packages found matching evcc" >&2; exit 1
fi
case "\$*" in
  *Status-Want*) if [ -e "$s/want" ]; then cat "$s/want"; else printf install; fi ;;
  *) cat "$s/dpkg" ;;
esac''',
          drainStdin: true);
      // apt: a simulation (-s) changes nothing and prints apt's plan (state
      // `sim_out` replaces it); `sim_fail` fails it the way an interrupted
      // dpkg or a held lock does. `apt_fail` fails only the real run.
      sb.stub(
          'apt-get',
          '''
case " \$* " in
  *" -s "*)
    if [ -e "$s/sim_fail" ]; then
      echo "E: dpkg was interrupted, you must manually run 'dpkg --configure -a' to correct the problem." >&2
      exit 100
    fi
    echo "Reading package lists..."
    echo "The following packages will be REMOVED:"
    echo "  evcc*"
    if [ -e "$s/sim_out" ]; then cat "$s/sim_out"; else
      case " \$* " in *" purge "*) echo "Purg evcc [0.300.0]" ;; *) echo "Remv evcc [0.300.0]" ;; esac
    fi
    exit 0 ;;
esac
if [ -e "$s/apt_fail" ]; then
  echo "E: Could not get lock /var/lib/dpkg/lock-frontend" >&2; exit 100
fi
case " \$* " in
  *" remove "*) printf config-files > "$s/dpkg" ;;
  *" purge "*) : > "$s/dpkg"; rm -f "$r/etc/evcc-userchoices.sh" ;;
  *) exit 100 ;;
esac
rm -f "$r/usr/bin/evcc" "$s/active"''',
          drainStdin: true);
      sb.stub('systemctl', '''
case "\$1" in
  is-active) [ -e "$s/active" ] ;;
  stop) rm -f "$s/active" ;;
esac''');
      sb.stub('getent', '''
case "\$1 \$2" in
  "passwd evcc") [ -e "$s/user" ] ;;
  "group evcc") [ -e "$s/group" ] ;;
  *) exit 2 ;;
esac''');
      sb.stub('userdel', '''
if [ -e "$s/userdel_fail" ]; then
  echo "userdel: user evcc is currently used by process 4711" >&2; exit 8
fi
rm -f "$s/user"''');
      sb.stub('groupdel', 'rm -f "$s/group"');
      sb.stub('pkill', 'exit 1');
      sb.stub('pgrep', 'exit 1');

      for (final f in [...evccFiles, ...evccAppBackups, ...neighbours]) {
        sb.put(f);
      }
      sb.setState('dpkg', 'installed');
      sb.setState('user');
      sb.setState('group');
      sb.setState('active');
    });
    tearDown(() => sb.dispose());

    void withDocker({String ps = '', String inspect = '', bool down = false}) {
      final s = sb.stateDir;
      sb.stub('docker', '''
if [ -e "$s/docker_down" ]; then
  echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock" >&2; exit 1
fi
case "\$1" in
  ps) cat "$s/docker_ps" 2>/dev/null ;;
  inspect) cat "$s/docker_inspect" 2>/dev/null ;;
esac
exit 0''', drainStdin: true);
      sb.setState('docker_ps', ps);
      sb.setState('docker_inspect', inspect);
      if (down) sb.setState('docker_down');
    }

    Future<_Run> run({required bool purge, String sudoUser = 'pi'}) =>
        sb.run(buildEvccUninstallScript(purge: purge),
            env: {'SUDO_USER': sudoUser});

    void expectSuccess(_Run r) {
      expect(r.code, 0, reason: '${r.out}\n${r.err}');
      // No output at all usually means a call read the script's tail off
      // stdin (a missing </dev/null).
      expect(r.lines, isNotEmpty, reason: 'script tail swallowed?\n${r.err}');
      expect(r.lines.last, evccRemovedMarker, reason: r.out);
    }

    // Real apt runs vs. dry runs (-s), in call order across all runs.
    List<String> aptRuns() => sb.calls
        .where((c) => c.startsWith('apt-get ') && !c.contains(' -s '))
        .toList();
    List<String> aptSims() => sb.calls
        .where((c) => c.startsWith('apt-get ') && c.contains(' -s '))
        .toList();

    void expectRefusedUntouched(_Run r) {
      expect(r.code, 3, reason: '${r.out}\n${r.err}');
      expect(r.lines, hasLength(1), reason: r.out);
      expect(r.lines.single, startsWith('UNINSTALL_REFUSED: '));
      expect(r.out, isNot(contains(evccRemovedMarker)));
      // Only read-only probes ran; not a single file changed.
      for (final c in sb.calls) {
        expect(
            c,
            matches(RegExp(
                r'^(dpkg-query|docker (ps|inspect)|apt-get( -o \S+)* -s) ')),
            reason: c);
      }
      expect(sb.state('dpkg'), anyOf('installed', ''), reason: 'no apt run');
      expect(sb.hasState('user'), isTrue);
      for (final f in [...evccFiles, ...evccAppBackups, ...neighbours]) {
        expect(sb.exists(f), isTrue, reason: f);
      }
      expect(sb.exists('/var/lib/pi-tool/evcc-purge.pending'), isFalse);
    }

    test('keep: removes the package, leaves config, data, source and user',
        () async {
      final r = await run(purge: false);
      expectSuccess(r);
      expect(aptSims().single, contains(' -s remove evcc'));
      expect(aptRuns().single, contains(' remove -y evcc'));
      expect(sb.calls.indexOf(aptSims().single),
          lessThan(sb.calls.indexOf(aptRuns().single)));
      expect(sb.state('dpkg'), 'config-files');
      expect(sb.exists('/usr/bin/evcc'), isFalse);
      for (final f in [
        ...evccFiles.where((f) => f != '/usr/bin/evcc'),
        ...evccAppBackups,
        ...neighbours,
      ]) {
        expect(sb.exists(f), isTrue, reason: f);
      }
      expect(sb.hasState('user'), isTrue);
      expect(sb.hasState('active'), isFalse);
    });

    test('keep: a retry after the package is already gone (rc) succeeds',
        () async {
      sb.setState('dpkg', 'config-files');
      sb.clearState('active');
      final r = await run(purge: false);
      expectSuccess(r);
      expect(sb.calls.where((c) => c.startsWith('apt-get')), isEmpty);
    });

    test('keep: refuses (and changes nothing) when evcc is no apt install',
        () async {
      sb.setState('dpkg', '');
      final r = await run(purge: false);
      expectRefusedUntouched(r);
      expect(r.lines.single, contains('nicht als apt-Paket'));
    });

    test('keep: a failing apt (lock) leaves no marker and everything intact',
        () async {
      sb.setState('apt_fail');
      final r = await run(purge: false);
      expect(r.code, isNot(0));
      expect(r.out, isNot(contains(evccRemovedMarker)));
      expect(sb.state('dpkg'), 'installed');
      expect(sb.hasState('active'), isTrue, reason: 'not stopped before apt');
    });

    test('purge: removes evcc completely and nothing that is not evcc',
        () async {
      sb.put('/root/.evcc/evcc.db');
      sb.put('/root/.evcc/.copiedToEvccUser');
      final r = await run(purge: true);
      expectSuccess(r);
      expect(aptSims().single, contains(' -s purge evcc'));
      expect(aptRuns().single, contains(' purge -y evcc'));
      for (final f in [...evccFiles, ...evccAppBackups]) {
        expect(sb.exists(f), isFalse, reason: f);
      }
      expect(sb.exists('/var/lib/evcc'), isFalse);
      expect(sb.exists('/etc/systemd/system/evcc.service.d'), isFalse);
      expect(sb.exists('/root/.evcc'), isFalse);
      for (final f in neighbours) {
        expect(sb.exists(f), isTrue, reason: f);
      }
      expect(sb.hasState('user'), isFalse);
      expect(sb.hasState('group'), isFalse);
      expect(sb.exists('/var/lib/pi-tool/evcc-purge.pending'), isFalse);
    });

    test('purge: a legacy /root/.evcc the package never migrated stays',
        () async {
      sb.put('/root/.evcc/evcc.db');
      final r = await run(purge: true);
      expectSuccess(r);
      expect(sb.exists('/root/.evcc/evcc.db'), isTrue);
    });

    test('purge: a retry after a half-finished purge completes it', () async {
      sb.setState('userdel_fail');
      final first = await run(purge: true);
      expect(first.code, isNot(0));
      expect(first.out, isNot(contains(evccRemovedMarker)));
      expect(sb.state('dpkg'), '', reason: 'package already purged');
      expect(sb.exists('/var/lib/pi-tool/evcc-purge.pending'), isTrue);

      sb.clearState('userdel_fail');
      final second = await run(purge: true);
      expectSuccess(second);
      // apt ran (dry + real) only in the first run: nothing left for it now.
      expect(aptRuns(), hasLength(1));
      expect(aptSims(), hasLength(1));
      expect(sb.hasState('user'), isFalse);
      expect(sb.exists('/var/lib/pi-tool/evcc-purge.pending'), isFalse);
    });

    test('keep after an interrupted purge points back to the purge', () async {
      sb.setState('dpkg', '');
      sb.put('/var/lib/pi-tool/evcc-purge.pending');
      final r = await run(purge: false);
      expect(r.code, 3);
      expect(r.lines.single, startsWith('UNINSTALL_REFUSED: '));
      expect(r.lines.single, contains('Auch Konfiguration und Daten löschen'));
      expect(sb.exists('/etc/evcc.yaml'), isTrue);
    });

    test('purge: refuses (and changes nothing) when evcc is no apt install',
        () async {
      sb.setState('dpkg', '');
      final r = await run(purge: true);
      expectRefusedUntouched(r);
    });

    test('purge: refuses next to a stopped evcc container', () async {
      withDocker(ps: 'a1\nb2\n', inspect: '/web|nginx:latest|/srv/www|\n'
          '/evcc-evccpitool-old|evcc/evcc:latest|/home/pi/evcc.yaml|\n');
      final r = await run(purge: true);
      expectRefusedUntouched(r);
      expect(r.lines.single, contains('evcc-evccpitool-old'));
    });

    test('purge: refuses when any container mounts evcc data', () async {
      withDocker(ps: 'c3\n', inspect: '/wallbox|me/ev:1|/var/lib/evcc|\n');
      final r = await run(purge: true);
      expectRefusedUntouched(r);
      expect(r.lines.single, contains('wallbox'));
    });

    test('purge: refuses when docker exists but cannot be asked', () async {
      withDocker(down: true);
      final r = await run(purge: true);
      expectRefusedUntouched(r);
      expect(r.lines.single, contains('Docker'));
    });

    test('purge: unrelated containers do not block it', () async {
      withDocker(
          ps: 'a1\n', inspect: '/web|nginx:latest|/srv/www|/etc/localtime|\n');
      final r = await run(purge: true);
      expectSuccess(r);
      expect(sb.exists('/etc/evcc.yaml'), isFalse);
    });

    test('purge: refuses when the app itself is logged in as evcc', () async {
      final r = await run(purge: true, sudoUser: 'evcc');
      expectRefusedUntouched(r);
    });

    test('purge: a failing apt (lock) leaves config and data in place',
        () async {
      sb.setState('apt_fail');
      final r = await run(purge: true);
      expect(r.code, isNot(0));
      expect(r.out, isNot(contains(evccRemovedMarker)));
      expect(sb.exists('/etc/evcc.yaml'), isTrue);
      expect(sb.exists('/var/lib/evcc/evcc.db'), isTrue);
      expect(sb.hasState('user'), isTrue);
    });

    for (final purge in [false, true]) {
      final mode = purge ? 'purge' : 'keep';

      test('$mode: refuses a held evcc before apt or anything else runs',
          () async {
        // `apt-get -y` would abort on the hold ("Held packages were changed")
        // — for the purge only after the pending marker was set.
        sb.setState('want', 'hold');
        final r = await run(purge: purge);
        expectRefusedUntouched(r);
        expect(r.lines.single, contains('sudo apt-mark unhold evcc'));
        expect(sb.calls.where((c) => c.startsWith('apt-get')), isEmpty);
        expect(sb.hasState('active'), isTrue, reason: 'service untouched');
      });

      test('$mode: a failing apt dry run is a refusal, nothing changed',
          () async {
        sb.setState('sim_fail');
        final r = await run(purge: purge);
        expectRefusedUntouched(r);
        expect(r.lines.single, contains('apt-Probelauf'));
        // apt's own reason goes to stderr (the app logs both streams).
        expect(r.err, contains('dpkg was interrupted'));
        expect(aptRuns(), isEmpty);
        expect(sb.hasState('active'), isTrue, reason: 'service untouched');
      });

      test('$mode: refuses when apt would take other packages along',
          () async {
        final verb = purge ? 'Purg' : 'Remv';
        sb.setState('sim_out',
            '$verb evcc [0.300.0]\n$verb evcc-ha-bridge [1.2]\n');
        final r = await run(purge: purge);
        expectRefusedUntouched(r);
        expect(r.lines.single, contains('evcc-ha-bridge'));
        expect(r.lines.single, isNot(contains(' evcc ')));
        expect(aptRuns(), isEmpty);
      });

      test('$mode: an arch-qualified evcc in the dry run is still just evcc',
          () async {
        final verb = purge ? 'Purg' : 'Remv';
        sb.setState('sim_out', '$verb evcc:arm64 [0.300.0]\n');
        final r = await run(purge: purge);
        expectSuccess(r);
        expect(aptRuns(), hasLength(1));
      });
    }
  }, skip: _needsBash);

  group('dockerListRunningCommand (post-update verification)', () {
    test('lists only running containers — restarting ones are excluded', () {
      // `docker ps` alone also lists a container in its restart loop
      // ("Restarting (1) …"), so a crash-looping update looked like success.
      // The status filter matches the exact state word, so `restarting`,
      // `paused` and `exited` are out.
      for (final c in [dockerListRunningCommand, dockerListRunningSudoCommand]) {
        expect(c, contains('docker ps --filter status=running '));
        expect(c, endsWith("--format '{{.Names}}|{{.Image}}'"));
        expect(c, isNot(contains(' -a')));
      }
      expect(dockerListRunningSudoCommand,
          'LC_ALL=C sudo -S $dockerListRunningCommand');
      // Detection keeps listing restarting containers: a crash-looping evcc
      // must still be found so it can be updated or repaired.
      expect(dockerListCommand, isNot(contains('--filter')));
      expect(dockerListSudoCommand, isNot(contains('--filter')));
    });

    test('its output feeds the same parser as detection', () {
      expect(parseEvccDocker('evcc|evcc/evcc:latest\n')?.name, 'evcc');
    });
  });

  // A `docker inspect` object the way the daemon reports a hand-made
  // `docker run` container; [host], [config] and [networks] override it.
  Map<String, dynamic> inspectOf({
    Map<String, dynamic> host = const {},
    Map<String, dynamic> config = const {},
    Map<String, dynamic>? networks,
  }) =>
      {
        'Id': 'abc123def456${'0' * 52}',
        'Name': '/web',
        'Config': {
          'Hostname': 'abc123def456',
          'Image': 'nginx:1.27',
          'Labels': <String, dynamic>{},
          ...config,
        },
        'HostConfig': {
          'NetworkMode': 'bridge',
          'RestartPolicy': {'Name': 'unless-stopped', 'MaximumRetryCount': 0},
          'AutoRemove': false,
          'Privileged': false,
          'CapAdd': null,
          'CapDrop': null,
          'SecurityOpt': null,
          'ShmSize': 67108864,
          'Memory': 0,
          'MemorySwap': 0,
          'MemoryReservation': 0,
          'NanoCpus': 0,
          'CpuShares': 0,
          'CpuQuota': 0,
          'CpuPeriod': 0,
          'CpusetCpus': '',
          'CpusetMems': '',
          'PidsLimit': null,
          'PidMode': '',
          'IpcMode': 'private',
          ...host,
        },
        'NetworkSettings': {
          'Networks': networks ??
              {
                'bridge': {
                  'IPAMConfig': null,
                  'Aliases': null,
                  'IPAddress': '172.17.0.2',
                }
              },
        },
      };

  group('buildDockerRunCommand: isolation and resource settings', () {
    const head = "docker run -d --name 'web' --restart unless-stopped";

    test('the daemon\'s defaults turn into no flag at all', () {
      expect(buildDockerRunCommand(inspectOf()), "$head 'nginx:1.27'");
    });

    test('carries cap-drop, security-opt, tmpfs, shm-size, sysctls, limits '
        'and the pid mode', () {
      final cmd = buildDockerRunCommand(inspectOf(host: {
        'CapDrop': ['ALL'],
        'SecurityOpt': ['no-new-privileges:true', 'apparmor=unconfined'],
        'Tmpfs': {'/run': 'rw,noexec,nosuid,size=65536k', '/scratch': ''},
        'ShmSize': 268435456,
        'Sysctls': {'net.core.somaxconn': '1024'},
        'Memory': 536870912,
        'MemorySwap': 1073741824,
        'MemoryReservation': 268435456,
        'NanoCpus': 1500000000,
        'CpuShares': 512,
        'CpusetCpus': '0-2',
        'CpusetMems': '0',
        'PidsLimit': 200,
        'PidMode': 'host',
      }));
      expect(
          cmd,
          "$head --cap-drop 'ALL' --security-opt 'no-new-privileges:true' "
          "--security-opt 'apparmor=unconfined' "
          "--tmpfs '/run:rw,noexec,nosuid,size=65536k' --tmpfs '/scratch' "
          "--shm-size 268435456 --sysctl 'net.core.somaxconn=1024' "
          '--memory 536870912 --memory-reservation 268435456 --cpus 1.5 '
          "--cpu-shares 512 --cpuset-cpus '0-2' --cpuset-mems '0' "
          "--pids-limit 200 --pid 'host' 'nginx:1.27'");
    });

    test('memory-swap only when it is not the daemon\'s own doubling', () {
      String run(Map<String, dynamic> host) =>
          buildDockerRunCommand(inspectOf(host: host));
      // No --memory-swap given: the daemon stores twice the memory.
      expect(run({'Memory': 536870912, 'MemorySwap': 1073741824}),
          "$head --memory 536870912 'nginx:1.27'");
      expect(run({'Memory': 536870912, 'MemorySwap': 805306368}),
          "$head --memory 536870912 --memory-swap 805306368 'nginx:1.27'");
      // Unlimited swap, also what a kernel without swap accounting leaves.
      expect(run({'Memory': 536870912, 'MemorySwap': -1}),
          "$head --memory 536870912 --memory-swap -1 'nginx:1.27'");
      // A kernel without the memory cgroup discards the limit: 0 and -1.
      expect(run({'Memory': 0, 'MemorySwap': -1}), "$head 'nginx:1.27'");
    });

    test('--cpus is the exact decimal of NanoCpus', () {
      String cpus(int nano) => RegExp(r'--cpus (\S+)')
          .firstMatch(buildDockerRunCommand(inspectOf(host: {'NanoCpus': nano})))!
          .group(1)!;
      expect(cpus(500000000), '0.5');
      expect(cpus(2000000000), '2');
      expect(cpus(1250000000), '1.25');
      expect(cpus(1), '0.000000001');
    });

    test('cpu quota and period, unless --cpus already says it', () {
      expect(
          buildDockerRunCommand(
              inspectOf(host: {'CpuQuota': 50000, 'CpuPeriod': 100000})),
          "$head --cpu-quota 50000 --cpu-period 100000 'nginx:1.27'");
      // docker refuses --cpus together with a period or a quota.
      expect(
          buildDockerRunCommand(inspectOf(host: {
            'NanoCpus': 1000000000,
            'CpuQuota': 50000,
            'CpuPeriod': 100000,
          })),
          "$head --cpus 1 'nginx:1.27'");
    });

    test('pid mode: host and another container, nothing else', () {
      expect(buildDockerRunCommand(inspectOf(host: {'PidMode': 'container:f00'})),
          "$head --pid 'container:f00' 'nginx:1.27'");
      expect(buildDockerRunCommand(inspectOf(host: {'PidMode': 'private'})),
          "$head 'nginx:1.27'");
    });

    test('label=disable the daemon added itself is not passed back', () {
      // For --privileged, --pid=host and --ipc=host the daemon appends it.
      for (final own in [
        {'Privileged': true},
        {'PidMode': 'host'},
        {'IpcMode': 'host'},
      ]) {
        final cmd = buildDockerRunCommand(inspectOf(host: {
          ...own,
          'SecurityOpt': ['seccomp=unconfined', 'label=disable'],
        }));
        expect(cmd, contains("--security-opt 'seccomp=unconfined'"));
        expect(cmd, isNot(contains('label=disable')), reason: '$own');
      }
      // Set by hand on an ordinary container, it is the user's.
      expect(
          buildDockerRunCommand(inspectOf(host: {
            'SecurityOpt': ['label=disable'],
          })),
          "$head --security-opt 'label=disable' 'nginx:1.27'");
    });

    test('hostile values in the new fields cannot break out', () {
      const evil = "x';reboot;'";
      final cmd = buildDockerRunCommand(inspectOf(host: {
        'CapDrop': [evil],
        'SecurityOpt': [evil],
        'Tmpfs': {evil: evil},
        'Sysctls': {evil: evil},
        'CpusetCpus': evil,
        'CpusetMems': evil,
        'PidMode': 'container:$evil',
        // Not numbers: never interpolated.
        'Memory': evil,
        'ShmSize': evil,
        'NanoCpus': evil,
        'PidsLimit': evil,
      }));
      expect(cmd, isNot(contains("x';reboot")));
      expect(cmd, isNot(contains('--memory')));
      expect(cmd, isNot(contains('--shm-size')));
      expect(cmd, isNot(contains('--cpus ')));
      expect(cmd, isNot(contains('--pids-limit')));
      // Every `'` of the values is escaped: what is left parses as one word
      // per flag value.
      expect(RegExp(r"x'\\'';reboot;'\\''").allMatches(cmd), hasLength(9));
    });
  });

  group('dockerRecreateRefusal', () {
    test('ordinary containers are recreated, not refused', () {
      for (final c in [
        inspectOf(),
        // A user-defined network: older daemons list the short id and a
        // custom hostname as aliases themselves, newer ones an empty config.
        inspectOf(host: {
          'NetworkMode': 'iot'
        }, networks: {
          'iot': {
            'IPAMConfig': null,
            'Aliases': ['abc123def456'],
          }
        }),
        // … and a tool that recreated the container (Portainer) may have
        // carried the previous container's short id along.
        inspectOf(config: {
          'Hostname': 'web-1'
        }, host: {
          'NetworkMode': 'iot'
        }, networks: {
          'iot': {
            'IPAMConfig': <String, dynamic>{},
            'Aliases': ['abc123def456', 'web-1', '0f1e2d3c4b5a', 'web'],
          }
        }),
        inspectOf(host: {
          'NetworkMode': 'iot'
        }, networks: {
          'iot': {
            'IPAMConfig': {'IPv4Address': '', 'IPv6Address': ''},
            'Aliases': <String>[],
          }
        }),
        inspectOf(
            host: {'NetworkMode': 'host'},
            networks: {
              'host': {'IPAMConfig': null, 'Aliases': null}
            }),
        inspectOf(
            host: {'NetworkMode': 'container:f00'},
            networks: <String, dynamic>{}),
        // Settings that are carried over are no reason to refuse.
        inspectOf(host: {
          'CapDrop': ['ALL'],
          'SecurityOpt': ['seccomp=unconfined', 'no-new-privileges'],
          'Tmpfs': {'/run': ''},
          'Memory': 536870912,
          'PidMode': 'host',
          'Mounts': <dynamic>[],
        }),
        // An inspect object without the sections at all.
        <String, dynamic>{
          'Name': '/web',
          'Config': {'Image': 'nginx'},
        },
      ]) {
        expect(dockerRecreateRefusal(c), isNull, reason: '$c');
      }
    });

    test('--rm: the daemon deletes the container on stop, no rollback', () {
      final reason = dockerRecreateRefusal(inspectOf(host: {'AutoRemove': true}));
      expect(reason, contains('--rm'));
      expect(reason, contains('Rollback'));
      expect(reason, endsWith('Nichts geändert.'));
    });

    test('--mount entries are not rebuilt from HostConfig.Mounts', () {
      final reason = dockerRecreateRefusal(inspectOf(host: {
        'Mounts': [
          {'Type': 'volume', 'Source': 'data', 'Target': '/var/lib/data'},
          {'Type': 'bind', 'Source': '/srv/conf', 'Target': '/conf'},
        ],
      }));
      expect(reason, contains('--mount'));
      expect(reason, contains('/var/lib/data, /conf'));
      expect(reason, endsWith('Nichts geändert.'));
    });

    test('more than one network', () {
      final reason = dockerRecreateRefusal(inspectOf(host: {
        'NetworkMode': 'iot'
      }, networks: {
        'iot': {'IPAMConfig': null, 'Aliases': null},
        'proxy': {'IPAMConfig': null, 'Aliases': null},
      }));
      expect(reason, contains('mehreren Netzwerken (iot, proxy)'));
      expect(reason, endsWith('Nichts geändert.'));
    });

    test('a fixed IP address, v4 or v6', () {
      for (final ipam in [
        {'IPv4Address': '172.30.0.10'},
        {'IPv4Address': '', 'IPv6Address': 'fd00::10'},
        {
          'LinkLocalIPs': ['169.254.10.10']
        },
      ]) {
        final reason = dockerRecreateRefusal(inspectOf(host: {
          'NetworkMode': 'iot'
        }, networks: {
          'iot': {'IPAMConfig': ipam, 'Aliases': null}
        }));
        expect(reason, contains('feste IP-Adresse'), reason: '$ipam');
        expect(reason, contains('„iot“'));
        expect(reason, endsWith('Nichts geändert.'));
      }
      expect(
          dockerRecreateRefusal(inspectOf(host: {
            'NetworkMode': 'iot'
          }, networks: {
            'iot': {
              'IPAMConfig': {'IPv4Address': '172.30.0.10'},
              'Aliases': null
            }
          })),
          contains('172.30.0.10'));
    });

    test('a network alias the user set', () {
      final reason = dockerRecreateRefusal(inspectOf(host: {
        'NetworkMode': 'iot'
      }, networks: {
        'iot': {
          'IPAMConfig': null,
          'Aliases': ['db', 'abc123def456'],
        }
      }));
      expect(reason, contains('Netzwerk-Alias'));
      expect(reason, contains('db'));
      expect(reason, isNot(contains('abc123def456')));
      expect(reason, endsWith('Nichts geändert.'));
    });

    test('a seccomp profile the docker CLI inlined from a file', () {
      // `--security-opt seccomp=profile.json` is stored as the JSON itself;
      // passed back, the CLI would look for a file of that name.
      final reason = dockerRecreateRefusal(inspectOf(host: {
        'SecurityOpt': ['seccomp={"defaultAction":"SCMP_ACT_ERRNO"}'],
      }));
      expect(reason, contains('seccomp'));
      expect(reason, endsWith('Nichts geändert.'));
      for (final ok in ['seccomp=unconfined', 'seccomp=builtin']) {
        expect(
            dockerRecreateRefusal(inspectOf(host: {
              'SecurityOpt': [ok]
            })),
            isNull,
            reason: ok);
      }
    });

    test('--rm is named first: it decides whether a rollback exists', () {
      final reason = dockerRecreateRefusal(inspectOf(host: {
        'AutoRemove': true,
        'Mounts': [
          {'Type': 'volume', 'Source': 'data', 'Target': '/data'}
        ],
      }));
      expect(reason, contains('--rm'));
      expect(reason, isNot(contains('--mount')));
    });
  });

  group('isVersionPinnedImage', () {
    test('a tag that names a version is pinned', () {
      for (final image in [
        'ghcr.io/home-assistant/home-assistant:2026.6.3',
        'ghcr.io/home-assistant/home-assistant:2026.6',
        'evcc/evcc:0.203.2',
        'nginx:v1.27',
        'postgres:16-alpine',
        'registry.local:5000/app:1.2',
      ]) {
        expect(isVersionPinnedImage(image), isTrue, reason: image);
      }
    });

    test('a moving tag, or none, is not', () {
      for (final image in [
        'ghcr.io/home-assistant/home-assistant:stable',
        'evcc/evcc:latest',
        'evcc/evcc:nightly',
        'nginx',
        'registry.local:5000/app',
        'debian:bookworm-slim',
        '',
      ]) {
        expect(isVersionPinnedImage(image), isFalse, reason: image);
      }
    });
  });

  group('isDockerImageUnchanged', () {
    test('only the marker on a line of its own counts', () {
      expect(
          isDockerImageUnchanged('stable: Pulling from home-assistant\n'
              'Status: Image is up to date\n$dockerImageUnchangedMarker\n'),
          isTrue);
      expect(isDockerImageUnchanged('  $dockerImageUnchangedMarker\r\n'), isTrue);
      expect(isDockerImageUnchanged(''), isFalse);
      expect(isDockerImageUnchanged('Status: Image is up to date'), isFalse);
      expect(isDockerImageUnchanged('x $dockerImageUnchangedMarker y'), isFalse);
    });
  });

  group('dockerRunRecreateScript restart policy', () {
    final s = dockerRunRecreateScript(
      name: 'evcc',
      image: 'evcc/evcc:latest',
      runCommand: "docker run -d --name 'evcc' 'evcc/evcc:latest'",
    );

    test('reads the live container\'s policy before anything is changed', () {
      final read = s.indexOf('{{.HostConfig.RestartPolicy.Name}}');
      expect(read, greaterThan(s.indexOf('docker pull')));
      expect(read, lessThan(s.indexOf("docker rm -f 'evcc-evccpitool-old'")));
      expect(read, lessThan(s.indexOf("docker stop 'evcc'")));
    });

    test('parks the renamed rollback container with restart=no, non-fatally',
        () {
      final park = s.indexOf("docker update --restart=no 'evcc-evccpitool-old'");
      expect(park,
          greaterThan(s.indexOf("docker rename 'evcc' 'evcc-evccpitool-old'")));
      expect(park, lessThan(s.indexOf('docker run -d')));
      final line = s.split('\n').firstWhere((l) => l.contains('--restart=no'));
      expect(line, contains('||'), reason: 'must not abort the update');
    });

    test('both rollback paths hand the saved policy back before the start', () {
      final restores = RegExp(r'''docker update --restart="\$rp" 'evcc' ''')
          .allMatches(s)
          .toList();
      expect(restores, hasLength(2));
      for (final m in restores) {
        final start = s.indexOf("docker start 'evcc'", m.end);
        expect(start, greaterThan(m.end));
        final renameBack =
            s.lastIndexOf("docker rename 'evcc-evccpitool-old' 'evcc'", m.start);
        expect(renameBack, greaterThan(-1));
      }
    });

    test('the container name stays shell-quoted in the new lines', () {
      final evil = dockerRunRecreateScript(
          name: "x'; reboot; '", image: 'i', runCommand: 'true');
      expect(evil, contains(r"""docker update --restart=no 'x'\''; reboot; '\''-evccpitool-old'"""));
      expect(evil, isNot(contains("--restart=no x';")));
    });

    test('after the settle it demands a clean start, not just State.Running',
        () {
      // Docker reports Running=true while a container sits in its restart
      // loop (always / unless-stopped / on-failure), so Running alone never
      // caught a crash-on-boot. A fresh container starts with RestartCount 0.
      expect(s, contains(
          "docker inspect -f '{{.State.Status}}|{{.RestartCount}}' 'evcc'"));
      expect(s, contains("!= 'running|0'"));
      expect(s, isNot(contains('{{.State.Running}}')));
      final check = s.indexOf('{{.State.Status}}');
      expect(check, greaterThan(s.indexOf('sleep 3')));
      expect(check, greaterThan(s.indexOf('docker run -d')));
    });
  });

  group('dockerRunRecreateScript in bash', () {
    late _Sandbox sb;

    setUp(() {
      sb = _Sandbox();
      // The new container as the daemon reports it: state `status|restarts`
      // (no state file: the container is gone). Like moby, Running is true
      // while the container is restarting. Formats are rendered literally,
      // so the script may ask for any of these fields.
      // No stdin draining here: the docker CLI only reads stdin with -i, and
      // none of pull/stop/rename/update/run -d/start/inspect has it.
      sb.stub('docker', r'''
case "$1" in
  inspect)
    case "$3" in
      *RestartPolicy*) cat "@S@/rp" ;;
      *)
        [ -e "@S@/state" ] || { echo "Error: No such object: $4" >&2; exit 1; }
        st=$(cat "@S@/state"); n=${st#*|}; st=${st%%|*}
        case "$st" in running|restarting|paused) run=true ;; *) run=false ;; esac
        rs=false; [ "$st" != restarting ] || rs=true
        printf '%s\n' "$3" | awk -v st="$st" -v n="$n" -v run="$run" -v rs="$rs" '
          function rep(s, a, b,   i) {
            while ((i = index(s, a)) > 0) s = substr(s, 1, i - 1) b substr(s, i + length(a))
            return s
          }
          { s = rep($0, "{{.State.Status}}", st); s = rep(s, "{{.RestartCount}}", n)
            s = rep(s, "{{.State.Running}}", run); s = rep(s, "{{.State.Restarting}}", rs)
            print s }' ;;
    esac ;;
  # The image a container was created from (state `cimg`) and the one a tag
  # points to now (state `timg`); without the state file: no such object.
  container) [ -e "@S@/cimg" ] && cat "@S@/cimg" ;;
  image) [ -e "@S@/timg" ] && cat "@S@/timg" ;;
  pull) [ ! -e "@S@/pull_fail" ] ;;
  run) [ ! -e "@S@/run_fail" ] ;;
esac'''
          .replaceAll('@S@', sb.stateDir));
    });
    tearDown(() => sb.dispose());

    Future<_Run> recreate() => sb.run(dockerRunRecreateScript(
          name: 'evcc',
          image: 'evcc/evcc:latest',
          runCommand: "docker run -d --name 'evcc' 'evcc/evcc:latest'",
        ));

    test('the sandbox runs its stubs, not a host command of the same name',
        () async {
      // `sleep` exists on every host: the settle must not really wait, and a
      // host with Docker must never have its daemon asked.
      final r = await sb.run('command -v sleep docker\n');
      final bin = '${_posix(sb.root)}/bin';
      expect(r.lines, ['$bin/sleep', '$bin/docker'], reason: r.err);
    });

    // The two questions the script asks after the pull, as the stub logs them.
    const askContainer = 'docker container inspect -f {{.Image}} evcc';
    const askTag = 'docker image inspect -f {{.Id}} evcc/evcc:latest';

    test('nothing new behind the tag: the container is left alone', () async {
      sb.setState('rp', 'unless-stopped:0');
      sb.setState('cimg', 'sha256:aaa\n');
      sb.setState('timg', 'sha256:aaa\n');
      final r = await recreate();
      expect(r.code, 0, reason: '${r.out}\n${r.err}');
      expect(r.lines.last, dockerImageUnchangedMarker);
      expect(isDockerImageUnchanged(r.out), isTrue);
      // Pulled and asked, nothing else: not stopped, renamed or recreated.
      expect(sb.calls, ['docker pull evcc/evcc:latest', askContainer, askTag]);
    });

    test('a new image behind the tag: recreated as before', () async {
      sb.setState('rp', 'unless-stopped:0');
      sb.setState('state', 'running|0');
      sb.setState('cimg', 'sha256:aaa\n');
      sb.setState('timg', 'sha256:bbb\n');
      final r = await recreate();
      expect(r.code, 0, reason: '${r.out}\n${r.err}');
      expect(isDockerImageUnchanged(r.out), isFalse);
      final c = sb.calls;
      expect(c.sublist(0, 3),
          ['docker pull evcc/evcc:latest', askContainer, askTag]);
      final stop = c.indexOf('docker stop evcc');
      expect(stop, greaterThan(2));
      expect(c.indexOf('docker rename evcc evcc-evccpitool-old'),
          greaterThan(stop));
      expect(c, contains('docker run -d --name evcc evcc/evcc:latest'));
    });

    test('image ids that cannot be read never count as unchanged', () async {
      for (final known in ['cimg', 'timg', null]) {
        sb.clearState('cimg');
        sb.clearState('timg');
        sb.clearState('calls');
        if (known != null) sb.setState(known, 'sha256:aaa\n');
        sb.setState('rp', 'unless-stopped:0');
        sb.setState('state', 'running|0');
        final r = await recreate();
        expect(r.code, 0, reason: '$known: ${r.out}\n${r.err}');
        expect(isDockerImageUnchanged(r.out), isFalse, reason: '$known');
        expect(sb.calls, contains('docker stop evcc'), reason: '$known');
        expect(sb.calls, contains('docker run -d --name evcc evcc/evcc:latest'),
            reason: '$known');
      }
    });

    test('a failing pull ends the script before anything is asked or changed',
        () async {
      sb.setState('pull_fail');
      sb.setState('cimg', 'sha256:aaa\n');
      sb.setState('timg', 'sha256:aaa\n');
      final r = await recreate();
      expect(r.code, isNot(0));
      expect(isDockerImageUnchanged(r.out), isFalse);
      expect(sb.calls, ['docker pull evcc/evcc:latest']);
    });

    List<String> updates() =>
        sb.calls.where((c) => c.startsWith('docker update')).toList();

    // The retained old container is back under its name, with its own policy,
    // and started only after the policy was handed back.
    void expectRolledBack(_Run r, String policy) {
      expect(r.code, 1, reason: '${r.out}\n${r.err}');
      expect(r.out, contains('stelle den alten wieder her'));
      expect(updates(), [
        'docker update --restart=no evcc-evccpitool-old',
        'docker update --restart=$policy evcc',
      ]);
      final c = sb.calls;
      final run = c.indexWhere((l) => l.startsWith('docker run -d'));
      final rm = c.indexOf('docker rm -f evcc');
      final back = c.indexOf('docker rename evcc-evccpitool-old evcc');
      final restore = c.indexOf('docker update --restart=$policy evcc');
      expect(rm, greaterThan(run), reason: 'the broken new one goes first');
      expect(back, greaterThan(rm));
      expect(restore, greaterThan(back));
      expect(c.lastIndexOf('docker start evcc'), greaterThan(restore));
    }

    test('success: the parked rollback no longer restarts on its own',
        () async {
      sb.setState('rp', 'unless-stopped:0');
      sb.setState('state', 'running|0');
      final r = await recreate();
      expect(r.code, 0, reason: '${r.out}\n${r.err}');
      expect(updates(), ['docker update --restart=no evcc-evccpitool-old']);
      expect(sb.calls, isNot(contains('docker rm -f evcc')));
    });

    test('crash loop under always: restarting is no start, it rolls back',
        () async {
      sb.setState('rp', 'always:0');
      sb.setState('state', 'restarting|2');
      expectRolledBack(await recreate(), 'always');
    });

    test('up again after a crash (RestartCount > 0) is no clean start',
        () async {
      sb.setState('rp', 'unless-stopped:0');
      sb.setState('state', 'running|1');
      expectRolledBack(await recreate(), 'unless-stopped');
    });

    test('crash on boot: on-failure keeps its retry count on rollback',
        () async {
      sb.setState('rp', 'on-failure:5');
      sb.setState('state', 'restarting|1');
      expectRolledBack(await recreate(), 'on-failure:5');
    });

    test('an exited container without a policy is rolled back without one',
        () async {
      sb.setState('rp', ':0');
      sb.setState('state', 'exited|0');
      expectRolledBack(await recreate(), 'no');
    });

    test('a new container that vanished is rolled back too', () async {
      sb.setState('rp', 'unless-stopped:0'); // no state file: inspect fails
      expectRolledBack(await recreate(), 'unless-stopped');
    });

    test('run fails: the old container gets its own policy back', () async {
      sb.setState('rp', 'always:0');
      sb.setState('run_fail');
      final r = await recreate();
      expect(r.code, 1);
      expect(updates(), [
        'docker update --restart=no evcc-evccpitool-old',
        'docker update --restart=always evcc',
      ]);
      final c = sb.calls;
      expect(c.indexOf('docker update --restart=always evcc'),
          greaterThan(c.indexOf('docker rename evcc-evccpitool-old evcc')));
      expect(c.indexOf('docker start evcc'),
          greaterThan(c.indexOf('docker update --restart=always evcc')));
    });

    test('a container without a policy is rolled back without one', () async {
      sb.setState('rp', ':0'); // older engines report an empty name
      sb.setState('run_fail');
      final r = await recreate();
      expect(r.code, 1);
      expect(updates(), [
        'docker update --restart=no evcc-evccpitool-old',
        'docker update --restart=no evcc',
      ]);
    });
  }, skip: _needsBash);

  // The config editor's write script in a REAL bash on a sandboxed "Pi": where
  // the content lands, what happens to a link or a directory at the target,
  // what a failure leaves behind — and that an account which owns the
  // directory cannot steer what root writes, owns or opens up. (The backup
  // rotation of the same script is covered in backup_scripts_test.)
  group('buildConfigWriteScript in bash', () {
    late PiSandbox pi;

    /// The plain tools this script needs beyond the sandbox's own, by path.
    final real = <String, String>{};

    setUp(() {
      pi = PiSandbox();
      for (final tool in ['base64', 'cp', 'chown', 'readlink', 'ln']) {
        real[tool] =
            (Process.runSync(sandboxBash!, ['-c', 'command -v $tool']).stdout
                    as String)
                .trim();
        pi.stub(tool, 'exec "${real[tool]}" "\$@"', log: false);
      }
    });
    tearDown(() => pi.dispose());

    /// Runs the script. [sudoUid] is the account that called sudo
    /// (`$SUDO_UID`); without one only root owns a directory in the script's
    /// eyes. The script's own descriptor (/proc/self/fd/3) is no Pi path and
    /// stays what it is.
    Future<SandboxRun> write(String path, String content, {int? sudoUid}) {
      final script = pi
          .rebase(buildConfigWriteScript(
              path: path, base64Content: base64Encode(utf8.encode(content))))
          .replaceAll('${pi.root}/proc/self/fd/', '/proc/self/fd/');
      return pi.run(
          '${sudoUid == null ? 'unset SUDO_UID' : 'export SUDO_UID=$sudoUid'}\n'
          '$script',
          rebase: false);
    }

    /// Temp files of the script still lying in [absDir].
    List<String> leftovers(String absDir) =>
        pi.ls(absDir).where((n) => n.startsWith('.pitool-cfg.')).toList();

    /// Lets `stat` answer the script's two questions from a list instead of
    /// the host, which under Git Bash knows neither owners nor real modes:
    /// the directory check (`-L -c '%f %u' -- <dir>`) from [dirs] — raw mode
    /// in hex and owner, `'/home/svc': '41ed 999'`; a directory not listed is
    /// root's, 0755, as on a Pi — and owner and mode of the file being
    /// replaced (`-c '%f +%u:+%g' -- <file>`) from [files]; a file not listed
    /// goes to the real stat, like any other question.
    ///
    /// With [realDirs] the directories of the sandbox are answered by the
    /// real stat too. Those above it never are: they are the host's (/tmp is
    /// open to everyone) and stand for the root of the Pi, which is root's.
    void fakeStat({
      Map<String, String> dirs = const {},
      Map<String, String> files = const {},
      bool realDirs = false,
    }) {
      String lines(Map<String, String> m) =>
          m.entries.map((e) => '${e.key}|${e.value}\n').join();
      pi.put('/state/stat-dirs', lines(dirs));
      pi.put('/state/stat-files', lines(files));
      pi.stub('stat', '''
last=
for a in "\$@"; do last=\$a; done
case "\$*" in
  "-L -c %f %u -- "*)
    case "\$R" in "\${last%/}"/*) echo "41ed 0"; exit 0 ;; esac
    ${realDirs ? r'exec "$REAL_STAT" "$@"' : r'list=$S/stat-dirs'} ;;
  "-c %f +%u:+%g -- "*) list=\$S/stat-files ;;
  *) exec "\$REAL_STAT" "\$@" ;;
esac
while IFS='|' read -r path answer; do
  [ "\$R\$path" = "\$last" ] && { echo "\$answer"; exit 0; }
done < "\$list"
[ "\$list" = "\$S/stat-dirs" ] && { echo "41ed 0"; exit 0; }
exec "\$REAL_STAT" "\$@"''');
    }

    /// The directories of the "Pi" the script asked `stat` about, in order
    /// (`/` is the sandbox itself).
    List<String> dirsAsked() {
      const question = 'stat -L -c %f %u -- ';
      return [
        for (final c in pi.calls)
          if (c.startsWith('$question${pi.root}'))
            c.substring(question.length + pi.root.length).isEmpty
                ? '/'
                : c.substring(question.length + pi.root.length)
      ];
    }

    /// The chown and chmod calls so far (where a test logs them).
    List<String> ownerAndModeCalls() => pi.calls
        .where((c) => c.startsWith('chown ') || c.startsWith('chmod '))
        .toList();

    /// Puts the symlink [link] → [target] on the "Pi" and says whether this
    /// host can; a [target] without a leading slash stays relative. MSYS=…:
    /// Git Bash copies instead of linking unless it is told to write a link
    /// of its own kind — one its readlink, mv and test treat like the real
    /// thing. Anywhere else the variable means nothing.
    Future<bool> symlink(String target, String link) async {
      // /dev/null stays the real one.
      final onPi = target.startsWith('/') && !target.startsWith('/dev/');
      final to = onPi ? '${pi.root}$target' : target;
      final r = await pi.run(
          "mkdir -p \"\$(dirname '${pi.root}$link')\" && "
          "MSYS=winsymlinks:sysfile ln -s '$to' "
          "'${pi.root}$link' && [ -L '${pi.root}$link' ]",
          rebase: false);
      return r.code == 0;
    }

    Future<bool> isLink(String abs) async =>
        (await pi.run("[ -L '${pi.root}$abs' ]", rebase: false)).code == 0;

    /// The script refused: its one line says why ([because]), and nothing was
    /// written — no backup, no temp file in [dirs].
    void expectRefused(SandboxRun r, String because, List<String> dirs) {
      expect(r.code, 3, reason: '${r.out}${r.err}');
      expect(r.lines, hasLength(1), reason: r.out);
      expect(r.lines.single, startsWith('CONFIG_REFUSED: '));
      expect(r.lines.single, contains(because));
      expect(pi.exists('/var/backups/pi-tool'), isFalse);
      for (final d in dirs) {
        expect(leftovers(d), isEmpty, reason: d);
      }
    }

    test('a plain file is replaced, backed up, and nothing lies next to it',
        () async {
      pi.put('/etc/evcc.yaml', 'old');
      final r = await write('/etc/evcc.yaml', 'new');
      expect(r.code, 0, reason: '${r.out}${r.err}');
      expect(r.lines.last, 'CONFIG_SAVED');
      expect(pi.read('/etc/evcc.yaml'), 'new');
      expect(leftovers('/etc'), isEmpty);
      final backups = pi.ls('/var/backups/pi-tool');
      expect(backups, hasLength(1));
      expect(pi.read('/var/backups/pi-tool/${backups.single}'), 'old');
    });

    test('a file that does not exist yet is created', () async {
      pi.put('/etc/other.conf');
      final r = await write('/etc/new.conf', 'new');
      expect(r.code, 0, reason: '${r.out}${r.err}');
      expect(r.lines.last, 'CONFIG_SAVED');
      expect(pi.read('/etc/new.conf'), 'new');
      expect(leftovers('/etc'), isEmpty);
    });

    test('a name with a space and an apostrophe is written as it is',
        () async {
      const path = "/etc/my pi's notes.conf";
      pi.put(path, 'old');
      final r = await write(path, 'new');
      expect(r.code, 0, reason: '${r.out}${r.err}');
      expect(r.lines.last, 'CONFIG_SAVED');
      expect(pi.read(path), 'new');
      expect(leftovers('/etc'), isEmpty);
    });

    test('a file of a service account is replaced in place; owner and mode '
        'reach the new file through the descriptor', () async {
      // /home/svc is nobody's the script would trust (no $SUDO_UID, not
      // root's) — a regular file is saved there all the same.
      pi.put('/home/svc/app.conf', 'old');
      fakeStat(files: {'/home/svc/app.conf': '81a0 +112:+120'});
      pi.stub('chown', 'exit 0');
      pi.stub('chmod', 'exit 0');
      final r = await write('/home/svc/app.conf', 'new');
      expect(r.code, 0, reason: '${r.out}${r.err}');
      expect(r.lines.last, 'CONFIG_SAVED');
      expect(pi.read('/home/svc/app.conf'), 'new');
      expect(leftovers('/home/svc'), isEmpty);
      // Owner first: chown may clear mode bits that chmod then sets again.
      expect(ownerAndModeCalls(), [
        'chown +112:+120 /proc/self/fd/3',
        'chmod 640 /proc/self/fd/3',
      ]);
      expect(dirsAsked(), isEmpty);
    });

    test('setuid and setgid bits of the old file are not taken over',
        () async {
      pi.put('/home/svc/tool', 'old');
      fakeStat(files: {'/home/svc/tool': '8de8 +0:+0'}); // 6750
      pi.stub('chown', 'exit 0');
      pi.stub('chmod', 'exit 0');
      final r = await write('/home/svc/tool', 'new');
      expect(r.code, 0, reason: '${r.out}${r.err}');
      expect(ownerAndModeCalls(),
          ['chown +0:+0 /proc/self/fd/3', 'chmod 750 /proc/self/fd/3']);
    });

    test('neither a link nor a missing file hands on owner or mode', () async {
      pi.stub('chown', 'exit 0');
      pi.stub('chmod', 'exit 0');
      // A link that took the place of the file after the script looked: the
      // entry itself is asked, and a link has nothing to hand on.
      pi.put('/home/svc/app.conf', 'old');
      fakeStat(files: {'/home/svc/app.conf': 'a1ff +0:+0'});
      var r = await write('/home/svc/app.conf', 'new');
      expect(r.code, 0, reason: '${r.out}${r.err}');
      // A new file stays root's alone.
      r = await write('/home/svc/new.conf', 'new');
      expect(r.code, 0, reason: '${r.out}${r.err}');
      expect(pi.read('/home/svc/new.conf'), 'new');
      expect(ownerAndModeCalls(), isEmpty);
    });

    test('a link in /etc to a file in the home of the invoking user: the '
        'file gets the content, the link stays', () async {
      pi.put('/home/pi/evcc.yaml', 'old');
      if (!await symlink('/home/pi/evcc.yaml', '/etc/evcc.yaml')) {
        markTestSkipped('this host creates no symlinks');
        return;
      }
      fakeStat(dirs: {'/etc': '41ed 0', '/home/pi': '41c0 1000'});
      final r = await write('/etc/evcc.yaml', 'new', sudoUid: 1000);
      expect(r.code, 0, reason: '${r.out}${r.err}');
      expect(r.lines.last, 'CONFIG_SAVED');
      expect(pi.read('/home/pi/evcc.yaml'), 'new');
      expect(await isLink('/etc/evcc.yaml'), isTrue);
      // Every directory a name was looked up in: down to the link, then from
      // the root again down to the file.
      expect(dirsAsked(), ['/', '/etc', '/', '/home', '/home/pi']);
      expect(leftovers('/etc'), isEmpty);
      expect(leftovers('/home/pi'), isEmpty);
      // The backup holds what the file behind the link held.
      final backups = pi.ls('/var/backups/pi-tool');
      expect(backups, hasLength(1));
      expect(backups.single, startsWith('config-evcc.yaml-'));
      expect(pi.read('/var/backups/pi-tool/${backups.single}'), 'old');
    });

    test('the same link without an invoking user: only root owns a '
        'directory, refused', () async {
      pi.put('/home/pi/evcc.yaml', 'old');
      if (!await symlink('/home/pi/evcc.yaml', '/etc/evcc.yaml')) {
        markTestSkipped('this host creates no symlinks');
        return;
      }
      fakeStat(dirs: {'/etc': '41ed 0', '/home/pi': '41c0 1000'});
      final r = await write('/etc/evcc.yaml', 'new');
      expectRefused(r, 'anderes Konto', ['/etc', '/home/pi']);
      expect(pi.read('/home/pi/evcc.yaml'), 'old');
    });

    // The attack of the release review: the account that can write to the
    // directory shows the editor a regular file and puts a link in its place
    // while it is open. Root would write the edited text to the file the
    // link names.
    for (final (what, dir) in [
      ('belongs to another account', '41ed 999'),
      ('is writable for the group', '41fd 0'),
      ('is writable for everyone', '41ef 1000'),
      ('is sticky and writable for everyone, like /tmp', '43ff 0'),
    ]) {
      test('a link in a directory that $what: refused, nothing written',
          () async {
        pi.put('/etc/cron.d/pitool', 'old');
        if (!await symlink('/etc/cron.d/pitool', '/home/svc/app.conf')) {
          markTestSkipped('this host creates no symlinks');
          return;
        }
        fakeStat(dirs: {'/home/svc': dir, '/etc/cron.d': '41ed 0'});
        final r = await write('/home/svc/app.conf', '* * * * * root id',
            sudoUid: 1000);
        expectRefused(r, 'anderes Konto', ['/home/svc', '/etc/cron.d']);
        expect(pi.read('/etc/cron.d/pitool'), 'old');
        expect(await isLink('/home/svc/app.conf'), isTrue);
      });
    }

    test('a link in /etc to a file in a directory of another account: refused',
        () async {
      pi.put('/home/svc/evcc.yaml', 'old');
      if (!await symlink('/home/svc/evcc.yaml', '/etc/evcc.yaml')) {
        markTestSkipped('this host creates no symlinks');
        return;
      }
      fakeStat(dirs: {'/etc': '41ed 0', '/home/svc': '41ed 999'});
      final r = await write('/etc/evcc.yaml', 'new', sudoUid: 1000);
      expectRefused(r, 'anderes Konto', ['/etc', '/home/svc']);
      expect(pi.read('/home/svc/evcc.yaml'), 'old');
      expect(await isLink('/etc/evcc.yaml'), isTrue);
    });

    test('a link of root that leads on through a link of another account: '
        'refused', () async {
      // Root put /etc/evcc.yaml there, but it points into the directory of a
      // service account — which has since put a link of its own at that
      // name. Both the first link and the file lie in directories of root.
      pi.put('/etc/cron.d/pitool', 'old');
      if (!await symlink('/etc/cron.d/pitool', '/home/svc/evcc.yaml') ||
          !await symlink('/home/svc/evcc.yaml', '/etc/evcc.yaml')) {
        markTestSkipped('this host creates no symlinks');
        return;
      }
      fakeStat(dirs: {'/home/svc': '41ed 999'});
      final r =
          await write('/etc/evcc.yaml', '* * * * * root id', sudoUid: 1000);
      expectRefused(r, 'anderes Konto', ['/etc', '/home/svc', '/etc/cron.d']);
      expect(pi.read('/etc/cron.d/pitool'), 'old');
    });

    test('a link of root that leads through a directory link of another '
        'account: refused', () async {
      // The same with a directory: /home/svc/conf is a link to /etc/cron.d.
      pi.put('/etc/cron.d/evcc.yaml', 'old');
      if (!await symlink('/etc/cron.d', '/home/svc/conf') ||
          !await symlink('/home/svc/conf/evcc.yaml', '/etc/evcc.yaml')) {
        markTestSkipped('this host creates no symlinks');
        return;
      }
      fakeStat(dirs: {'/home/svc': '41ed 999'});
      final r =
          await write('/etc/evcc.yaml', '* * * * * root id', sudoUid: 1000);
      expectRefused(r, 'anderes Konto', ['/etc', '/home/svc', '/etc/cron.d']);
      expect(pi.read('/etc/cron.d/evcc.yaml'), 'old');
    });

    test('a link below a directory of another account: refused, whoever '
        'owns its own directory', () async {
      // /home/svc/sub is root's — and can be exchanged as a whole by the
      // account that owns /home/svc.
      pi.put('/etc/cron.d/pitool', 'old');
      if (!await symlink('/etc/cron.d/pitool', '/home/svc/sub/app.conf')) {
        markTestSkipped('this host creates no symlinks');
        return;
      }
      fakeStat(dirs: {'/home/svc': '41ed 999'});
      final r = await write('/home/svc/sub/app.conf', '* * * * * root id',
          sudoUid: 1000);
      expectRefused(r, 'anderes Konto', ['/home/svc/sub', '/etc/cron.d']);
      expect(pi.read('/etc/cron.d/pitool'), 'old');
    });

    test('links of root on the way are followed: a directory link, a '
        'relative target, ".."', () async {
      // As on a Pi with a merged /usr: /lib -> usr/lib.
      pi.put('/usr/lib/app/app.conf', 'old');
      if (!await symlink('usr/lib', '/lib') ||
          !await symlink('../lib/app/app.conf', '/etc/app.conf')) {
        markTestSkipped('this host creates no symlinks');
        return;
      }
      fakeStat();
      final r = await write('/etc/app.conf', 'new', sudoUid: 1000);
      expect(r.code, 0, reason: '${r.out}${r.err}');
      expect(r.lines.last, 'CONFIG_SAVED');
      expect(pi.read('/usr/lib/app/app.conf'), 'new');
      expect(await isLink('/etc/app.conf'), isTrue);
      expect(await isLink('/lib'), isTrue);
      expect(dirsAsked(),
          ['/', '/etc', '/', '/', '/usr', '/usr/lib', '/usr/lib/app']);
      expect(leftovers('/usr/lib/app'), isEmpty);
    });

    test('a link that leads to no file: refused, nothing created', () async {
      pi.put('/home/pi/dir/keep');
      pi.put('/home/pi/evcc.yaml', 'old');
      if (!await symlink('/home/pi/gone.yaml', '/etc/dangling.conf') ||
          !await symlink('/home/pi/dir', '/etc/dir.conf') ||
          !await symlink('/home/pi/evcc.yaml', '/etc/evcc.yaml')) {
        markTestSkipped('this host creates no symlinks');
        return;
      }
      fakeStat(dirs: {'/etc': '41ed 0', '/home/pi': '41ed 0'});
      var r = await write('/etc/dangling.conf', 'new');
      expectRefused(r, 'keiner Datei', ['/etc', '/home/pi']);
      expect(pi.exists('/home/pi/gone.yaml'), isFalse);
      r = await write('/etc/dir.conf', 'new');
      expectRefused(r, 'keiner Datei', ['/etc', '/home/pi']);
      expect(pi.ls('/home/pi/dir'), ['keep']);
      // Where the link leads cannot be told: it is not followed on a guess.
      pi.stub('readlink', 'exit 1');
      r = await write('/etc/evcc.yaml', 'new');
      expectRefused(r, 'keiner Datei', ['/etc', '/home/pi']);
      expect(pi.read('/home/pi/evcc.yaml'), 'old');
    });

    test('two links that point at each other: refused, no endless loop',
        () async {
      // Relative targets: the script follows 40 links before it gives up and
      // asks stat for every directory on the way each time. From the root
      // again at every link, that took Git Bash longer than the default
      // timeout on a busy PC — hence the longer one as well.
      if (!await symlink('b.conf', '/etc/a.conf') ||
          !await symlink('a.conf', '/etc/b.conf')) {
        markTestSkipped('this host creates no symlinks');
        return;
      }
      fakeStat();
      final r = await write('/etc/a.conf', 'new');
      expectRefused(r, 'keiner Datei', ['/etc']);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('a link with spaces in its name and in its target is followed to '
        'the letter', () async {
      pi.put('/home/pi/my configs/evcc main.yaml', 'old');
      pi.put('/home/pi/my', 'not this one');
      if (!await symlink(
          '/home/pi/my configs/evcc main.yaml', '/etc/evcc main.yaml')) {
        markTestSkipped('this host creates no symlinks');
        return;
      }
      fakeStat();
      final r = await write('/etc/evcc main.yaml', 'new', sudoUid: 1000);
      expect(r.code, 0, reason: '${r.out}${r.err}');
      expect(r.lines.last, 'CONFIG_SAVED');
      expect(pi.read('/home/pi/my configs/evcc main.yaml'), 'new');
      expect(pi.read('/home/pi/my'), 'not this one');
      expect(await isLink('/etc/evcc main.yaml'), isTrue);
    });

    // The name of the temp file is fresh and random, and it is opened
    // exclusively: an account that owns the directory and has a link (or a
    // file) waiting under that name gets nothing written through it.
    for (final (what, place) in <(String, Future<bool> Function(String))>[
      ('a link to a file', (name) => symlink('/etc/shadow', name)),
      ('a link to nowhere', (name) => symlink('/etc/nowhere', name)),
      // No regular file: bash's noclobber opens such a name, the script
      // looks at what it got.
      ('a link to a device', (name) => symlink('/dev/null', name)),
      (
        'a file',
        (name) async {
          pi.put(name, 'theirs');
          return true;
        }
      ),
    ]) {
      test('the temp name is taken by $what: refused, nothing goes through it',
          () async {
        pi.put('/etc/shadow', 'secret');
        pi.put('/home/svc/app.conf', 'old');
        pi.stub('mktemp', r'''
last=
for a in "$@"; do last=$a; done
echo "${last%XXXXXX}taken1"''', log: false);
        const name = '/home/svc/.pitool-cfg.taken1';
        if (!await place(name)) {
          markTestSkipped('this host creates no symlinks');
          return;
        }
        final r = await write('/home/svc/app.conf', 'new');
        expect(r.code, isNot(0));
        expect(r.out, isNot(contains('CONFIG_SAVED')));
        expect(pi.read('/home/svc/app.conf'), 'old');
        expect(pi.read('/etc/shadow'), 'secret');
        expect(pi.exists('/etc/nowhere'), isFalse);
        // Not the script's file, so not the script's to remove either.
        expect(pi.exists(name), isTrue);
        if (what == 'a file') expect(pi.read(name), 'theirs');
      });
    }

    test('the temp name swapped for a link once the file exists: owner and '
        'mode go to the script\'s own file, not through the link', () async {
      pi.put('/etc/shadow', 'secret');
      pi.put('/home/svc/app.conf', 'old');
      final modes = await pi.run(
          "chmod 600 '${pi.root}/etc/shadow' && "
          "chmod 644 '${pi.root}/home/svc/app.conf'",
          rebase: false);
      expect(modes.code, 0, reason: modes.err);
      // base64 is the first command after the temp file was created: it
      // decodes as always, then does what the owner of the directory would.
      pi.stub('base64', '''
"${real['base64']}" "\$@" || exit 1
for f in "\$R"/home/svc/.pitool-cfg.*; do
  "\$REAL_RM" -f "\$f"
  MSYS=winsymlinks:sysfile "${real['ln']}" -s "\$R/etc/shadow" "\$f"
done''', log: false);
      // After the swap Git Bash no longer finds the file behind the
      // descriptor; there the calls are what counts.
      pi.stub('chown',
          Platform.isWindows ? 'exit 0' : 'exec "${real['chown']}" "\$@"');
      pi.stub('chmod', Platform.isWindows ? 'exit 0' : r'exec "$REAL_CHMOD" "$@"');
      await write('/home/svc/app.conf', 'new');
      expect(pi.read('/etc/shadow'), 'secret');
      final calls = ownerAndModeCalls();
      expect(calls, hasLength(2));
      expect(calls[0], matches(r'^chown \+\d+:\+\d+ /proc/self/fd/3$'));
      expect(calls[1], matches(r'^chmod \d+ /proc/self/fd/3$'));
      // Git Bash only emulates modes; where they are real, the mode is that
      // of the config and the file behind the link keeps its own.
      if (!Platform.isWindows) {
        expect(calls[1], 'chmod 644 /proc/self/fd/3');
        expect(await pi.mode('/etc/shadow'), '600');
      }
    });

    test('a directory at the target: nothing is moved into it, no marker',
        () async {
      pi.put('/etc/evcc.yaml/keep');
      final r = await write('/etc/evcc.yaml', 'new');
      expect(r.code, isNot(0));
      expect(r.out, isNot(contains('CONFIG_SAVED')));
      expect(pi.ls('/etc/evcc.yaml'), ['keep']);
      expect(leftovers('/etc'), isEmpty);
    });

    test('a failure after the temp file was created leaves none behind',
        () async {
      pi.put('/etc/evcc.yaml', 'old');
      pi.stub('base64', 'exit 1');
      final r = await write('/etc/evcc.yaml', 'new');
      expect(r.code, isNot(0));
      expect(r.out, isNot(contains('CONFIG_SAVED')));
      expect(pi.read('/etc/evcc.yaml'), 'old');
      expect(leftovers('/etc'), isEmpty);
    });

    // Where owners and modes are real (Linux, CI): the same decisions with the
    // real stat for everything in the sandbox. It belongs to the account
    // that runs the tests — as $SUDO_UID that is the invoking user, without
    // it a stranger.
    group('with real owners and modes', () {
      late int me;

      setUp(() async {
        me = int.parse(
            (await pi.run("stat -c %u '${pi.root}'", rebase: false)).out.trim());
        fakeStat(realDirs: true);
      });

      Future<void> chmod(String mode, String abs) async {
        final r = await pi.run("chmod $mode '${pi.root}$abs'", rebase: false);
        expect(r.code, 0, reason: r.err);
      }

      /// /etc/evcc.yaml → /home/pi/evcc.yaml (0640); every directory on the
      /// way is the test account's and closed to everyone else.
      Future<void> linkedConfig() async {
        pi.put('/home/pi/evcc.yaml', 'old');
        expect(await symlink('/home/pi/evcc.yaml', '/etc/evcc.yaml'), isTrue);
        await chmod('755', '/etc');
        await chmod('755', '/home');
        await chmod('700', '/home/pi');
        await chmod('640', '/home/pi/evcc.yaml');
      }

      test('a link between directories of the invoking user is written '
          'through, the file keeps its mode', () async {
        await linkedConfig();
        final r = await write('/etc/evcc.yaml', 'new', sudoUid: me);
        expect(r.code, 0, reason: '${r.out}${r.err}');
        expect(r.lines.last, 'CONFIG_SAVED');
        expect(pi.read('/home/pi/evcc.yaml'), 'new');
        expect(await isLink('/etc/evcc.yaml'), isTrue);
        expect(await pi.mode('/home/pi/evcc.yaml'), '640');
      });

      test('the same link once the group may write to its directory: refused',
          () async {
        await linkedConfig();
        await chmod('775', '/etc');
        final r = await write('/etc/evcc.yaml', 'new', sudoUid: me);
        expectRefused(r, 'anderes Konto', ['/etc', '/home/pi']);
        expect(pi.read('/home/pi/evcc.yaml'), 'old');
      });

      test('the same link without an invoking user: the directories are a '
          'stranger\'s, refused', () async {
        if (me == 0) {
          markTestSkipped('runs as root: every directory here is root\'s');
          return;
        }
        await linkedConfig();
        final r = await write('/etc/evcc.yaml', 'new');
        expectRefused(r, 'anderes Konto', ['/etc', '/home/pi']);
        expect(pi.read('/home/pi/evcc.yaml'), 'old');
      });

      test('a regular file keeps its permission bits, the setuid bit goes',
          () async {
        pi.put('/home/svc/tool', 'old');
        await chmod('4750', '/home/svc/tool');
        final r = await write('/home/svc/tool', 'new');
        expect(r.code, 0, reason: '${r.out}${r.err}');
        expect(pi.read('/home/svc/tool'), 'new');
        expect(await pi.mode('/home/svc/tool'), '750');
      });

      test('a new file is for its owner alone', () async {
        pi.put('/etc/other.conf');
        final r = await write('/etc/new.conf', 'new');
        expect(r.code, 0, reason: '${r.out}${r.err}');
        expect(await pi.mode('/etc/new.conf'), '600');
      });
    }, skip: Platform.isWindows ? 'needs real owners and modes' : false);
  }, skip: needsBash);
}

/// Result of one sandboxed script run.
class _Run {
  _Run(this.code, this.out, this.err);
  final int code;
  final String out;
  final String err;

  /// Non-empty stdout lines, trimmed.
  List<String> get lines => out
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
}

/// The bash for the sandbox runs — absolute, because PATH inside the sandbox
/// is the stub directory alone. On Windows `bash` may be the WSL launcher, so
/// the sandbox groups only run with an explicit Git Bash
/// (PITOOL_TEST_BASH=C:\Program Files\Git\bin\bash.exe).
final String? _bash = Platform.isWindows
    ? Platform.environment['PITOOL_TEST_BASH']
    : (Process.runSync('bash', ['-c', 'command -v bash']).stdout as String)
        .trim();

/// Skip reason for the real-bash groups, or false when a bash is at hand.
final Object _needsBash =
    _bash == null ? 'needs bash (PITOOL_TEST_BASH on Windows)' : false;

/// A path usable inside PATH (Git Bash wants /c/... there, not C:/...).
String _posix(String p) {
  final s = p.replaceAll(r'\', '/');
  final m = RegExp(r'^([A-Za-z]):/').firstMatch(s);
  return m == null ? s : '/${m.group(1)!.toLowerCase()}/${s.substring(3)}';
}

/// A throwaway "Pi" for running a real root script in a real bash. Every
/// command the script may call is a logging stub in `bin/`, and PATH holds
/// ONLY that directory, so nothing on the host (docker, apt, systemctl) can
/// leak in. Absolute Pi paths (/etc, /var, /usr, /root) are rebased into the
/// sandbox; /dev/null stays real. Stubs for commands that may read stdin
/// (apt, dpkg, docker) drain it — like under `sudo -S bash -s`, a call without
/// its own `</dev/null` then swallows the rest of the script and the marker
/// never comes.
class _Sandbox {
  _Sandbox() : _dir = Directory.systemTemp.createTempSync('pitool-sb') {
    root = _dir.path.replaceAll(r'\', '/');
    Directory('$root/bin').createSync();
    Directory(stateDir).createSync();
    for (final tool in ['cat', 'rm', 'rmdir', 'mkdir', 'readlink', 'awk']) {
      final real = (Process.runSync(_bash!, ['-c', 'command -v $tool']).stdout
              as String)
          .trim();
      stub(tool, 'exec $real "\$@"', log: false);
    }
    stub('sleep', 'exit 0', log: false);
  }

  final Directory _dir;
  late final String root;
  String get stateDir => '$root/state';

  /// Writes the executable stub [name]; each call is logged as `name args`.
  void stub(String name, String body,
      {bool log = true, bool drainStdin = false}) {
    File('$root/bin/$name').writeAsStringSync('#!/bin/sh\n'
        '${log ? 'echo "$name \$*" >> "$stateDir/calls"\n' : ''}'
        '${drainStdin ? 'cat >/dev/null\n' : ''}'
        '$body\n');
  }

  void put(String abs) =>
      File('$root$abs')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('x');

  bool exists(String abs) =>
      FileSystemEntity.typeSync('$root$abs', followLinks: false) !=
      FileSystemEntityType.notFound;

  void setState(String name, [String content = '']) =>
      File('$stateDir/$name').writeAsStringSync(content);
  void clearState(String name) {
    final f = File('$stateDir/$name');
    if (f.existsSync()) f.deleteSync();
  }

  bool hasState(String name) => File('$stateDir/$name').existsSync();
  String state(String name) => File('$stateDir/$name').readAsStringSync();

  List<String> get calls {
    final f = File('$stateDir/calls');
    return f.existsSync()
        ? f.readAsLinesSync().where((l) => l.isNotEmpty).toList()
        : const [];
  }

  /// Feeds [script] to `bash -s` on stdin, exactly like the app's root shell.
  Future<_Run> run(String script, {Map<String, String> env = const {}}) async {
    Process.runSync(_bash!, ['-c', r'chmod +x "$0"/bin/*', root]);
    final rebased = script.replaceAllMapped(
        RegExp(r'(?<![\w.$-])/(etc|var|usr|root)/'), (m) => '$root${m[0]}');
    final p = await Process.start(_bash!, ['-s'],
        environment: {'PATH': '$root/bin', ...env});
    final out = p.stdout.transform(utf8.decoder).join();
    final err = p.stderr.transform(utf8.decoder).join();
    // Stubs first, set INSIDE the shell: Git Bash's launcher puts its own
    // directories in front of an inherited PATH, so on Windows the environment
    // alone would let a real binary of the same name win over its stub. As
    // /c/…, not C:/…: bash splits PATH at every colon, drive letter included.
    p.stdin.add(
        utf8.encode("export PATH='${_posix('$root/bin')}':\"\$PATH\"\n"));
    p.stdin.add(utf8.encode(rebased));
    await p.stdin.close();
    return _Run(await p.exitCode, await out, await err);
  }

  void dispose() => _dir.deleteSync(recursive: true);
}
