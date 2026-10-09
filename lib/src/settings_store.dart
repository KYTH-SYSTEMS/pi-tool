import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'history.dart';
import 'host_key.dart';

/// Android options of the secure storage behind every store of this app.
///
/// `resetOnError: false`: with the plugin's default (true) a value that cannot
/// be decrypted is deleted and read as "not stored", and a Keystore key that
/// no longer fits takes all data with it. The app would see a first start and
/// save an empty configuration over profiles, passwords and SSH keys. With the
/// flag off the failure reaches Dart as an exception and what is stored stays
/// as it is; the start page then offers a retry and [resetSecureStorage].
/// The plugin reads the flag in its failure paths only — storage file, key
/// and cipher are those of the default options.
///
/// One constant for every store: the plugin keeps the options of the call that
/// opened the storage for as long as the process lives.
const kSecureStorageOptions = AndroidOptions(resetOnError: false);

/// The secure storage every store uses, unless a test hands it another one.
const kSecureStorage = FlutterSecureStorage(aOptions: kSecureStorageOptions);

/// Deletes everything in [storage] — profiles, history and trusted host keys
/// alike. The way out when what is stored can no longer be read.
///
/// If the delete throws as well, the storage did not even open (its key no
/// longer fits what is stored). One call with the plugin's own
/// `resetOnError: true` then makes the plugin drop data and key and start
/// over, as it did by default — and keep that setting until the app restarts.
/// A failure of that call is the caller's.
Future<void> resetSecureStorage(FlutterSecureStorage storage) async {
  try {
    await storage.deleteAll();
  } catch (_) {
    await storage.deleteAll(
        aOptions: const AndroidOptions(resetOnError: true));
  }
}

/// How to authenticate the SSH connection.
enum AuthMode { password, key }

/// User-entered connection settings, persisted between launches.
class Settings {
  final String host;
  final String port;
  final String username;

  /// In password mode: the SSH+sudo password. In key mode: the sudo password.
  final String password;
  final bool fullUpgrade;

  final AuthMode authMode;

  /// PEM-encoded private key (key mode only).
  final String privateKey;
  final String keyPassphrase;

  /// Scheme + port for the "open evcc web UI" link.
  final String uiScheme; // 'http' | 'https'
  final String uiPort;

  /// Whether the app requires biometric/PIN unlock on launch + resume.
  final bool lockEnabled;

  /// 'system' | 'dark' | 'light'.
  final String themeMode;

  /// evcc apt channel for fresh installs: 'stable' | 'unstable' (nightly).
  final String channel;

  /// Run a read-only status check automatically on launch.
  final bool autoCheck;

  const Settings({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.fullUpgrade,
    this.authMode = AuthMode.password,
    this.privateKey = '',
    this.keyPassphrase = '',
    this.uiScheme = 'http',
    this.uiPort = '7070',
    this.lockEnabled = false,
    this.themeMode = 'system',
    this.channel = 'stable',
    this.autoCheck = false,
  });

  static const empty = Settings(
    host: '',
    port: '22',
    username: 'pi',
    password: '',
    fullUpgrade: false,
  );
}

/// Persists [Settings] in the platform secure storage (Android Keystore-backed).
///
/// The password lives only here, encrypted at rest — never in plain prefs.
/// Tests subclass this and override [load]/[save] to avoid platform channels.
class SettingsStore {
  static const _kHost = 'host';
  static const _kPort = 'port';
  static const _kUser = 'user';
  static const _kPassword = 'password';
  static const _kFullUpgrade = 'fullUpgrade';
  static const _kAuthMode = 'authMode';
  static const _kPrivateKey = 'privateKey';
  static const _kKeyPassphrase = 'keyPassphrase';
  static const _kUiScheme = 'uiScheme';
  static const _kUiPort = 'uiPort';
  static const _kLockEnabled = 'lockEnabled';
  static const _kThemeMode = 'themeMode';
  static const _kChannel = 'channel';
  static const _kAutoCheck = 'autoCheck';

  final FlutterSecureStorage _storage;

  SettingsStore([FlutterSecureStorage? storage])
      : _storage = storage ?? kSecureStorage;

