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
  }) =>
      SshConfig(
        host: '127.0.0.1',
        port: port,
        username: 'pi',
        password: password,
        privateKey: privateKey,
        timeout: timeout,
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
}
