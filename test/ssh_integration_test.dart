// End-to-end test of the real SSH adapter against an actual SSH peer.
//
// Everything else in the suite fakes the SshRunner; this is the one place the
// dartssh2 transport itself is exercised — key exchange, host-key check, both
// auth methods, exec with stdin/stdout/stderr and exit status. Run it before
// shipping a dartssh2 upgrade.
//
// Needs the local server from tool/ssh_test_server.py and is skipped unless
// PITOOL_TEST_SSHD_PYTHON names a Python that has asyncssh installed:
//
//   PITOOL_TEST_SSHD_PYTHON=C:\path\to\python.exe
//   PITOOL_TEST_BASH=C:\Program Files\Git\bin\bash.exe   (Windows only)
//   flutter test test/ssh_integration_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:evcc_updater/src/dartssh2_runner.dart';
import 'package:evcc_updater/src/host_key.dart';
import 'package:evcc_updater/src/ssh_keys.dart';
import 'package:evcc_updater/src/ssh_runner.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryHostKeyStore implements HostKeyStore {
  final Map<String, String> data = {};
  @override
  Future<String?> get(String id) async => data[id];
  @override
  Future<void> set(String id, String fingerprint) async =>
      data[id] = fingerprint;
  @override
  Future<void> remove(String id) async => data.remove(id);
}

const _password = 'test-pw';
final String? _python = Platform.environment['PITOOL_TEST_SSHD_PYTHON'];

void main() {
  group('SSH adapter end-to-end', _tests,
      skip: _python == null
          ? 'needs PITOOL_TEST_SSHD_PYTHON (see the file header)'
          : false);
}

