/// Connection config + the SSH abstraction the updater depends on.
///
/// Keeping the SSH surface behind [SshRunner] lets the update orchestration be
/// unit-tested with a fake, without a real connection. The real adapter lives
/// in `dartssh2_runner.dart`.
library;

/// Immutable connection parameters entered by the user.
class SshConfig {
  final String host;
  final int port;
  final String username;
  final String password;

  /// Bounds the TCP connect AND the SSH auth handshake.
  final Duration timeout;

  /// Max time a command may produce NO output before it's considered stalled.
  /// This is an *inactivity* timeout, not a total cap: a big `apt-get
  /// full-upgrade` or `docker pull` streams progress for many minutes and must
  /// be allowed to finish, but a truly dropped/hung connection (no output at
  /// all for this long) still aborts. Reset on every stdout/stderr chunk.
  final Duration commandTimeout;

  /// Optional PEM private key for SSH auth. When non-empty, the connection
  /// authenticates with this key instead of [password]; [password] is then
  /// used only for `sudo -S`.
  final String privateKey;
  final String keyPassphrase;

  const SshConfig({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    this.timeout = const Duration(seconds: 15),
    this.commandTimeout = const Duration(minutes: 10),
    this.privateKey = '',
    this.keyPassphrase = '',
  });

  /// Same connection, different address or deadline — used by the home/tailnet
  /// fallback (short deadline for the first attempt) and by the reachability
  /// probe. Everything else, credentials included, is carried over unchanged.
  SshConfig copyWith({String? host, Duration? timeout}) => SshConfig(
        host: host ?? this.host,
        port: port,
        username: username,
        password: password,
        timeout: timeout ?? this.timeout,
        commandTimeout: commandTimeout,
        privateKey: privateKey,
        keyPassphrase: keyPassphrase,
      );

  bool get usesKeyAuth => privateKey.trim().isNotEmpty;
}

/// Result of running a single remote command.
class CommandResult {
  final int? exitCode;
  final String stdout;
  final String stderr;

  const CommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });
}

/// Thrown by a runner when the host's SSH key no longer matches the trusted
/// one (possible MITM, or the Pi was re-flashed). Carries the new fingerprint
/// so the UI can show it.
class HostKeyChangedException implements Exception {
  final String host;
  final int port;
  final String presented;
  final String? stored;

  const HostKeyChangedException({
    required this.host,
    required this.port,
    required this.presented,
    required this.stored,
  });

  @override
  String toString() => 'HostKeyChangedException($host:$port, new=$presented)';
}

/// Thrown when the user declined to trust a host's key on first use (the
/// fingerprint confirmation dialog was cancelled). The handshake is aborted
/// before any password is sent.
class HostKeyDeclinedException implements Exception {
  const HostKeyDeclinedException();
  @override
  String toString() => 'HostKeyDeclinedException';
}

/// Minimal SSH surface used by the updater.
abstract class SshRunner {
  /// Open the connection and authenticate. Throws on connection/auth failure.
  Future<void> connect();

  /// Run [command]. If [stdin] is non-null it is written to the process' stdin
  /// (used to feed the sudo password to `sudo -S`). [onOutput] receives output
  /// chunks as they arrive so the UI can stream them live.
  Future<CommandResult> run(
    String command, {
    String? stdin,
    void Function(String chunk)? onOutput,
  });

  /// Close the connection. Safe to call even if [connect] failed.
  Future<void> close();
}
