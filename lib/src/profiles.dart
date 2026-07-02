import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'settings_store.dart';

/// One named connection profile (a Pi). Holds only connection fields; global
/// app settings live on [AppConfig].
class Profile {
  final String name;
  final String host;
  final String port;
  final String username;
  final String password;
  final AuthMode authMode;
  final String privateKey;
  final String keyPassphrase;
  final bool fullUpgrade;

  const Profile({
    required this.name,
    this.host = '',
    this.port = '22',
    this.username = 'pi',
    this.password = '',
    this.authMode = AuthMode.password,
    this.privateKey = '',
    this.keyPassphrase = '',
    this.fullUpgrade = false,
  });

  Profile copyWith({String? name}) => Profile(
        name: name ?? this.name,
        host: host,
        port: port,
        username: username,
        password: password,
        authMode: authMode,
        privateKey: privateKey,
        keyPassphrase: keyPassphrase,
        fullUpgrade: fullUpgrade,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'host': host,
        'port': port,
        'username': username,
        'password': password,
        'authMode': authMode.name,
        'privateKey': privateKey,
        'keyPassphrase': keyPassphrase,
        'fullUpgrade': fullUpgrade,
      };

  static Profile fromJson(Map<String, dynamic> j) => Profile(
        name: (j['name'] ?? 'Profil').toString(),
        host: (j['host'] ?? '').toString(),
        port: (j['port'] ?? '22').toString(),
        username: (j['username'] ?? 'pi').toString(),
        password: (j['password'] ?? '').toString(),
        authMode: j['authMode'] == 'key' ? AuthMode.key : AuthMode.password,
        privateKey: (j['privateKey'] ?? '').toString(),
        keyPassphrase: (j['keyPassphrase'] ?? '').toString(),
        fullUpgrade: j['fullUpgrade'] == true,
      );
}

/// The whole persisted app config: a list of profiles + the active one, plus
/// the global (not per-profile) settings.
class AppConfig {
  final List<Profile> profiles;
  final int activeIndex;
  final String uiScheme;
  final String uiPort;
  final bool lockEnabled;
  final String themeMode;
  final String channel;
  final bool autoCheck;

  /// Snapshot evcc config + DB on the Pi before each update.
  final bool backupBeforeUpdate;

  /// Daily background check that notifies when a Pi has pending updates.
  final bool notifyUpdates;

  const AppConfig({
    required this.profiles,
    required this.activeIndex,
    this.uiScheme = 'http',
    this.uiPort = '7070',
    this.lockEnabled = false,
    this.themeMode = 'system',
    this.channel = 'stable',
    this.autoCheck = false,
    this.backupBeforeUpdate = true,
    this.notifyUpdates = false,
  });

  static const initial =
      AppConfig(profiles: [Profile(name: 'Standard')], activeIndex: 0);

  int get safeIndex =>
      profiles.isEmpty ? 0 : activeIndex.clamp(0, profiles.length - 1);

  Profile get active =>
      profiles.isEmpty ? const Profile(name: 'Standard') : profiles[safeIndex];

  AppConfig copyWith({
    List<Profile>? profiles,
    int? activeIndex,
    String? uiScheme,
    String? uiPort,
    bool? lockEnabled,
    String? themeMode,
    String? channel,
    bool? autoCheck,
    bool? backupBeforeUpdate,
    bool? notifyUpdates,
  }) =>
      AppConfig(
        profiles: profiles ?? this.profiles,
        activeIndex: activeIndex ?? this.activeIndex,
        uiScheme: uiScheme ?? this.uiScheme,
        uiPort: uiPort ?? this.uiPort,
        lockEnabled: lockEnabled ?? this.lockEnabled,
        themeMode: themeMode ?? this.themeMode,
        channel: channel ?? this.channel,
        autoCheck: autoCheck ?? this.autoCheck,
        backupBeforeUpdate: backupBeforeUpdate ?? this.backupBeforeUpdate,
        notifyUpdates: notifyUpdates ?? this.notifyUpdates,
      );

  Map<String, dynamic> toJson() => {
        'activeIndex': activeIndex,
        'profiles': profiles.map((p) => p.toJson()).toList(),
        'uiScheme': uiScheme,
        'uiPort': uiPort,
        'lockEnabled': lockEnabled,
        'themeMode': themeMode,
        'channel': channel,
        'autoCheck': autoCheck,
        'backupBeforeUpdate': backupBeforeUpdate,
        'notifyUpdates': notifyUpdates,
      };

  static AppConfig fromJson(Map<String, dynamic> j) {
    final list = (j['profiles'] is List)
        ? (j['profiles'] as List)
            .whereType<Map>()
            .map((m) => Profile.fromJson(Map<String, dynamic>.from(m)))
            .toList()
        : <Profile>[];
    final profiles = list.isEmpty ? const [Profile(name: 'Standard')] : list;
    return AppConfig(
      profiles: profiles,
      activeIndex: (j['activeIndex'] is int) ? j['activeIndex'] as int : 0,
      uiScheme: (j['uiScheme'] ?? 'http').toString(),
      uiPort: (j['uiPort'] ?? '7070').toString(),
      lockEnabled: j['lockEnabled'] == true,
      themeMode: (j['themeMode'] ?? 'system').toString(),
      channel: (j['channel'] ?? 'stable').toString(),
      autoCheck: j['autoCheck'] == true,
      // Default ON; only an explicit false disables it.
      backupBeforeUpdate: j['backupBeforeUpdate'] != false,
      notifyUpdates: j['notifyUpdates'] == true,
    );
  }
}

String encodeAppConfig(AppConfig c) => jsonEncode(c.toJson());

/// Tolerant decode: any error falls back to [AppConfig.initial].
AppConfig parseAppConfig(String json) {
  if (json.trim().isEmpty) return AppConfig.initial;
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map) return AppConfig.initial;
    return AppConfig.fromJson(Map<String, dynamic>.from(decoded));
  } catch (_) {
    return AppConfig.initial;
  }
}

/// Migrates the old single flat [Settings] into a one-profile [AppConfig].
AppConfig migrateFromSettings(Settings s) => AppConfig(
      profiles: [
        Profile(
          name: 'Standard',
          host: s.host,
          port: s.port,
          username: s.username,
          password: s.password,
          authMode: s.authMode,
          privateKey: s.privateKey,
          keyPassphrase: s.keyPassphrase,
          fullUpgrade: s.fullUpgrade,
        ),
      ],
      activeIndex: 0,
      uiScheme: s.uiScheme,
      uiPort: s.uiPort,
      lockEnabled: s.lockEnabled,
      themeMode: s.themeMode,
      channel: s.channel,
      autoCheck: s.autoCheck,
    );

/// Persists [AppConfig] in secure storage, migrating from the legacy flat keys
/// on first run. Tests subclass this and override [load]/[save].
class AppConfigStore {
  static const _key = 'app_config_v1';

  final FlutterSecureStorage _storage;
  final SettingsStore _legacy;

  AppConfigStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage(),
        _legacy = SettingsStore(storage);

  Future<AppConfig> load() async {
    final raw = await _storage.read(key: _key);
    if (raw != null && raw.isNotEmpty) return parseAppConfig(raw);
    // First run after the multi-profile update: migrate the old flat settings,
    // then purge the legacy keys so no stale credential copy lingers.
    final migrated = migrateFromSettings(await _legacy.load());
    await save(migrated);
    await _legacy.clear();
    return migrated;
  }

  Future<void> save(AppConfig config) =>
      _storage.write(key: _key, value: encodeAppConfig(config));
}
