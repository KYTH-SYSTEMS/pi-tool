import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'host_key.dart';
import 'settings_store.dart';
import 'ssh_runner.dart';

/// Real [SshRunner] backed by dartssh2 (pure-Dart SSH, password auth).
///
/// Thin I/O adapter: no parsing or business logic lives here (that is in the
/// unit-tested pure layer). Exercised end-to-end against a real SSH peer by
/// test/ssh_integration_test.dart (with tool/ssh_test_server.py) — run that
/// before shipping a dartssh2 upgrade.
class Dartssh2Runner implements SshRunner {
  final SshConfig config;
  final HostKeyStore _hostKeyStore;

  /// On the FIRST connection to a host, ask the user to confirm the presented
  /// SHA256 fingerprint before trusting it. Returns true to trust + proceed,
  /// false to abort (no password is sent). When null, first use is trusted
  /// automatically (legacy TOFU / tests).
  ///
  /// [host] is the host actually being verified — NOT necessarily the one in
  /// the connection form: the migration helper and the "Alle Pis" overview
  /// connect to other profiles, and the dialog used to name the wrong Pi above
  /// a foreign fingerprint (audit 2026-08-15).
  final Future<bool> Function(String host, String fingerprint)? confirmFirstUse;

  SSHClient? _client;
  SSHSocket? _socket;
  // Completed by close() to abort an in-flight connect() immediately (cancel),
  // instead of blocking until the connect/auth timeout fires.
  Completer<void>? _closeSignal;
  String? _changedFingerprint;
  String? _storedAtCheck;
  bool _firstUseDeclined = false;
  // Measures the handshake for its timeout. Stopped while the user reads the
  // first-use fingerprint dialog — that is their time, not the Pi's.
  final Stopwatch _handshakeClock = Stopwatch();

  /// Cipher preference. Not dartssh2's default order on purpose: its AES-GCM is
  /// pure Dart and moved 6.9 MB in 31 s in the integration test, against under
  /// 2 s for ChaCha20-Poly1305 or AES-CTR — that is the difference between a
  /// backup download taking seconds or minutes. ChaCha20 is an AEAD cipher
  /// every OpenSSH since 6.5 offers; CTR (with the library's ETM MACs) covers
  /// what is older, GCM stays as the last resort.
  static const _algorithms = SSHAlgorithms(
    cipher: [
      SSHCipherType.chacha20poly1305,
      SSHCipherType.aes256ctr,
      SSHCipherType.aes128ctr,
      SSHCipherType.aes256gcm,
      SSHCipherType.aes128gcm,
    ],
  );

  Dartssh2Runner(this.config, {HostKeyStore? hostKeyStore, this.confirmFirstUse})
      : _hostKeyStore = hostKeyStore ?? SecureHostKeyStore();

  /// True when the user declined the first-use fingerprint confirmation.
  bool get firstUseDeclined => _firstUseDeclined;

  /// TOFU host-key decision, isolated for unit testing. [fingerprint] is the
  /// UTF-8-encoded `SHA256:<base64>` dartssh2 presents. First use records the
  /// key and accepts; a match accepts; a change records the new fingerprint and
  /// rejects (false) so the handshake aborts before any password is sent.
  Future<bool> checkAndRecordHostKey(Uint8List fingerprint) async {
    final presented = utf8.decode(fingerprint);
    final id = hostKeyId(config.host, config.port);
    final String? stored;
    try {
      stored = await _hostKeyStore.get(id);
    } catch (_) {
      // What is trusted for this host cannot be read (secure storage throws
      // for a value it cannot decrypt, instead of answering "nothing
      // stored"). Not a first use: that would trust whoever answers and write
      // over the pin. Rejected like a changed key, with no stored value to go
      // with it — no password is sent, and "trust new key" (forget, then
      // confirm as on first use) is the way on.
      _changedFingerprint = presented;
      _storedAtCheck = null;
      return false;
    }
    switch (verifyHostKey(stored: stored, presented: presented)) {
      case HostKeyVerdict.firstUse:
        if (confirmFirstUse != null) {
          final wasRunning = _handshakeClock.isRunning;
          _handshakeClock.stop();
          final bool trust;
          try {
            trust = await confirmFirstUse!(config.host, presented);
          } finally {
            if (wasRunning) _handshakeClock.start();
          }
          if (!trust) {
            _firstUseDeclined = true;
            return false; // abort the handshake — never trust or send a password
          }
        }
        await _hostKeyStore.set(id, presented);
        return true;
      case HostKeyVerdict.match:
        return true;
      case HostKeyVerdict.changed:
        _changedFingerprint = presented;
        _storedAtCheck = stored;
        return false;
    }
  }

