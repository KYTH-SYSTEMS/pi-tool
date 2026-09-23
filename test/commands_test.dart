import 'dart:convert';
import 'dart:io';

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
    p.stdin.add(utf8.encode(rebased));
    await p.stdin.close();
    return _Run(await p.exitCode, await out, await err);
  }

  void dispose() => _dir.deleteSync(recursive: true);
}