void _tests() {
  late Process server;
  late int port;
  late String serverFingerprint;
  late Directory tmp;
  late GeneratedSshKey clientKey;

  SshConfig config({
    String password = _password,
    String privateKey = '',
    Duration timeout = const Duration(seconds: 15),
    Duration startTimeout = const Duration(seconds: 60),
    Duration commandTimeout = const Duration(minutes: 10),
  }) =>
      SshConfig(
        host: '127.0.0.1',
        port: port,
        username: 'pi',
        password: password,
        privateKey: privateKey,
        timeout: timeout,
        startTimeout: startTimeout,
        commandTimeout: commandTimeout,
      );

  /// Connects with a store that already trusts the server.
  Future<Dartssh2Runner> connected({SshConfig? cfg}) async {
    final c = cfg ?? config();
    final store = _MemoryHostKeyStore()
      ..data[hostKeyId(c.host, c.port)] = serverFingerprint;
    final runner = Dartssh2Runner(c, hostKeyStore: store);
    await runner.connect();
    return runner;
  }

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('pitool-sshd');
    clientKey = await generateSshKey(comment: 'integration');
    final keys = File('${tmp.path}/authorized_keys');
    await keys.writeAsString('${clientKey.publicKeyLine}\n');
    server = await Process.start(
      _python!,
      ['tool/ssh_test_server.py', keys.path],
      environment: {'PITOOL_TEST_SSHD_PASSWORD': _password},
    );
    final ready = Completer<String>();
    server.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((l) {
      if (l.startsWith('LISTENING ') && !ready.isCompleted) ready.complete(l);
    });
    final err = StringBuffer();
    server.stderr.transform(utf8.decoder).listen(err.write);
    final line = await ready.future.timeout(const Duration(seconds: 20),
        onTimeout: () => throw StateError('test server did not start: $err'));
    final parts = line.split(' ');
    port = int.parse(parts[1]);
    serverFingerprint = parts[2];
  });

  tearDownAll(() async {
    server.kill();
    await tmp.delete(recursive: true);
  });

  group('host key (TOFU)', () {
    test('first use records the fingerprint the server itself reports',
        () async {
      final store = _MemoryHostKeyStore();
      final runner = Dartssh2Runner(config(), hostKeyStore: store);
      await runner.connect();
      await runner.close();
      // Cross-check against an independent implementation: the format must
      // stay OpenSSH's "SHA256:<base64 without padding>" across upgrades, or
      // every stored fingerprint would read as "host key changed".
      expect(store.data[hostKeyId('127.0.0.1', port)], serverFingerprint);
    });

    test('a different stored fingerprint aborts before authentication',
        () async {
      final store = _MemoryHostKeyStore()
        ..data[hostKeyId('127.0.0.1', port)] = 'SHA256:somethingelse';
      final runner = Dartssh2Runner(config(), hostKeyStore: store);
      await expectLater(
          runner.connect(), throwsA(isA<HostKeyChangedException>()));
      await runner.close();
    });

    test('a declined first use aborts and stores nothing', () async {
      final store = _MemoryHostKeyStore();
      final runner = Dartssh2Runner(config(),
          hostKeyStore: store, confirmFirstUse: (_, _) async => false);
      await expectLater(
          runner.connect(), throwsA(isA<HostKeyDeclinedException>()));
      await runner.close();
      expect(store.data, isEmpty);
    });

    test('reading the fingerprint dialog does not eat the handshake timeout',
        () async {
      final store = _MemoryHostKeyStore();
      final runner = Dartssh2Runner(
        config(timeout: const Duration(seconds: 1)),
        hostKeyStore: store,
        confirmFirstUse: (_, _) async {
          await Future<void>.delayed(const Duration(seconds: 3));
          return true;
        },
      );
      await runner.connect();
      final r = await runner.run('echo ok');
      await runner.close();
      expect(r.stdout.trim(), 'ok');
    });
  });

  group('authentication', () {
    test('a wrong password is an auth error', () async {
      final store = _MemoryHostKeyStore()
        ..data[hostKeyId('127.0.0.1', port)] = serverFingerprint;
      final runner =
          Dartssh2Runner(config(password: 'wrong'), hostKeyStore: store);
      await expectLater(runner.connect(), throwsA(isA<SSHAuthError>()));
      await runner.close();
    });

    test('a key generated by the app logs in', () async {
      final runner = await connected(
          cfg: config(password: '', privateKey: clientKey.privateKeyPem));
      final r = await runner.run('echo key-ok');
      await runner.close();
      expect(r.stdout.trim(), 'key-ok');
      expect(r.exitCode, 0);
    });
  });

  group('exec', () {
    test('stdout, stderr and exit status arrive separately', () async {
      final runner = await connected();
      final r = await runner.run('echo out; echo err >&2; exit 3');
      await runner.close();
      expect(r.stdout, 'out\n');
      expect(r.stderr, 'err\n');
      expect(r.exitCode, 3);
    });

    test('stdin reaches the command in full, then EOF', () async {
      final runner = await connected();
      // Larger than one SSH packet and than the initial channel window.
      final script = '${List.filled(40000, 'echo line').join('\n')}\n';
      final r = await runner.run('wc -c', stdin: script);
      await runner.close();
      expect(int.parse(r.stdout.trim()), script.length);
      expect(r.exitCode, 0);
    });

    test('a command that ends without taking its stdin returns its result',
        () async {
      // A rejected sudo password in front of an upload: more input than the
      // channel window, and nobody reads it. The result must not wait for it.
      final runner = await connected();
      final watch = Stopwatch()..start();
      final r = await runner.run('echo early; exit 3',
          stdin: 'x' * (6 * 1024 * 1024));
      await runner.close();
      expect(r.stdout, 'early\n');
      expect(r.exitCode, 3);
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('a large output arrives complete, and live chunks are whole lines',
        () async {
      final runner = await connected();
      final chunks = <String>[];
      final watch = Stopwatch()..start();
      final r = await runner.run('seq 1 300000', onOutput: chunks.add);
      watch.stop();
      await runner.close();
      final lines = const LineSplitter().convert(r.stdout);
      expect(lines.length, 300000);
      expect(lines.last, '300000');
      expect(chunks.every((c) => c.endsWith('\n')), isTrue);
      expect(chunks.join(), r.stdout);
      // Informational: throughput of the negotiated cipher in pure Dart.
      printOnFailure('seq 1 300000: ${watch.elapsedMilliseconds} ms');
      // ignore: avoid_print
      print('transfer of ${r.stdout.length} bytes: '
          '${watch.elapsedMilliseconds} ms');
    });

    test('a multi-byte character split across two packets stays intact',
        () async {
      final runner = await connected();
      final r = await runner.run('pitool-test split-utf8');
      await runner.close();
      expect(r.stdout, 'grün\n');
    });

    test('non-ASCII in the command and on stdin round-trips', () async {
      final runner = await connected();
      final r = await runner.run("printf '%s' 'Zähler: '; cat",
          stdin: 'Größe 5 kWh – ok\n');
      await runner.close();
      expect(r.stdout, 'Zähler: Größe 5 kWh – ok\n');
    });
  });

  group('connection loss', () {
    test('a reset mid-command yields no exit status, and close() stays quiet',
        () async {
      final runner = await connected();
      CommandResult? result;
      Object? error;
      try {
        result = await runner.run('pitool-test reset');
      } catch (e) {
        error = e;
      }
      // Either outcome is a legitimate "result unknown" — what must never
      // happen is close() throwing and replacing it.
      if (result != null) {
        expect(result.exitCode, isNull);
        expect(result.stdout, contains('before reset'));
      } else {
        expect(error, isNotNull);
      }
      await runner.close(); // must complete without throwing
    });
  });

  // `pitool-test freeze <s>`: the server answers nothing for that long — what
  // a link that died without a word looks like from here.
  group('a peer that stops answering', () {
    test('an exec request without an answer ends as a TimeoutException',
        () async {
      final runner = await connected(
          cfg: config(startTimeout: const Duration(seconds: 1)));
      final frozen = runner.run('pitool-test freeze 3');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      // The channel for this one is not confirmed before the thaw.
      final watch = Stopwatch()..start();
      await expectLater(
        runner.run('echo late'),
        // Its own kind of timeout: the command never started (see reboot).
        throwsA(isA<CommandNotStartedException>().having(
            (e) => e.duration, 'duration', const Duration(seconds: 1))),
      );
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 2200)));
      // The connection itself was fine: the first command still ends.
      final r = await frozen;
      await runner.close();
      expect(r.stdout, 'thawed\n');
      expect(r.exitCode, 0);
    });

    test('a command the peer confirms late still runs: the connect timeout '
        'does not bound its start', () async {
      // A Pi whose session setup takes longer than the connect timeout (the
      // 4 s of an address probe, here 1 s): it answered the login, so it is
      // there, and the command waits for it under the start limit.
      final runner =
          await connected(cfg: config(timeout: const Duration(seconds: 1)));
      final frozen = runner.run('pitool-test freeze 3');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final watch = Stopwatch()..start();
      final late = await runner.run('echo late');
      // Confirmed only after the thaw, well past the connect timeout.
      expect(watch.elapsed, greaterThan(const Duration(milliseconds: 1500)));
      expect(late.stdout, 'late\n');
      expect(late.exitCode, 0);
      await frozen;
      await runner.close();
    });

    test('close() ends a run() whose exec request is still unanswered',
        () async {
      // The cancel path. With dartssh2 2.22.5 this run() never returned.
      final runner = await connected(); // start limit 60 s: not what ends it
      final frozen = runner.run('pitool-test freeze 2');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      Object? error;
      final waiting = runner
          .run('echo late')
          .then<void>((_) {}, onError: (Object e) => error = e);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final closing = runner.close();
      await waiting.timeout(const Duration(seconds: 1));
      expect(error, isNotNull);
      expect(error, isNot(isA<TimeoutException>()));
      await closing;
      await frozen.then<void>((_) {}, onError: (Object _) {});
      // Leave only once the server answers again.
      await (await connected()).close();
    });

    test('close() while a command is at work returns what came, without an '
        'exit status', () async {
      // The other side of the test above, and what reboot/shutdown tell the
      // two apart by: a result means the peer had the command, an error that
      // it had not confirmed it yet.
      final runner = await connected();
      final running = runner.run('echo started; sleep 5', stdin: 'pw\n');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await runner.close();
      final r = await running.timeout(const Duration(seconds: 5));
      expect(r.stdout, 'started\n');
      expect(r.exitCode, isNull);
    });

    test('stdin the peer does not take ends under the inactivity timeout',
        () async {
      final runner = await connected(
          cfg: config(commandTimeout: const Duration(seconds: 1)));
      // More than the channel window, for a command that never reads it. The
      // inactivity check ticks every 5 s; without it this returned when the
      // command ended, and over a dead link not at all.
      final input = 'x' * (6 * 1024 * 1024);
      final watch = Stopwatch()..start();
      await expectLater(
        runner.run('sleep 9', stdin: input),
        throwsA(isA<TimeoutException>()),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 8)));
      await runner.close();
    });

    test('close() ends a run() whose stdin is still on its way', () async {
      // The cancel path during an upload; the inactivity timeout (10 min) is
      // not what ends it.
      final runner = await connected();
      final input = 'x' * (6 * 1024 * 1024);
      final running = runner
          .run('sleep 5', stdin: input)
          .then<Object?>((r) => r, onError: (Object e) => e);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await runner.close();
      final outcome = await running.timeout(const Duration(seconds: 3));
      // A result without an exit status or an error: both say "unknown".
      if (outcome is CommandResult) {
        expect(outcome.exitCode, isNull);
      } else {
        expect(outcome, isNot(isA<TimeoutException>()));
      }
    });

    test('stdin that takes longer than the connect timeout is not cut off',
        () async {
      // An upload: the peer takes its time. The connect timeout must not be
      // what bounds it, or every larger file would fail.
      final runner =
          await connected(cfg: config(timeout: const Duration(seconds: 1)));
      final input = 'x' * (6 * 1024 * 1024);
      final r = await runner.run('sleep 3; wc -c', stdin: input);
      await runner.close();
      expect(int.parse(r.stdout.trim()), input.length);
      expect(r.exitCode, 0);
    });

    test('stdin the peer takes slowly is not cut off while it keeps moving',
        () async {
      // A slow upload: as a whole it takes longer than the inactivity timeout
      // and prints nothing, but it never stands still for that long. The peer
      // takes 1 MiB and pauses, sixteen times, then the rest at once.
      final runner = await connected(
          cfg: config(commandTimeout: const Duration(seconds: 4)));
      const mib = 1024 * 1024;
      final input = 'x' * (24 * mib);
      final r = await runner.run(
          'for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do '
          'head -c $mib >/dev/null; sleep 0.5; done; wc -c',
          stdin: input);
      await runner.close();
      expect(int.parse(r.stdout.trim()), 8 * mib);
      expect(r.exitCode, 0);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