  /// The new fingerprint captured when [checkAndRecordHostKey] saw a change.
  String? get changedFingerprint => _changedFingerprint;

  @override
  Future<void> connect() async {
    // SSHSocket.connect's timeout only bounds the TCP handshake, so bound the
    // auth handshake separately — otherwise a host that accepts TCP but stalls
    // during key-exchange/auth would hang forever.
    // Parse the private key before opening the socket so a bad key/passphrase
    // fails fast (and surfaces as a clear auth error) without leaking a socket.
    // fromPem throws SSHKeyDecryptError for passphrase issues but plain
    // FormatException/UnsupportedError/ArgumentError for malformed/unsupported
    // keys — normalise them all to SSHKeyDecodeError so the UI shows one clear
    // "key invalid" message instead of a raw error.
    List<SSHKeyPair>? identities;
    if (config.usesKeyAuth) {
      try {
        identities = SSHKeyPair.fromPem(
          config.privateKey,
          config.keyPassphrase.isEmpty ? null : config.keyPassphrase,
        );
      } on SSHKeyDecodeError {
        rethrow;
      } catch (e) {
        throw SSHKeyDecodeError('Privater SSH-Key konnte nicht gelesen werden', e);
      }
    }

    // Make the whole handshake abortable: close()/cancel completes this signal,
    // and each await below races against it so a cancel returns at once instead
    // of blocking until the connect/auth timeout (the Tailscale "stalls mid-
    // handshake" case). Whichever future settles first wins the race.
    final closed = _closeSignal = Completer<void>();
    Future<S> untilClosed<S>(Future<S> f) => Future.any<S>([
          f,
          closed.future.then<S>((_) => throw const _ConnectAborted()),
        ]);

    final socketFuture =
        SSHSocket.connect(config.host, config.port, timeout: config.timeout);
    // If the cancel won the race, the socket may still open a moment later —
    // close it then so it isn't leaked.
    unawaited(socketFuture.then((s) {
      if (closed.isCompleted) s.close();
    }, onError: (_) {}));

    final SSHSocket socket;
    try {
      socket = await untilClosed(socketFuture);
    } on _ConnectAborted {
      return; // _withConnection sees the cancel flag → reports "Abgebrochen."
    }
    _socket = socket;

    final client = SSHClient(
      socket,
      username: config.username,
      // Keep the connection alive during long, quiet phases (e.g. dpkg
      // unpacking a large package) so a NAT/router doesn't drop the idle TCP
      // session mid-upgrade.
      keepAliveInterval: const Duration(seconds: 20),
      algorithms: _algorithms,
      // Key auth when a private key is provided; otherwise password auth.
      identities: identities,
      onPasswordRequest: config.usesKeyAuth ? null : () => config.password,
      // TOFU host-key check. dartssh2 hands us the OpenSSH `SHA256:<base64>`
      // fingerprint (UTF-8 bytes). Returning false aborts the handshake before
      // any password is sent. Delegates to a testable method.
      onVerifyHostKey: (type, fingerprint) => checkAndRecordHostKey(fingerprint),
    );
    // Store BEFORE awaiting auth so a cancel during the handshake can close it.
    _client = client;
    _handshakeClock
      ..reset()
      ..start();
    try {
      // Force authentication now so wrong-password errors surface here. The
      // deadline counts handshake time only: the first-use dialog stops the
      // clock, or a user who actually compares the fingerprint would be told
      // "Pi nicht erreichbar" for a Pi that answered at once.
      await untilClosed(withinActiveTime(
          client.authenticated, config.timeout, _handshakeClock));
    } on _ConnectAborted {
      _closeQuietly(client);
      return; // cancelled during the handshake
    } catch (e) {
      _closeQuietly(client);
      // The user declined to trust a first-seen key — abort with a clear error.
      if (_firstUseDeclined) {
        throw const HostKeyDeclinedException();
      }
      // A rejected host key surfaces as an SSHHostkeyError here; translate it
      // to a typed domain error carrying the new fingerprint.
      if (_changedFingerprint != null) {
        throw HostKeyChangedException(
          host: config.host,
          port: config.port,
          presented: _changedFingerprint!,
          stored: _storedAtCheck,
        );
      }
      rethrow;
    } finally {
      _handshakeClock.stop();
    }
  }

