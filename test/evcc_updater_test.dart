import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:evcc_updater/src/commands.dart';
import 'package:evcc_updater/src/evcc_updater.dart';
import 'package:evcc_updater/src/parsing.dart';
import 'package:evcc_updater/src/services/apt_services.dart';
import 'package:evcc_updater/src/services/pi_service.dart';
import 'package:evcc_updater/src/services/pihole_service.dart';
import 'package:evcc_updater/src/services/system_service.dart';
import 'package:evcc_updater/src/ssh_runner.dart';
import 'package:flutter_test/flutter_test.dart';

// Exact command strings the updater is expected to run (see commands.dart).
const _vQuery = r"dpkg-query -W -f='${db:Status-Status} ${Version}' evcc";
const _aptUpdate = 'LC_ALL=C sudo -S apt-get update -qq';
const _aptUpgrade = 'LC_ALL=C sudo -S apt-get install --only-upgrade -y evcc';
const _aptDryRun =
    'LC_ALL=C sudo -S apt-get install --only-upgrade --dry-run evcc';
const _svc = 'systemctl is-active evcc';

const _config = SshConfig(
  host: '192.168.178.64',
  port: 22,
  username: 'pi',
  password: 'sekret',
  timeout: Duration(seconds: 10),
);

CommandResult _r(String stdout, {String stderr = '', int exitCode = 0}) =>
    CommandResult(exitCode: exitCode, stdout: stdout, stderr: stderr);

/// In-memory [SshRunner] that returns scripted output per command. A command
/// listed with several results yields them in order on successive calls (the
/// version query runs twice: before and after).
class FakeSshRunner implements SshRunner {
  final Map<String, List<CommandResult>> responses;
  final Object? connectError;

  /// Per-command error to throw from [run] (e.g. simulate a dropped connection).
  final Map<String, Object> runErrors;

  final List<String> commandsRun = [];
  final Map<String, String?> stdinByCommand = {};
  bool closed = false;
  bool connected = false;

  FakeSshRunner(this.responses,
      {this.connectError, this.runErrors = const {}});

  @override
  Future<void> connect() async {
    if (connectError != null) throw connectError!;
    connected = true;
  }

  @override
  Future<CommandResult> run(String command,
      {String? stdin, void Function(String chunk)? onOutput}) async {
    commandsRun.add(command);
    stdinByCommand[command] = stdin;

    if (runErrors.containsKey(command)) throw runErrors[command]!;

    // Detection is now a single batched command. Tests still configure the
    // per-probe outputs individually, so synthesize the batch from them.
    if (command == detectShellCommand) {
      return _r(_synthesizeDetectBatch(stdin ?? ''));
    }

    final queue = responses[command];
    final CommandResult result;
    if (queue == null || queue.isEmpty) {
      result = _r('');
    } else {
      result = queue.length > 1 ? queue.removeAt(0) : queue.first;
    }

    if (onOutput != null) {
      if (result.stdout.isNotEmpty) onOutput(result.stdout);
      if (result.stderr.isNotEmpty) onOutput(result.stderr);
    }
    return result;
  }

  /// Rebuilds the batched detection output from the individually-configured
  /// per-command [responses], so the existing per-command tests keep working
  /// unchanged. Honors [runErrors] on any probe command (throws it).
  String _synthesizeDetectBatch(String script) {
    const m = '@@PT@@';
    final b = StringBuffer();
    final lines = script.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final t = lines[i].trim();
      if (!(t.startsWith('echo $m') && t.endsWith(m) && t != 'echo $m$m')) {
        continue;
      }
      final key = t.substring('echo $m'.length, t.length - m.length);
      var cmd = (i + 1 < lines.length) ? lines[i + 1].trim() : '';
      const wrap = ' ; } 2>&1';
      if (cmd.startsWith('{ ') && cmd.contains(wrap)) {
        cmd = cmd.substring(2, cmd.indexOf(wrap));
      }
      if (runErrors.containsKey(cmd)) throw runErrors[cmd]!;
      final queue = responses[cmd];
      final outp = (queue == null || queue.isEmpty)
          ? ''
          : (queue.length > 1 ? queue.removeAt(0) : queue.first).stdout;
      b.writeln('$m$key$m');
      if (outp.isNotEmpty) b.write(outp.endsWith('\n') ? outp : '$outp\n');
    }
    return b.toString();
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

EvccUpdater _updaterWith(FakeSshRunner runner) =>
    EvccUpdater(runnerFactory: (_) => runner);

/// A runner whose [run] hangs until [close] is called — mirroring dartssh2:
/// closing the connection ends the channel stream NORMALLY, so the in-flight
/// run() RETURNS a partial result (exitCode null) rather than throwing, and a
/// subsequent run() throws because the client is gone.
class _HangingRunner implements SshRunner {
  final runStarted = Completer<void>();
  Completer<CommandResult>? _gate;
  bool closed = false;

  @override
  Future<void> connect() async {}

  @override
  Future<CommandResult> run(String command,
      {String? stdin, void Function(String chunk)? onOutput}) {
    if (closed) throw StateError('connection closed');
    if (!runStarted.isCompleted) runStarted.complete();
    _gate = Completer<CommandResult>();
    return _gate!.future;
  }

  @override
  Future<void> close() async {
    closed = true;
    if (_gate != null && !_gate!.isCompleted) {
      _gate!.complete(
          const CommandResult(exitCode: null, stdout: '', stderr: ''));
    }
  }
}

/// A runner whose connect() hangs until close() is called — models a cancel
/// arriving DURING the connect handshake.
class _ConnectHangRunner implements SshRunner {
  final connectStarted = Completer<void>();
  final _connectGate = Completer<void>();
  bool bodyRan = false;

  @override
  Future<void> connect() {
    if (!connectStarted.isCompleted) connectStarted.complete();
    return _connectGate.future;
  }

  @override
  Future<CommandResult> run(String command,
      {String? stdin, void Function(String chunk)? onOutput}) async {
    bodyRan = true;
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<void> close() async {
    if (!_connectGate.isCompleted) _connectGate.complete();
  }
}

FakeSshRunner _happyRunner() => FakeSshRunner({
      _vQuery: [_r('installed 0.310.0\n'), _r('installed 0.311.0\n')],
      _aptUpdate: [_r('')],
      _aptUpgrade: [
        _r('Setting up evcc (0.311.0) ...\n'
            '1 upgraded, 0 newly installed, 0 to remove and 27 not upgraded.')
      ],
      _svc: [_r('active\n')],
    });

void main() {
  group('EvccUpdater happy paths', () {
    test('real run upgrades evcc and reports the version change', () async {
      final runner = _happyRunner();
      final log = <String>[];

      final result = await _updaterWith(runner).run(
        config: _config,
        fullUpgrade: false,
        dryRun: false,
        onLog: log.add,
      );

      expect(result.status, UpdateStatus.updated);
      expect(result.before, '0.310.0');
      expect(result.after, '0.311.0');
      expect(result.message, 'evcc 0.310.0 → 0.311.0 aktualisiert.');
      expect(runner.closed, isTrue);
    });

    test('real run without a newer version reports already current', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('installed 0.310.0\n'), _r('installed 0.310.0\n')],
        _aptUpdate: [_r('')],
        _aptUpgrade: [
          _r('evcc is already the newest version (0.310.0).\n'
              '0 upgraded, 0 newly installed, 0 to remove and 28 not upgraded.')
        ],
        _svc: [_r('active\n')],
      });

      final result = await _updaterWith(runner).run(
        config: _config,
        fullUpgrade: false,
        dryRun: false,
        onLog: (_) {},
      );

      expect(result.status, UpdateStatus.alreadyCurrent);
    });

