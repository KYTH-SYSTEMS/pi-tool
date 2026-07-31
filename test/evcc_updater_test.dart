import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:evcc_updater/src/alerts.dart';
import 'package:evcc_updater/src/auto_update.dart';
import 'package:evcc_updater/src/commands.dart';
import 'package:evcc_updater/src/docker_containers.dart';
import 'package:evcc_updater/src/evcc_updater.dart';
import 'package:evcc_updater/src/files.dart';
import 'package:evcc_updater/src/parsing.dart';
import 'package:evcc_updater/src/security_check.dart';
import 'package:evcc_updater/src/ssh_keys.dart';
import 'package:evcc_updater/src/services/apt_services.dart';
import 'package:evcc_updater/src/services/pi_service.dart';
import 'package:evcc_updater/src/services/pi_connect.dart';
import 'package:evcc_updater/src/services/pihole_service.dart';
import 'package:evcc_updater/src/services/system_service.dart';
import 'package:evcc_updater/src/services/tailscale.dart';
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
        installShellCommand: [_r('RESTORE_OK\n')],
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
        installShellCommand: [_r('RESTORE_OK\n')],
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

  group('EvccUpdater file browser writes', () {
    test('uploadFile pipes the password first and needs the UPLOAD_OK marker',
        () async {
      final runner = FakeSshRunner({
        installShellCommand: [_r('UPLOAD_OK\n')],
      });
      await _updaterWith(runner).uploadFile(
          config: _config,
          path: '/etc/x.yaml',
          bytes: Uint8List.fromList([1, 2, 3]),
          onLog: (_) {});
      final stdin = runner.stdinByCommand[installShellCommand]!;
      expect(stdin, startsWith('sekret\n')); // password only via stdin
      expect(stdin, contains('base64 -d')); // the upload script ran
    });

    test('uploadFile throws when the UPLOAD_OK marker is missing (exit 0)',
        () async {
      final runner = FakeSshRunner({
        installShellCommand: [_r('done, but no marker\n')],
      });
      await expectLater(
        _updaterWith(runner).uploadFile(
            config: _config,
            path: '/etc/x.yaml',
            bytes: Uint8List(1),
            onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()),
      );
    });

    test('deleteRemotePath pipes the password on stdin', () async {
      final cmd = buildDeleteCommand(path: '/tmp/x', isDir: false);
      final runner = FakeSshRunner({cmd: [_r('')]});
      await _updaterWith(runner).deleteRemotePath(
          config: _config, path: '/tmp/x', isDir: false, onLog: (_) {});
      expect(runner.stdinByCommand[cmd], 'sekret\n');
    });

    test('deleteRemotePath maps a rejected sudo password to UpdateErrorKind.sudo',
        () async {
      final cmd = buildDeleteCommand(path: '/tmp/x', isDir: false);
      final runner = FakeSshRunner({
        cmd: [_r('sudo: 1 incorrect password attempt', exitCode: 1)],
      });
      await expectLater(
        _updaterWith(runner).deleteRemotePath(
            config: _config, path: '/tmp/x', isDir: false, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.sudo)),
      );
    });
  });

  group('EvccUpdater.downloadFile', () {
    final sizeCmd = buildFileSizeCommand('/var/backups/pi-tool/a.tar.gz');
    final dlCmd = buildDownloadFileCommand('/var/backups/pi-tool/a.tar.gz');

    test('checks the size first, then transfers base64 and verifies length',
        () async {
      final bytes = [1, 2, 3, 4, 5];
      final runner = FakeSshRunner({
        sizeCmd: [_r('5\n')],
        dlCmd: [_r('${base64.encode(bytes)}\n')],
      });
      final out = await _updaterWith(runner).downloadFile(
          config: _config,
          path: '/var/backups/pi-tool/a.tar.gz',
          onLog: (_) {});
      expect(out, bytes);
    });

    test('aborts BEFORE transferring when the file exceeds the limit',
        () async {
      final runner = FakeSshRunner({
        sizeCmd: [_r('${kBackupDownloadLimit + 1}\n')],
      });
      await expectLater(
        _updaterWith(runner).downloadFile(
            config: _config,
            path: '/var/backups/pi-tool/a.tar.gz',
            onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.message, 'message', contains('zu groß'))),
      );
      expect(runner.commandsRun, isNot(contains(dlCmd))); // never streamed
    });

    test('a truncated transfer (length mismatch) is an error, not silent data',
        () async {
      final runner = FakeSshRunner({
        sizeCmd: [_r('10\n')], // 10 bytes expected …
        dlCmd: [_r('${base64.encode([1, 2, 3])}\n')], // … only 3 arrived
      });
      await expectLater(
        _updaterWith(runner).downloadFile(
            config: _config,
            path: '/var/backups/pi-tool/a.tar.gz',
            onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()),
      );
    });

    test('a missing file (no size) is a clear error', () async {
      final runner = FakeSshRunner({
        sizeCmd: [_r('', stderr: 'wc: no such file', exitCode: 1)],
      });
      await expectLater(
        _updaterWith(runner).downloadFile(
            config: _config,
            path: '/var/backups/pi-tool/a.tar.gz',
            onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()),
      );
    });
  });

  group('EvccUpdater tailscale', () {
    test('tailscaleUp throws sudo on a rejected password (no false success)',
        () async {
      final runner = FakeSshRunner({
        installShellCommand: [
          _r('', stderr: 'sudo: 1 incorrect password attempt', exitCode: 1)
        ],
      });
      await expectLater(
        _updaterWith(runner).tailscaleUp(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.sudo)),
      );
    });

    test('tailscaleSet(logout) throws sudo on a rejected password', () async {
      final runner = FakeSshRunner({
        tailscaleLogoutCommand: [
          _r('sudo: 1 incorrect password attempt', exitCode: 1)
        ],
      });
      await expectLater(
        _updaterWith(runner)
            .tailscaleSet(config: _config, logout: true, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.sudo)),
      );
    });
  });

  group('EvccUpdater.installAptService', () {
    test('installs the service by running its script as root', () async {
      final grafana = knownAptServices.firstWhere((s) => s.id == 'grafana');
      final runner = FakeSshRunner({
        installShellCommand: [_r('...\nSetting up grafana ...\nINSTALL_OK\n')],
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

  group('EvccUpdater service backup management', () {
    test('listServiceBackups lists one service, newest first', () async {
      final cmd = serviceBackupListCommand('pihole');
      final runner = FakeSshRunner({
        cmd: [
          _r('/var/backups/pi-tool/pihole-backup-2.zip\n'
              '/var/backups/pi-tool/pihole-backup-1.zip\n')
        ],
      });
      final list = await _updaterWith(runner).listServiceBackups(
          config: _config, servicePrefix: 'pihole', onLog: (_) {});
      expect(list, hasLength(2));
      expect(list.first, endsWith('pihole-backup-2.zip'));
    });

    test('deleteServiceBackup removes via sudo (password on stdin)', () async {
      const path = '/var/backups/pi-tool/pihole-backup-1.zip';
      final cmd = serviceBackupDeleteCommand(path);
      final runner = FakeSshRunner({cmd: [_r('')]});
      await _updaterWith(runner)
          .deleteServiceBackup(config: _config, path: path, onLog: (_) {});
      expect(runner.stdinByCommand[cmd], 'sekret\n');
    });

    test('restorePiholeBackup runs the teleporter import as root', () async {
      final runner = FakeSshRunner({
        installShellCommand: [_r('RESTORE_OK\n')],
      });
      await _updaterWith(runner).restorePiholeBackup(
          config: _config,
          path: '/var/backups/pi-tool/pihole-backup-1.zip',
          onLog: (_) {});
      final stdin = runner.stdinByCommand[installShellCommand]!;
      expect(stdin, startsWith('sekret\n'));
      expect(stdin, contains('pihole-FTL --teleporter'));
    });

    test('restorePiholeBackup refuses a v5 tar.gz with a clear error',
        () async {
      final runner = FakeSshRunner({});
      await expectLater(
        _updaterWith(runner).restorePiholeBackup(
            config: _config,
            path: '/var/backups/pi-tool/pihole-backup-1.tar.gz',
            onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.message, 'message', contains('Web-Oberfläche'))),
      );
      expect(runner.commandsRun, isEmpty); // never even connects to the Pi
    });

    test('restoreHomeAssistantBackup stops, extracts and restarts via trap',
        () async {
      final inspectCmd = dockerInspectJsonCommand('homeassistant');
      final runner = FakeSshRunner({
        dockerListCommand: [
          _r('homeassistant|ghcr.io/home-assistant/home-assistant:stable\n')
        ],
        inspectCmd: [
          _r('[{"Name":"/homeassistant","Mounts":['
              '{"Type":"bind","Source":"/opt/ha/config","Destination":"/config"}]}]')
        ],
        installShellCommand: [_r('RESTORE_OK\n')],
      });
      await _updaterWith(runner).restoreHomeAssistantBackup(
          config: _config,
          path: '/var/backups/pi-tool/homeassistant-backup-1.tar.gz',
          onLog: (_) {});
      final stdin = runner.stdinByCommand[installShellCommand]!;
      expect(stdin, contains("docker stop 'homeassistant'"));
      expect(stdin, contains("-C '/opt/ha/config'"));
      expect(stdin, contains('trap'));
    });
  });

  group('EvccUpdater.cleanupSystem', () {
    test('runs the cleanup as root and returns the freed bytes', () async {
      final runner = FakeSshRunner({
        installShellCommand: [
          _r('cleaning …\nCLEANUP_OK 1000000000 1250000000\n')
        ],
      });
      final freed = await _updaterWith(runner)
          .cleanupSystem(config: _config, onLog: (_) {});
      expect(freed, 250000000);
      final stdin = runner.stdinByCommand[installShellCommand]!;
      expect(stdin, startsWith('sekret\n'));
      expect(stdin, contains('apt-get autoremove -y'));
    });

    test('a missing marker is a clear failure', () async {
      final runner = FakeSshRunner({
        installShellCommand: [_r('boom', exitCode: 1)],
      });
      await expectLater(
        _updaterWith(runner).cleanupSystem(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()),
      );
    });
  });

  group('EvccUpdater auto-update', () {
    test('enableAutoUpdate installs the timer as root with the schedule',
        () async {
      final runner = FakeSshRunner({
        installShellCommand: [_r('AUTOUPDATE_INSTALLED\n')]
      });
      await _updaterWith(runner).enableAutoUpdate(
          config: _config, onCalendar: '*-*-* 04:00:00', onLog: (_) {});
      final stdin = runner.stdinByCommand[installShellCommand]!;
      expect(stdin, startsWith('sekret\n'));
      expect(stdin, contains('OnCalendar=*-*-* 04:00:00'));
      expect(stdin, contains('enable --now pi-tool-autoupdate.timer'));
    });

    test('enableAutoUpdate fails clearly when the marker is missing', () async {
      final runner =
          FakeSshRunner({installShellCommand: [_r('boom', exitCode: 1)]});
      await expectLater(
        _updaterWith(runner).enableAutoUpdate(
            config: _config, onCalendar: 'x', onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()),
      );
    });

    test('disableAutoUpdate removes the timer as root', () async {
      final runner =
          FakeSshRunner({installShellCommand: [_r('AUTOUPDATE_REMOVED\n')]});
      await _updaterWith(runner)
          .disableAutoUpdate(config: _config, onLog: (_) {});
      expect(runner.stdinByCommand[installShellCommand],
          contains('disable --now pi-tool-autoupdate.timer'));
    });

    test('readAutoUpdateStatus parses the timer state', () async {
      final runner = FakeSshRunner({
        autoUpdateStatusCommand: [
          _r('ENABLED enabled\nNEXT Sun 2026-07-12 04:00:00\n'
              'STATUS 2026-07-05 04:00:12 ok\n')
        ]
      });
      final st = await _updaterWith(runner)
          .readAutoUpdateStatus(config: _config, onLog: (_) {});
      expect(st.enabled, isTrue);
      expect(st.lastResult, contains('ok'));
    });
  });

  group('EvccUpdater file browser', () {
    test('listDir lists a directory as root (password piped)', () async {
      final cmd = buildListDirCommand('/home/pi');
      final runner = FakeSshRunner({cmd: [_r('backups/\nnotes.txt\n')]});
      final e = await _updaterWith(runner)
          .listDir(config: _config, path: '/home/pi', onLog: (_) {});
      expect(e.map((x) => x.name).toList(), ['backups', 'notes.txt']);
      expect(runner.stdinByCommand[cmd], 'sekret\n');
    });

    test('readFileBytes base64-decodes the file content', () async {
      final cmd = buildReadFileCommand('/etc/hostname');
      final runner = FakeSshRunner({cmd: [_r('cGkK\n')]}); // base64('pi\n')
      final bytes = await _updaterWith(runner)
          .readFileBytes(config: _config, path: '/etc/hostname', onLog: (_) {});
      expect(utf8.decode(bytes), 'pi\n');
    });

    test('readFileBytes on unreadable output is a clear failure', () async {
      final cmd = buildReadFileCommand('/root/secret');
      final runner =
          FakeSshRunner({cmd: [_r('base64: /root/secret: Permission denied')]});
      await expectLater(
        _updaterWith(runner)
            .readFileBytes(config: _config, path: '/root/secret', onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()),
      );
    });
  });

  group('EvccUpdater config edit', () {
    test('readConfigFile cats the file as root (password piped)', () async {
      final cmd = buildConfigReadCommand('/etc/evcc.yaml');
      final runner = FakeSshRunner({cmd: [_r('network:\n  schema: http\n')]});
      final text = await _updaterWith(runner)
          .readConfigFile(config: _config, path: '/etc/evcc.yaml', onLog: (_) {});
      expect(text, contains('schema: http'));
      expect(runner.stdinByCommand[cmd], 'sekret\n');
    });

    test('saveConfigFile base64-transfers the content + backs up', () async {
      final runner =
          FakeSshRunner({installShellCommand: [_r('CONFIG_SAVED\n')]});
      await _updaterWith(runner).saveConfigFile(
          config: _config,
          path: '/etc/evcc.yaml',
          content: 'hallo: welt',
          onLog: (_) {});
      final stdin = runner.stdinByCommand[installShellCommand]!;
      expect(stdin, startsWith('sekret\n'));
      // 'hallo: welt' → base64
      expect(stdin, contains('base64 -d'));
      expect(stdin, contains('aGFsbG86IHdlbHQ='));
    });

    test('saveConfigFile fails clearly without the marker', () async {
      final runner = FakeSshRunner({installShellCommand: [_r('boom', exitCode: 1)]});
      await expectLater(
        _updaterWith(runner).saveConfigFile(
            config: _config,
            path: '/etc/evcc.yaml',
            content: 'x',
            onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()),
      );
    });
  });

  group('EvccUpdater Tailscale', () {
    test('installTailscale runs the official installer as root', () async {
      final runner =
          FakeSshRunner({installShellCommand: [_r('TAILSCALE_INSTALLED\n')]});
      await _updaterWith(runner)
          .installTailscale(config: _config, onLog: (_) {});
      expect(runner.stdinByCommand[installShellCommand], contains('install.sh'));
    });

    test('tailscaleUp returns the login URL', () async {
      final runner = FakeSshRunner({
        installShellCommand: [
          _r('To authenticate, visit https://login.tailscale.com/a/xyz\n')
        ]
      });
      final url =
          await _updaterWith(runner).tailscaleUp(config: _config, onLog: (_) {});
      expect(url, 'https://login.tailscale.com/a/xyz');
    });

    test('tailscaleSet down pipes the password (sudo)', () async {
      final runner = FakeSshRunner({tailscaleDownCommand: [_r('')]});
      await _updaterWith(runner)
          .tailscaleSet(config: _config, logout: false, onLog: (_) {});
      expect(runner.stdinByCommand[tailscaleDownCommand], 'sekret\n');
    });

    test('tailscaleUp: connected (marker, no URL) returns null', () async {
      final runner = FakeSshRunner({
        installShellCommand: [_r('Success.\nTS_UP_OK\n')],
      });
      final url =
          await _updaterWith(runner).tailscaleUp(config: _config, onLog: (_) {});
      expect(url, isNull);
    });

    test('tailscaleUp: no URL and no marker is a real failure (not "connected")',
        () async {
      final runner = FakeSshRunner({
        installShellCommand: [_r('failed to connect to local tailscaled\n')],
      });
      await expectLater(
        _updaterWith(runner).tailscaleUp(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.unknown)),
      );
    });

    test('tailscaleSet(down) surfaces a non-zero exit as an error', () async {
      final runner = FakeSshRunner({
        tailscaleDownCommand: [_r('daemon not running\n', exitCode: 1)],
      });
      await expectLater(
        _updaterWith(runner)
            .tailscaleSet(config: _config, logout: false, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.unknown)),
      );
    });
  });

  group('EvccUpdater Pi Connect', () {
    test('installPiConnect installs lite + linger as root', () async {
      final runner =
          FakeSshRunner({installShellCommand: [_r('PICONNECT_INSTALLED\n')]});
      await _updaterWith(runner)
          .installPiConnect(config: _config, onLog: (_) {});
      final stdin = runner.stdinByCommand[installShellCommand]!;
      expect(stdin, contains('rpi-connect-lite'));
      expect(stdin, contains('enable-linger'));
    });

    test('piConnectSignin returns the verify URL', () async {
      final runner = FakeSshRunner({
        piConnectSigninCommand: [
          _r('Complete sign in by visiting '
              'https://connect.raspberrypi.com/verify/AB-12\n')
        ]
      });
      final url = await _updaterWith(runner)
          .piConnectSignin(config: _config, onLog: (_) {});
      expect(url, 'https://connect.raspberrypi.com/verify/AB-12');
    });

    test('piConnectSet runs the user command WITHOUT a password', () async {
      final runner = FakeSshRunner({piConnectOnCommand: [_r('')]});
      await _updaterWith(runner)
          .piConnectSet(config: _config, on: true, onLog: (_) {});
      expect(runner.commandsRun, contains(piConnectOnCommand));
      expect(runner.stdinByCommand[piConnectOnCommand], isNull);
    });
  });

  group('EvccUpdater.fetchServiceLogs', () {
    test('runs journalctl for an apt service and pipes the password', () async {
      final spec = buildServiceLogsCommand(id: 'evcc', detail: 'apt · aktiv');
      final runner = FakeSshRunner({
        spec.command: [_r('-- Logs begin --\nevcc[123]: started\n')]
      });
      final logs = await _updaterWith(runner).fetchServiceLogs(
          config: _config, id: 'evcc', detail: 'apt · aktiv', onLog: (_) {});
      expect(logs, contains('started'));
      expect(runner.stdinByCommand[spec.command], 'sekret\n');
    });

    test('docker service reads docker logs (no password unless the fallback)',
        () async {
      final spec = buildServiceLogsCommand(
          id: 'homeassistant', detail: 'Docker · homeassistant');
      final runner = FakeSshRunner({spec.command: [_r('HA up on :8123\n')]});
      final logs = await _updaterWith(runner).fetchServiceLogs(
          config: _config,
          id: 'homeassistant',
          detail: 'Docker · homeassistant',
          onLog: (_) {});
      expect(logs, contains(':8123'));
    });
  });

  group('EvccUpdater health-alerts', () {
    test('enableAlerts installs the timer with the ntfy destination', () async {
      final runner = FakeSshRunner({
        installShellCommand: [_r('ALERTS_INSTALLED\n')]
      });
      await _updaterWith(runner).enableAlerts(
          config: _config,
          ntfyServer: 'https://ntfy.sh',
          ntfyTopic: 'my-pi-42',
          onLog: (_) {});
      final stdin = runner.stdinByCommand[installShellCommand]!;
      expect(stdin, startsWith('sekret\n'));
      expect(stdin, contains("TOPIC='my-pi-42'"));
      expect(stdin, contains('enable --now pi-tool-alerts.timer'));
    });

    test('disableAlerts removes the timer', () async {
      final runner =
          FakeSshRunner({installShellCommand: [_r('ALERTS_REMOVED\n')]});
      await _updaterWith(runner)
          .disableAlerts(config: _config, onLog: (_) {});
      expect(runner.stdinByCommand[installShellCommand],
          contains('disable --now pi-tool-alerts.timer'));
    });

    test('sendTestAlert curls the ntfy destination', () async {
      final cmd = buildTestAlertCommand(
          ntfyServer: 'https://ntfy.sh', ntfyTopic: 'my-pi-42');
      final runner = FakeSshRunner({cmd: [_r('')]});
      await _updaterWith(runner).sendTestAlert(
          config: _config,
          ntfyServer: 'https://ntfy.sh',
          ntfyTopic: 'my-pi-42',
          onLog: (_) {});
      expect(runner.commandsRun, contains(cmd));
    });

    test('readAlertsStatus parses the timer state', () async {
      final runner = FakeSshRunner({
        alertsStatusCommand: [_r('ENABLED enabled\nLAST 2026-07-07 12:00 checked\n')]
      });
      final st = await _updaterWith(runner)
          .readAlertsStatus(config: _config, onLog: (_) {});
      expect(st.enabled, isTrue);
      expect(st.lastCheck, contains('12:00'));
    });
  });

  group('EvccUpdater.runConsoleCommand', () {
    // The exec is wrapped to cap output: `{ <cmd> ; } 2>&1 | head -c 262144`.
    String capped(String inner) => '{ $inner ; } 2>&1 | head -c 262144';

    test('runs a plain command, echoes it and streams the output', () async {
      final runner = FakeSshRunner({
        capped('df -h'): [_r('Filesystem Size\n/dev/root 30G\n')],
      });
      final logs = <String>[];
      final out = await _updaterWith(runner)
          .runConsoleCommand(config: _config, command: 'df -h', onLog: logs.add);
      expect(out, contains('/dev/root'));
      expect(logs, contains(r'$ df -h')); // the command is echoed
    });

    test('pipes the Pi password for a sudo command', () async {
      final exec = capped("sudo -S -p '' systemctl restart evcc");
      final runner = FakeSshRunner({exec: [_r('')]});
      await _updaterWith(runner).runConsoleCommand(
          config: _config,
          command: 'sudo systemctl restart evcc',
          onLog: (_) {});
      expect(runner.stdinByCommand[exec], startsWith('sekret\n'));
    });

    test('a rejected sudo password surfaces as a sudo error', () async {
      final exec = capped("sudo -S -p '' apt-get update");
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

  group('EvccUpdater.installSshKey', () {
    const line = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 pi-tool';
    test('succeeds when KEY_INSTALLED is printed', () async {
      final runner = FakeSshRunner({
        buildInstallAuthorizedKeyScript(line): [_r('KEY_INSTALLED\n')],
      });
      await _updaterWith(runner)
          .installSshKey(config: _config, publicKeyLine: line, onLog: (_) {});
    });

    test('throws when the marker is absent (install failed)', () async {
      final runner = FakeSshRunner({
        buildInstallAuthorizedKeyScript(line): [
          _r('', stderr: 'Permission denied', exitCode: 1)
        ],
      });
      await expectLater(
        _updaterWith(runner)
            .installSshKey(config: _config, publicKeyLine: line, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()),
      );
    });
  });

  group('EvccUpdater docker', () {
    test('dockerContainers parses the ps output', () async {
      final runner = FakeSshRunner({
        dockerPsSudoCommand: [_r('evcc|running|Up 2 hours|evcc/evcc\n')],
      });
      final r = await _updaterWith(runner)
          .dockerContainers(config: _config, onLog: (_) {});
      expect(r.single.name, 'evcc');
      expect(r.single.state, 'running');
    });

    test('restartDockerContainer surfaces a non-zero exit', () async {
      final runner = FakeSshRunner({
        buildDockerRestartCommand('x'): [
          _r('', stderr: 'No such container: x', exitCode: 1)
        ],
      });
      await expectLater(
        _updaterWith(runner)
            .restartDockerContainer(config: _config, name: 'x', onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()),
      );
    });
  });

  group('EvccUpdater.verifyKeyAuth', () {
    test('true when the key-only connection returns the marker', () async {
      final runner =
          FakeSshRunner({'echo SSH_KEY_AUTH_OK': [_r('SSH_KEY_AUTH_OK\n')]});
      expect(
        await _updaterWith(runner).verifyKeyAuth(config: _config, onLog: (_) {}),
        isTrue,
      );
    });

    test('throws when key auth is rejected', () async {
      final runner = FakeSshRunner({},
          runErrors: {'echo SSH_KEY_AUTH_OK': const SocketException('denied')});
      await expectLater(
        _updaterWith(runner).verifyKeyAuth(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()),
      );
    });
  });

  group('EvccUpdater.runSecurityCheck', () {
    test('parses a hardened Pi (no warnings) from the probe', () async {
      final runner = FakeSshRunner({
        buildSecurityProbe(): [
          _r('__SEC_SSHD__\npermitrootlogin no\npasswordauthentication no\n'
              '__SEC_UNATT__\nenabled\nactive\n__SEC_F2B__\nactive\n'
              '__SEC_PORTS__\n0.0.0.0:22\n')
        ],
      });
      final r = await _updaterWith(runner)
          .runSecurityCheck(config: _config, onLog: (_) {});
      expect(r, hasLength(5));
      expect(r.any((f) => f.level == SecurityLevel.warn), isFalse);
    });

    test('reports a rejected sudo password', () async {
      final runner = FakeSshRunner({
        buildSecurityProbe(): [
          _r('', stderr: 'sudo: 1 incorrect password attempt', exitCode: 1)
        ],
      });
      await expectLater(
        _updaterWith(runner).runSecurityCheck(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.sudo)),
      );
    });
  });

  group('EvccUpdater.shutdown', () {
    test('treats a dropped connection as success', () async {
      final runner = FakeSshRunner({},
          runErrors: {shutdownCommand: const SocketException('closed')});
      // poweroff drops the SSH connection — must NOT be reported as an error.
      await _updaterWith(runner).shutdown(config: _config, onLog: (_) {});
    });

    test('reports failure on a non-zero, non-password exit', () async {
      final runner = FakeSshRunner({
        shutdownCommand: [
          _r('', stderr: 'poweroff: Operation not permitted', exitCode: 1)
        ],
      });
      await expectLater(
        _updaterWith(runner).shutdown(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()),
      );
    });

    test('reports a rejected sudo password (no disconnect)', () async {
      final runner = FakeSshRunner({
        shutdownCommand: [
          _r('', stderr: 'sudo: 1 incorrect password attempt', exitCode: 1)
        ],
      });
      await expectLater(
        _updaterWith(runner).shutdown(config: _config, onLog: (_) {}),
        throwsA(isA<EvccUpdateException>()
            .having((e) => e.kind, 'kind', UpdateErrorKind.sudo)),
      );
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

  group('EvccUpdater.probeConnection', () {
    test('true when the host answers', () async {
      final runner = FakeSshRunner({'true': [_r('')]});
      expect(
          await _updaterWith(runner).probeConnection(config: _config), isTrue);
    });

    test('false when the connection fails — never throws', () async {
      final runner = FakeSshRunner(const {},
          connectError: const SocketException('no route to host'));
      expect(
          await _updaterWith(runner).probeConnection(config: _config), isFalse);
    });

    test('a CHANGED HOST KEY still throws — never a silent "unreachable"',
        () async {
      // Swallowing this would turn a possible MITM into a shrug.
      final runner = FakeSshRunner(const {},
          connectError: const HostKeyChangedException(
              host: '192.168.178.125',
              port: 22,
              presented: 'SHA256:new',
              stored: 'SHA256:old'));
      // _withConnection translates it into this kind; the probe must let it
      // through instead of reporting a plain "unreachable".
      expect(
        () => _updaterWith(runner).probeConnection(config: _config),
        throwsA(isA<EvccUpdateException>().having(
            (e) => e.kind, 'kind', UpdateErrorKind.hostKeyChanged)),
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
        systemAptAgeCommand: [_r('3600')], // fresh index — currency is knowable
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
        systemAptAgeCommand: [_r('3600')], // fresh index — currency is knowable
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

    test('a stale package index stops every apt card from claiming currency',
        () async {
      // The v0.63.6 bug: a 10-day-old index answered "0 upgraded", so every
      // apt-backed card showed a green "aktuell" — including System, while 27
      // updates (incl. security) waited in the repo.
      final runner = FakeSshRunner({
        _vQuery: [_r('installed 0.310.0\n')],
        _svc: [_r('active\n')],
        piConnectStatusCommand: [_r('Signed in: yes')],
        tailscaleStatusCommand: [_r('100.64.0.5   mypi   linux\n100.64.0.5')],
        systemOsCommand: [_r('PRETTY_NAME="Debian GNU/Linux 13 (trixie)"')],
        systemPendingCommand: [_r('0 upgraded, 0 newly installed, 0 to remove.')],
        systemAptAgeCommand: [_r('${10 * 24 * 3600}')],
      });

      final list =
          await _updaterWith(runner).detectServices(config: _config, onLog: (_) {});
      final byId = {for (final s in list) s.id: s};

      for (final id in ['evcc', 'piconnect', 'tailscale', 'system']) {
        expect(byId[id]!.updateKnown, isFalse,
            reason: '$id must not claim currency on a stale index');
      }
      // …and the System card says why, with the age.
      expect(byId['system']!.detail, contains('10 Tage'));
    });

    test('a fresh package index keeps the cards authoritative', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('installed 0.310.0\n')],
        _svc: [_r('active\n')],
        piConnectStatusCommand: [_r('Signed in: yes')],
        systemOsCommand: [_r('PRETTY_NAME="Debian GNU/Linux 13 (trixie)"')],
        systemPendingCommand: [_r('0 upgraded, 0 newly installed, 0 to remove.')],
        systemAptAgeCommand: [_r('3600')],
      });

      final list =
          await _updaterWith(runner).detectServices(config: _config, onLog: (_) {});
      final byId = {for (final s in list) s.id: s};

      expect(byId['evcc']!.updateKnown, isTrue);
      expect(byId['piconnect']!.updateKnown, isTrue);
      expect(byId['system']!.updateKnown, isTrue);
      expect(byId['system']!.detail, 'aktuell');
    });

    test('Pi Connect + Tailscale (apt) flag an update when the apt sim upgrades them',
        () async {
      final runner = FakeSshRunner({
        piConnectStatusCommand: [_r('Signed in: yes\nScreen sharing: on')],
        tailscaleStatusCommand: [_r('100.64.0.5   mypi   linux\n100.64.0.5')],
        systemPendingCommand: [
          _r('Inst rpi-connect-lite [1.0] (1.1 raspberrypi:armhf [armhf])\n'
              'Inst tailscale [1.70] (1.72 tailscale:armhf [armhf])\n'
              '2 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.')
        ],
        systemOsCommand: [_r('PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"')],
        systemAptAgeCommand: [_r('3600')], // fresh index — currency is knowable
      });

      final byId = {
        for (final s in await _updaterWith(runner)
            .detectServices(config: _config, onLog: (_) {}))
          s.id: s
      };

      expect(byId['piconnect']!.installed, isTrue);
      expect(byId['piconnect']!.updateKnown, isTrue);
      expect(byId['piconnect']!.updateAvailable, isTrue);
      expect(byId['piconnect']!.aptPackage, 'rpi-connect-lite');
      expect(byId['tailscale']!.updateAvailable, isTrue);
      expect(byId['tailscale']!.aptPackage, 'tailscale');
    });

    test('Pi Connect + Tailscale report up to date when the apt sim has no upgrade',
        () async {
      final runner = FakeSshRunner({
        piConnectStatusCommand: [_r('Signed in: yes')],
        tailscaleStatusCommand: [_r('100.64.0.5   mypi\n100.64.0.5')],
        systemPendingCommand: [_r('0 upgraded, 0 newly installed, 0 to remove.')],
        systemOsCommand: [_r('PRETTY_NAME="Debian GNU/Linux 12"')],
        systemAptAgeCommand: [_r('3600')], // fresh index — currency is knowable
      });
      final byId = {
        for (final s in await _updaterWith(runner)
            .detectServices(config: _config, onLog: (_) {}))
          s.id: s
      };
      expect(byId['piconnect']!.updateKnown, isTrue);
      expect(byId['piconnect']!.updateAvailable, isFalse);
      expect(byId['tailscale']!.updateKnown, isTrue);
      expect(byId['tailscale']!.updateAvailable, isFalse);
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

    test('System card warns on a read-only root (dying SD card)', () async {
      final runner = FakeSshRunner({
        _vQuery: [_r('installed 0.310.0\n')],
        _svc: [_r('active\n')],
        systemOsCommand: [_r('PRETTY_NAME="Debian GNU/Linux 12"')],
        systemPendingCommand: [_r('0 upgraded, 0 newly installed.')],
        systemStorageCommand: [
          _r('/dev/mmcblk0p2 / ext4 ro,noatime 0 0\n0\n')
        ],
      });

      final list =
          await _updaterWith(runner).detectServices(config: _config, onLog: (_) {});
      final sys = list.firstWhere((s) => s.id == 'system');
      expect(sys.healthWarning, isTrue);
      expect(sys.health, contains('SD-Karte prüfen'));
      expect(sys.health, contains('nur-lesend'));
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
      const upg =
          "LC_ALL=C sudo -S apt-get install --only-upgrade -y 'grafana'";
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
