import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'review_prompt.dart';
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

  /// Last-seen Tailscale tailnet IP (100.x) of this Pi, remembered so the
  /// remote-access helper can pre-fill it as host even when NOT connected.
  final String tailscaleIp;

  /// Last-seen home/LAN address of this Pi (the non-tailnet host used to connect),
  /// remembered so the user can switch the host back from the tailnet IP to the
  /// home IP with one tap after using remote access.
  final String lanHost;

  /// Which of [lanHost]/[tailscaleIp] answered on the last successful connect.
  /// Only an ordering hint for the next attempt — never a source of truth, and
  /// never shown to the user.
  final String lastGoodHost;

  /// Connect to this Pi automatically when the app starts. Off by default —
  /// a connection runs sudo-capable commands, so it stays an explicit choice
  /// per Pi rather than a global convenience.
  final bool autoConnect;

  /// Last successful detection for this Pi, as raw JSON. Shown immediately on
  /// start so the app opens with something instead of an empty screen, then
  /// replaced by the live result. Marked as a remembered state in the UI —
  /// never presented as current. Holds no credentials.
  final List<Map<String, dynamic>> cachedServices;

  /// Whether THIS phone was ever proven to reach the Pi over the tailnet. Set
  /// only by a successful reachability check, so the remote-access card can
  /// disappear for good instead of becoming permanent furniture.
  final bool remoteAccessProven;

  /// ntfy destination of this Pi's Health-Alerts, as last set up from this
  /// app. Empty = none of its own: the app-wide one on [AppConfig] then stands
  /// in (see [effectiveNtfyDestination]). The topic works like a password
  /// (alerts.dart) — it must never reach a log line.
  final String alertsNtfyServer;
  final String alertsNtfyTopic;

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
    this.tailscaleIp = '',
    this.lanHost = '',
    this.lastGoodHost = '',
    this.remoteAccessProven = false,
    this.autoConnect = false,
    this.cachedServices = const [],
    this.alertsNtfyServer = '',
    this.alertsNtfyTopic = '',
  });

  Profile copyWith(
          {String? name,
          String? tailscaleIp,
          String? lanHost,
          String? lastGoodHost,
          bool? remoteAccessProven,
          bool? autoConnect,
          List<Map<String, dynamic>>? cachedServices,
          String? alertsNtfyServer,
          String? alertsNtfyTopic}) =>
      Profile(
        name: name ?? this.name,
        host: host,
        port: port,
        username: username,
        password: password,
        authMode: authMode,
        privateKey: privateKey,
        keyPassphrase: keyPassphrase,
        fullUpgrade: fullUpgrade,
        tailscaleIp: tailscaleIp ?? this.tailscaleIp,
        lanHost: lanHost ?? this.lanHost,
        lastGoodHost: lastGoodHost ?? this.lastGoodHost,
        remoteAccessProven: remoteAccessProven ?? this.remoteAccessProven,
        autoConnect: autoConnect ?? this.autoConnect,
        cachedServices: cachedServices ?? this.cachedServices,
        alertsNtfyServer: alertsNtfyServer ?? this.alertsNtfyServer,
        alertsNtfyTopic: alertsNtfyTopic ?? this.alertsNtfyTopic,
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
        'tailscaleIp': tailscaleIp,
        'lanHost': lanHost,
        'lastGoodHost': lastGoodHost,
        'remoteAccessProven': remoteAccessProven,
        'autoConnect': autoConnect,
        'cachedServices': cachedServices,
        'alertsNtfyServer': alertsNtfyServer,
        'alertsNtfyTopic': alertsNtfyTopic,
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
        tailscaleIp: (j['tailscaleIp'] ?? '').toString(),
        lanHost: (j['lanHost'] ?? '').toString(),
        lastGoodHost: (j['lastGoodHost'] ?? '').toString(),
        remoteAccessProven: j['remoteAccessProven'] == true,
        autoConnect: j['autoConnect'] == true,
        cachedServices: (j['cachedServices'] is List)
            ? [
                for (final e in (j['cachedServices'] as List))
                  if (e is Map) Map<String, dynamic>.from(e)
              ]
            : const [],
        alertsNtfyServer: (j['alertsNtfyServer'] ?? '').toString(),
        alertsNtfyTopic: (j['alertsNtfyTopic'] ?? '').toString(),
      );
}