  Future<Settings> load() async {
    final all = await _storage.readAll();
    return Settings(
      host: all[_kHost] ?? Settings.empty.host,
      port: all[_kPort] ?? Settings.empty.port,
      username: all[_kUser] ?? Settings.empty.username,
      password: all[_kPassword] ?? Settings.empty.password,
      fullUpgrade: all[_kFullUpgrade] == 'true',
      authMode:
          all[_kAuthMode] == 'key' ? AuthMode.key : AuthMode.password,
      privateKey: all[_kPrivateKey] ?? '',
      keyPassphrase: all[_kKeyPassphrase] ?? '',
      uiScheme: all[_kUiScheme] ?? Settings.empty.uiScheme,
      uiPort: all[_kUiPort] ?? Settings.empty.uiPort,
      lockEnabled: all[_kLockEnabled] == 'true',
      themeMode: all[_kThemeMode] ?? Settings.empty.themeMode,
      channel: all[_kChannel] ?? Settings.empty.channel,
      autoCheck: all[_kAutoCheck] == 'true',
    );
  }

  Future<void> save(Settings s) async {
    await _storage.write(key: _kHost, value: s.host);
    await _storage.write(key: _kPort, value: s.port);
    await _storage.write(key: _kUser, value: s.username);
    await _storage.write(key: _kPassword, value: s.password);
    await _storage.write(key: _kFullUpgrade, value: s.fullUpgrade.toString());
    await _storage.write(key: _kAuthMode, value: s.authMode.name);
    await _storage.write(key: _kPrivateKey, value: s.privateKey);
    await _storage.write(key: _kKeyPassphrase, value: s.keyPassphrase);
    await _storage.write(key: _kUiScheme, value: s.uiScheme);
    await _storage.write(key: _kUiPort, value: s.uiPort);
    await _storage.write(key: _kLockEnabled, value: s.lockEnabled.toString());
    await _storage.write(key: _kThemeMode, value: s.themeMode);
    await _storage.write(key: _kChannel, value: s.channel);
    await _storage.write(key: _kAutoCheck, value: s.autoCheck.toString());
  }

  /// Deletes the legacy flat keys (called after migrating to the profile-based
  /// config, so no stale credential copy lingers).
  Future<void> clear() async {
    for (final k in const [
      _kHost, _kPort, _kUser, _kPassword, _kFullUpgrade, _kAuthMode,
      _kPrivateKey, _kKeyPassphrase, _kUiScheme, _kUiPort, _kLockEnabled,
      _kThemeMode, _kChannel, _kAutoCheck,
    ]) {
      await _storage.delete(key: k);
    }
  }
}

/// Persists the action history (JSON array) in secure storage.
class HistoryStore {
  static const _key = 'history_v1';
  final FlutterSecureStorage _storage;

  HistoryStore([FlutterSecureStorage? storage])
      : _storage = storage ?? kSecureStorage;

  // [add] reads the list, appends and writes it back. The writes run one
  // after the other through this chain: a second one would otherwise read the
  // list before the first has written it, and then write over its entry.
  Future<void> _lastWrite = Future<void>.value();

  Future<List<HistoryEntry>> load() async =>
      parseHistory(await _storage.read(key: _key) ?? '');

  /// Appends [entry]. Fails when the stored list cannot be read, and writes
  /// nothing then — an unreadable history is not an empty one.
  Future<void> add(HistoryEntry entry) => _queued(() async {
        final list = capHistory([...await load(), entry]);
        await _storage.write(key: _key, value: encodeHistory(list));
      });

  Future<void> clear() => _queued(() => _storage.delete(key: _key));

  Future<void> _queued(Future<void> Function() write) {
    final done = _lastWrite.then((_) => write());
    // The chain itself never fails: a write that threw must not take the ones
    // behind it with it. Its caller still gets the error, through [done].
    _lastWrite = done.then((_) {}, onError: (_) {});
    return done;
  }
}

/// [HostKeyStore] backed by the platform secure storage.
class SecureHostKeyStore implements HostKeyStore {
  final FlutterSecureStorage _storage;

  SecureHostKeyStore([FlutterSecureStorage? storage])
      : _storage = storage ?? kSecureStorage;

  @override
  Future<String?> get(String id) => _storage.read(key: id);

  @override
  Future<void> set(String id, String fingerprint) =>
      _storage.write(key: id, value: fingerprint);

  @override
  Future<void> remove(String id) => _storage.delete(key: id);
}