  /// Closes [client] without waiting and without letting a failure surface:
  /// dartssh2's close() is asynchronous and can complete with the socket's
  /// error, which nobody would be listening for.
  void _closeQuietly(SSHClient client) {
    unawaited(client.close().catchError((Object _) {}));
  }

  @override
  Future<CommandResult> run(
    String command, {
    String? stdin,
    void Function(String chunk)? onOutput,
  }) async {
    final client = _client;
    if (client == null) {
      throw StateError('connect() must be called before run()');
    }

    // Until the Pi has confirmed the channel and the exec request, nothing
    // below is listening and the inactivity timeout has not started. dartssh2
    // ends this wait on a transport error and on close(), but over a link that
    // died silently neither comes before the TCP stack gives up. So it is
    // bounded — by a limit of its own, not by the connect timeout: sshd sets
    // the session up (PAM) only after the login it has already reported as
    // successful, and a Pi that takes 25 s for that is slow but usable. A
    // session that still opens later is closed again.
    final SSHSession session;
    try {
      session = await withinOrDiscard(client.execute(command),
          config.startTimeout, (opened) => opened.close());
    } on TimeoutException catch (e) {
      // Its own type: who takes a lost connection for the command at work
      // (reboot, shutdown) has to tell this apart — nothing was started.
      throw CommandNotStartedException(e.duration ?? config.startTimeout);
    }

    final stdoutBuf = StringBuffer();
    final stderrBuf = StringBuffer();

    // Line-buffer the live [onOutput] callback: emit only whole lines so a
    // consumer that redacts per call (the updater masks the sudo password) can
    // never be defeated by a value split across two network chunks — a secret
    // would have to straddle a newline, which it cannot. The full raw output is
    // still captured verbatim in the buffers for the returned result.
    final outLines = onOutput == null ? null : LineBuffer(onOutput);
    final errLines = onOutput == null ? null : LineBuffer(onOutput);

    // Drain both streams to completion. asFuture() resolves on the stream's
    // onDone, which dartssh2 fires only after all channel data is delivered —
    // so no trailing chunk (e.g. a short version string) can be lost. Awaiting
    // the streams (rather than session.done + cancel) is what guarantees this.
    // Every chunk also refreshes [lastActivity] for the inactivity timeout.
    // Decoded as a stream, not packet by packet: SSH cuts the output at byte
    // boundaries, so a multi-byte character can straddle two packets — decoded
    // separately both halves became U+FFFD, and the config editor wrote that
    // back into the file.
    var lastActivity = DateTime.now();
    final outText = Utf8ChunkDecoder((s) {
      stdoutBuf.write(s);
      outLines?.add(s);
    });
    final errText = Utf8ChunkDecoder((s) {
      stderrBuf.write(s);
      errLines?.add(s);
    });
    final outSub = session.stdout.listen((data) {
      lastActivity = DateTime.now();
      outText.add(data);
    });
    final errSub = session.stderr.listen((data) {
      lastActivity = DateTime.now();
      errText.add(data);
    });

    // Not awaited on its own: stdin is out once all of it is handed to the
    // transport, and input beyond the peer's window only goes out as the Pi
    // reads it — over a dead link, never. So it is waited for under the
    // inactivity timeout below, together with the output. That limit and not
    // the short connect timeout: an upload legitimately takes minutes. And as
    // inactivity, not as a cap on the transfer: stdin goes in pieces, dartssh2
    // takes the next one only when the peer's window has room for it, and
    // every piece taken counts like output. A slow upload that still moves
    // runs on; one the Pi stopped taking goes quiet.
    void active() => lastActivity = DateTime.now();
    final stdinSent = (stdin == null
            ? session.stdin.close()
            : session.stdin
                .addStream(
                    inPieces(Uint8List.fromList(utf8.encode(stdin)), active))
                .then((_) => session.stdin.close()))
        .whenComplete(active);

    // Inactivity timeout, not a total cap: a multi-minute upgrade that keeps
    // streaming progress must run to completion, but a command that produces no
    // output for [commandTimeout] (stalled/dropped connection) aborts.
    final drained = Future.wait(
        [stdinSent, outSub.asFuture<void>(), errSub.asFuture<void>()]);
    final idle = Completer<void>();
    final ticker = Timer.periodic(const Duration(seconds: 5), (t) {
      if (DateTime.now().difference(lastActivity) >= config.commandTimeout) {
        t.cancel();
        if (!idle.isCompleted) {
          idle.completeError(
              TimeoutException('keine Ausgabe', config.commandTimeout));
        }
      }
    });
    try {
      await Future.any([drained, idle.future]);
    } on TimeoutException {
      // Deterministic cleanup: cancel the subscriptions, don't rely on close()
      // tearing the streams down promptly.
      await outSub.cancel();
      await errSub.cancel();
      session.close();
      rethrow;
    } finally {
      ticker.cancel();
    }

    // End of stream: a character cut off by it is reported, not dropped.
    outText.close();
    errText.close();
    // Flush any trailing partial line (output without a final newline).
    outLines?.flush();
    errLines?.flush();

    // dartssh2 ends the output streams on CHANNEL_EOF, but the exit status
    // may only arrive after it (just before CHANNEL_CLOSE). Reading
    // session.exitCode right away returned null for commands that did
    // finish — and callers must treat null as "result unknown". Wait briefly.
    final exitCode = await resolveExitCode(
      () => session.waitForExit(timeout: exitStatusWait),
      () => session.exitCode,
    );

    return CommandResult(
      exitCode: exitCode,
      stdout: stdoutBuf.toString(),
      stderr: stderrBuf.toString(),
    );
  }