/// The ntfy destination the Health-Alerts sheet starts with for a Pi: the
/// profile's own when it has one, else the app-wide one from before the
/// destination was kept per profile. A blank topic means neither is known.
({String server, String topic}) effectiveNtfyDestination({
  required String profileServer,
  required String profileTopic,
  required String fallbackServer,
  required String fallbackTopic,
}) =>
    profileTopic.trim().isNotEmpty
        ? (server: profileServer, topic: profileTopic)
        : (server: fallbackServer, topic: fallbackTopic);

/// The profiles of an export file as an import takes them over. One without
/// an ntfy destination of its own showed the exporting app's app-wide one —
/// that comes along, since the importing app's fallback is a different one.
List<Profile> profilesForImport(AppConfig exported) => [
      for (final p in exported.profiles)
        p.alertsNtfyTopic.trim().isEmpty &&
                exported.alertsNtfyTopic.trim().isNotEmpty
            ? p.copyWith(
                alertsNtfyServer: exported.alertsNtfyServer,
                alertsNtfyTopic: exported.alertsNtfyTopic)
            : p,
    ];

/// The whole persisted app config: a list of profiles + the active one, plus
/// the global (not per-profile) settings.
class AppConfig {
  final List<Profile> profiles;
  final int activeIndex;
  final String uiScheme;
  final String uiPort;
  final bool lockEnabled;
  final String themeMode;

  /// UI language: 'system' (follow the device), 'de' or 'en'.
  final String languageMode;
  final String channel;

  /// Snapshot evcc config + DB on the Pi before each update.
  final bool backupBeforeUpdate;

  /// Whether the user accepted the first-run disclaimer/terms.
  final bool disclaimerAccepted;

  /// The app version last seen by the user — drives the "What's New" popup.
  final String lastSeenVersion;

  /// Recent console commands (newest first, capped by the UI).
  final List<String> consoleHistory;

  /// User-defined console quick commands (shown above the history).
  final List<String> customCommands;

  /// Health-Alerts ntfy destination from before it was kept per profile: the
  /// fallback for a profile that has none of its own ([Profile.alertsNtfyTopic]),
  /// so a Pi set up back then still shows its topic. Loaded and saved as it
  /// is — a new destination goes to the profile.
  final String alertsNtfyServer;
  final String alertsNtfyTopic;

  /// The app build (versionCode) this user first ran — for future Pro
  /// grandfathering (null = not yet stamped). See early_adopter.dart.
  final int? firstSeenVersionCode;

  /// Whether a connection to any Pi has EVER succeeded on this install. Gates
  /// the demo entry: "the fields look filled in" is not the same as "this works"
  /// — a Play reviewer typed a host and password that never connected, the entry
  /// vanished, and the app was rejected as a login wall. A real session is the
  /// only proof that someone no longer needs the way in.
  final bool everConnected;

  /// The user tapped ✕ on the remote-access entry. A "no thanks" that sticks —
  /// without it the entry returned on every single connect, which is what made
  /// it feel pushy. Still reachable afterwards from the Tailscale card, so the
  /// ✕ is a dismissal, not a dead end.
  final bool remoteAccessDismissed;

  /// What the app remembers about asking for a Play review: how much has
  /// worked so far and when it last asked. See review_prompt.dart.
  final ReviewPromptState reviewPrompt;

