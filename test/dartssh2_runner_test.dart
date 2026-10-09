import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:evcc_updater/src/dartssh2_runner.dart';
import 'package:evcc_updater/src/host_key.dart';
import 'package:evcc_updater/src/parsing.dart';
import 'package:evcc_updater/src/ssh_runner.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeHostKeyStore implements HostKeyStore {
  final Map<String, String> data;
  FakeHostKeyStore([Map<String, String>? initial]) : data = {...?initial};
  @override
  Future<String?> get(String id) async => data[id];
  @override
  Future<void> set(String id, String fingerprint) async =>
      data[id] = fingerprint;
  @override
  Future<void> remove(String id) async => data.remove(id);
}

/// A store whose reads throw, as secure storage does for a value it cannot
/// decrypt.
class _UnreadableHostKeyStore extends FakeHostKeyStore {
  _UnreadableHostKeyStore(super.initial);
  @override
  Future<String?> get(String id) async =>
      throw Exception('AEADBadTagException');
}

const _config =
    SshConfig(host: '192.168.178.64', port: 22, username: 'pi', password: 'pw');

Uint8List _fp(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('Dartssh2Runner.checkAndRecordHostKey (TOFU glue)', () {
    final id = hostKeyId(_config.host, _config.port);

    test('first use: records the key and accepts', () async {
      final store = FakeHostKeyStore();
      final runner = Dartssh2Runner(_config, hostKeyStore: store);

      final accepted = await runner.checkAndRecordHostKey(_fp('SHA256:aaa'));

      expect(accepted, isTrue);
      expect(store.data[id], 'SHA256:aaa'); // trusted on first use
    });

    test('first use with a confirm callback that accepts: records + accepts',
        () async {
      final store = FakeHostKeyStore();
      var shown = '';
      var shownHost = '';
      final runner = Dartssh2Runner(_config,
          hostKeyStore: store,
          confirmFirstUse: (h, fp) async {
            shown = fp;
            shownHost = h;
            return true;
          });

      final accepted = await runner.checkAndRecordHostKey(_fp('SHA256:new'));

      expect(accepted, isTrue);
      expect(shown, 'SHA256:new'); // fingerprint surfaced to the user
      // The host being verified travels with it — otherwise the dialog names
      // whatever sits in the connection form (audit 2026-08-15).
      expect(shownHost, _config.host);
      expect(store.data[id], 'SHA256:new');
      expect(runner.firstUseDeclined, isFalse);
    });

    test('first use declined: does not trust, aborts before any password',
        () async {
      final store = FakeHostKeyStore();
      final runner = Dartssh2Runner(_config,
          hostKeyStore: store, confirmFirstUse: (_, _) async => false);

      final accepted = await runner.checkAndRecordHostKey(_fp('SHA256:new'));

      expect(accepted, isFalse); // false aborts the handshake → no password sent
      expect(store.data, isEmpty); // NOT trusted
      expect(runner.firstUseDeclined, isTrue);
    });

    test('match: accepts without rewriting the store', () async {
      final store = FakeHostKeyStore({id: 'SHA256:aaa'});
      final runner = Dartssh2Runner(_config, hostKeyStore: store);

      final accepted = await runner.checkAndRecordHostKey(_fp('SHA256:aaa'));

      expect(accepted, isTrue);
      expect(store.data[id], 'SHA256:aaa');
      expect(runner.changedFingerprint, isNull);
    });

    test('changed: rejects, leaves the stored key, records the new fingerprint',
        () async {
      final store = FakeHostKeyStore({id: 'SHA256:old'});
      final runner = Dartssh2Runner(_config, hostKeyStore: store);

      final accepted = await runner.checkAndRecordHostKey(_fp('SHA256:new'));

      expect(accepted, isFalse); // aborts the handshake → no password sent
      expect(store.data[id], 'SHA256:old'); // NOT overwritten
      expect(runner.changedFingerprint, 'SHA256:new');
    });

    // Secure storage throws for a value it cannot decrypt: the pin is there,
    // it just cannot be read. That is neither a match nor a first use.
    test('unreadable pin: rejects like a changed key, asks nobody, writes '
        'nothing', () async {
      final store = _UnreadableHostKeyStore({id: 'SHA256:old'});
      var asked = false;
      final runner = Dartssh2Runner(_config,
          hostKeyStore: store,
          confirmFirstUse: (_, _) async {
            asked = true;
            return true;
          });

      final accepted = await runner.checkAndRecordHostKey(_fp('SHA256:new'));

      expect(accepted, isFalse); // aborts the handshake → no password sent
      expect(asked, isFalse); // the first-use dialog would trust over the pin
      expect(store.data[id], 'SHA256:old'); // NOT overwritten
      expect(runner.changedFingerprint, 'SHA256:new');
      expect(runner.firstUseDeclined, isFalse);
    });
  });

  group('LineBuffer (per-line redaction guard)', () {
    test('holds a partial line until the newline, then emits it whole', () {
      final lines = <String>[];
      final lb = LineBuffer(lines.add);
      lb.add('sek'); // a secret split across two chunks…
      lb.add('ret\n'); // …only surfaces once the whole line is complete
      expect(lines, ['sekret\n']);
    });

    test('a redactor applied per whole line cannot be defeated by a chunk split',
        () {
      final out = <String>[];
      final lb = LineBuffer((line) => out.add(redactPassword(line, 'sekret')));
      lb.add('pw=sek');
      lb.add('ret done\n');
      expect(out, ['pw=$passwordMask done\n']); // masked despite the split
    });

    test('splits multiple newlines in one chunk and flushes the tail', () {
      final lines = <String>[];
      final lb = LineBuffer(lines.add);
      lb.add('a\nb\nc'); // 'c' has no trailing newline yet
      expect(lines, ['a\n', 'b\n']);
      lb.flush();
      expect(lines, ['a\n', 'b\n', 'c']);
    });

    test('a partial line spread over many chunks is emitted once, whole', () {
      final lines = <String>[];
      final lb = LineBuffer(lines.add);
      for (final part in ['a', 'b', 'c', 'd']) {
        lb.add(part);
      }
      expect(lines, isEmpty);
      lb.add('e\nf');
      expect(lines, ['abcde\n']);
      lb.flush();
      expect(lines, ['abcde\n', 'f']);
      lb.flush(); // nothing left
      expect(lines, ['abcde\n', 'f']);
    });

    test('cost grows with the output, not with its square', () {
      // An apt run or a journal dump is hundreds of thousands of short lines
      // arriving in 32 KiB packets. Re-slicing the rest of the packet after
      // every line took 16 s for this input; a single pass takes milliseconds.
      final chunk = '${List.generate(4700, (i) => '$i').join('\n')}\n';
      var lines = 0;
      final lb = LineBuffer((_) => lines++);
      final watch = Stopwatch()..start();
      for (var i = 0; i < 200; i++) {
        lb.add(chunk);
      }
      watch.stop();
      expect(lines, 200 * 4700);
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    });
  });

  group('Utf8ChunkDecoder (characters across SSH packets)', () {
    test('a multi-byte character split across two chunks stays intact', () {
      final out = <String>[];
      final d = Utf8ChunkDecoder(out.add);
      final bytes = utf8.encode('grün\n');
      final cut = bytes.indexOf(0xc3) + 1; // between the two bytes of "ü"
      d.add(bytes.sublist(0, cut));
      d.add(bytes.sublist(cut));
      d.close();
      expect(out.join(), 'grün\n');
      expect(out.join(), isNot(contains('�')));
    });

    test('a four-byte character fed one byte at a time stays intact', () {
      final out = <String>[];
      final d = Utf8ChunkDecoder(out.add);
      for (final b in utf8.encode('a😀b')) {
        d.add([b]);
      }
      d.close();
      expect(out.join(), 'a😀b');
    });

    test('bytes that are not UTF-8 become U+FFFD instead of throwing', () {
      final out = <String>[];
      final d = Utf8ChunkDecoder(out.add);
      d.add([0x67, 0x72, 0xfc, 0x6e]); // "grün" in ISO-8859-1
      d.close();
      expect(out.join(), 'gr�n');
    });

    test('a sequence cut off by the end of the stream is flushed on close', () {
      final out = <String>[];
      final d = Utf8ChunkDecoder(out.add);
      d.add([0x61, 0xc3]); // "a" + first half of "ü", then nothing
      expect(out.join(), 'a');
      d.close();
      expect(out.join(), 'a�');
    });
  });

  group('withinActiveTime (handshake deadline)', () {
    test('time the clock was stopped does not count', () async {
      final clock = Stopwatch()..start();
      final work = Future<String>.delayed(
          const Duration(milliseconds: 700), () => 'done');
      // The user reads a dialog for 500 ms: the clock stands still meanwhile.
      clock.stop();
      Timer(const Duration(milliseconds: 500), clock.start);
      final result = await withinActiveTime(
          work, const Duration(milliseconds: 400), clock,
          tick: const Duration(milliseconds: 20));
      expect(result, 'done');
    });

    test('running time beyond the limit is a TimeoutException', () async {
      final clock = Stopwatch()..start();
      final work = Future<String>.delayed(
          const Duration(milliseconds: 700), () => 'done');
      await expectLater(
        withinActiveTime(work, const Duration(milliseconds: 200), clock,
            tick: const Duration(milliseconds: 20)),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('an error of the work itself passes through', () async {
      final clock = Stopwatch()..start();
      await expectLater(
        withinActiveTime(Future<void>.error(StateError('boom')),
            const Duration(seconds: 5), clock),
        throwsStateError,
      );
    });
  });

  // run() opens the channel with it: an exec request the Pi never answers
  // must end, and a channel that opens after all must not be left behind.
  group('withinOrDiscard (exec start deadline)', () {
    test('an answer in time is returned and kept', () async {
      final discarded = <String>[];
      final r = await withinOrDiscard(
          Future<String>.delayed(const Duration(milliseconds: 20), () => 'ok'),
          const Duration(seconds: 5),
          discarded.add);
      expect(r, 'ok');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(discarded, isEmpty);
    });

    test('no answer within the limit is a TimeoutException with that limit',
        () async {
      const limit = Duration(milliseconds: 100);
      final watch = Stopwatch()..start();
      await expectLater(
        withinOrDiscard(Completer<String>().future, limit, (_) {}),
        throwsA(isA<TimeoutException>()
            .having((e) => e.duration, 'duration', limit)),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('an answer after the limit is handed to discard', () async {
      final discarded = <String>[];
      final opening = Completer<String>();
      await expectLater(
        withinOrDiscard(
            opening.future, const Duration(milliseconds: 50), discarded.add),
        throwsA(isA<TimeoutException>()),
      );
      expect(discarded, isEmpty);
      opening.complete('session');
      await Future<void>.delayed(Duration.zero);
      expect(discarded, ['session']);
    });

    test('an error after the limit is dropped, not left unhandled', () async {
      final opening = Completer<String>();
      await expectLater(
        withinOrDiscard(
            opening.future, const Duration(milliseconds: 50), (_) {}),
        throwsA(isA<TimeoutException>()),
      );
      // An unhandled asynchronous error would fail this test.
      opening.completeError(StateError('SSH client closed'));
      await Future<void>.delayed(Duration.zero);
    });

    test('an error in time passes through', () async {
      await expectLater(
        withinOrDiscard(Future<String>.error(StateError('refused')),
            const Duration(seconds: 5), (_) {}),
        throwsStateError,
      );
    });
  });

  // The limit run() opens the channel under. Its own, not the connect
  // timeout: that one is short on the probes (4 s, 8 s, 12 s), and a Pi that
  // takes its time behind a successful login is slow, not out of reach.
  group('SshConfig.startTimeout (exec start limit)', () {
    test('60 s unless set, whatever the connect timeout', () {
      expect(_config.startTimeout, const Duration(seconds: 60));
      const probe = SshConfig(
          host: '192.168.178.64',
          port: 22,
          username: 'pi',
          password: 'pw',
          timeout: Duration(seconds: 4));
      expect(probe.startTimeout, const Duration(seconds: 60));
    });

    test('copyWith with another address and a short deadline keeps it', () {
      const base = SshConfig(
          host: '192.168.178.64',
          port: 2222,
          username: 'pi',
          password: 'pw',
          startTimeout: Duration(seconds: 7),
          commandTimeout: Duration(minutes: 3));
      final probe = base.copyWith(
          host: '100.64.0.5', timeout: const Duration(seconds: 4));
      expect(probe.host, '100.64.0.5');
      expect(probe.timeout, const Duration(seconds: 4));
      expect(probe.startTimeout, const Duration(seconds: 7));
      // …and the rest as it was.
      expect(probe.port, 2222);
      expect(probe.commandTimeout, const Duration(minutes: 3));
    });
  });

  // run() hands stdin to the channel with it, and counts every piece taken as
  // activity: an upload that still moves must not hit the inactivity timeout.
  group('inPieces (stdin handed over on demand)', () {
    Uint8List bytes(int n) =>
        Uint8List.fromList(List.generate(n, (i) => i % 251));

    test('the pieces put together are the input, none larger than the size',
        () async {
      final input = bytes(70000);
      final pieces = await inPieces(input, () {}, size: 32768).toList();
      expect(pieces.map((p) => p.length), [32768, 32768, 4464]);
      expect(pieces.expand((p) => p).toList(), input);
    });

    test('input that fits into one piece is one piece', () async {
      final input = bytes(32768);
      final pieces = await inPieces(input, () {}, size: 32768).toList();
      expect(pieces, [input]);
    });

    test('no input: no piece', () async {
      var made = 0;
      expect(await inPieces(Uint8List(0), () => made++).toList(), isEmpty);
      expect(made, 0);
    });

    test('a piece is made only when the listener takes one', () async {
      var made = 0;
      final taken = <Uint8List>[];
      final done = Completer<void>();
      late final StreamSubscription<Uint8List> sub;
      sub = inPieces(bytes(40), () => made++, size: 4).listen((p) {
        taken.add(p);
        if (taken.length == 1) sub.pause(); // the window is full
      }, onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // One piece handed over, at most one more waiting — not all ten.
      expect(taken.length, 1);
      expect(made, lessThanOrEqualTo(2));

      sub.resume();
      await done.future;
      expect(taken.length, 10);
      expect(made, 10);
    });
  });

  // dartssh2 closes stdout on CHANNEL_EOF; the exit status can arrive after
  // it. run() therefore waits for it (resolveExitCode) instead of reading a
  // premature null — null means "unknown" to every caller, never success.
  group('resolveExitCode (exit status after EOF)', () {
    test('an exit status that arrives after the output is returned', () async {
      final code = await resolveExitCode(
        () => Future<int?>.delayed(const Duration(milliseconds: 50), () => 0),
        () => null, // what session.exitCode says right at EOF
      );
      expect(code, 0);
    });

    test('a non-zero late status is returned as is', () async {
      final code = await resolveExitCode(
          () => Future<int?>.delayed(const Duration(milliseconds: 10), () => 100),
          () => null);
      expect(code, 100);
    });

    test('no status within the wait (timeout → null): falls back', () async {
      expect(await resolveExitCode(() async => null, () => 7), 7);
      expect(await resolveExitCode(() async => null, () => null), isNull);
    });

    test('a failing wait counts as no answer', () async {
      expect(
          await resolveExitCode(
              () => Future<int?>.error(StateError('closed')), () => null),
          isNull);
      expect(
          await resolveExitCode(
              () => Future<int?>.error(StateError('closed')), () => 3),
          3);
    });

    test('the wait is bounded', () {
      expect(Dartssh2Runner.exitStatusWait, const Duration(seconds: 3));
    });
  });

  group('Dartssh2Runner.run / connect guards', () {
    test('run() before connect() throws StateError', () {
      final runner = Dartssh2Runner(_config, hostKeyStore: FakeHostKeyStore());
      expect(() => runner.run('echo hi'), throwsStateError);
    });

    test('connect() with a malformed private key throws SSHKeyDecodeError',
        () async {
      const cfg = SshConfig(
        host: '192.168.178.64',
        port: 22,
        username: 'pi',
        password: 'pw',
        privateKey: 'not a real pem key',
      );
      final runner = Dartssh2Runner(cfg, hostKeyStore: FakeHostKeyStore());
      // The key is parsed before any socket is opened, so this fails fast with
      // a clear typed error and never touches the network.
      await expectLater(runner.connect(), throwsA(isA<SSHKeyDecodeError>()));
    });

    test('close() aborts a stalled handshake at once (cancel works mid-connect)',
        () async {
      // A server that accepts TCP but never sends the SSH banner — exactly the
      // "TCP connects but the SSH handshake stalls" case (e.g. a flaky Tailscale
      // link). Without an abortable connect this would block for the full 15 s
      // timeout, so "Abbrechen" would appear to do nothing.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final held = <Socket>[];
      server.listen(held.add); // hold the socket open, send nothing

      final runner = Dartssh2Runner(
        SshConfig(
          host: '127.0.0.1',
          port: server.port,
          username: 'pi',
          password: 'pw',
          timeout: const Duration(seconds: 15),
        ),
        hostKeyStore: FakeHostKeyStore(),
      );

      final connecting = runner.connect();
      // Let the TCP connect complete and the handshake stall.
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final sw = Stopwatch()..start();
      await runner.close(); // the user taps "Abbrechen"
      await connecting; // connect returns immediately (aborted), not after 15 s
      sw.stop();

      expect(sw.elapsed, lessThan(const Duration(seconds: 3)));

      for (final s in held) {
        s.destroy();
      }
      await server.close();
    });
  });
}