  /// How long [run] waits for a late exit status after the output ended.
  static const Duration exitStatusWait = Duration(seconds: 3);

  @override
  Future<void> close() async {
    // Abort an in-flight connect() that's racing on this signal so a cancel
    // takes effect immediately instead of waiting out the connect/auth timeout.
    if (_closeSignal != null && !_closeSignal!.isCompleted) {
      _closeSignal!.complete();
    }
    final client = _client;
    final socket = _socket;
    _client = null;
    _socket = null;
    // Best-effort and bounded. After a socket error (Wi-Fi gone, connection
    // reset) dart:io completes Socket.done with that error and close() hands
    // back the very same future — so closing a dead connection would throw,
    // from the `finally` of the action that just ran on it, and replace its
    // result ("Pi-Job läuft weiter", "Ergebnis unbekannt") with a raw socket
    // error. Closing must never have a say in what the action reports.
    for (final close in [
      if (client != null) client.close,
      if (socket != null) socket.close,
    ]) {
      try {
        await close().timeout(closeWait);
      } catch (_) {}
    }
  }

  /// How long [close] waits for either side of the connection to shut down.
  static const Duration closeWait = Duration(seconds: 3);
}

/// Completes with [work], or with a [TimeoutException] once [clock] has RUN
/// for [limit]. Time during which the clock is stopped does not count — the
/// caller stops it while waiting on the user.
Future<T> withinActiveTime<T>(
  Future<T> work,
  Duration limit,
  Stopwatch clock, {
  Duration tick = const Duration(milliseconds: 200),
}) {
  final result = Completer<T>();
  final timer = Timer.periodic(tick, (_) {
    if (clock.elapsed >= limit && !result.isCompleted) {
      result.completeError(TimeoutException('handshake', limit));
    }
  });
  work.then((value) {
    if (!result.isCompleted) result.complete(value);
  }, onError: (Object e, StackTrace st) {
    if (!result.isCompleted) result.completeError(e, st);
  });
  return result.future.whenComplete(timer.cancel);
}