    test('full system upgrade: evcc unchanged, system packages upgraded',
        () async {
      const fullCmd = 'LC_ALL=C sudo -S apt-get full-upgrade -y';
      final runner = FakeSshRunner({
        _vQuery: [_r('installed 0.310.0\n'), _r('installed 0.310.0\n')],
        _aptUpdate: [_r('')],
        fullCmd: [
          _r('The following packages will be upgraded:\n  libfoo libbar\n'
              '12 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.')
        ],
        _svc: [_r('active\n')],
      });

      final result = await _updaterWith(runner).run(
        config: _config,
        fullUpgrade: true,
        dryRun: false,
        onLog: (_) {},
      );

      expect(runner.commandsRun, contains(fullCmd));
      expect(result.status, UpdateStatus.alreadyCurrent);
      expect(result.message, contains('System-Pakete'));
    });

    test('dry-run uses the --dry-run command and reports a probe', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('installed 0.310.0\n')],
        _aptUpdate: [_r('')],
        _aptDryRun: [
          _r('Inst evcc [0.310.0] (0.311.0 ...)\n'
              '1 upgraded, 0 newly installed, 0 to remove.')
        ],
        _svc: [_r('active\n')],
      });

      final result = await _updaterWith(runner).run(
        config: _config,
        fullUpgrade: false,
        dryRun: true,
        onLog: (_) {},
      );

      expect(runner.commandsRun, contains(_aptDryRun));
      expect(result.status, UpdateStatus.dryRunWouldUpdate);
    });
  });

  group('EvccUpdater password handling', () {
    test('feeds the sudo password via stdin only for the apt-get steps',
        () async {
      final runner = _happyRunner();

      await _updaterWith(runner).run(
        config: _config,
        fullUpgrade: false,
        dryRun: false,
        onLog: (_) {},
      );

      expect(runner.stdinByCommand[_aptUpdate], 'sekret\n');
      expect(runner.stdinByCommand[_aptUpgrade], 'sekret\n');
      expect(runner.stdinByCommand[_vQuery], isNull);
      expect(runner.stdinByCommand[_svc], isNull);
      expect(runner.commandsRun.any((c) => c.contains('sekret')), isFalse);
    });

    test('redacts the password if it ever surfaces in command output',
        () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('installed 0.310.0\n'), _r('installed 0.310.0\n')],
        _aptUpdate: [_r('', stderr: 'oops leaked sekret here')],
        _aptUpgrade: [
          _r('evcc is already the newest version (0.310.0).\n'
              '0 upgraded, 0 newly installed, 0 to remove and 28 not upgraded.')
        ],
        _svc: [_r('active\n')],
      });
      final log = <String>[];

      await _updaterWith(runner).run(
        config: _config,
        fullUpgrade: false,
        dryRun: false,
        onLog: log.add,
      );

      expect(log.any((l) => l.contains('sekret')), isFalse);
      expect(log.any((l) => l.contains(passwordMask)), isTrue);
    });
  });

  group('EvccUpdater.install', () {
    const installCmd = 'LC_ALL=C sudo -S bash -s';

    test('runs the install script as root, then verifies version + service',
        () async {
      final runner = FakeSshRunner({
        installCmd: [_r('Setting up evcc ...', exitCode: 0)],
        _vQuery: [_r('installed 0.310.0\n')],
        _svc: [_r('active\n')],
      });

      final res =
          await _updaterWith(runner).install(config: _config, onLog: (_) {});

      expect(res.version, '0.310.0');
      expect(res.serviceActive, isTrue);
      // Password is the FIRST stdin line (for sudo -S), not in the command.
      expect(runner.stdinByCommand[installCmd], startsWith('sekret\n'));
      expect(runner.stdinByCommand[installCmd], contains('apt-get install -y evcc'));
      expect(runner.commandsRun.any((c) => c.contains('sekret')), isFalse);
    });

    test('detects a rejected sudo password', () async {
      final runner = FakeSshRunner({
        installCmd: [
          _r('', stderr: 'sudo: 1 incorrect password attempt', exitCode: 1)
        ],
      });

      await expectLater(
        _updaterWith(runner).install(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.sudo)),
      );
    });

    test('fails when the install script exits non-zero', () async {
      final runner = FakeSshRunner({
        installCmd: [_r('E: Unable to locate package evcc', exitCode: 100)],
      });

      await expectLater(
        _updaterWith(runner).install(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()),
      );
    });
  });

  group('EvccUpdater error handling', () {
    test('maps a socket failure to a connection error', () async {
      final runner = FakeSshRunner({}, connectError: SocketException('refused'));

      await expectLater(
        _updaterWith(runner).run(
            config: _config, fullUpgrade: false, dryRun: false, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.connection)),
      );
    });

    test('maps an SSH auth failure to an auth error', () async {
      final runner =
          FakeSshRunner({}, connectError: SSHAuthFailError('no auth methods'));

      await expectLater(
        _updaterWith(runner).run(
            config: _config, fullUpgrade: false, dryRun: false, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.auth)),
      );
    });

    test('detects a rejected sudo password and still cleans up', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('installed 0.310.0\n')],
        _aptUpdate: [
          _r('', stderr: 'sudo: 1 incorrect password attempt', exitCode: 1)
        ],
      });

      await expectLater(
        _updaterWith(runner).run(
            config: _config, fullUpgrade: false, dryRun: false, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.sudo)),
      );
      expect(runner.closed, isTrue);
    });

    test('a failed apt-get update (unreachable repo) does NOT block the upgrade',
        () async {
      // i==1 (apt-get update) may exit non-zero on a flaky third-party repo;
      // that must not abort an otherwise-fine evcc upgrade (only i==2 is gated).
      final runner = FakeSshRunner({
        _vQuery: [_r('installed 0.310.0\n'), _r('installed 0.311.0\n')],
        _aptUpdate: [
          _r('', stderr: 'Failed to fetch http://other.repo', exitCode: 100)
        ],
        _aptUpgrade: [_r('1 upgraded, 0 newly installed')],
        _svc: [_r('active\n')],
      });

      final result = await _updaterWith(runner).run(
          config: _config, fullUpgrade: false, dryRun: false, onLog: (_) {});

      expect(result.status, UpdateStatus.updated);
    });

    test('a non-zero apt step is a hard error, not a false "already current"',
        () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('installed 0.310.0\n'), _r('installed 0.310.0\n')],
        _aptUpdate: [_r('')],
        _aptUpgrade: [
          _r('E: Could not get lock /var/lib/dpkg/lock-frontend', exitCode: 100)
        ],
        _svc: [_r('active\n')],
      });

      await expectLater(
        _updaterWith(runner).run(
            config: _config, fullUpgrade: false, dryRun: false, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.message, 'message', contains('fehlgeschlagen'))),
      );
    });

    test('fails when the service is not active after a real upgrade', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('installed 0.310.0\n'), _r('installed 0.311.0\n')],
        _aptUpdate: [_r('')],
        _aptUpgrade: [_r('1 upgraded, 0 newly installed')],
        _svc: [_r('inactive\n', exitCode: 3)],
      });

      await expectLater(
        _updaterWith(runner).run(
            config: _config, fullUpgrade: false, dryRun: false, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.serviceInactive)),
      );
    });

    test('fails clearly when evcc is not installed', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('', stderr: 'no packages found matching evcc', exitCode: 1)],
      });

      await expectLater(
        _updaterWith(runner).run(
            config: _config, fullUpgrade: false, dryRun: false, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.packageMissing)),
      );
    });

    test('maps a private-key decode failure to an auth error', () async {
      final runner =
          FakeSshRunner({}, connectError: SSHKeyDecodeError('malformed key'));

      await expectLater(
        _updaterWith(runner).run(
            config: _config, fullUpgrade: false, dryRun: false, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.auth)),
      );
    });

    test('maps a changed host key to a hostKeyChanged error', () async {
      final runner = FakeSshRunner({},
          connectError: const HostKeyChangedException(
            host: '192.168.178.64',
            port: 22,
            presented: 'SHA256:new',
            stored: 'SHA256:old',
          ));

      await expectLater(
        _updaterWith(runner).run(
            config: _config, fullUpgrade: false, dryRun: false, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.hostKeyChanged)),
      );
    });
  });

  group('EvccUpdater admin actions', () {
    test('restartService restarts (sudo) and confirms the service is active',
        () async {
      final runner = FakeSshRunner({
        serviceRestartCommand: [_r('')],
        _svc: [_r('active\n')],
      });

      await _updaterWith(runner)
          .restartService(config: _config, onLog: (_) {});

      expect(runner.commandsRun, contains(serviceRestartCommand));
      expect(runner.stdinByCommand[serviceRestartCommand], 'sekret\n');
    });

    test('restartService reports a rejected sudo password', () async {
      final runner = FakeSshRunner({
        serviceRestartCommand: [
          _r('', stderr: 'sudo: 1 incorrect password attempt', exitCode: 1)
        ],
      });

      await expectLater(
        _updaterWith(runner).restartService(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.sudo)),
      );
    });

    test('restartService fails if the service is not active afterwards',
        () async {
      final runner = FakeSshRunner({
        serviceRestartCommand: [_r('')],
        _svc: [_r('inactive\n')],
      });

      await expectLater(
        _updaterWith(runner).restartService(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.serviceInactive)),
      );
    });

    test('reboot tolerates the connection dropping (success)', () async {
      final runner = FakeSshRunner({},
          runErrors: {rebootCommand: const SocketException('connection closed')});

      // Must NOT throw — a dropped connection is the expected outcome.
      await _updaterWith(runner).reboot(config: _config, onLog: (_) {});
    });

    test('reboot reports a rejected sudo password (no disconnect)', () async {
      final runner = FakeSshRunner({
        rebootCommand: [
          _r('', stderr: 'sudo: 1 incorrect password attempt', exitCode: 1)
        ],
      });

      await expectLater(
        _updaterWith(runner).reboot(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.sudo)),
      );
    });

    test('fetchStatus returns the systemctl status output', () async {
      final runner = FakeSshRunner({
        statusCommand: [
          _r('● evcc.service - evcc\n   Active: active (running) since ...')
        ],
      });

      final status =
          await _updaterWith(runner).fetchStatus(config: _config, onLog: (_) {});

      expect(status, contains('active (running)'));
      expect(runner.commandsRun, contains(statusCommand));
    });

    test('fetchStatus runs a custom command and pipes the password when sudo',
        () async {
      const cmd = "docker logs --tail 80 'evcc'";
      final runner = FakeSshRunner({
        cmd: [_r('starting evcc ...\nlistening on :7070')]
      });

      final status = await _updaterWith(runner).fetchStatus(
          config: _config, command: cmd, sudo: true, onLog: (_) {});

      expect(status, contains('listening on :7070'));
      expect(runner.commandsRun, contains(cmd));
      expect(runner.stdinByCommand[cmd], 'sekret\n'); // password piped
    });
  });

  group('EvccUpdater.backup', () {
    final backupCmd = installShellCommand;

    test('returns the archive path; password only via stdin', () async {
      final runner = FakeSshRunner({
        backupCmd: [
          _r('EVCC_BACKUP_OK /var/backups/evcc/evcc-backup-x.tar.gz',
              exitCode: 0)
        ],
      });

      final path =
          await _updaterWith(runner).backup(config: _config, onLog: (_) {});

      expect(path, '/var/backups/evcc/evcc-backup-x.tar.gz');
      expect(runner.stdinByCommand[backupCmd], startsWith('sekret\n'));
      expect(runner.commandsRun.any((c) => c.contains('sekret')), isFalse);
    });

    test('returns null when there is nothing to back up (not an error)',
        () async {
      final runner =
          FakeSshRunner({backupCmd: [_r('EVCC_BACKUP_EMPTY', exitCode: 0)]});
      expect(
        await _updaterWith(runner).backup(config: _config, onLog: (_) {}),
        isNull,
      );
    });

    test('throws on a rejected sudo password', () async {
      final runner = FakeSshRunner({
        backupCmd: [
          _r('', stderr: 'sudo: 1 incorrect password attempt', exitCode: 1)
        ],
      });
      await expectLater(
        _updaterWith(runner).backup(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.sudo)),
      );
    });

    test('throws when the backup script fails', () async {
      final runner =
          FakeSshRunner({backupCmd: [_r('EVCC_BACKUP_FAIL', exitCode: 1)]});
      await expectLater(
        _updaterWith(runner).backup(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()),
      );
    });
  });

  group('EvccUpdater backup restore', () {
    test('listBackups parses the archive paths newest-first', () async {
      final runner = FakeSshRunner({
        listBackupsCommand: [
          _r('/var/backups/evcc/evcc-backup-20260630-120000.tar.gz\n'
              '/var/backups/evcc/evcc-backup-20260628-090000.tar.gz\n')
        ],
      });
      final list =
          await _updaterWith(runner).listBackups(config: _config, onLog: (_) {});
      expect(list.first, endsWith('20260630-120000.tar.gz'));
      expect(list.length, 2);
    });

    test('restoreBackup runs the restore as root and verifies evcc is active',
        () async {
      const path = '/var/backups/evcc/evcc-backup-20260630-120000.tar.gz';
      final runner = FakeSshRunner({
        installShellCommand: [_r('Wiederhergestellt.')],
        _svc: [_r('active\n')],
      });
      await _updaterWith(runner)
          .restoreBackup(config: _config, path: path, onLog: (_) {});
      final stdin = runner.stdinByCommand[installShellCommand]!;
      expect(stdin, startsWith('sekret\n'));
      expect(stdin, contains("tar -xzf '$path' -C /"));
      expect(stdin, contains('systemctl start evcc'));
    });

    test('restoreBackup fails when evcc is not active after the restore',
        () async {
      const path = '/var/backups/evcc/evcc-backup-20260630-120000.tar.gz';
      final runner = FakeSshRunner({
        installShellCommand: [_r('Wiederhergestellt.')],
        _svc: [_r('inactive\n')], // restored config crashes evcc on start
      });
      await expectLater(
        _updaterWith(runner).restoreBackup(config: _config, path: path, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.serviceInactive)),
      );
    });

    test('restoreBackup rejects a path outside the backup dir', () async {
      final runner = FakeSshRunner({});
      await expectLater(
        _updaterWith(runner).restoreBackup(
            config: _config, path: '/etc/passwd', onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()),
      );
      expect(runner.commandsRun, isEmpty); // never connected/ran anything
    });
  });

  group('EvccUpdater service backups', () {
    test('backupPihole runs the teleporter as root and returns the path',
        () async {
      final runner = FakeSshRunner({
        installShellCommand: [
          _r('BACKUP_OK /var/backups/pi-tool/pihole-backup-20260702-100000.tar.gz\n')
        ],
      });
      final path =
          await _updaterWith(runner).backupPihole(config: _config, onLog: (_) {});
      expect(path, endsWith('pihole-backup-20260702-100000.tar.gz'));
      expect(runner.stdinByCommand[installShellCommand], startsWith('sekret\n'));
    });

    test('backupPihole surfaces a Pi-hole-specific error on no marker',
        () async {
      final runner = FakeSshRunner({
        installShellCommand: [_r('BACKUP_FAIL', exitCode: 1)],
      });
      await expectLater(
        _updaterWith(runner).backupPihole(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>().having(
            (e) => e.message, 'message', contains('Pi-hole-Backup'))),
      );
    });

    test('backupHomeAssistant tars the /config dir found via inspect', () async {
      final inspectCmd = dockerInspectJsonCommand('homeassistant');
      final runner = FakeSshRunner({
        dockerListCommand: [
          _r('homeassistant|ghcr.io/home-assistant/home-assistant:stable\n')
        ],
        inspectCmd: [
          _r('[{"Name":"/homeassistant","Mounts":['
              '{"Type":"bind","Source":"/opt/homeassistant/config","Destination":"/config"}]}]')
        ],
        installShellCommand: [
          _r('BACKUP_OK /var/backups/pi-tool/homeassistant-backup-x.tar.gz\n')
        ],
      });
      final path = await _updaterWith(runner)
          .backupHomeAssistant(config: _config, onLog: (_) {});
      expect(path, contains('homeassistant-backup'));
      final stdin = runner.stdinByCommand[installShellCommand]!;
      expect(stdin, contains("-C '/opt/homeassistant/config'"));
    });
  });

  group('EvccUpdater.installAptService', () {
    test('installs the service by running its script as root', () async {
      final grafana = knownAptServices.firstWhere((s) => s.id == 'grafana');
      final runner = FakeSshRunner({
        installShellCommand: [_r('...\nSetting up grafana ...\n')],
      });
      await _updaterWith(runner)
          .installAptService(config: _config, service: grafana, onLog: (_) {});
      final stdin = runner.stdinByCommand[installShellCommand]!;
      expect(stdin, startsWith('sekret\n')); // sudo password piped first
      expect(stdin, contains('apt.grafana.com')); // the service's script ran
    });

    test('a rejected sudo password is surfaced as a sudo error', () async {
      final mosquitto = knownAptServices.firstWhere((s) => s.id == 'mosquitto');
      final runner = FakeSshRunner({
        installShellCommand: [_r('sudo: 1 incorrect password attempt', exitCode: 1)],
      });
      await expectLater(
        _updaterWith(runner)
            .installAptService(config: _config, service: mosquitto, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.sudo)),
      );
    });
  });

  group('EvccUpdater.runConsoleCommand', () {
    test('runs a plain command, echoes it and streams the output', () async {
      final runner = FakeSshRunner({
        'df -h': [_r('Filesystem Size\n/dev/root 30G\n')],
      });
      final logs = <String>[];
      final out = await _updaterWith(runner)
          .runConsoleCommand(config: _config, command: 'df -h', onLog: logs.add);
      expect(out, contains('/dev/root'));
      expect(logs, contains(r'$ df -h')); // the command is echoed
    });

    test('pipes the Pi password for a sudo command', () async {
      const exec = "sudo -S -p '' systemctl restart evcc";
      final runner = FakeSshRunner({exec: [_r('')]});
      await _updaterWith(runner).runConsoleCommand(
          config: _config,
          command: 'sudo systemctl restart evcc',
          onLog: (_) {});
      expect(runner.stdinByCommand[exec], startsWith('sekret\n'));
    });

    test('a rejected sudo password surfaces as a sudo error', () async {
      const exec = "sudo -S -p '' apt-get update";
      final runner = FakeSshRunner({
        exec: [_r('sudo: 1 incorrect password attempt', exitCode: 1)],
      });
      await expectLater(
        _updaterWith(runner).runConsoleCommand(
            config: _config, command: 'sudo apt-get update', onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.sudo)),
      );
    });
  });

  group('EvccUpdater.reboot', () {
    test('reports failure on a non-zero, non-password exit', () async {
      final runner = FakeSshRunner({
        rebootCommand: [
          _r('', stderr: 'reboot: Operation not permitted', exitCode: 1)
        ],
      });
      await expectLater(
        _updaterWith(runner).reboot(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()),
      );
    });

    test('treats a dropped connection as success', () async {
      final runner = FakeSshRunner({},
          runErrors: {rebootCommand: const SocketException('closed')});
      // A real reboot drops the SSH connection — must NOT be reported as an error.
      await _updaterWith(runner).reboot(config: _config, onLog: (_) {});
    });
  });

  group('EvccUpdater.cancel', () {
    test('closes the connection and surfaces a cancelled error', () async {
      final runner = _HangingRunner();
      final updater = EvccUpdater(runnerFactory: (_) => runner);
      final f = updater.detectServices(config: _config, onLog: (_) {});
      await runner.runStarted.future; // a command is now in flight
      await updater.cancel();
      await expectLater(
        f,
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.cancelled)),
      );
      expect(runner.closed, isTrue);
    });

    test('cancel during connect stops before the (destructive) body runs',
        () async {
      final runner = _ConnectHangRunner();
      final updater = EvccUpdater(runnerFactory: (_) => runner);
      final f = updater.upgradeSystem(config: _config, onLog: (_) {});
      await runner.connectStarted.future;
      await updater.cancel(); // flag + close() completes the connect handshake
      await expectLater(
        f,
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.cancelled)),
      );
      expect(runner.bodyRan, isFalse); // the action never executed on the Pi
    });

    test('a single-command action reports cancelled, not false success',
        () async {
      // A single run() returns normally on a mid-command close (dartssh2), so
      // this must rely on the post-body cancel check, not on run() throwing.
      final runner = _HangingRunner();
      final updater = EvccUpdater(runnerFactory: (_) => runner);
      final f = updater.updatePihole(config: _config, onLog: (_) {});
      await runner.runStarted.future;
      await updater.cancel();
      await expectLater(
        f,
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.cancelled)),
      );
    });
  });

  group('EvccUpdater.detectServices', () {
    test('detects evcc(apt) + Pi-hole + System in one pass', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('installed 0.310.0\n')],
        _svc: [_r('active\n')],
        piholeVersionCommand: [_r('Core version is v6.0.4 (Latest: v6.1.0)')],
        piholeStatusCommand: [_r('[✓] Pi-hole blocking is enabled')],
        systemOsCommand: [_r('PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"')],
        systemPendingCommand: [_r('3 upgraded, 0 newly installed, 0 to remove.')],
      });

      final list =
          await _updaterWith(runner).detectServices(config: _config, onLog: (_) {});
      final byId = {for (final s in list) s.id: s};

      expect(byId['evcc']!.installed, isTrue);
      expect(byId['evcc']!.version, '0.310.0');
      // apt-evcc currency is known; this sim has no "Inst evcc" line.
      expect(byId['evcc']!.updateKnown, isTrue);
      expect(byId['evcc']!.updateAvailable, isFalse);
      expect(byId['pihole']!.installed, isTrue);
      expect(byId['pihole']!.version, 'v6.0.4');
      expect(byId['pihole']!.updateAvailable, isTrue);
      expect(byId['system']!.version, contains('Debian'));
      expect(byId['system']!.updateAvailable, isTrue);
    });

    test('evcc(apt) shows an update when the apt sim would upgrade it',
        () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('installed 0.310.0\n')],
        _svc: [_r('active\n')],
        systemPendingCommand: [
          _r('Inst evcc [0.310.0] (0.311.0 evcc:armhf [armhf])\n'
              'Conf evcc (0.311.0 evcc:armhf [armhf])\n'
              '1 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.')
        ],
        piholeVersionCommand: [_r('')],
        systemOsCommand: [_r('PRETTY_NAME="Debian GNU/Linux 12"')],
      });

      final list =
          await _updaterWith(runner).detectServices(config: _config, onLog: (_) {});
      final evcc = list.firstWhere((s) => s.id == 'evcc');
      expect(evcc.updateKnown, isTrue);
      expect(evcc.updateAvailable, isTrue);
    });

    test('evcc(apt) update detected even when apt arch-qualifies the name',
        () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('installed 0.310.0\n')],
        _svc: [_r('active\n')],
        systemPendingCommand: [
          _r('Inst evcc:arm64 [0.310.0] (0.311.0 evcc:arm64 [arm64])\n'
              '1 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.')
        ],
        piholeVersionCommand: [_r('')],
        systemOsCommand: [_r('PRETTY_NAME="Debian GNU/Linux 12"')],
      });
      final list =
          await _updaterWith(runner).detectServices(config: _config, onLog: (_) {});
      expect(list.firstWhere((s) => s.id == 'evcc').updateAvailable, isTrue);
    });

    test('System card carries vitals (temp, disk, RAM) with low-disk warning',
        () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('installed 0.310.0\n')],
        _svc: [_r('active\n')],
        piholeVersionCommand: [_r('')],
        systemOsCommand: [_r('PRETTY_NAME="Debian GNU/Linux 12"')],
        systemPendingCommand: [_r('0 upgraded, 0 newly installed.')],
        systemTempCommand: [_r("temp=51.2'C\n")],
        systemDiskCommand: [
          _r('Filesystem 1048576-blocks Used Available Capacity Mounted on\n'
              '/dev/root 29000M 27500M 900M 95% /\n')
        ],
        systemMemCommand: [
          _r('      total used free shared buff/cache available\n'
              'Mem:   430  180   50      9        200       240\n')
        ],
        systemUptimeCommand: [_r('up 5 days\n')],
      });

      final list =
          await _updaterWith(runner).detectServices(config: _config, onLog: (_) {});
      final sys = list.firstWhere((s) => s.id == 'system');
      expect(sys.health, contains('51.2°C'));
      expect(sys.health, contains('900 MB frei'));
      expect(sys.health, contains('up 5 days'));
      expect(sys.healthWarning, isTrue); // 95% used → low-disk warning
      expect(sys.health, contains('Speicher fast voll'));
    });

    test('detects an installed Grafana (card only when installed)', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('installed 0.310.0\n')],
        _svc: [_r('active\n')],
        piholeVersionCommand: [_r('')],
        aptServicesQuery: [_r('grafana installed 13.1.0\n')],
        'systemctl is-active grafana-server': [_r('active\n')],
        systemOsCommand: [_r('PRETTY_NAME="Debian"')],
        systemPendingCommand: [
          _r('Inst grafana [13.1.0] (13.2.0 grafana:arm64 [arm64])\n'
              '1 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.')
        ],
      });

      final list =
          await _updaterWith(runner).detectServices(config: _config, onLog: (_) {});
      final g = list.firstWhere((s) => s.id == 'grafana');
      expect(g.installed, isTrue);
      expect(g.version, '13.1.0');
      expect(g.active, isTrue);
      expect(g.updateAvailable, isTrue);
      expect(g.webPort, 3000);
      expect(g.aptPackage, 'grafana');
      // InfluxDB is NOT installed → no card at all.
      expect(list.any((s) => s.id == 'influxdb'), isFalse);
    });

    test('InfluxDB v1 gets no web button, v2 does', () async {
      Future<List<ServiceStatus>> detect(String pkgLine) {
        final runner = FakeSshRunner({
          _vQuery: [_r('installed 0.310.0\n')],
          _svc: [_r('active\n')],
          piholeVersionCommand: [_r('')],
          aptServicesQuery: [_r(pkgLine)],
          'systemctl is-active influxdb': [_r('active\n')],
          systemOsCommand: [_r('PRETTY_NAME="Debian"')],
          systemPendingCommand: [_r('0 upgraded, 0 newly installed.')],
        });
        return _updaterWith(runner)
            .detectServices(config: _config, onLog: (_) {});
      }

      final v1 = await detect('influxdb installed 1.8.10-1\n');
      expect(v1.firstWhere((s) => s.id == 'influxdb').webPort, isNull);

      final v2 = await detect('influxdb2 installed 2.7.6\n');
      final s2 = v2.firstWhere((s) => s.id == 'influxdb');
      expect(s2.webPort, 8086);
      expect(s2.aptPackage, 'influxdb2');
    });

    test('apt-service update flag matches only the INSTALLED package', () async {
      // v1 influxdb installed; the sim would install influxdb2 as something
      // NEW — that is not an update for this card.
      final runner = FakeSshRunner({
        _vQuery: [_r('installed 0.310.0\n')],
        _svc: [_r('active\n')],
        piholeVersionCommand: [_r('')],
        aptServicesQuery: [_r('influxdb installed 1.8.10-1\n')],
        'systemctl is-active influxdb': [_r('active\n')],
        systemOsCommand: [_r('PRETTY_NAME="Debian"')],
        systemPendingCommand: [
          _r('Inst influxdb2 (2.7.6 influxdata:arm64 [arm64])\n'
              '0 upgraded, 1 newly installed, 0 to remove and 0 not upgraded.')
        ],
      });
      final list =
          await _updaterWith(runner).detectServices(config: _config, onLog: (_) {});
      expect(
          list.firstWhere((s) => s.id == 'influxdb').updateAvailable, isFalse);
    });

    test('updateAptPackage refreshes tolerantly then only-upgrades the package',
        () async {
      const upd = 'LC_ALL=C sudo -S apt-get update -qq';
      const upg = 'LC_ALL=C sudo -S apt-get install --only-upgrade -y grafana';
      final runner = FakeSshRunner({
        upd: [_r('', stderr: 'Failed to fetch', exitCode: 100)], // tolerated
        upg: [_r('1 upgraded, 0 newly installed', exitCode: 0)],
      });
      await _updaterWith(runner).updateAptPackage(
          config: _config, package: 'grafana', onLog: (_) {});
      expect(runner.commandsRun, contains(upg));
      expect(runner.stdinByCommand[upg], 'sekret\n');
    });

    test('a failed apt simulation leaves evcc + System updateKnown=false',
        () async {
      // Broken/locked apt: no "N upgraded" summary + non-zero exit. The app must
      // NOT claim "Aktuell" — updateKnown stays false so it keeps offering it.
      final runner = FakeSshRunner({
        _vQuery: [_r('installed 0.310.0\n')],
        _svc: [_r('active\n')],
        systemPendingCommand: [
          _r('', stderr: 'E: Could not get lock /var/lib/dpkg/lock', exitCode: 100)
        ],
        piholeVersionCommand: [_r('')],
        systemOsCommand: [_r('PRETTY_NAME="Debian"')],
      });
      final list =
          await _updaterWith(runner).detectServices(config: _config, onLog: (_) {});
      final byId = {for (final s in list) s.id: s};
      expect(byId['evcc']!.updateKnown, isFalse);
      expect(byId['evcc']!.updateAvailable, isFalse);
      expect(byId['system']!.updateKnown, isFalse);
    });

    test('a connection timeout maps to a connection error', () async {
      final runner = FakeSshRunner({}, connectError: TimeoutException('x'));
      await expectLater(
        _updaterWith(runner).detectServices(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.connection)),
      );
    });

    test('a generic SSHError maps to unknown with an "SSH-Fehler" message',
        () async {
      final runner = FakeSshRunner({},
          runErrors: {dockerListCommand: SSHStateError('boom')});
      await expectLater(
        _updaterWith(runner).detectServices(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.unknown)
            .having((e) => e.message, 'message', contains('SSH-Fehler'))),
      );
    });

    test('a declined first-use host key maps to a clear connection error',
        () async {
      final runner =
          FakeSshRunner({}, connectError: const HostKeyDeclinedException());
      await expectLater(
        _updaterWith(runner).detectServices(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.connection)
            .having((e) => e.message, 'message', contains('nicht bestätigt'))),
      );
    });

    test('Pi-hole reported absent when not installed', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('installed 0.310.0\n')],
        _svc: [_r('active\n')],
        piholeVersionCommand: [_r('')],
        systemOsCommand: [_r('PRETTY_NAME="Raspbian"')],
        systemPendingCommand: [_r('0 upgraded, 0 newly installed.')],
      });

      final list =
          await _updaterWith(runner).detectServices(config: _config, onLog: (_) {});
      expect(list.firstWhere((s) => s.id == 'pihole').installed, isFalse);
      expect(list.firstWhere((s) => s.id == 'system').updateAvailable, isFalse);
    });

    test('detects a Home Assistant container from docker ps', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('installed 0.310.0\n')],
        _svc: [_r('active\n')],
        dockerListCommand: [
          _r('homeassistant|ghcr.io/home-assistant/home-assistant:stable\n')
        ],
        piholeVersionCommand: [_r('')],
        systemOsCommand: [_r('PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"')],
        systemPendingCommand: [_r('0 upgraded, 0 newly installed.')],
      });

      final list =
          await _updaterWith(runner).detectServices(config: _config, onLog: (_) {});
      final ha = list.firstWhere((s) => s.id == 'homeassistant');
      expect(ha.installed, isTrue);
      expect(ha.version, 'stable');
    });
  });

  group('EvccUpdater Home Assistant actions', () {
    test('installHomeAssistant installs as root, then verifies it is running',
        () async {
      final runner = FakeSshRunner({
        installShellCommand: [_r('Home Assistant gestartet.')],
        dockerListCommand: [
          _r('homeassistant|ghcr.io/home-assistant/home-assistant:stable\n')
        ],
      });
      await _updaterWith(runner)
          .installHomeAssistant(config: _config, onLog: (_) {});
      expect(runner.commandsRun, contains(installShellCommand));
      final stdin = runner.stdinByCommand[installShellCommand]!;
      expect(stdin, startsWith('sekret\n')); // sudo password consumed first
      expect(stdin, contains('ghcr.io/home-assistant/home-assistant:stable'));
    });

    test('installHomeAssistant surfaces a Home-Assistant-specific error',
        () async {
      final runner = FakeSshRunner({
        installShellCommand: [_r('boom', exitCode: 1)],
      });
      await expectLater(
        _updaterWith(runner).installHomeAssistant(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>().having((e) => e.message, 'message',
            contains('Home-Assistant-Installation'))),
      );
    });

    test('installHomeAssistant fails when the container is not running after',
        () async {
      final runner = FakeSshRunner({
        installShellCommand: [_r('')],
        dockerListCommand: [_r('evcc|evcc/evcc:latest\n')], // no HA came up
      });
      await expectLater(
        _updaterWith(runner).installHomeAssistant(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.serviceInactive)),
      );
    });

    test('updateHomeAssistant pulls + recreates the container (no sudo)',
        () async {
      final inspectCmd = dockerInspectJsonCommand('homeassistant');
      final runner = FakeSshRunner({
        dockerListCommand: [
          _r('homeassistant|ghcr.io/home-assistant/home-assistant:stable\n')
        ],
        inspectCmd: [
          _r('[{"Name":"/homeassistant","Config":{"Image":'
              '"ghcr.io/home-assistant/home-assistant:stable"},"HostConfig":'
              '{"NetworkMode":"host","Privileged":true,"Binds":'
              '["/opt/homeassistant/config:/config"]}}]')
        ],
        'bash -s': [_r('')],
      });
      await _updaterWith(runner)
          .updateHomeAssistant(config: _config, onLog: (_) {});
      final recreate = runner.stdinByCommand['bash -s']!;
      expect(recreate, contains('docker pull'));
      expect(recreate, contains('ghcr.io/home-assistant/home-assistant:stable'));
    });

    test('updateHomeAssistant uses docker compose for a compose-managed HA',
        () async {
      final inspectCmd = dockerInspectJsonCommand('homeassistant');
      final runner = FakeSshRunner({
        dockerListCommand: [
          _r('homeassistant|ghcr.io/home-assistant/home-assistant:stable\n')
        ],
        inspectCmd: [
          _r(jsonEncode([
            {
              'Name': '/homeassistant',
              'Config': {
                'Image': 'ghcr.io/home-assistant/home-assistant:stable',
                'Labels': {
                  'com.docker.compose.project.working_dir': '/home/pi/ha',
                  'com.docker.compose.project.config_files':
                      '/home/pi/ha/docker-compose.yml',
                  'com.docker.compose.service': 'homeassistant',
                  'com.docker.compose.project': 'ha',
                },
              },
              'HostConfig': <String, dynamic>{},
            }
          ]))
        ],
        'bash -s': [_r('')],
      });
      await _updaterWith(runner)
          .updateHomeAssistant(config: _config, onLog: (_) {});
      final script = runner.stdinByCommand['bash -s']!;
      expect(script, contains('docker compose'));
      expect(script, contains('/home/pi/ha'));
    });

    test('updateHomeAssistant fails clearly when no HA container exists',
        () async {
      final runner = FakeSshRunner({
        dockerListCommand: [_r('evcc|evcc/evcc:latest\n')],
      });
      await expectLater(
        _updaterWith(runner).updateHomeAssistant(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>().having((e) => e.message, 'message',
            contains('Home-Assistant-Container'))),
      );
    });
  });

  group('EvccUpdater Pi-hole + System actions', () {
    test('updatePihole runs pihole -up with the password via stdin', () async {
      final runner =
          FakeSshRunner({piholeUpdateCommand: [_r('[✓] Update complete')]});
      await _updaterWith(runner).updatePihole(config: _config, onLog: (_) {});
      expect(runner.commandsRun, contains(piholeUpdateCommand));
      expect(runner.stdinByCommand[piholeUpdateCommand], 'sekret\n');
      expect(runner.commandsRun.any((c) => c.contains('sekret')), isFalse);
    });

    test('updatePihole maps a rejected sudo password', () async {
      final runner = FakeSshRunner({
        piholeUpdateCommand: [
          _r('', stderr: 'sudo: 1 incorrect password attempt', exitCode: 1)
        ],
      });
      await expectLater(
        _updaterWith(runner).updatePihole(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.sudo)),
      );
    });

    test('upgradeSystem runs full-upgrade and tolerates a failed apt update',
        () async {
      const upd = 'LC_ALL=C sudo -S apt-get update -qq';
      const full = 'LC_ALL=C sudo -S apt-get full-upgrade -y';
      final runner = FakeSshRunner({
        upd: [_r('', stderr: 'Failed to fetch', exitCode: 100)],
        full: [_r('12 upgraded, 0 newly installed', exitCode: 0)],
      });
      await _updaterWith(runner).upgradeSystem(config: _config, onLog: (_) {});
      expect(runner.commandsRun, contains(full));
    });
  });

  group('EvccUpdater.detectInstall', () {
    test('apt: a dpkg version means an apt install + service state', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('installed 0.310.0\n')],
        _svc: [_r('active\n')],
      });

      final d =
          await _updaterWith(runner).detectInstall(config: _config, onLog: (_) {});

      expect(d.kind, InstallKind.apt);
      expect(d.aptVersion, '0.310.0');
      expect(d.serviceActive, isTrue);
      // Detection must not touch docker when apt is present.
      expect(runner.commandsRun, isNot(contains(dockerListCommand)));
    });

    test('docker: no apt package but an evcc container (no sudo needed)',
        () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('\n')],
        dockerListCommand: [_r('db|postgres:16\nevcc|evcc/evcc:latest\n')],
      });

      final d =
          await _updaterWith(runner).detectInstall(config: _config, onLog: (_) {});

      expect(d.kind, InstallKind.docker);
      expect(d.container!.name, 'evcc');
      expect(d.dockerNeedsSudo, isFalse);
    });

    test('docker: retries via sudo when the daemon denies access', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('\n')],
        dockerListCommand: [
          _r('',
              stderr: 'permission denied while trying to connect to the '
                  'Docker daemon socket',
              exitCode: 1)
        ],
        dockerListSudoCommand: [_r('evcc|evcc/evcc:latest\n')],
      });

      final d =
          await _updaterWith(runner).detectInstall(config: _config, onLog: (_) {});

      expect(d.kind, InstallKind.docker);
      expect(d.dockerNeedsSudo, isTrue);
      expect(runner.stdinByCommand[dockerListSudoCommand], 'sekret\n');
    });

    test('rc-state (removed, not purged) evcc is not treated as apt-installed',
        () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('config-files 0.310.0\n')], // Version present, but removed
        dockerListCommand: [_r('')],
      });
      final d =
          await _updaterWith(runner).detectInstall(config: _config, onLog: (_) {});
      expect(d.kind, InstallKind.unknown);
    });

    test('unknown: neither apt package nor docker container', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('\n')],
        dockerListCommand: [_r('', stderr: 'bash: docker: command not found')],
      });

      final d =
          await _updaterWith(runner).detectInstall(config: _config, onLog: (_) {});

      expect(d.kind, InstallKind.unknown);
    });

    test('allowSudoForDocker:false never escalates to sudo (no password sent)',
        () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('\n')],
        dockerListCommand: [
          _r('',
              stderr: 'permission denied while trying to connect to the '
                  'Docker daemon socket',
              exitCode: 1)
        ],
        dockerListSudoCommand: [_r('evcc|evcc/evcc:latest\n')],
      });

      final d = await _updaterWith(runner).detectInstall(
        config: _config,
        onLog: (_) {},
        allowSudoForDocker: false,
      );

      // No sudo retry → can't see the container → unknown, and crucially the
      // sudo command (which carries the password) was never run.
      expect(d.kind, InstallKind.unknown);
      expect(runner.commandsRun, isNot(contains(dockerListSudoCommand)));
    });
  });

  group('EvccUpdater.updateDocker', () {
    final detection = InstallDetection(
      kind: InstallKind.docker,
      container: const EvccDocker(name: 'evcc', image: 'evcc/evcc:latest'),
    );
    final sudoDetection = InstallDetection(
      kind: InstallKind.docker,
      container: const EvccDocker(name: 'evcc', image: 'evcc/evcc:latest'),
      dockerNeedsSudo: true,
    );
    final jsonCmd = dockerInspectJsonCommand('evcc');
    final jsonSudoCmd = dockerInspectJsonSudoCommand('evcc');
    const shell = 'bash -s';
    const sudoShell = 'LC_ALL=C sudo -S bash -s';

    String composeInspect() => jsonEncode([
          {
            'Name': '/evcc',
            'Config': {
              'Image': 'evcc/evcc:0.123',
              'Labels': {
                'com.docker.compose.project.working_dir': '/home/pi/evcc',
                'com.docker.compose.project.config_files':
                    '/home/pi/evcc/docker-compose.yml',
                'com.docker.compose.service': 'evcc',
                'com.docker.compose.project': 'evcc',
              },
            },
            'HostConfig': <String, dynamic>{},
          }
        ]);

    String runInspect() => jsonEncode([
          {
            'Name': '/evcc',
            'Config': {
              'Image': 'evcc/evcc:latest',
              'Env': ['TZ=Europe/Berlin'],
              'Labels': <String, dynamic>{},
            },
            'HostConfig': {
              'RestartPolicy': {'Name': 'unless-stopped', 'MaximumRetryCount': 0},
              'PortBindings': {
                '7070/tcp': [
                  {'HostIp': '', 'HostPort': '7070'}
                ]
              },
              'Binds': ['/home/pi/evcc.yaml:/etc/evcc.yaml'],
              'NetworkMode': 'default',
            },
          }
        ]);

    test('compose-managed: pulls + recreates the service, then verifies',
        () async {
      final runner = FakeSshRunner({
        jsonCmd: [_r(composeInspect())],
        shell: [_r('Pulling evcc ... done', exitCode: 0)],
        dockerListCommand: [_r('evcc|evcc/evcc:0.123\n')],
      });

      await _updaterWith(runner).updateDocker(
          config: _config, detection: detection, onLog: (_) {});

      final stdin = runner.stdinByCommand[shell]!;
      expect(stdin, contains("pull 'evcc'"));
      expect(stdin, contains("up -d 'evcc'"));
      expect(stdin, contains("-f '/home/pi/evcc/docker-compose.yml'"));
    });

    test('plain docker-run container: pulls + recreates from inspect data',
        () async {
      final runner = FakeSshRunner({
        jsonCmd: [_r(runInspect())],
        shell: [_r('recreated', exitCode: 0)],
        dockerListCommand: [_r('evcc|evcc/evcc:latest\n')],
      });

      await _updaterWith(runner).updateDocker(
          config: _config, detection: detection, onLog: (_) {});

      final stdin = runner.stdinByCommand[shell]!;
      expect(stdin, contains("docker pull 'evcc/evcc:latest'"));
      expect(stdin, contains("docker rename 'evcc' 'evcc-evccpitool-old'"));
      expect(stdin, contains("docker run -d --name 'evcc'"));
      expect(stdin, contains("-v '/home/pi/evcc.yaml:/etc/evcc.yaml'"));
    });

    test('a digest-pinned image is reported as not auto-updatable', () async {
      final digestInspect = jsonEncode([
        {
          'Name': '/evcc',
          'Config': {
            'Image': 'evcc/evcc@sha256:deadbeef',
            'Labels': <String, dynamic>{}
          },
          'HostConfig': {'NetworkMode': 'default'},
        }
      ]);
      final runner = FakeSshRunner({jsonCmd: [_r(digestInspect)]});
      await expectLater(
        _updaterWith(runner).updateDocker(
            config: _config, detection: detection, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.message, 'm', contains('Digest'))),
      );
    });

    test('sudo branch feeds the password as the first stdin line only',
        () async {
      final runner = FakeSshRunner({
        jsonSudoCmd: [_r(composeInspect())],
        sudoShell: [_r('done', exitCode: 0)],
        dockerListSudoCommand: [_r('evcc|evcc/evcc:0.123\n')],
      });

      await _updaterWith(runner).updateDocker(
          config: _config, detection: sudoDetection, onLog: (_) {});

      expect(runner.stdinByCommand[jsonSudoCmd], 'sekret\n');
      expect(runner.stdinByCommand[sudoShell], startsWith('sekret\n'));
      // password never appears in any command string
      expect(runner.commandsRun.any((c) => c.contains('sekret')), isFalse);
    });

    test('container missing in detection is a clear error', () async {
      final runner = FakeSshRunner({});
      await expectLater(
        _updaterWith(runner).updateDocker(
            config: _config,
            detection: const InstallDetection(kind: InstallKind.docker),
            onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()),
      );
    });

    test('a non-zero update script is reported as a failure', () async {
      final runner = FakeSshRunner({
        jsonCmd: [_r(composeInspect())],
        shell: [_r('boom', exitCode: 1)],
      });
      await expectLater(
        _updaterWith(runner).updateDocker(
            config: _config, detection: detection, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.message, 'm', contains('fehlgeschlagen'))),
      );
    });

    test('container gone after the update is reported (not silent success)',
        () async {
      final runner = FakeSshRunner({
        jsonCmd: [_r(composeInspect())],
        shell: [_r('done', exitCode: 0)],
        dockerListCommand: [_r('')], // no evcc container after
      });
      await expectLater(
        _updaterWith(runner).updateDocker(
            config: _config, detection: detection, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.serviceInactive)),
      );
    });

    test('sudo branch: a rejected password on inspect is a sudo error',
        () async {
      final runner = FakeSshRunner({
        jsonSudoCmd: [
          _r('', stderr: 'sudo: 1 incorrect password attempt', exitCode: 1)
        ],
      });
      await expectLater(
        _updaterWith(runner).updateDocker(
            config: _config, detection: sudoDetection, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.sudo)),
      );
    });

    test('sudo branch: a rejected password on the update script is a sudo error',
        () async {
      final runner = FakeSshRunner({
        jsonSudoCmd: [_r(composeInspect())],
        sudoShell: [
          _r('', stderr: 'sudo: 1 incorrect password attempt', exitCode: 1)
        ],
      });
      await expectLater(
        _updaterWith(runner).updateDocker(
            config: _config, detection: sudoDetection, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.sudo)),
      );
    });
  });
}