  const AppConfig({
    required this.profiles,
    required this.activeIndex,
    this.uiScheme = 'http',
    this.uiPort = '7070',
    this.lockEnabled = false,
    this.themeMode = 'system',
    this.languageMode = 'system',
    this.channel = 'stable',
    this.backupBeforeUpdate = true,
    this.disclaimerAccepted = false,
    this.lastSeenVersion = '',
    this.consoleHistory = const [],
    this.customCommands = const [],
    this.alertsNtfyServer = 'https://ntfy.sh',
    this.alertsNtfyTopic = '',
    this.firstSeenVersionCode,
    this.everConnected = false,
    this.remoteAccessDismissed = false,
    this.reviewPrompt = ReviewPromptState.initial,
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
    String? languageMode,
    String? channel,
    bool? backupBeforeUpdate,
    bool? disclaimerAccepted,
    String? lastSeenVersion,
    List<String>? consoleHistory,
    List<String>? customCommands,
    String? alertsNtfyServer,
    String? alertsNtfyTopic,
    int? firstSeenVersionCode,
    bool? everConnected,
    bool? remoteAccessDismissed,
    ReviewPromptState? reviewPrompt,
  }) =>
      AppConfig(
        profiles: profiles ?? this.profiles,
        activeIndex: activeIndex ?? this.activeIndex,
        uiScheme: uiScheme ?? this.uiScheme,
        uiPort: uiPort ?? this.uiPort,
        lockEnabled: lockEnabled ?? this.lockEnabled,
        themeMode: themeMode ?? this.themeMode,
        languageMode: languageMode ?? this.languageMode,
        channel: channel ?? this.channel,
        backupBeforeUpdate: backupBeforeUpdate ?? this.backupBeforeUpdate,
        disclaimerAccepted: disclaimerAccepted ?? this.disclaimerAccepted,
        lastSeenVersion: lastSeenVersion ?? this.lastSeenVersion,
        consoleHistory: consoleHistory ?? this.consoleHistory,
        customCommands: customCommands ?? this.customCommands,
        alertsNtfyServer: alertsNtfyServer ?? this.alertsNtfyServer,
        alertsNtfyTopic: alertsNtfyTopic ?? this.alertsNtfyTopic,
        firstSeenVersionCode:
            firstSeenVersionCode ?? this.firstSeenVersionCode,
        everConnected: everConnected ?? this.everConnected,
        remoteAccessDismissed:
            remoteAccessDismissed ?? this.remoteAccessDismissed,
        reviewPrompt: reviewPrompt ?? this.reviewPrompt,
      );

  Map<String, dynamic> toJson() => {
        'activeIndex': activeIndex,
        'profiles': profiles.map((p) => p.toJson()).toList(),
        'uiScheme': uiScheme,
        'uiPort': uiPort,
        'lockEnabled': lockEnabled,
        'themeMode': themeMode,
        'languageMode': languageMode,
        'channel': channel,
        'backupBeforeUpdate': backupBeforeUpdate,
        'disclaimerAccepted': disclaimerAccepted,
        'lastSeenVersion': lastSeenVersion,
        'consoleHistory': consoleHistory,
        'customCommands': customCommands,
        'alertsNtfyServer': alertsNtfyServer,
        'alertsNtfyTopic': alertsNtfyTopic,
        'firstSeenVersionCode': firstSeenVersionCode,
        'everConnected': everConnected,
        'remoteAccessDismissed': remoteAccessDismissed,
        'reviewPrompt': reviewPrompt.toJson(),
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
      languageMode: (j['languageMode'] ?? 'system').toString(),
      channel: (j['channel'] ?? 'stable').toString(),
      // Default ON; only an explicit false disables it.
      backupBeforeUpdate: j['backupBeforeUpdate'] != false,
      disclaimerAccepted: j['disclaimerAccepted'] == true,
      lastSeenVersion: (j['lastSeenVersion'] ?? '').toString(),
      consoleHistory: (j['consoleHistory'] is List)
          ? (j['consoleHistory'] as List).map((e) => e.toString()).toList()
          : const [],
      customCommands: (j['customCommands'] is List)
          ? (j['customCommands'] as List).map((e) => e.toString()).toList()
          : const [],
      alertsNtfyServer:
          (j['alertsNtfyServer'] ?? 'https://ntfy.sh').toString(),
      alertsNtfyTopic: (j['alertsNtfyTopic'] ?? '').toString(),
      firstSeenVersionCode: j['firstSeenVersionCode'] is int
          ? j['firstSeenVersionCode'] as int
          : null,
      everConnected: j['everConnected'] == true,
      remoteAccessDismissed: j['remoteAccessDismissed'] == true,
      reviewPrompt: ReviewPromptState.fromJson(j['reviewPrompt']),
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
    );

/// Persists [AppConfig] in secure storage, migrating from the legacy flat keys
/// on first run. Tests subclass this and override [load]/[save].
class AppConfigStore {
  static const _key = 'app_config_v1';

  final FlutterSecureStorage _storage;
  final SettingsStore _legacy;

  AppConfigStore([FlutterSecureStorage? storage])
      : _storage = storage ?? kSecureStorage,
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

  /// Deletes everything the app has stored (see [resetSecureStorage]) — for
  /// the start page, when [load] keeps failing.
  Future<void> reset() => resetSecureStorage(_storage);
}