/// Completes with [pending], or with a [TimeoutException] once [limit] has
/// passed. What [pending] still delivers after that is handed to [discard] —
/// it holds something (an open channel) nobody is waiting for any more. A late
/// error is dropped.
Future<T> withinOrDiscard<T>(
  Future<T> pending,
  Duration limit,
  void Function(T value) discard,
) =>
    pending.timeout(limit, onTimeout: () {
      unawaited(pending.then(discard).catchError((Object _) {}));
      throw TimeoutException('keine Antwort', limit);
    });

/// [bytes] as a stream of pieces of at most [size], each made only when the
/// listener is ready for the next one; [onPiece] runs for every piece made. A
/// paused listener (dartssh2 waiting for room in the peer's window) stops it —
/// so [onPiece] tells how far a transfer got, which one big chunk cannot.
Stream<Uint8List> inPieces(
  Uint8List bytes,
  void Function() onPiece, {
  int size = 32 * 1024,
}) async* {
  for (var at = 0; at < bytes.length; at += size) {
    final end = at + size < bytes.length ? at + size : bytes.length;
    onPiece();
    yield Uint8List.sublistView(bytes, at, end);
  }
}

/// Decodes UTF-8 that arrives in arbitrary byte chunks. A character whose bytes
/// are split across two chunks is held back until it is complete; bytes that
/// are not UTF-8 at all become U+FFFD instead of throwing.
class Utf8ChunkDecoder {
  Utf8ChunkDecoder(void Function(String text) onText)
      : _sink = const Utf8Decoder(allowMalformed: true)
            .startChunkedConversion(_TextSink(onText));

  final ByteConversionSink _sink;

  void add(List<int> bytes) => _sink.add(bytes);

  /// Call once at the end of the stream to flush an incomplete tail.
  void close() => _sink.close();
}

class _TextSink implements Sink<String> {
  _TextSink(this._onText);
  final void Function(String text) _onText;

  @override
  void add(String text) {
    if (text.isNotEmpty) _onText(text);
  }

  @override
  void close() {}
}

/// The exit code of a command whose output is fully drained: [waitForExit]
/// (bounded by its own timeout) for a status that may still be on its way,
/// else whatever [current] already knows. A failing wait counts as no answer.
/// Null stays null — callers treat it as "unknown", never as success.
Future<int?> resolveExitCode(
  Future<int?> Function() waitForExit,
  int? Function() current,
) async {
  int? code;
  try {
    code = await waitForExit();
  } catch (_) {
    code = null;
  }
  return code ?? current();
}

/// Thrown internally when close() (a user cancel) aborts an in-flight connect().
class _ConnectAborted implements Exception {
  const _ConnectAborted();
}

/// Buffers streamed output and emits only WHOLE lines to [onLine], holding any
/// trailing partial line until a newline arrives (or [flush] is called). This
/// is a security control: a per-line redactor (the sudo-password mask) can't be
/// defeated by a secret split across two network chunks, because a secret would
/// have to straddle a newline — which it cannot.
class LineBuffer {
  LineBuffer(this.onLine);

  final void Function(String line) onLine;
  final StringBuffer _partial = StringBuffer();

  /// Feed a raw chunk; emits every complete line it now contains.
  ///
  /// One pass over the chunk. Cutting the emitted line off the front of the
  /// remaining text copied that remainder once per line — quadratic in the
  /// packet size, 16 s for an output of 940,000 short lines.
  void add(String chunk) {
    var start = 0;
    var nl = chunk.indexOf('\n');
    while (nl != -1) {
      if (_partial.isEmpty) {
        onLine(chunk.substring(start, nl + 1));
      } else {
        _partial.write(chunk.substring(start, nl + 1));
        final line = _partial.toString();
        _partial.clear();
        onLine(line);
      }
      start = nl + 1;
      nl = chunk.indexOf('\n', start);
    }
    if (start < chunk.length) _partial.write(chunk.substring(start));
  }

  /// Emit any trailing output that had no final newline.
  void flush() {
    if (_partial.isNotEmpty) {
      final line = _partial.toString();
      _partial.clear();
      onLine(line);
    }
  }
}
