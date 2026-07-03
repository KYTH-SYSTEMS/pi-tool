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
/// unit-tested pure layer). Exercised end-to-end by the manual dry-run against
/// the real Pi (see README).
class Dartssh2Runner implements SshRunner {
  final SshConfig config;
  final HostKeyStore _hostKeyStore;

  /// On the FIRST connection to a host, ask the user to confirm the presented
  /// SHA256 fingerprint before trusting it. Returns true to trust + proceed,
  /// false to abort (no password is sent). When null, first use is trusted
  /// automatically (legacy TOFU / tests).
  final Future<bool> Function(String fingerprint)? confirmFirstUse;

  SSHClient? _client;
  SSHSocket? _socket;
  // Completed by close() to abort an in-flight connect() immediately (cancel),
  // instead of blocking until the connect/auth timeout fires.
  Completer<void>? _closeSignal;
  String? _changedFingerprint;
  String? _storedAtCheck;
  bool _firstUseDeclined = false;

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
    final stored = await _hostKeyStore.get(id);
    switch (verifyHostKey(stored: stored, presented: presented)) {
      case HostKeyVerdict.firstUse:
        if (confirmFirstUse != null) {
          final trust = await confirmFirstUse!(presented);
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
    try {
      // Force authentication now so wrong-password errors surface here.
      await untilClosed(client.authenticated.timeout(config.timeout));
    } on _ConnectAborted {
      client.close();
      return; // cancelled during the handshake
    } catch (e) {
      client.close();
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
    }
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

    final session = await client.execute(command);

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
    var lastActivity = DateTime.now();
    final outSub = session.stdout.listen((data) {
      lastActivity = DateTime.now();
      final s = utf8.decode(data, allowMalformed: true);
      stdoutBuf.write(s);
      outLines?.add(s);
    });
    final errSub = session.stderr.listen((data) {
      lastActivity = DateTime.now();
      final s = utf8.decode(data, allowMalformed: true);
      stderrBuf.write(s);
      errLines?.add(s);
    });

    if (stdin != null) {
      session.stdin.add(Uint8List.fromList(utf8.encode(stdin)));
    }
    await session.stdin.close();

    // Inactivity timeout, not a total cap: a multi-minute upgrade that keeps
    // streaming progress must run to completion, but a command that produces no
    // output for [commandTimeout] (stalled/dropped connection) aborts.
    final drained =
        Future.wait([outSub.asFuture<void>(), errSub.asFuture<void>()]);
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

    // Flush any trailing partial line (output without a final newline).
    outLines?.flush();
    errLines?.flush();

    return CommandResult(
      exitCode: session.exitCode,
      stdout: stdoutBuf.toString(),
      stderr: stderrBuf.toString(),
    );
  }

  @override
  Future<void> close() async {
    // Abort an in-flight connect() that's racing on this signal so a cancel
    // takes effect immediately instead of waiting out the connect/auth timeout.
    if (_closeSignal != null && !_closeSignal!.isCompleted) {
      _closeSignal!.complete();
    }
    _client?.close();
    _client = null;
    await _socket?.close();
    _socket = null;
  }
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
  String _partial = '';

  /// Feed a raw chunk; emits every complete line it now contains.
  void add(String chunk) {
    var buf = _partial + chunk;
    var nl = buf.indexOf('\n');
    while (nl != -1) {
      onLine(buf.substring(0, nl + 1));
      buf = buf.substring(nl + 1);
      nl = buf.indexOf('\n');
    }
    _partial = buf;
  }

  /// Emit any trailing output that had no final newline.
  void flush() {
    if (_partial.isNotEmpty) {
      onLine(_partial);
      _partial = '';
    }
  }
}
