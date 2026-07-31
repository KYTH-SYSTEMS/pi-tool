import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File;
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator, rootBundle;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'src/app_launcher.dart';
import 'src/authenticator.dart';
import 'src/alerts.dart';
import 'src/auto_update.dart';
import 'src/commands.dart';
import 'src/demo.dart';
import 'src/docker_containers.dart';
import 'src/early_adopter.dart';
import 'src/entitlement.dart';
import 'src/file_pick.dart';
import 'src/files.dart';
import 'src/profile_transfer.dart';
import 'src/scheduled_backup.dart';
import 'src/security_check.dart';
import 'src/ssh_keys.dart';
import 'src/storage_explorer.dart';
import 'src/systemd_services.dart';
import 'src/kyth_splash.dart';
import 'src/kyth_wordmark.dart';
import 'src/whats_new.dart';
import 'src/evcc_api.dart';
import 'src/evcc_updater.dart';
import 'src/history.dart';
import 'src/keep_alive.dart';
import 'src/l10n.dart';
import 'src/language.dart';
import 'src/network_scan.dart';
import 'src/parsing.dart';
import 'src/profiles.dart';
import 'src/services/apt_services.dart';
import 'src/services/pi_service.dart';
import 'src/services/tailscale.dart';
import 'src/session.dart';
import 'src/settings_store.dart';
import 'src/ssh_runner.dart';
import 'src/update_check.dart';

part 'src/ui_widgets.dart';

void main() {
  // Attribute the bundled Bricolage Grotesque (SIL OFL) on the licenses page.
  // Lazy: the asset is only read when the user opens that page — nothing runs
  // in the startup path.
  LicenseRegistry.addLicense(() async* {
    final ofl = await rootBundle.loadString('assets/fonts/OFL.txt');
    yield LicenseEntryWithLineBreaks(const ['Bricolage Grotesque'], ofl);
  });
  runApp(const EvccPiToolApp());
}

/// Clean minimal dark: near-black canvas, a single vivid green accent.
// Single source of truth for the brand green: the wordmark owns it (see the
// owner-decision note there); the app accent simply aliases it.
const kGreen = KythWordmark.kWordmarkGreen;
const kBlack = Color(0xFF0B0E0C);
const kCard = Color(0xFF161A17);

const kEvccPlayStoreUrl =
    'https://play.google.com/store/apps/details?id=io.evcc.android';
/// Our own Play listing — where a Play build gets its updates.
const kPlayStoreUrl =
    'https://play.google.com/store/apps/details?id=systems.kyth.pitool';
/// Legal pages live on a KYTH-owned domain, not on a GitHub-owner path: these
/// URLs are filed with Play and baked into every shipped build, so they must
/// survive a repo transfer or rename (Pages is not redirected like git).
const kPrivacyUrl = 'https://pi-tool.kyth.systems/privacy.html';
const kImpressumUrl = 'https://pi-tool.kyth.systems/impressum.html';
const kAgbUrl = 'https://pi-tool.kyth.systems/agb.html';
const kReleasesUrl = 'https://github.com/KYTH-SYSTEMS/pi-tool/releases';
const kImagerUrl = 'https://www.raspberrypi.com/software/';
const kKythUrl = 'https://www.kyth.systems';
const kSupportEmail = 'support@kyth.systems';

/// Drives MaterialApp.themeMode; updated from the loaded setting + the picker.
/// Light and system modes are supported; only the lock/fingerprint screen is
/// pinned dark (it follows the dark splash video) — see [_LockScreen].
final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier<ThemeMode>(ThemeMode.system);

ThemeMode parseThemeMode(String s) => switch (s) {
      'dark' => ThemeMode.dark,
      'light' => ThemeMode.light,
      _ => ThemeMode.system,
    };

/// Drives the app locale. null = follow the device language (system mode);
/// otherwise a forced Locale('de')/('en'). See [localeForLanguageMode].
final ValueNotifier<Locale?> localeNotifier = ValueNotifier<Locale?>(null);

/// The app theme — public so tooling (e.g. the screenshot generator) reuses it
/// instead of re-hardcoding the brand colors. [fontFamily] lets tests inject a
/// bundled font.
ThemeData buildAppTheme(Brightness brightness, {String? fontFamily}) {
  final dark = brightness == Brightness.dark;
  final scheme = dark
      ? ColorScheme.fromSeed(seedColor: kGreen, brightness: Brightness.dark)
          .copyWith(primary: kGreen, onPrimary: Colors.black, surface: kBlack)
      : ColorScheme.fromSeed(seedColor: kGreen, brightness: Brightness.light);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: fontFamily,
    scaffoldBackgroundColor: dark ? kBlack : null,
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? kBlack : scheme.surface,
      foregroundColor: dark ? Colors.white : scheme.onSurface,
      elevation: 0,
    ),
  );
}

class EvccPiToolApp extends StatelessWidget {
  const EvccPiToolApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (_, mode, _) => ValueListenableBuilder<Locale?>(
        valueListenable: localeNotifier,
        builder: (_, locale, _) => MaterialApp(
          title: 'Pi-Tool',
          debugShowCheckedModeBanner: false,
          themeMode: mode,
          theme: buildAppTheme(Brightness.light),
          darkTheme: buildAppTheme(Brightness.dark),
          // null → follow the device; else a forced de/en. Framework strings
          // (copy/paste menus, dialogs, license page) follow the resolved locale.
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          // English fallback for any non-German device language.
          localeResolutionCallback: (device, supported) =>
              resolveSystemLocale(locale ?? device),
          home: const KythSplashGate(child: UpdaterPage()),
        ),
      ),
    );
  }
}

/// Where the remote-access setup stands. In memory only: after a restart the
/// remembered tailnet IP decides what to show, not a stale phase.
enum _RemoteAccessPhase { idle, awaitingBrowser, phoneMissing, done }

class UpdaterPage extends StatefulWidget {
  /// All collaborators are injectable so widget tests avoid real platform
  /// channels, SSH, network and biometrics.
  const UpdaterPage({
    super.key,
    this.store,
    this.updater,
    this.updateChecker,
    this.authenticator,
    this.apiClient,
    this.piFinder,
    this.evccReleaseFetcher,
    this.haVersionFetcher,
    this.entitlement,
    this.keepAlive,
    this.filePicker,
    this.fileSaver,
    this.appLauncher,
  });

  final AppConfigStore? store;
  final EvccUpdater? updater;
  final UpdateChecker? updateChecker;
  final Authenticator? authenticator;
  final EvccApiClient? apiClient;

  /// Keeps the app alive (Android foreground service) during long actions.
  /// Injectable so tests can record start/stop without a platform channel.
  final KeepAliveService? keepAlive;

  /// Discovers reachable SSH hosts on the local network. Injectable for tests.
  final Future<List<String>> Function()? piFinder;

  /// Fetches evcc's latest release (for the pre-update notes). Injectable so
  /// tests can drive the confirm/cancel flow without a live GitHub call.
  final Future<EvccRelease?> Function()? evccReleaseFetcher;

  /// Fetches Home Assistant's latest release tag (for the currency check).
  /// Injectable so tests stay offline.
  final Future<String?> Function()? haVersionFetcher;

  /// Source of the Pro entitlement. Defaults to [DormantEntitlement] (everyone
  /// Pro) until Play Billing is wired at launch; injectable for tests.
  final EntitlementService? entitlement;

  /// Picks a local file to upload. Defaults to the in-app SAF picker; injectable
  /// so widget tests supply bytes without a platform channel.
  final FilePickerService? filePicker;

  /// Saves downloaded bytes to the phone (default: temp file + share sheet).
  /// Injectable so widget tests record instead of hitting platform channels.
  final Future<void> Function(String name, Uint8List bytes)? fileSaver;

  /// Opens another app (Tailscale) for the remote-access helper. Injectable so
  /// widget tests don't hit the native channel.
  final AppLauncher? appLauncher;

  @override
  State<UpdaterPage> createState() => _UpdaterPageState();
}

class _UpdaterPageState extends State<UpdaterPage>
    with WidgetsBindingObserver {
  late final AppConfigStore _store = widget.store ?? AppConfigStore();
  late final EvccUpdater _realUpdater =
      widget.updater ?? EvccUpdater.real(confirmFirstUse: _confirmFirstHostKey);
  // Demo backend (canned data, no real Pi); built lazily on first demo use.
  late final EvccUpdater _demoUpdater = buildDemoUpdater();
  // Points at the real or demo updater. Every action call-site uses `_updater`
  // unchanged; demo mode swaps this pointer (_startDemo / _restoreRealBackend).
  late EvccUpdater _updater = _realUpdater;
  late final UpdateChecker _updateChecker =
      widget.updateChecker ?? UpdateChecker();
  late final Authenticator _authenticator =
      widget.authenticator ?? LocalAuthenticator();
  late final EvccApiClient _realApi = widget.apiClient ?? EvccApiClient();
  late final EvccApiClient _demoApi = buildDemoApiClient();
  late EvccApiClient _apiClient = _realApi;
  late final KeepAliveService _keepAlive =
      widget.keepAlive ?? ForegroundKeepAlive();
  late final Future<List<String>> Function() _piFinder =
      widget.piFinder ?? findSshHosts;
  late final Future<EvccRelease?> Function() _fetchEvccRelease =
      widget.evccReleaseFetcher ?? fetchEvccRelease;
  late final Future<String?> Function() _fetchHaLatest =
      widget.haVersionFetcher ?? fetchLatestHomeAssistantVersion;
  late final EntitlementService _entitlement =
      widget.entitlement ?? const DormantEntitlement();
  late final FilePickerService _filePicker =
      widget.filePicker ?? const ChannelFilePicker();
  late final Future<void> Function(String name, Uint8List bytes) _fileSaver =
      widget.fileSaver ?? _saveAndShareBytes;
  late final AppLauncher _appLauncher =
      widget.appLauncher ?? const ChannelAppLauncher();
  final HistoryStore _historyStore = HistoryStore();

  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _user = TextEditingController(text: 'pi');
  final _password = TextEditingController();
  final _privateKey = TextEditingController();
  final _keyPassphrase = TextEditingController();
  final _uiPort = TextEditingController(text: '7070');
  final _logScroll = ScrollController();
  final _consoleInput = TextEditingController(); // free-form command entry

  bool _fullUpgrade = false;
  String _tailscaleIp = ''; // remembered 100.x tailnet IP of the active Pi
  String _lanHost = ''; // remembered home/LAN address of the active Pi
  // Which of the two answered last — an ordering hint for the next connect,
  // never a source of truth and never shown.
  String _lastGoodHost = '';
  _RemoteAccessPhase _remoteAccessPhase = _RemoteAccessPhase.idle;
  bool _remoteAccessProven = false; // this phone reached the tailnet once
  bool _obscure = true;
  bool _connExpanded = true; // connection form collapses once creds are set
  bool _busy = false;
  AuthMode _authMode = AuthMode.password;
  String _uiScheme = 'http';
  bool _lockEnabled = false;
  bool _locked = false;
  bool _booting = true; // true until settings load, so the shell isn't shown
  bool _unlocking = false;
  // Suppress the auto-lock for an in-app modal that backgrounds us (e.g. the
  // system file picker) — otherwise you return from picking a file to the lock
  // screen. Like _unlocking (which covers the biometric prompt).
  bool _suppressLock = false;
  String _themeMode = 'system';
  String _languageMode = 'system'; // 'system' | 'de' | 'en'
  String _channel = 'stable';
  bool _backupBeforeUpdate = true;
  bool _disclaimerAccepted = false; // first-run terms accepted
  String _lastSeenVersion = ''; // for the "What's New" popup after an update
  bool _whatsNewChecked = false; // one-shot guard for the popup
  List<String> _consoleHistory = []; // recent console commands, newest first
  List<String> _customCommands = []; // user-defined quick commands
  String _alertsServer = 'https://ntfy.sh'; // Health-Alerts ntfy destination
  String _alertsTopic = '';
  // The app build (versionCode) first seen by this install — Pro grandfathering
  // marker; null until stamped once at startup. See early_adopter.dart.
  int? _firstSeenVersionCode;
  bool _isPro = true; // Pro entitlement (dormant default: everyone Pro)
  // Demo mode: canned data via the demo updater/API, everything unlocked, no
  // real Pi. In-memory only (like _connected); never persisted.
  bool _demoMode = false;
  int _tab = kTabVerwaltung; // Verwaltung · Automatik · Terminal · Dateien
  String? _busyMessage; // shown in the shared running bar while _busy
  bool _testing = false; // a "Verbindung herstellen" run is in flight
  bool? _connectionOk; // null=untested, true=ok, false=failed (Test-Button color)
  // Active, validated session to the active Pi (set by an explicit "Verbindung
  // herstellen"; survives per-action work — NOT reset in _beginBusy). Gates the
  // Automatik/Terminal/Dateien tabs. In-memory only; never persisted.
  bool _connected = false;
  List<ServiceStatus> _services = []; // detected services → service cards
  List<Profile> _profiles = [const Profile(name: 'Standard')]; // growable
  int _activeIndex = 0;

  final List<String> _log = [];
  String? _statusMessage;
  bool _statusOk = true;
  ReleaseInfo? _update;
  String _appVersion = ''; // this app's version, shown in the footer
  EvccRelease? _evccLatest; // evcc's latest GitHub release, cached per session
  String? _haLatest; // Home Assistant's latest release, cached per session
  String? _setupUrl;
  Timer? _saveDebounce;
  bool _hostKeyIssue = false;
  SshConfig? _lastConfig;
  Future<void> Function()? _lastAction;

  List<TextEditingController> get _savedControllers =>
      [_host, _port, _user, _password, _privateKey, _keyPassphrase, _uiPort];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSettings();
    _checkForUpdate();
    _loadEntitlement();
  }

  Future<void> _loadEntitlement() async {
    final pro = await _entitlement.isPro();
    if (mounted) setState(() => _isPro = pro);
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _persistSettings(); // reads controllers synchronously before disposal
    for (final c in _savedControllers) {
      c.dispose();
    }
    _logScroll.dispose();
    _consoleInput.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Persist on any background-ish transition (cheap, safe).
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _saveDebounce?.cancel();
      _persistSettings();
    }
    // Lock only on REAL backgrounding (paused/hidden), not on transient
    // `inactive` (notification shade, system dialogs, the auth prompt itself),
    // and not while an unlock is already in progress.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (_lockEnabled && !_unlocking && !_suppressLock && mounted) {
        // Dismiss any open sheet/dialog (API status, history, settings, find-Pi)
        // so it can't stay readable above the lock screen on resume.
        Navigator.of(context, rootNavigator: true)
            .popUntil((r) => r.isFirst);
        setState(() => _locked = true);
      }
    } else if (state == AppLifecycleState.resumed && _locked && !_unlocking) {
      _tryUnlock();
    }
  }

  Future<void> _loadSettings() async {
    final cfg = await _store.load();
    if (!mounted) return;
    setState(() {
      _profiles = List.of(cfg.profiles); // always growable, never the const fallback
      _activeIndex = cfg.safeIndex;
      _uiScheme = cfg.uiScheme;
      _uiPort.text = cfg.uiPort;
      _lockEnabled = cfg.lockEnabled;
      _themeMode = cfg.themeMode;
      _languageMode = cfg.languageMode;
      _channel = cfg.channel;
      _backupBeforeUpdate = cfg.backupBeforeUpdate;
      _disclaimerAccepted = cfg.disclaimerAccepted;
      _lastSeenVersion = cfg.lastSeenVersion;
      _firstSeenVersionCode = cfg.firstSeenVersionCode;
      _consoleHistory = List.of(cfg.consoleHistory);
      _customCommands = List.of(cfg.customCommands);
      _alertsServer = cfg.alertsNtfyServer;
      _alertsTopic = cfg.alertsNtfyTopic;
      _applyProfile(cfg.active);
      if (_lockEnabled) _locked = true;
      _booting = false; // settings + lock state resolved → reveal the UI
    });
    themeModeNotifier.value = parseThemeMode(_themeMode);
    localeNotifier.value = localeForLanguageMode(_languageMode);
    // Attach auto-save listeners after initial values are set.
    for (final c in _savedControllers) {
      c.addListener(_scheduleSave);
    }
    // Editing a connection field invalidates the last test result (clears the
    // green/red Test-Button indicator).
    for (final c in [_host, _port, _user, _password, _privateKey, _keyPassphrase]) {
      c.addListener(_invalidateConnTest);
    }
    if (_locked) _unlockAfterSplash();
    // Stamp the early-adopter marker as a best-effort BACKGROUND task —
    // deliberately after the unlock is scheduled and fully off the boot-critical
    // path (no setState, no lock interaction, per the "nothing untested in the
    // startup path" invariant).
    unawaited(_stampFirstSeenMarker(cfg));
  }

  /// Records `firstSeenVersionCode` once (if not yet set) for future Pro
  /// grandfathering. Best-effort and decoupled from startup/lock; no setState
  /// (the field is never shown in the UI).
  Future<void> _stampFirstSeenMarker(AppConfig cfg) async {
    if (cfg.firstSeenVersionCode != null) return;
    try {
      final info = await PackageInfo.fromPlatform();
      final current = int.tryParse(info.buildNumber) ?? 0;
      final wasUsedBefore =
          cfg.disclaimerAccepted || cfg.lastSeenVersion.isNotEmpty;
      _firstSeenVersionCode = resolveFirstSeenVersionCode(
        stored: null,
        wasUsedBefore: wasUsedBefore,
        currentVersionCode: current,
      );
      await _store.save(_currentConfig());
    } catch (_) {
      // Best-effort; a marker failure must never affect the app.
    }
  }

  /// Prompt for biometric unlock only once the brand splash has finished — the
  /// system biometric dialog would otherwise pop over (and hide) the splash.
  void _unlockAfterSplash() {
    if (splashDoneNotifier.value) {
      _tryUnlock();
      return;
    }
    void listener() {
      if (splashDoneNotifier.value) {
        splashDoneNotifier.removeListener(listener);
        if (mounted) _tryUnlock();
      }
    }

    splashDoneNotifier.addListener(listener);
  }

  void _invalidateConnTest() {
    if ((_connectionOk != null || _connected) && mounted) {
      setState(() {
        if (_demoMode) _restoreRealBackend();
        _connectionOk = null;
        _connected = false; // editing creds invalidates the session
        if (isGatedTab(_tab)) _tab = tabAfterDisconnect(_tab);
      });
    }
  }

  /// Loads a profile's connection fields into the controllers/state.
  void _applyProfile(Profile p) {
    _host.text = p.host;
    _port.text = p.port;
    _user.text = p.username;
    _password.text = p.password;
    _privateKey.text = p.privateKey;
    _keyPassphrase.text = p.keyPassphrase;
    _authMode = p.authMode;
    _fullUpgrade = p.fullUpgrade;
    _tailscaleIp = p.tailscaleIp;
    _lanHost = p.lanHost;
    _lastGoodHost = p.lastGoodHost;
    _remoteAccessProven = p.remoteAccessProven;
    // Collapse the (space-hungry) connection form when this Pi is already set up;
    // expand it for a fresh/empty profile that still needs input.
    _connExpanded = !_credsComplete();
  }

  /// Whether the active profile has enough to connect (host + the secret the
  /// current auth mode needs). Drives the connection form's collapsed default.
  bool _credsComplete() {
    if (_host.text.trim().isEmpty) return false;
    return _authMode == AuthMode.key
        ? _privateKey.text.trim().isNotEmpty
        : _password.text.isNotEmpty;
  }

  /// Switching to another Pi: drop everything tied to the previous host so
  /// nothing from it leaks into the new Pi's view — detected services, the
  /// connection indicator, banners, the host-key "trust new key" prompt and the
  /// stashed trust-and-retry target ([_lastConfig]/[_lastAction]).
  void _resetDetectionForNewPi() {
    _restoreRealBackend(); // a profile switch also leaves any demo session
    _services = [];
    _connectionOk = null;
    _connected = false; // end the session — the new Pi must be connected anew
    if (isGatedTab(_tab)) _tab = kTabVerwaltung; // snap back off a gated tab
    _setupUrl = null;
    _statusMessage = null;
    _hostKeyIssue = false;
    _lastConfig = null;
    _lastAction = null;
  }

  /// Debounced auto-save: persists ~0.8s after the last edit.
  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 800), _persistSettings);
  }

  Future<void> _persistSettings() => _store.save(_currentConfig());

  /// The active profile rebuilt from the live controller values.
  Profile _currentProfile() => Profile(
        name: _activeIndex < _profiles.length
            ? _profiles[_activeIndex].name
            : 'Standard',
        host: _host.text.trim(),
        port: _port.text.trim().isEmpty ? '22' : _port.text.trim(),
        username: _user.text.trim().isEmpty ? 'pi' : _user.text.trim(),
        password: _password.text,
        authMode: _authMode,
        privateKey: _privateKey.text,
        keyPassphrase: _keyPassphrase.text,
        fullUpgrade: _fullUpgrade,
        tailscaleIp: _tailscaleIp,
        lanHost: _lanHost,
        lastGoodHost: _lastGoodHost,
        remoteAccessProven: _remoteAccessProven,
      );

  /// Remembers the Pi's Tailscale tailnet IP from a detection, so the remote-
  /// access helper can pre-fill it as host later even when offline. Call inside
  /// a setState (updates the field) — it persists the change (debounced).
  void _rememberTailscaleIp(List<ServiceStatus> services) {
    for (final s in services) {
      if (s.id == 'tailscale' &&
          s.active &&
          (s.version ?? '').startsWith('100.') &&
          s.version != _tailscaleIp) {
        _tailscaleIp = s.version!;
        _scheduleSave();
        return;
      }
    }
  }

  /// Remembers the home/LAN address we just connected with, so the user can
  /// switch the host back to it with one tap after using remote access. A
  /// tailnet address (100.x OR a `*.ts.net` MagicDNS name) is NOT a home
  /// address — that's what [_tailscaleIp] is for; anything else (LAN IP or
  /// `.local` hostname) counts as home.
  void _rememberLanHost() {
    final host = _host.text.trim();
    if (host.isNotEmpty && !isTailnetHost(host) && host != _lanHost) {
      _lanHost = host;
      _scheduleSave();
    }
  }

  AppConfig _currentConfig() {
    final profiles = [..._profiles];
    if (_activeIndex < profiles.length) {
      profiles[_activeIndex] = _currentProfile();
    }
    return AppConfig(
      profiles: profiles,
      activeIndex: _activeIndex,
      uiScheme: _uiScheme,
      uiPort: _uiPort.text.trim().isEmpty ? '7070' : _uiPort.text.trim(),
      lockEnabled: _lockEnabled,
      themeMode: _themeMode,
      languageMode: _languageMode,
      channel: _channel,
      backupBeforeUpdate: _backupBeforeUpdate,
      disclaimerAccepted: _disclaimerAccepted,
      lastSeenVersion: _lastSeenVersion,
      consoleHistory: _consoleHistory,
      customCommands: _customCommands,
      alertsNtfyServer: _alertsServer,
      alertsNtfyTopic: _alertsTopic,
      firstSeenVersionCode: _firstSeenVersionCode,
    );
  }

  /// Records first-run acceptance of the disclaimer and persists it.
  void _acceptDisclaimer() {
    setState(() => _disclaimerAccepted = true);
    _persistSettings();
  }

  // ---- profile export / import (encrypted, for a phone change) ----

  /// Exports ALL profiles + settings as a passphrase-encrypted file and hands
  /// it to the share sheet. The file contains credentials — hence the explicit
  /// warning + authenticated encryption (see profile_transfer.dart).
  Future<void> _exportProfiles() async {
    final pass = await _promptPassphrase(
      context.l10n.exportProfilesTitle,
      context.l10n.exportProfilesBody,
      confirm: true,
    );
    if (pass == null || !mounted) return;
    try {
      final envelope =
          await encryptProfileExport(encodeAppConfig(_currentConfig()), pass);
      if (!mounted) return;
      await _fileSaver('pi-tool-profile.pitool',
          Uint8List.fromList(utf8.encode(envelope)));
      if (mounted) _snack(context.l10n.snackExportCreated);
    } catch (_) {
      if (mounted) _snack(context.l10n.snackExportFailed);
    }
  }

  /// Imports profiles from an exported file (SAF picker → passphrase → merge).
  Future<void> _importProfiles() async {
    if (_busy) return;
    final l10n = context.l10n;
    _suppressLock = true;
    PickedFile? picked;
    try {
      picked = await _filePicker.pick();
    } catch (_) {
      if (mounted) _snack(l10n.snackFilePickFailed);
      return;
    } finally {
      _suppressLock = false;
    }
    if (picked == null || !mounted) return;
    final pass = await _promptPassphrase(l10n.importProfilesTitle,
        l10n.importProfilesBody);
    if (pass == null || !mounted) return;
    try {
      final json =
          await decryptProfileExport(utf8.decode(picked.bytes), pass);
      final cfg = parseAppConfig(json);
      if (cfg.profiles.isEmpty) {
        _snack(l10n.snackFileNoProfiles);
        return;
      }
      if (!await _confirm(l10n.dialogImportTitle,
          l10n.dialogImportBody(cfg.profiles.length))) {
        return;
      }
      setState(() {
        _profiles = [..._profiles, ...cfg.profiles];
        _activeIndex = _profiles.length - cfg.profiles.length; // first imported
        _applyProfile(_profiles[_activeIndex]);
        _resetDetectionForNewPi();
      });
      _persistSettings();
      _snack(l10n.snackProfilesImported(cfg.profiles.length));
    } on ProfileTransferException catch (e) {
      if (mounted) _snack(e.message);
    } catch (_) {
      if (mounted) _snack(l10n.snackImportFailed);
    }
  }

  /// Effective Pro unlock: the real entitlement OR demo mode. Every gate reads
  /// this, so demo mode shows all Pro features even after Play Billing is live.
  bool get _unlocked => _isPro || _demoMode;

  /// Runs [action] for Pro users; otherwise opens the paywall. The single gate
  /// every Pro feature routes through.
  void _proGate(VoidCallback action) {
    if (_unlocked) {
      action();
    } else {
      _showPaywall();
    }
  }

  /// Bottom sheet explaining Pro and offering the one-time unlock. Billing is
  /// dormant pre-launch (buyPro succeeds), so this only ever shows once the Play
  /// build gates a free user.
  Future<void> _showPaywall() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.workspace_premium, color: kGreen),
                const SizedBox(width: 10),
                Text('Pi-Tool Pro',
                    style: Theme.of(ctx).textTheme.titleLarge),
              ]),
              const SizedBox(height: 12),
              Text(ctx.l10n.paywallSubtitle),
              const SizedBox(height: 10),
              for (final f in [
                ctx.l10n.paywallFeatureBackups,
                ctx.l10n.paywallFeatureAutomation,
                ctx.l10n.paywallFeatureFiles,
                ctx.l10n.paywallFeatureTerminal,
                ctx.l10n.paywallFeatureProfiles,
                ctx.l10n.paywallFeatureCleanup,
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.check, size: 18, color: kGreen),
                      const SizedBox(width: 8),
                      Expanded(child: Text(f)),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.lock_open),
                  label: Text(ctx.l10n.paywallUnlockButton),
                  onPressed: () async {
                    final ok = await _entitlement.buyPro();
                    if (!ctx.mounted) return;
                    Navigator.pop(ctx);
                    if (ok && mounted) {
                      setState(() => _isPro = true);
                      _snack(context.l10n.snackProUnlocked);
                    }
                  },
                ),
              ),
              Center(
                child: TextButton(
                  onPressed: () async {
                    final ok = await _entitlement.restore();
                    if (!ctx.mounted) return;
                    Navigator.pop(ctx);
                    if (mounted) {
                      setState(() => _isPro = ok);
                      _snack(ok
                          ? context.l10n.snackProRestored
                          : context.l10n.snackNoPurchaseFound);
                    }
                  },
                  child: Text(ctx.l10n.paywallRestoreButton),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// On the first launch after an update, show a "What's New" popup once. The
  /// current version is recorded either way (a fresh install records silently).
  Future<void> _maybeShowWhatsNew() async {
    try {
      final lang = Localizations.localeOf(context).languageCode; // before await
      final current = (await PackageInfo.fromPlatform()).version;
      if (current.isEmpty) return;
      final last = _lastSeenVersion;
      final notes = whatsNewFor(current, lang);
      // Show on a real update; and also once for an EXISTING user (has a Pi
      // configured) whose last-seen version wasn't tracked yet — so the first
      // version with this feature isn't silently missed. A truly fresh install
      // (no host) records the version silently and shows nothing.
      final existingUser = _profiles.any((p) => p.host.trim().isNotEmpty);
      final show = notes != null &&
          (shouldShowWhatsNew(lastSeen: last, current: current) ||
              (last.isEmpty && existingUser));
      if (last != current) {
        _lastSeenVersion = current;
        _persistSettings();
      }
      if (show && mounted) await _showWhatsNewDialog(current, notes);
    } catch (_) {
      // never let the popup disrupt startup
    }
  }

  Future<void> _showWhatsNewDialog(String version, List<String> notes) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.whatsNewTitle(version)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final n in notes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('•  '),
                      Expanded(child: Text(n)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(ctx.l10n.whatsNewGotIt),
          ),
        ],
      ),
    );
  }

  // ---- profile management --------------------------------------------------

  String get _activeProfileName => _profiles.isEmpty
      ? 'Standard'
      : _profiles[_activeIndex.clamp(0, _profiles.length - 1)].name;

  /// Bottom sheet to pick / add / rename / delete a Pi profile — the single home
  /// for profile management (replaces the old on-screen profile bar).
  void _showProfileSwitcher() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true, // don't clip the profile list when there are many Pis
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              title: Text(ctx.l10n.profileSwitcherTitle,
                  style: Theme.of(ctx).textTheme.titleMedium),
              dense: true,
            ),
            for (var i = 0; i < _profiles.length; i++)
              ListTile(
                // Neutral icon (the check on the right marks the active Pi) — a
                // coloured dot here read like a "connected" status light.
                leading: Icon(Icons.dns_outlined,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                title: Text(_profiles[i].name),
                subtitle: _profiles[i].host.trim().isEmpty
                    ? null
                    : Text(_profiles[i].host,
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12)),
                // Per-profile: check on the active one + a ⋮ to rename/delete
                // ANY profile (no need to switch to it first).
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (i == _activeIndex)
                      const Icon(Icons.check, color: kGreen, size: 20),
                    PopupMenuButton<String>(
                      tooltip: ctx.l10n.profileActionsTooltip,
                      onSelected: (v) {
                        Navigator.pop(ctx);
                        if (v == 'rename') _renameProfile(i);
                        if (v == 'delete') _deleteProfile(i);
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                            value: 'rename', child: Text(ctx.l10n.menuRename)),
                        if (_profiles.length > 1)
                          PopupMenuItem(
                              value: 'delete', child: Text(ctx.l10n.actionDelete)),
                      ],
                    ),
                  ],
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  if (i != _activeIndex) _switchProfile(i);
                },
              ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.add),
              title: Text(ctx.l10n.addProfile),
              onTap: () {
                Navigator.pop(ctx);
                _addProfile();
              },
            ),
          ],
        ),
        ),
      ),
    );
  }

  void _switchProfile(int i) {
    if (i == _activeIndex || i < 0 || i >= _profiles.length) return;
    _profiles[_activeIndex] = _currentProfile(); // capture outgoing edits
    setState(() {
      _activeIndex = i;
      _applyProfile(_profiles[i]);
      _resetDetectionForNewPi();
    });
    _persistSettings();
  }

  Future<void> _addProfile() async {
    if (isAddProfileLocked(isPro: _unlocked, profileCount: _profiles.length)) {
      _showPaywall(); // multiple Pis are a Pro feature
      return;
    }
    final name = await _promptName(context.l10n.newProfileTitle, '');
    if (name == null || !mounted) return;
    _profiles[_activeIndex] = _currentProfile();
    final next = [..._profiles, Profile(name: name)];
    setState(() {
      _profiles = next;
      _activeIndex = next.length - 1;
      _applyProfile(_profiles[_activeIndex]);
      _resetDetectionForNewPi();
    });
    _persistSettings();
  }

  Future<void> _renameProfile(int i) async {
    if (i < 0 || i >= _profiles.length) return;
    final name = await _promptName(context.l10n.renameProfileTitle, _profiles[i].name);
    if (name == null || !mounted) return;
    setState(() {
      // Capture live edits before renaming the active profile.
      if (i == _activeIndex) _profiles[i] = _currentProfile();
      _profiles[i] = _profiles[i].copyWith(name: name);
    });
    _persistSettings();
  }

  Future<void> _deleteProfile(int i) async {
    if (_profiles.length <= 1 || i < 0 || i >= _profiles.length) return;
    final name = _profiles[i].name;
    // Destructive + irreversible (wipes host, credentials and any SSH key).
    if (!await _confirm(
      context.l10n.dialogDeleteProfileTitle(name),
      context.l10n.dialogDeleteProfileBody,
      destructive: true,
    )) {
      return;
    }
    if (_profiles.length <= 1 || i >= _profiles.length) return; // re-check
    final wasActive = i == _activeIndex;
    // Preserve the active profile's live edits when deleting a different one.
    if (!wasActive && _activeIndex < _profiles.length) {
      _profiles[_activeIndex] = _currentProfile();
    }
    final next = [..._profiles]..removeAt(i);
    setState(() {
      _profiles = next;
      if (wasActive) {
        _activeIndex = _activeIndex.clamp(0, next.length - 1);
        _applyProfile(_profiles[_activeIndex]);
        _resetDetectionForNewPi();
      } else {
        // A lower-index deletion shifts the active profile down by one.
        if (i < _activeIndex) _activeIndex -= 1;
        _activeIndex = _activeIndex.clamp(0, next.length - 1);
      }
    });
    _persistSettings();
  }

  Future<String?> _promptName(String title, String initial) async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => _NameDialog(title: title, initial: initial),
    );
    return (name != null && name.trim().isNotEmpty) ? name.trim() : null;
  }

  /// Passphrase dialog. [confirm] adds a second field (for export, to avoid a
  /// typo locking the user out of their own file).
  Future<String?> _promptPassphrase(String title, String body,
          {bool confirm = false}) =>
      showDialog<String>(
        context: context,
        builder: (ctx) =>
            _PassphraseDialog(title: title, body: body, confirm: confirm),
      );

  Future<void> _checkForUpdate() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _appVersion = info.version);
      // A Play build updates through Play — never point it at the GitHub APK
      // (Play requires updates to come through Play, and the sideload APK is
      // signed with a different key, so it could not install over it anyway).
      if (installChannelFor(info.installerStore) == InstallChannel.play) return;
      final release = await _updateChecker.checkForUpdate(info.version);
      if (release != null && mounted) setState(() => _update = release);
    } catch (_) {
      // never let the update check disrupt the app
    }
  }

  /// Manual "Auf Update prüfen": re-checks GitHub and reports the outcome (an
  /// update banner if newer, else a snackbar). Fail-soft — a failed check just
  /// says so. On a Play build there is nothing to check here: Play delivers the
  /// updates, so we only offer a shortcut to the store page.
  Future<void> _checkUpdatesNow() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (installChannelFor(info.installerStore) == InstallChannel.play) {
        if (!mounted) return;
        setState(() => _appVersion = info.version);
        _snack(context.l10n.snackUpdatesViaPlay,
            actionLabel: context.l10n.actionOpenPlayStore,
            onAction: () => _openUrl(kPlayStoreUrl));
        return;
      }
      final release = await _updateChecker.checkForUpdate(info.version);
      if (!mounted) return;
      setState(() {
        _appVersion = info.version;
        if (release != null) _update = release;
      });
      _snack(release != null
          ? context.l10n.snackUpdateAvailable(release.version)
          : context.l10n.snackUpToDate(info.version));
    } catch (_) {
      if (mounted) {
        _snack(context.l10n.snackUpdateCheckFailed);
      }
    }
  }

  Future<void> _tryUnlock() async {
    if (!_lockEnabled) {
      if (mounted) setState(() => _locked = false);
      return;
    }
    if (_unlocking) return; // re-entrancy guard: avoid overlapping prompts
    _unlocking = true;
    try {
      final ok = await _authenticator.authenticate(context.l10n.authUnlockReason);
      if (ok && mounted) setState(() => _locked = false);
    } finally {
      _unlocking = false;
    }
  }

  // ---- actions -------------------------------------------------------------

  int? _validatedPort() {
    if (_host.text.trim().isEmpty) {
      _snack(context.l10n.snackEnterHost);
      return null;
    }
    if (_authMode == AuthMode.password && _password.text.isEmpty) {
      _snack(context.l10n.snackEnterPassword);
      return null;
    }
    if (_authMode == AuthMode.key && _privateKey.text.trim().isEmpty) {
      _snack(context.l10n.snackEnterPrivateKey);
      return null;
    }
    final port = int.tryParse(_port.text.trim());
    if (port == null || port <= 0 || port > 65535) {
      _snack(context.l10n.snackInvalidPort);
      return null;
    }
    return port;
  }

  /// Builds an SshConfig from a stored [Profile] (not the live controllers) —
  /// used by the multi-Pi overview to probe every profile.
  SshConfig _configForProfile(Profile p) => SshConfig(
        host: p.host.trim(),
        port: int.tryParse(p.port.trim()) ?? 22,
        username: p.username.trim().isEmpty ? 'pi' : p.username.trim(),
        password: p.password,
        privateKey: p.authMode == AuthMode.key ? p.privateKey : '',
        keyPassphrase: p.authMode == AuthMode.key ? p.keyPassphrase : '',
        timeout: const Duration(seconds: 12),
      );

  /// Connects to one Pi and summarises its System card (fail-soft). Used by the
  /// multi-Pi overview.
  Future<PiSnapshot> _probePi(Profile p) async {
    final l10n = context.l10n;
    if (p.host.trim().isEmpty) {
      return (
        reachable: false,
        updates: false,
        warning: false,
        detail: l10n.probeNoHost
      );
    }
    try {
      final services = await _updater
          .detectServices(config: _configForProfile(p), onLog: (_) {});
      ServiceStatus? sys;
      for (final s in services) {
        if (s.id == 'system') sys = s;
      }
      return (
        reachable: true,
        updates: sys?.updateAvailable ?? false,
        warning: sys?.healthWarning ?? false,
        detail: (sys?.health.isNotEmpty ?? false) ? sys!.health : l10n.probeReachable,
      );
    } catch (_) {
      return (
        reachable: false,
        updates: false,
        warning: false,
        detail: l10n.probeUnreachable
      );
    }
  }

  /// Runs a system update (apt full-upgrade) on one profile's Pi. Fail-soft:
  /// returns false on any error so the multi-Pi bulk update can carry on.
  Future<bool> _updatePiSystem(Profile p) async {
    try {
      await _updater.upgradeSystem(config: _configForProfile(p), onLog: (_) {});
      return true;
    } catch (_) {
      return false;
    }
  }

  void _showMultiPiDashboard() {
    // Capture the active profile's live edits so the overview probes what's on
    // screen, not a stale copy.
    final profiles = [..._profiles];
    if (_activeIndex < profiles.length) {
      profiles[_activeIndex] = _currentProfile();
    }
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _MultiPiDashboardPage(
          profiles: profiles, probe: _probePi, update: _updatePiSystem),
    ));
  }

  SshConfig _configFor(int port) => SshConfig(
        host: _host.text.trim(),
        port: port,
        username: _user.text.trim().isEmpty ? 'pi' : _user.text.trim(),
        password: _password.text,
        privateKey: _authMode == AuthMode.key ? _privateKey.text : '',
        keyPassphrase: _authMode == AuthMode.key ? _keyPassphrase.text : '',
        timeout: const Duration(seconds: 15),
      );

  /// Validates, builds the config, remembers it, saves settings and enters the
  /// busy state. Returns the config, or null when validation failed.
  SshConfig? _prepare() {
    final port = _validatedPort();
    if (port == null) return null;
    final config = _configFor(port);
    _lastConfig = config;
    _persistSettings();
    _beginBusy();
    return config;
  }

  void _beginBusy() {
    setState(() {
      _busy = true;
      _log.clear();
      _statusMessage = null;
      _setupUrl = null;
      _hostKeyIssue = false;
      _connectionOk = null; // clear the Test-Button indicator while an action runs
    });
  }

  /// Shared error handling + busy-reset for every action. When
  /// [backgroundMessage] is given, a foreground service keeps the app alive for
  /// the duration so a long action (update/install) survives backgrounding.
  Future<void> _guard(
    Future<void> Function() body, {
    String? backgroundMessage,
  }) async {
    final l10n = context.l10n;
    if (backgroundMessage != null) {
      await _keepAlive.begin(backgroundMessage);
      if (mounted) setState(() => _busyMessage = backgroundMessage);
    }
    try {
      await body();
    } on EvccUpdateException catch (e) {
      final cancelled = e.kind == UpdateErrorKind.cancelled;
      _appendLog(cancelled ? l10n.logCancelled : l10n.logError(e.message));
      if (!mounted) return;
      // A connection-class failure means the session is no longer valid — drop
      // it honestly so the UI doesn't claim "verbunden" for an unreachable Pi.
      final connectionLost = e.kind == UpdateErrorKind.connection ||
          e.kind == UpdateErrorKind.auth ||
          e.kind == UpdateErrorKind.hostKeyChanged;
      setState(() {
        _statusMessage = e.message;
        _statusOk = false;
        _hostKeyIssue = e.kind == UpdateErrorKind.hostKeyChanged;
        if (connectionLost) {
          _connected = false;
          if (isGatedTab(_tab)) _tab = kTabVerwaltung;
        }
      });
    } catch (e) {
      _appendLog(l10n.logError('$e')); // _appendLog redacts the password
      if (!mounted) return;
      setState(() {
        // Keep the raw exception in the (redacted) log, not in the headline.
        _statusMessage = l10n.statusUnexpectedError;
        _statusOk = false;
      });
    } finally {
      if (backgroundMessage != null) await _keepAlive.end();
      if (mounted) {
        setState(() {
          _busy = false;
          _busyMessage = null;
        });
      }
    }
  }

  Future<void> _run({required bool dryRun}) async {
    if (_busy) return;
    final l10n = context.l10n;
    // Before a real update, show evcc's latest release notes (fail-soft). Mark
    // busy during the fetch/confirm so all action buttons disable — otherwise
    // the network await opens a window for double-taps / concurrent SSH ops.
    if (!dryRun) {
      // Show the running bar during the (network) fetch so the disabled UI has
      // feedback; clear it again before the confirm dialog opens.
      setState(() {
        _busy = true;
        _busyMessage = l10n.busyLoadingEvccRelease;
      });
      final rel = await _fetchEvccRelease();
      if (!mounted) return;
      setState(() => _busyMessage = null);
      // Always warn when full-upgrade is on (it touches ALL packages, not just
      // evcc) — even if the release-notes fetch failed.
      final warn = _fullUpgrade
          ? l10n.runFullUpgradeWarning
          : '';
      final notes = rel != null ? _notesExcerpt(rel.notes) : '';
      final body = [warn, notes].where((s) => s.isNotEmpty).join('\n\n');
      // Confirm whenever there's something to say (a warning or notes);
      // otherwise (plain evcc update, no notes) proceed silently as before.
      final proceed = body.isEmpty ||
          await _confirm(
            rel != null
                ? l10n.dialogEvccInstallTitle(rel.version)
                : l10n.dialogEvccUpdateTitle,
            body,
          );
      if (!proceed) {
        if (mounted) setState(() => _busy = false);
        return;
      }
    }
    final config = _prepare();
    if (config == null) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    _lastAction = () => _run(dryRun: dryRun);
    await _guard(() async {
      // Auto-detect how evcc is installed, then take the matching update path.
      final detection =
          await _updater.detectInstall(config: config, onLog: _appendLog);
      switch (detection.kind) {
        case InstallKind.unknown:
          throw EvccUpdateException(
            UpdateErrorKind.packageMissing,
            l10n.errorEvccNotFound,
          );
        case InstallKind.docker:
          if (dryRun) {
            if (!mounted) return;
            setState(() {
              _statusMessage = l10n
                  .statusDockerDryRunUnavailable(detection.container!.name);
              _statusOk = true;
            });
            return;
          }
          await _updater.updateDocker(
            config: config,
            detection: detection,
            onLog: _appendLog,
          );
          if (!mounted) return;
          setState(() {
            _statusMessage = l10n.statusEvccContainerUpdated;
            _statusOk = true;
          });
          _addHistory(l10n.historyEvccDockerUpdated);
          await _refreshServices(config);
        case InstallKind.apt:
          // Back up config + DB first (opt-out). A backup failure throws here
          // and is surfaced by _guard — the update does NOT proceed, so you're
          // never updated without the safety net you enabled. ("Nichts zu
          // sichern" returns null and is not an error.)
          if (!dryRun && _backupBeforeUpdate) {
            await _updater.backup(config: config, onLog: _appendLog);
            if (!mounted) return;
          }
          final summary = await _updater.run(
            config: config,
            fullUpgrade: _fullUpgrade,
            dryRun: dryRun,
            onLog: _appendLog,
          );
          if (!mounted) return;
          setState(() {
            _statusMessage = summary.message;
            _statusOk = true;
          });
          if (!dryRun) {
            _addHistory(summary.message);
            await _refreshServices(config);
          }
      }
    }, backgroundMessage: dryRun ? null : l10n.busyEvccUpdate);
  }

  /// Picks the address to connect with when a Pi has BOTH a home address and a
  /// tailnet IP: try the likelier one first with a short deadline, fall back to
  /// the other, and remember which won so the next connect starts there.
  ///
  /// With only one known address this returns [entered] untouched — a Pi without
  /// remote access must not pay a probe's latency for a feature it doesn't use.
  /// If neither answers we also return [entered], so the normal connect reports
  /// a real error instead of us inventing one here.
  Future<SshConfig> _pickReachableHost(SshConfig entered) async {
    final candidates = remoteAccessCandidates(
      lanHost: _lanHost,
      tailscaleIp: _tailscaleIp,
      lastGood: _lastGoodHost,
    );
    if (candidates.length < 2) return entered;
    for (final host in candidates) {
      final reachable = await _updater.probeConnection(
        config: entered.copyWith(
            host: host, timeout: const Duration(seconds: 4)),
        onLog: _appendLog,
      );
      if (!reachable) continue;
      if (mounted) {
        setState(() {
          _host.text = host;
          _lastGoodHost = host;
        });
        _scheduleSave();
      }
      return entered.copyWith(host: host);
    }
    return entered;
  }

  Future<void> _testConnection() async {
    if (_busy) return;
    final entered = _prepare();
    if (entered == null) return; // invalid port → keep any demo session intact
    // A real connect always uses the real backend, even if we were in a demo.
    if (_demoMode) setState(_restoreRealBackend);
    _lastAction = _testConnection;
    // Show the running bar + Abbrechen during connect, but WITHOUT a keep-alive
    // (connect is short); the finally in _guard clears _busyMessage.
    setState(() {
      _testing = true;
      _busyMessage = context.l10n.busyConnecting;
    });
    final config = await _pickReachableHost(entered);
    await _guard(() async {
      final detected = await _updater.detectServices(
        config: config,
        onLog: _appendLog,
        // Progressive: as soon as the SSH connection is up (before the service
        // probes run) show "Verbunden" so the wait feels shorter.
        onConnected: () {
          if (!mounted) return;
          setState(() {
            _statusMessage = context.l10n.statusConnectedDetecting;
            _statusOk = true;
          });
        },
      );
      final services = await _reconcileEvcc(detected);
      if (!mounted) return;
      setState(() {
        _services = services;
        _rememberTailscaleIp(services);
        _rememberLanHost();
        _connExpanded = false; // connected → free up space for the service cards
        _connected = true; // explicit session established → unlock gated tabs
        final found =
            services.where((s) => s.installed).map((s) => s.name).join(', ');
        _statusMessage = context.l10n.statusConnectionOk(found);
        _statusOk = true;
      });
      _appendLog(context.l10n.logConnectedWith(_host.text.trim()));
    });
    // Drive the Test-Button colour from the outcome (success populated the
    // cards; any thrown error set _statusOk=false via _guard).
    if (mounted) {
      setState(() {
        _testing = false;
        _connectionOk = _statusOk;
      });
    }
  }

  /// Restores the real backend (updater + evcc API) and clears the demo flag.
  /// Call inside a setState.
  void _restoreRealBackend() {
    _demoMode = false;
    _updater = _realUpdater;
    _apiClient = _realApi;
  }

  /// Enters demo mode: swaps in the demo backend and runs the normal detection
  /// against it, so every tab fills with believable sample data — no real Pi and
  /// no credentials. All Pro features are unlocked (via `_unlocked`). Exited via
  /// [_exitDemo] or any real connect.
  Future<void> _startDemo() async {
    if (_busy) return;
    const config =
        SshConfig(host: 'demo', port: 22, username: 'pi', password: 'demo');
    setState(() {
      _demoMode = true;
      _updater = _demoUpdater;
      _apiClient = _demoApi;
    });
    _lastConfig = config;
    _lastAction = _startDemo;
    _beginBusy();
    setState(() {
      _testing = true;
      _busyMessage = context.l10n.busyConnecting;
    });
    await _guard(() async {
      final detected = await _updater.detectServices(
        config: config,
        onLog: _appendLog,
        onConnected: () {
          if (!mounted) return;
          setState(() {
            _statusMessage = context.l10n.statusConnectedDetecting;
            _statusOk = true;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _services = detected;
        _connExpanded = false;
        _connected = true;
        final found =
            detected.where((s) => s.installed).map((s) => s.name).join(', ');
        _statusMessage = context.l10n.statusConnectionOk(found);
        _statusOk = true;
      });
      _appendLog(context.l10n.demoBanner);
    });
    if (mounted) {
      setState(() {
        _testing = false;
        _connectionOk = _statusOk;
      });
    }
  }

  /// Leaves demo mode, returning to the disconnected connect screen.
  void _exitDemo() {
    setState(() {
      _restoreRealBackend();
      _connected = false;
      _services = [];
      _statusMessage = null;
      _connectionOk = null;
      _lastConfig = null; // drop the dummy demo config
      _lastAction = null;
      _connExpanded = true;
      if (isGatedTab(_tab)) _tab = kTabVerwaltung;
    });
  }

  /// The banner shown above all tabs while in demo mode.
  Widget _demoBar(ThemeData theme) => Material(
        color: theme.colorScheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
          child: Row(
            children: [
              Icon(Icons.science_outlined,
                  size: 18, color: theme.colorScheme.onSecondaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.l10n.demoBanner,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer),
                ),
              ),
              TextButton(
                onPressed: _busy ? null : _exitDemo,
                child: Text(context.l10n.demoExit),
              ),
            ],
          ),
        ),
      );

  Future<void> _install() async {
    if (_busy) return;
    final l10n = context.l10n;
    if (!await _confirm(
      context.l10n.dialogInstallEvccTitle,
      context.l10n.dialogInstallEvccBody(_host.text.trim()),
    )) {
      return;
    }
    final config = _prepare();
    if (config == null) return;
    _lastAction = _install;
    await _guard(() async {
      final res = await _updater.install(
        config: config,
        onLog: _appendLog,
        channel: _channel,
      );
      if (!mounted) return;
      setState(() {
        _statusMessage = context.l10n.statusEvccInstalled(
            res.version,
            res.serviceActive
                ? context.l10n.serviceActive
                : context.l10n.serviceInactive);
        _statusOk = true;
        _setupUrl = _evccUiUrl();
      });
      _addHistory(context.l10n.historyEvccInstalled(res.version));
      await _refreshServices(config);
    }, backgroundMessage: l10n.busyInstallingEvcc);
  }

  Future<void> _restartService() async {
    if (_busy) return;
    if (!await _confirm(context.l10n.dialogRestartEvccTitle,
        context.l10n.dialogRestartEvccBody)) {
      return;
    }
    final config = _prepare();
    if (config == null) return;
    _lastAction = _restartService;
    await _guard(() async {
      await _updater.restartService(config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = context.l10n.statusEvccRestarted;
        _statusOk = true;
      });
      _addHistory(context.l10n.statusEvccRestarted);
    });
  }

  Future<void> _reboot() async {
    if (_busy) return;
    if (!await _confirm(
      context.l10n.dialogRebootTitle,
      context.l10n.dialogRebootBody,
      // Not destructive-red: a reboot interrupts service briefly but doesn't
      // lose data (unlike shutdown/delete). Confirm, but don't alarm.
    )) {
      return;
    }
    final config = _prepare();
    if (config == null) return;
    _lastAction = _reboot;
    await _guard(() async {
      await _updater.reboot(config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = context.l10n.statusRebootTriggered;
        _statusOk = true;
      });
      _addHistory(context.l10n.historyRebootTriggered);
    });
  }

  Future<void> _setupSshKey() async {
    if (_busy) return;
    final l10n = context.l10n;
    // Idempotent per-Pi: nothing to do once a key is already present (in either
    // auth mode) — the inline button hides then too.
    if (_privateKey.text.trim().isNotEmpty) {
      _snack(context.l10n.snackProfileHasKey);
      return;
    }
    if (_host.text.trim().isEmpty) {
      _snack(context.l10n.snackEnterHost);
      return;
    }
    if (_password.text.isEmpty) {
      _snack(context.l10n.snackKeySetupNeedsPassword);
      return;
    }
    final port = int.tryParse(_port.text.trim());
    if (port == null || port <= 0 || port > 65535) {
      _snack(context.l10n.snackInvalidPort);
      return;
    }
    if (!await _confirm(
      context.l10n.dialogSetupKeyTitle,
      context.l10n.dialogSetupKeyBody,
    )) {
      return;
    }
    // The install ALWAYS logs in via password (that's the whole point of the
    // upgrade), regardless of which auth segment is selected right now.
    final config = SshConfig(
      host: _host.text.trim(),
      port: port,
      username: _user.text.trim().isEmpty ? 'pi' : _user.text.trim(),
      password: _password.text,
      privateKey: '',
      timeout: const Duration(seconds: 15),
    );
    _lastConfig = config;
    _persistSettings();
    _lastAction = _setupSshKey; // set before busy, matching every other handler
    _beginBusy();
    final name = _currentProfile().name;
    await _guard(() async {
      final key = await generateSshKey(comment: 'pi-tool@$name');
      await _updater.installSshKey(
          config: config, publicKeyLine: key.publicKeyLine, onLog: _appendLog);
      if (!mounted) return;
      // Prove the Pi ACTUALLY accepts the new key (sshd may forbid pubkey auth,
      // StrictModes may reject it, …) BEFORE switching — a false "success" that
      // then breaks the next connect would be worse than staying on password.
      var keyWorks = false;
      try {
        keyWorks = await _updater.verifyKeyAuth(
          config: SshConfig(
            host: config.host,
            port: config.port,
            username: config.username,
            password: '',
            privateKey: key.privateKeyPem,
          ),
          onLog: _appendLog,
        );
      } catch (_) {
        keyWorks = false; // auth rejected — handled below, not a hard error
      }
      if (!mounted) return;
      if (keyWorks) {
        // Switch THIS profile to key auth; keep the password (used for sudo).
        setState(() {
          _privateKey.text = key.privateKeyPem;
          _authMode = AuthMode.key;
          _statusMessage = context.l10n.statusKeyConfigured;
          _statusOk = true;
        });
        _persistSettings();
        _addHistory(context.l10n.historyKeyConfigured);
      } else {
        setState(() {
          _statusMessage = context.l10n.statusKeyNotAccepted;
          _statusOk = false;
        });
      }
    }, backgroundMessage: l10n.busySettingUpKey);
  }

  Future<void> _dockerContainers() async {
    if (_busy) return;
    final config = _prepare();
    if (config == null) return;
    _lastAction = _dockerContainers;
    List<DockerContainer>? list;
    await _guard(() async {
      list =
          await _updater.dockerContainers(config: config, onLog: _appendLog);
    }, backgroundMessage: context.l10n.busyReadingDockerContainers);
    if (!mounted || list == null) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _DockerSheet(
        initial: list!,
        refresh: () =>
            _updater.dockerContainers(config: config, onLog: (_) {}),
        onRestart: (name) => _updater.restartDockerContainer(
            config: config, name: name, onLog: _appendLog),
        onLogs: (name) async {
          final logs = await _updater.fetchDockerLogs(
              config: config, name: name, onLog: (_) {});
          if (!mounted) return;
          await showModalBottomSheet<void>(
            context: context,
            showDragHandle: true,
            isScrollControlled: true,
            builder: (_) => _LiveLogSheet(
              title: context.l10n.logsTitle(name),
              initial: logs,
              fetch: () => _updater.fetchDockerLogs(
                  config: config, name: name, onLog: (_) {}),
            ),
          );
        },
      ),
    );
  }

  Future<void> _storageExplorer() async {
    if (_busy) return;
    final config = _prepare();
    if (config == null) return;
    _lastAction = _storageExplorer;
    const start = '/';
    List<DiskEntry>? entries;
    await _guard(() async {
      entries =
          await _updater.diskUsage(config: config, path: start, onLog: _appendLog);
    }, backgroundMessage: context.l10n.busyAnalyzingStorage);
    if (!mounted || entries == null) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _StorageExplorerSheet(
        initialPath: start,
        initialEntries: entries!,
        // Drill-down fetches its own levels (like the file browser), quietly.
        fetch: (p) =>
            _updater.diskUsage(config: config, path: p, onLog: (_) {}),
      ),
    );
  }

  Future<void> _securityCheck() async {
    if (_busy) return;
    final config = _prepare();
    if (config == null) return;
    _lastAction = _securityCheck;
    List<SecurityFinding>? findings;
    await _guard(() async {
      findings =
          await _updater.runSecurityCheck(config: config, onLog: _appendLog);
    }, backgroundMessage: context.l10n.busySecurityCheck);
    if (!mounted || findings == null) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _SecurityReportSheet(findings: findings!),
    );
  }

  Future<void> _shutdown() async {
    if (_busy) return;
    if (!await _confirm(
      context.l10n.dialogShutdownTitle,
      context.l10n.dialogShutdownBody,
      confirmLabel: context.l10n.confirmShutdown,
      destructive: true,
    )) {
      return;
    }
    final config = _prepare();
    if (config == null) return;
    _lastAction = _shutdown;
    await _guard(() async {
      await _updater.shutdown(config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = context.l10n.statusShuttingDown;
        _statusOk = true;
        // The Pi is now OFF until physically powered on — keeping the session
        // (and unlocked tabs) would claim a connection that no longer exists.
        _connected = false;
        if (isGatedTab(_tab)) _tab = kTabVerwaltung;
      });
      _addHistory(context.l10n.historyShutdown);
    });
  }

  /// Lists the evcc backups on the Pi, lets the user pick one, confirms, then
  /// restores it (stops evcc → extract → restart). Backups are made before apt
  /// updates (see the backup-before-update setting).
  Future<void> _restoreBackup() async {
    if (_busy) return;
    final l10n = context.l10n;
    final config = _prepare();
    if (config == null) return;
    _lastAction = _restoreBackup; // before the first guard (trust-and-retry)
    List<String>? backups; // stays null if listing errored (surfaced by _guard)
    await _guard(() async {
      backups = await _updater.listBackups(config: config, onLog: _appendLog);
    });
    if (!mounted || backups == null) return;
    if (backups!.isEmpty) {
      _snack(context.l10n.snackNoEvccBackups);
      return;
    }
    final chosen = await _pickBackup(backups!);
    if (chosen == null || !mounted) return;
    if (!await _confirm(
      context.l10n.dialogRestoreBackupTitle,
      context.l10n.dialogRestoreBackupBody(_backupLabel(chosen)),
    )) {
      return;
    }
    _beginBusy();
    _lastAction = _restoreBackup;
    await _guard(() async {
      await _updater.restoreBackup(
          config: config, path: chosen, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = context.l10n.statusBackupRestored(_backupLabel(chosen));
        _statusOk = true;
      });
      _addHistory(context.l10n.historyBackupRestored(_backupLabel(chosen)));
      await _refreshServices(config);
    }, backgroundMessage: l10n.busyRestoringBackup);
  }

  /// Human label for a backup archive path
  /// (.../evcc-backup-YYYYMMDD-HHMMSS.tar.gz → "DD.MM.YYYY HH:MM Uhr").
  String _backupLabel(String path) {
    final m = RegExp(r'(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})')
        .firstMatch(path);
    if (m == null) return path.split('/').last;
    return context.l10n
        .backupTimestamp('${m[3]}.${m[2]}.${m[1]} ${m[4]}:${m[5]}');
  }

  Future<String?> _pickBackup(List<String> backups) {
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(ctx.l10n.actionRestoreBackup,
                  style: Theme.of(ctx).textTheme.titleMedium),
              subtitle: Text(ctx.l10n.newestFirst),
            ),
            for (final b in backups)
              ListTile(
                leading: const Icon(Icons.restore),
                title: Text(_backupLabel(b)),
                subtitle: Text(b,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 11)),
                onTap: () => Navigator.pop(ctx, b),
              ),
          ],
        ),
      ),
    );
  }

  // ---- service backup management (Pi-hole + Home Assistant) ----

  /// Lists a service's backups and lets the user restore or delete one.
  Future<void> _manageServiceBackups({
    required String servicePrefix,
    required String serviceName,
    required Future<void> Function(SshConfig config, String path) restore,
    required String restoreWarning,
  }) async {
    if (_busy) return;
    final l10n = context.l10n;
    final config = _prepare();
    if (config == null) return;
    // Set BEFORE the first guard so a host-key "trust & retry" replays THIS
    // (listing) action, not whatever ran previously.
    _lastAction = () => _manageServiceBackups(
          servicePrefix: servicePrefix,
          serviceName: serviceName,
          restore: restore,
          restoreWarning: restoreWarning,
        );
    List<String>? backups;
    await _guard(() async {
      backups = await _updater.listServiceBackups(
          config: config, servicePrefix: servicePrefix, onLog: _appendLog);
    });
    if (!mounted || backups == null) return;
    if (backups!.isEmpty) {
      _snack(context.l10n.snackNoServiceBackups(serviceName));
      return;
    }
    final choice = await _pickServiceBackup(serviceName, backups!);
    if (choice == null || !mounted) return;
    final (action, path) = choice;
    if (action == 'download') {
      _beginBusy();
      await _guard(() async {
        final bytes = await _updater.downloadFile(
            config: config, path: path, onLog: _appendLog);
        if (!mounted) return;
        final name = path.split('/').last;
        await _fileSaver(name, bytes);
        if (!mounted) return;
        setState(() {
          _statusMessage = context.l10n.statusBackupDownloaded(name);
          _statusOk = true;
        });
        _addHistory(context.l10n.historyBackupDownloaded(serviceName, name));
      }, backgroundMessage: context.l10n.busyDownloadingBackup);
      return;
    }
    if (action == 'delete') {
      if (!await _confirm(context.l10n.dialogDeleteBackupTitle,
          context.l10n.dialogDeleteBackupBody(serviceName, _backupLabel(path)),
          destructive: true)) {
        return;
      }
      _beginBusy();
      await _guard(() async {
        await _updater.deleteServiceBackup(
            config: config, path: path, onLog: _appendLog);
        if (!mounted) return;
        setState(() {
          _statusMessage = context.l10n.statusBackupDeleted(_backupLabel(path));
          _statusOk = true;
        });
        _addHistory(
            context.l10n.historyBackupDeleted(serviceName, _backupLabel(path)));
      }, backgroundMessage: l10n.busyDeletingBackup);
      return;
    }
    if (!await _confirm(context.l10n.dialogRestoreBackupTitle, restoreWarning)) {
      return;
    }
    _beginBusy();
    await _guard(() async {
      await restore(config, path);
      if (!mounted) return;
      setState(() {
        _statusMessage =
            context.l10n.statusServiceRestored(serviceName, _backupLabel(path));
        _statusOk = true;
      });
      _addHistory(context.l10n.historyServiceBackupRestored(serviceName));
    }, backgroundMessage: l10n.busyRestoringService(serviceName));
  }

  Future<void> _managePiholeBackups() => _manageServiceBackups(
        servicePrefix: 'pihole',
        serviceName: 'Pi-hole',
        restoreWarning: context.l10n.restoreWarningPihole,
        restore: (config, path) => _updater.restorePiholeBackup(
            config: config, path: path, onLog: _appendLog),
      );

  Future<void> _manageHomeAssistantBackups() => _manageServiceBackups(
        servicePrefix: 'homeassistant',
        serviceName: 'Home Assistant',
        restoreWarning: context.l10n.restoreWarningHomeAssistant,
        restore: (config, path) => _updater.restoreHomeAssistantBackup(
            config: config, path: path, onLog: _appendLog),
      );

  /// Sheet of one service's backups: tap = restore, trash icon = delete.
  Future<(String action, String path)?> _pickServiceBackup(
      String serviceName, List<String> backups) {
    return showModalBottomSheet<(String, String)>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(ctx.l10n.serviceBackupsTitle(serviceName),
                  style: Theme.of(ctx).textTheme.titleMedium),
              subtitle: Text(ctx.l10n.serviceBackupsSubtitle),
            ),
            for (final b in backups)
              ListTile(
                leading: const Icon(Icons.restore),
                title: Text(_backupLabel(b)),
                subtitle: Text(b,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 11)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.download_outlined),
                      tooltip: ctx.l10n.tooltipDownloadToPhone,
                      onPressed: () => Navigator.pop(ctx, ('download', b)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: ctx.l10n.tooltipDeleteBackup,
                      onPressed: () => Navigator.pop(ctx, ('delete', b)),
                    ),
                  ],
                ),
                onTap: () => Navigator.pop(ctx, ('restore', b)),
              ),
          ],
        ),
      ),
    );
  }

  // ---- system cleanup ----

  /// Frees disk space on the Pi (confirmed), then reports how much.
  Future<void> _cleanupSystem() async {
    if (_busy) return;
    final l10n = context.l10n;
    if (!await _confirm(
      context.l10n.dialogCleanupTitle,
      context.l10n.dialogCleanupBody,
    )) {
      return;
    }
    final config = _prepare();
    if (config == null) return;
    _lastAction = _cleanupSystem;
    await _guard(() async {
      final freed =
          await _updater.cleanupSystem(config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = context.l10n.statusCleanedUp(_formatBytes(freed));
        _statusOk = true;
      });
      _addHistory(context.l10n.historyCleanedUp(_formatBytes(freed)));
      await _refreshServices(config);
    }, backgroundMessage: l10n.busyFreeingStorage);
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1000 * 1000 * 1000) {
      return '${(bytes / (1000 * 1000 * 1000)).toStringAsFixed(1)} GB';
    }
    return '${(bytes / (1000 * 1000)).round()} MB';
  }

  // ---- shared action bars (above all tabs) ----

  /// Visible on every tab while an action runs: progress + what's running + a
  /// jump to the live log + Abbrechen — so you always see (and can stop) it.
  Widget _runningBar(ThemeData theme) {
    final cs = theme.colorScheme;
    return Material(
      color: cs.surfaceContainerHighest,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const LinearProgressIndicator(minHeight: 3),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(_busyMessage ?? context.l10n.busyDefault,
                      style: theme.textTheme.bodyMedium,
                      overflow: TextOverflow.ellipsis),
                ),
                TextButton(
                  // Deliberate gate bypass: while an action runs, jumping to
                  // its live log must work even before a session exists.
                  onPressed: () => setState(() => _tab = kTabTerminal),
                  child: const Text('Log'),
                ),
                const SizedBox(width: 2),
                OutlinedButton.icon(
                  onPressed: _cancel,
                  icon: const Icon(Icons.close, size: 18),
                  label: Text(context.l10n.cancel),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: cs.error,
                    side: BorderSide(color: cs.error.withValues(alpha: 0.55)),
                    visualDensity: VisualDensity.compact,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Host-key-changed recovery, surfaced on whichever tab the failing action ran.
  Widget _hostKeyBar(ThemeData theme) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: FilledButton.icon(
          onPressed: _trustAndRetry,
          icon: const Icon(Icons.verified_user_outlined),
          label: Text(context.l10n.hostKeyTrustButton),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
      );

  // ---- remote file browser (read-only) ----

  // ---- Dateien tab: remote file browser (browse / preview / upload / delete) ----

  /// Quiet SSH config for the Dateien tab (no snack, no _busy). Null when no
  /// host is set yet — the tab then shows a "connect first" hint.
  SshConfig? _filesConfig() {
    if (_host.text.trim().isEmpty) return null;
    final port = int.tryParse(_port.text.trim());
    if (port == null || port <= 0 || port > 65535) return null;
    return _configFor(port);
  }

  Future<List<DirEntry>> _filesList(String path) {
    final c = _filesConfig();
    if (c == null) {
      throw EvccUpdateException(
          UpdateErrorKind.connection, context.l10n.errorNoPiConnected);
    }
    return _updater.listDir(config: c, path: path, onLog: _appendLog);
  }

  Future<void> _filesOpen(String path) async {
    final c = _filesConfig();
    if (c == null) return;
    await _openRemoteFile(c, path);
  }

  Future<bool> _filesUpload(String dir) async {
    final c = _filesConfig();
    if (c == null) {
      _snack(context.l10n.snackConnectPiFirst);
      return false;
    }
    PickedFile? picked;
    // The system picker backgrounds the app — hold off the auto-lock so the user
    // doesn't return from picking to the lock screen.
    _suppressLock = true;
    try {
      picked = await _filePicker.pick();
    } catch (_) {
      if (mounted) _snack(context.l10n.snackFilePickFailed);
      return false;
    } finally {
      _suppressLock = false;
    }
    if (picked == null || !mounted) return false; // cancelled
    if (picked.bytes.length > kFileUploadLimit) {
      _snack(context.l10n.snackFileTooLarge(kFileUploadLimit ~/ (1024 * 1024)));
      return false;
    }
    // Use only the basename — a hostile document provider could put `../` in the
    // display name and (as root) `mv` the file outside the browsed directory.
    final safeName = picked.name.split(RegExp(r'[\\/]')).last.trim();
    if (safeName.isEmpty || safeName == '.' || safeName == '..') {
      _snack(context.l10n.snackInvalidFilename);
      return false;
    }
    final target = joinRemotePath(dir, safeName);
    try {
      _snack(context.l10n.snackUploading(safeName));
      await _updater.uploadFile(
          config: c, path: target, bytes: picked.bytes, onLog: _appendLog);
      if (mounted) _snack(context.l10n.snackUploaded(safeName));
    } catch (_) {
      if (mounted) _snack(context.l10n.snackUploadFailed);
    }
    // Reload after any upload ATTEMPT, not only on success: if the app was
    // backgrounded by the picker the success marker can be missed even though
    // the file was written — a reload then still surfaces it.
    return true;
  }

  Future<bool> _filesDelete(DirEntry entry, String dir) async {
    final c = _filesConfig();
    if (c == null) return false;
    if (!await _confirm(
      context.l10n.dialogDeleteFileTitle(entry.name),
      entry.isDir
          ? context.l10n.dialogDeleteFolderBody
          : context.l10n.dialogDeleteFileBody,
      destructive: true,
    )) {
      return false;
    }
    try {
      await _updater.deleteRemotePath(
          config: c,
          path: joinRemotePath(dir, entry.name),
          isDir: entry.isDir,
          onLog: _appendLog);
      if (mounted) _snack(context.l10n.snackDeleted(entry.name));
      return true;
    } catch (_) {
      if (mounted) _snack(context.l10n.snackDeleteFailed);
      return false;
    }
  }

  Future<void> _openRemoteFile(SshConfig config, String path) async {
    try {
      final bytes = await _updater.readFileBytes(
          config: config, path: path, onLog: _appendLog);
      if (!mounted) return;
      final text = utf8.decode(bytes, allowMalformed: true);
      final name = path.split('/').last;
      // Text files of editable size get an "Bearbeiten" affordance that hands
      // off to the atomic config editor (backup + marker write, sudo-capable).
      final editable =
          isProbablyTextFile(bytes) && bytes.length <= kFileEditLimit;
      final edit = await _showFilePreview(context.l10n.filePreviewTitle(name),
          text.length > 100000 ? '${text.substring(0, 100000)}\n…' : text,
          editable: editable);
      if (edit == true && mounted) await _editConfig(path, name);
    } catch (_) {
      if (mounted) _snack(context.l10n.snackFileLoadFailed);
    }
  }

  /// Preview sheet for a remote file. Resolves to true if the user chose
  /// "Bearbeiten" (only offered when [editable]).
  Future<bool?> _showFilePreview(String header, String content,
      {required bool editable}) {
    return showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.78,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(header,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(ctx).textTheme.titleMedium),
                  ),
                  if (editable)
                    TextButton.icon(
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: Text(ctx.l10n.actionEdit),
                      onPressed: () => Navigator.pop(ctx, true),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  content.trim().isEmpty ? ctx.l10n.emptyFile : content,
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- config editor (read → edit → save with backup) ----

  Future<void> _editConfig(String path, String title) async {
    if (_busy) return;
    final l10n = context.l10n;
    final config = _prepare();
    if (config == null) return;
    _lastAction = () => _editConfig(path, title);
    String? content;
    await _guard(() async {
      content =
          await _updater.readConfigFile(config: config, path: path, onLog: _appendLog);
    }, backgroundMessage: context.l10n.busyLoadingFile(title));
    if (!mounted || content == null) return;
    final edited = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => _ConfigEditorPage(title: title, initial: content!),
      ),
    );
    if (edited == null || !mounted || edited == content) return; // cancel/no-op
    if (edited.trim().isEmpty) {
      _snack(context.l10n.snackEmptyContent(title));
      return;
    }
    if (!await _confirm(context.l10n.dialogSaveTitle,
        context.l10n.dialogSaveBody(path))) {
      return;
    }
    _beginBusy();
    await _guard(() async {
      await _updater.saveConfigFile(
          config: config, path: path, content: edited, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = context.l10n.statusFileSaved(title);
        _statusOk = true;
      });
      _addHistory(context.l10n.historyFileEdited(title));
    }, backgroundMessage: l10n.busySavingFile(title));
  }

  // ---- service logs (journalctl / docker logs) ----

  Future<void> _showServiceLogs(ServiceStatus s) async {
    if (_busy) return;
    final config = _prepare();
    if (config == null) return;
    _lastAction = () => _showServiceLogs(s);
    String? logs;
    await _guard(() async {
      logs = await _updater.fetchServiceLogs(
          config: config, id: s.id, detail: s.detail, onLog: _appendLog);
    }, backgroundMessage: context.l10n.busyLoadingLogs);
    if (!mounted || logs == null) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _LiveLogSheet(
        title: context.l10n.logsTitle(s.name),
        initial: logs!,
        // Live mode re-polls the tail quietly (no _guard/_busy churn).
        fetch: () => _updater.fetchServiceLogs(
            config: config, id: s.id, detail: s.detail, onLog: (_) {}),
      ),
    );
  }

  // ---- Health-Alerts (on-Pi systemd timer → ntfy push) ----

  Future<void> _configureAlerts() async {
    if (_busy) return;
    final config = _prepare();
    if (config == null) return;
    _lastAction = _configureAlerts;
    AlertsStatus? status;
    await _guard(() async {
      status = await _updater.readAlertsStatus(config: config, onLog: _appendLog);
    });
    if (!mounted || status == null) return;
    final choice = await _showAlertsSheet(status!, config);
    if (choice == null || !mounted) return;
    _beginBusy();
    await _guard(() async {
      if (choice.enable) {
        // Plain field writes (not rendered directly) — no setState needed, so no
        // setState-after-unmount risk across the awaits below.
        _alertsServer = choice.server;
        _alertsTopic = choice.topic;
        _persistSettings();
        await _updater.enableAlerts(
            config: config,
            ntfyServer: choice.server,
            ntfyTopic: choice.topic,
            onLog: _appendLog);
        if (!mounted) return;
        setState(() {
          _statusMessage = context.l10n.statusAlertsActive(choice.topic);
          _statusOk = true;
        });
        _addHistory(context.l10n.historyAlertsConfigured);
      } else {
        await _updater.disableAlerts(config: config, onLog: _appendLog);
        if (!mounted) return;
        setState(() {
          _statusMessage = context.l10n.statusAlertsDisabled;
          _statusOk = true;
        });
        _addHistory(context.l10n.statusAlertsDisabled);
      }
    },
        backgroundMessage: choice.enable
            ? context.l10n.busyEnablingAlerts
            : context.l10n.busyDisablingAlerts);
  }

  /// Fires a one-off test push (best-effort) so the user can confirm ntfy works.
  Future<void> _sendTestAlert(
      SshConfig config, String server, String topic) async {
    try {
      await _updater.sendTestAlert(
          config: config,
          ntfyServer: server,
          ntfyTopic: topic,
          onLog: _appendLog);
      if (!mounted) return;
      _snack(context.l10n.snackTestAlertSent);
    } catch (_) {
      if (!mounted) return;
      _snack(context.l10n.snackTestFailed);
    }
  }

  Future<({bool enable, String server, String topic})?> _showAlertsSheet(
      AlertsStatus status, SshConfig config) {
    return showModalBottomSheet<({bool enable, String server, String topic})>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      // A StatefulWidget owns the two text controllers so they're disposed only
      // after the sheet fully closes (disposing them in a finally right after
      // the future resolves used them during the dismiss animation).
      builder: (ctx) => _AlertsSheet(
        status: status,
        initialServer: _alertsServer,
        initialTopic: _alertsTopic,
        onOpenNtfy: () => _openUrl('https://ntfy.sh'),
        onSnack: _snack,
        onTest: (server, topic) => _sendTestAlert(config, server, topic),
      ),
    );
  }

  // ---- scheduled automatic updates (on-Pi systemd timer) ----

  /// Reads the current auto-update state, then lets the user schedule/disable it.
  Future<void> _configureAutoUpdate() async {
    if (_busy) return;
    final config = _prepare();
    if (config == null) return;
    _lastAction = _configureAutoUpdate;
    AutoUpdateStatus? status;
    await _guard(() async {
      status =
          await _updater.readAutoUpdateStatus(config: config, onLog: _appendLog);
    });
    if (!mounted || status == null) return;
    final choice = await _showAutoUpdateSheet(status!);
    if (choice == null || !mounted) return;

    _beginBusy();
    await _guard(() async {
      if (choice.enable) {
        final onCal = autoUpdateOnCalendar(
            weekly: choice.weekly, hour: choice.hour, weekday: choice.weekday);
        await _updater.enableAutoUpdate(
            config: config, onCalendar: onCal, onLog: _appendLog);
        if (!mounted) return;
        setState(() {
          _statusMessage = context.l10n.statusAutoUpdatesActive;
          _statusOk = true;
        });
        _addHistory(context.l10n.historyAutoUpdatesConfigured(onCal));
      } else {
        await _updater.disableAutoUpdate(config: config, onLog: _appendLog);
        if (!mounted) return;
        setState(() {
          _statusMessage = context.l10n.statusAutoUpdatesDisabled;
          _statusOk = true;
        });
        _addHistory(context.l10n.statusAutoUpdatesDisabled);
      }
    },
        backgroundMessage: choice.enable
            ? context.l10n.busyEnablingAutoUpdates
            : context.l10n.busyDisablingAutoUpdates);
  }

  Future<({bool enable, bool weekly, int hour, int weekday})?>
      _showAutoUpdateSheet(AutoUpdateStatus status) {
    var weekly = false;
    var hour = 4;
    var weekday = 7;
    final days = [
      context.l10n.dayMon,
      context.l10n.dayTue,
      context.l10n.dayWed,
      context.l10n.dayThu,
      context.l10n.dayFri,
      context.l10n.daySat,
      context.l10n.daySun,
    ];
    return showModalBottomSheet<
        ({bool enable, bool weekly, int hour, int weekday})>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(ctx.l10n.autoUpdatesTitle,
                    style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(ctx.l10n.autoUpdatesDescription),
                const SizedBox(height: 12),
                Text(
                  status.enabled
                      ? ctx.l10n.statusScheduleActive(status.nextRun ?? '—')
                      : ctx.l10n.statusScheduleOff,
                  style: TextStyle(
                      color: status.enabled ? kGreen : null,
                      fontWeight: FontWeight.w600),
                ),
                if (status.lastResult != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(ctx.l10n.labelLastRun(status.lastResult!),
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12)),
                  ),
                const Divider(height: 24),
                SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(value: false, label: Text(ctx.l10n.daily)),
                    ButtonSegment(value: true, label: Text(ctx.l10n.weekly)),
                  ],
                  selected: {weekly},
                  onSelectionChanged: (s) => setSheet(() => weekly = s.first),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text(ctx.l10n.labelTime),
                    DropdownButton<int>(
                      value: hour,
                      items: [
                        for (var h = 0; h < 24; h++)
                          DropdownMenuItem(
                              value: h,
                              child: Text(ctx.l10n
                                  .timeOClock(h.toString().padLeft(2, '0')))),
                      ],
                      onChanged: (v) => setSheet(() => hour = v ?? 4),
                    ),
                    if (weekly) ...[
                      const Spacer(),
                      Text(ctx.l10n.labelDay),
                      DropdownButton<int>(
                        value: weekday,
                        items: [
                          for (var d = 1; d <= 7; d++)
                            DropdownMenuItem(
                                value: d, child: Text(days[d - 1])),
                        ],
                        onChanged: (v) => setSheet(() => weekday = v ?? 7),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.pop(ctx, (
                          enable: true,
                          weekly: weekly,
                          hour: hour,
                          weekday: weekday
                        )),
                        child: Text(status.enabled
                            ? ctx.l10n.changeSchedule
                            : ctx.l10n.turnOn),
                      ),
                    ),
                    if (status.enabled) ...[
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, (
                          enable: false,
                          weekly: false,
                          hour: 0,
                          weekday: 7
                        )),
                        child: Text(ctx.l10n.turnOff),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _configureScheduledBackup() async {
    if (_busy) return;
    final config = _prepare();
    if (config == null) return;
    _lastAction = _configureScheduledBackup;
    ScheduledBackupStatus? status;
    await _guard(() async {
      status = await _updater.readScheduledBackupStatus(
          config: config, onLog: _appendLog);
    });
    if (!mounted || status == null) return;
    final choice = await _showScheduledBackupSheet(status!);
    if (choice == null || !mounted) return;

    _beginBusy();
    await _guard(() async {
      if (choice.enable) {
        final onCal = scheduledBackupOnCalendar(hour: choice.hour);
        await _updater.enableScheduledBackup(
            config: config, onCalendar: onCal, keep: choice.keep, onLog: _appendLog);
        if (!mounted) return;
        setState(() {
          _statusMessage = context.l10n.statusScheduledBackupsActive;
          _statusOk = true;
        });
        _addHistory(context.l10n
            .historyScheduledBackupsConfigured(onCal, choice.keep));
      } else {
        await _updater.disableScheduledBackup(config: config, onLog: _appendLog);
        if (!mounted) return;
        setState(() {
          _statusMessage = context.l10n.statusScheduledBackupsDisabled;
          _statusOk = true;
        });
        _addHistory(context.l10n.statusScheduledBackupsDisabled);
      }
    },
        backgroundMessage: choice.enable
            ? context.l10n.busyEnablingScheduledBackups
            : context.l10n.busyDisablingScheduledBackups);
  }

  Future<({bool enable, int hour, int keep})?> _showScheduledBackupSheet(
      ScheduledBackupStatus status) {
    var hour = 3;
    var keep = 7;
    return showModalBottomSheet<({bool enable, int hour, int keep})>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(ctx.l10n.scheduledBackupsTitle,
                    style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(ctx.l10n.scheduledBackupsDescription),
                const SizedBox(height: 12),
                Text(
                  status.enabled
                      ? ctx.l10n.statusScheduleActive(status.nextRun ?? '—')
                      : ctx.l10n.statusScheduleOff,
                  style: TextStyle(
                      color: status.enabled ? kGreen : null,
                      fontWeight: FontWeight.w600),
                ),
                if (status.lastResult != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(ctx.l10n.labelLast(status.lastResult!),
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12)),
                  ),
                const Divider(height: 24),
                Row(
                  children: [
                    Text(ctx.l10n.labelTime),
                    DropdownButton<int>(
                      value: hour,
                      items: [
                        for (var h = 0; h < 24; h++)
                          DropdownMenuItem(
                              value: h,
                              child: Text(ctx.l10n
                                  .timeOClock(h.toString().padLeft(2, '0')))),
                      ],
                      onChanged: (v) => setSheet(() => hour = v ?? 3),
                    ),
                    const Spacer(),
                    Text(ctx.l10n.labelKeep),
                    DropdownButton<int>(
                      value: keep,
                      items: [
                        for (final k in [3, 5, 7, 14, 30])
                          DropdownMenuItem(value: k, child: Text('$k')),
                      ],
                      onChanged: (v) => setSheet(() => keep = v ?? 7),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.pop(
                            ctx, (enable: true, hour: hour, keep: keep)),
                        child: Text(status.enabled
                            ? ctx.l10n.changeSchedule
                            : ctx.l10n.turnOn),
                      ),
                    ),
                    if (status.enabled) ...[
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => Navigator.pop(
                            ctx, (enable: false, hour: 0, keep: 0)),
                        child: Text(ctx.l10n.turnOff),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- Pi-hole + System service actions ----

  Future<void> _updatePihole() async {
    if (_busy) return;
    final config = _prepare();
    if (config == null) return;
    _lastAction = _updatePihole;
    await _guard(() async {
      await _updater.updatePihole(config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = context.l10n.statusPiholeUpdated;
        _statusOk = true;
      });
      _addHistory(context.l10n.statusPiholeUpdated);
      await _refreshServices(config);
    }, backgroundMessage: context.l10n.busyUpdatingPihole);
  }

  Future<void> _piholeGravity() async {
    if (_busy) return;
    final config = _prepare();
    if (config == null) return;
    _lastAction = _piholeGravity;
    await _guard(() async {
      await _updater.updatePiholeGravity(config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = context.l10n.statusPiholeBlocklistsUpdated;
        _statusOk = true;
      });
    }, backgroundMessage: context.l10n.busyUpdatingBlocklists);
  }

  Future<void> _piholeRestartDns() async {
    if (_busy) return;
    final config = _prepare();
    if (config == null) return;
    _lastAction = _piholeRestartDns;
    await _guard(() async {
      await _updater.restartPiholeDns(config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = context.l10n.statusPiholeDnsRestarted;
        _statusOk = true;
      });
    });
  }

  Future<void> _installPihole() async {
    if (_busy) return;
    final l10n = context.l10n;
    if (!await _confirm(
      context.l10n.dialogInstallPiholeTitle,
      context.l10n.dialogInstallPiholeBody(_host.text.trim()),
    )) {
      return;
    }
    final config = _prepare();
    if (config == null) return;
    _lastAction = _installPihole;
    await _guard(() async {
      await _updater.installPihole(config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = context.l10n.statusPiholeInstalled;
        _statusOk = true;
        _setupUrl = '$_uiScheme://${_host.text.trim()}/admin';
      });
      _addHistory(context.l10n.historyPiholeInstalled);
      await _refreshServices(config);
    }, backgroundMessage: l10n.busyInstallingPihole);
  }

  /// Refreshes the Pi's package index, then re-reads the cards. Without this
  /// the app can only report what a possibly weeks-old index knows — see
  /// [kAptIndexMaxAge] and the "Stand unbekannt" hint on the System card.
  Future<void> _refreshAptIndex() async {
    if (_busy) return;
    final l10n = context.l10n;
    final config = _prepare();
    if (config == null) return;
    _lastAction = _refreshAptIndex;
    await _guard(() async {
      await _updater.refreshAptIndex(config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = context.l10n.statusAptIndexRefreshed;
        _statusOk = true;
      });
      await _refreshServices(config);
    }, backgroundMessage: l10n.busyRefreshingAptIndex);
  }

  /// Completes an interrupted dpkg run. Offered unconditionally rather than
  /// only after a failure: by the time the user hits the error they are in the
  /// middle of something else, and the repair has no downside on a healthy Pi.
  Future<void> _repairPackageState() async {
    if (_busy) return;
    final l10n = context.l10n;
    final config = _prepare();
    if (config == null) return;
    _lastAction = _repairPackageState;
    await _guard(() async {
      await _updater.repairPackageState(config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = context.l10n.statusPackagesRepaired;
        _statusOk = true;
      });
      await _refreshServices(config);
    }, backgroundMessage: l10n.busyRepairingPackages);
  }

  Future<void> _upgradeSystem() async {
    if (_busy) return;
    final l10n = context.l10n;
    if (!await _confirm(
      context.l10n.dialogUpgradeSystemTitle,
      context.l10n.dialogUpgradeSystemBody,
    )) {
      return;
    }
    final config = _prepare();
    if (config == null) return;
    _lastAction = _upgradeSystem;
    await _guard(() async {
      await _updater.upgradeSystem(config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = context.l10n.statusSystemUpdated;
        _statusOk = true;
      });
      _addHistory(context.l10n.historySystemUpgraded);
      await _refreshServices(config);
    }, backgroundMessage: l10n.busySystemUpgrade);
  }

  void _openPiholeAdmin() {
    if (_host.text.trim().isEmpty) {
      _snack(context.l10n.snackEnterHostFirst);
      return;
    }
    _openUrl('$_uiScheme://${_host.text.trim()}/admin');
  }

  Future<void> _backupPihole() => _runServiceBackup(
        label: 'Pi-hole',
        backgroundMessage: context.l10n.busyBackingUpPihole,
        run: (config) =>
            _updater.backupPihole(config: config, onLog: _appendLog),
      );

  Future<void> _backupHomeAssistant() => _runServiceBackup(
        label: 'Home Assistant',
        backgroundMessage: context.l10n.busyBackingUpHomeAssistant,
        run: (config) =>
            _updater.backupHomeAssistant(config: config, onLog: _appendLog),
      );

  /// Shared flow for the on-demand Pi-hole / HA backups: run, show the path.
  Future<void> _runServiceBackup({
    required String label,
    required String backgroundMessage,
    required Future<String> Function(SshConfig config) run,
  }) async {
    if (_busy) return;
    final config = _prepare();
    if (config == null) return;
    _lastAction = () => _runServiceBackup(
        label: label, backgroundMessage: backgroundMessage, run: run);
    await _guard(() async {
      final path = await run(config);
      if (!mounted) return;
      setState(() {
        _statusMessage = context.l10n.statusServiceBackedUp(label, path);
        _statusOk = true;
      });
      _addHistory(context.l10n.historyServiceBackedUp(label));
    }, backgroundMessage: backgroundMessage);
  }

  // ---- Home Assistant service actions ----

  Future<void> _updateHomeAssistant() async {
    if (_busy) return;
    final config = _prepare();
    if (config == null) return;
    _lastAction = _updateHomeAssistant;
    await _guard(() async {
      await _updater.updateHomeAssistant(config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = context.l10n.statusHomeAssistantUpdated;
        _statusOk = true;
      });
      _addHistory(context.l10n.statusHomeAssistantUpdated);
      await _refreshServices(config);
    }, backgroundMessage: context.l10n.busyUpdatingHomeAssistant);
  }

  Future<void> _installHomeAssistant() async {
    if (_busy) return;
    final l10n = context.l10n;
    if (!await _confirm(
      context.l10n.dialogInstallHomeAssistantTitle,
      context.l10n.dialogInstallHomeAssistantBody(_host.text.trim()),
    )) {
      return;
    }
    final config = _prepare();
    if (config == null) return;
    _lastAction = _installHomeAssistant;
    await _guard(() async {
      await _updater.installHomeAssistant(config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = context.l10n.statusHomeAssistantInstalled;
        _statusOk = true;
        _setupUrl = 'http://${_host.text.trim()}:8123';
      });
      _addHistory(context.l10n.historyHomeAssistantInstalled);
      await _refreshServices(config);
    }, backgroundMessage: l10n.busyInstallingHomeAssistant);
  }

  void _openHomeAssistant() {
    if (_host.text.trim().isEmpty) {
      _snack(context.l10n.snackEnterHostFirst);
      return;
    }
    _openUrl('http://${_host.text.trim()}:8123');
  }

  /// Cancels the in-flight action by closing its SSH connection; the running
  /// action then finishes as "Abgebrochen".
  Future<void> _cancel() async {
    _appendLog(context.l10n.logCancelRequested);
    await _updater.cancel();
  }

  /// Re-trust a changed host key, then retry the action that hit it.
  Future<void> _trustAndRetry() async {
    if (_busy) return; // synchronous re-entrancy guard: forgetHostKey is async
    final config = _lastConfig;
    final action = _lastAction;
    if (config == null || action == null) return;
    setState(() => _busy = true);
    try {
      await _updater.forgetHostKey(config);
    } catch (_) {
      // proceed to retry regardless — forgetting is best-effort
    }
    if (!mounted) return;
    // Hand control to the original action, which re-enters the normal
    // busy/_guard lifecycle (it sets _busy synchronously before its first await,
    // so there is no concurrency gap here).
    setState(() => _busy = false);
    await action();
  }

  void _shareLog() {
    if (_log.isEmpty) {
      _snack(context.l10n.snackLogEmpty);
      return;
    }
    SharePlus.instance.share(ShareParams(text: _log.join('\n')));
  }

  /// Opens the mail app with a pre-filled support address + subject (version
  /// included, so support mails carry the app version automatically).
  void _contactSupport() {
    final subject = Uri.encodeComponent(_appVersion.isEmpty
        ? 'Pi-Tool – Support'
        : 'Pi-Tool v$_appVersion – Support');
    _openUrl('mailto:$kSupportEmail?subject=$subject');
  }

  /// Default [UpdaterPage.fileSaver]: writes [bytes] into the app's temp dir
  /// (dart:io — on Android that's the app cache, no plugin needed) and opens
  /// the share sheet, so the user can save to Dateien/Drive/etc.
  Future<void> _saveAndShareBytes(String name, Uint8List bytes) async {
    final f = File('${Directory.systemTemp.path}/$name');
    await f.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path)]));
  }

  /// Read-only live status straight from evcc's Web-API (no SSH, no creds).
  void _showApiStatus() {
    final host = _host.text.trim();
    if (host.isEmpty) {
      _snack(context.l10n.snackEnterHostFirst);
      return;
    }
    final port = _uiPort.text.trim().isEmpty ? '7070' : _uiPort.text.trim();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _ApiStatusSheet(
        future: _apiClient.fetchState(
            scheme: _uiScheme, host: host, port: port),
      ),
    );
  }

  /// Scans the local /24 for hosts with SSH open, then lets the user pick one.
  Future<void> _findPi() async {
    // Capture the navigator up front and block back-dismissal, so the dialog we
    // pop after the scan is guaranteed to be this progress dialog (never some
    // other topmost route).
    final navigator = Navigator.of(context, rootNavigator: true);
    var cancelled = false;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: _ScanProgressDialog(onCancel: () {
          if (cancelled) return; // guard: a double-tap must not pop the page too
          cancelled = true;
          navigator.pop();
        }),
      ),
    );
    var hosts = const <String>[];
    try {
      hosts = await _piFinder();
    } catch (_) {
      // fail-soft: treated as "nothing found" below
    }
    // The (bounded) scan still finishes in the background; if the user already
    // cancelled, the dialog is gone — just drop the result.
    if (cancelled) return;
    // Only pop if our dialog is still the top route: if the app was backgrounded
    // mid-scan with app-lock on, the lifecycle handler already popUntil'd to the
    // home route, and a blind pop() would remove the home route (blank screen).
    if (navigator.canPop()) navigator.pop();
    // Don't draw the results over the lock screen (or after dispose).
    if (!mounted || _locked) return;
    if (hosts.isEmpty) {
      _snack(context.l10n.snackNoSshDevices);
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(ctx.l10n.foundDevicesTitle,
                  style: Theme.of(ctx).textTheme.titleMedium),
              subtitle: Text(ctx.l10n.foundDevicesSubtitle),
            ),
            for (final ip in hosts)
              ListTile(
                dense: true,
                leading: const Icon(Icons.dns_outlined, size: 18),
                title: Text(ip),
                onTap: () {
                  setState(() => _host.text = ip);
                  _scheduleSave();
                  Navigator.pop(ctx);
                  _snack(context.l10n.snackHostSet(ip));
                },
              ),
          ],
        ),
      ),
    );
  }

  /// Runs a free-form console command entered by the user and streams the
  /// output into the console log. sudo is handled by the updater.
  Future<void> _runConsoleCommand(String command) async {
    final cmd = command.trim();
    if (cmd.isEmpty || _busy) return;
    if (!_unlocked) {
      _showPaywall(); // Konsole is a Pro feature
      return;
    }
    // Interactive/TUI programs (htop, editors, pagers, -f follow) can't work in
    // the non-PTY console — show a helpful hint instead of the cryptic error.
    final hint = interactiveCommandHint(cmd);
    if (hint != null) {
      _consoleInput.clear();
      _appendLog('\$ $cmd');
      _appendLog('⚠ $hint');
      setState(() {
        _statusMessage = context.l10n.statusInteractiveCommand;
        _statusOk = false;
      });
      _consoleHistory
        ..remove(cmd)
        ..insert(0, cmd);
      if (_consoleHistory.length > 20) {
        _consoleHistory = _consoleHistory.sublist(0, 20);
      }
      _scheduleSave();
      return;
    }
    final config = _prepare();
    if (config == null) return;
    _consoleInput.clear();
    // Remember the command (newest first, deduped, capped) for the history.
    _consoleHistory
      ..remove(cmd)
      ..insert(0, cmd);
    if (_consoleHistory.length > 20) {
      _consoleHistory = _consoleHistory.sublist(0, 20);
    }
    _scheduleSave();
    _lastAction = () => _runConsoleCommand(cmd);
    await _guard(() async {
      await _updater
          .runConsoleCommand(config: config, command: cmd, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = context.l10n.statusCommandExecuted(cmd);
        _statusOk = true;
      });
    }, backgroundMessage: context.l10n.busyCommandRunning);
  }

  /// Frequently useful read-only commands, offered above the history.
  static const _quickCommands = [
    'df -h',
    'free -m',
    'uptime',
    'docker ps',
    'systemctl --failed',
    'journalctl -n 50 --no-pager',
  ];

  /// Prompts for a new custom quick command and persists it. Returns inside
  /// [setSheet] so the open sheet updates in place.
  Future<void> _addCustomCommand(StateSetter setSheet) async {
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => _NameDialog(
        title: ctx.l10n.dialogAddQuickCommandTitle,
        initial: '',
        label: ctx.l10n.labelCommand,
        hint: ctx.l10n.hintCommandExample,
        confirmLabel: ctx.l10n.actionSave,
        fieldKey: const Key('customCommandField'),
        mono: true,
      ),
    );
    final cmd = saved?.trim() ?? '';
    if (cmd.isEmpty || _customCommands.contains(cmd) || !mounted) return;
    setState(() => _customCommands = [..._customCommands, cmd]);
    setSheet(() {});
    _scheduleSave();
  }

  /// Bottom sheet with quick commands (built-in + user-defined) + the
  /// recent-command history. Tapping an entry fills the input (deliberately
  /// does NOT auto-run it).
  void _showConsoleHistory() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(ctx.l10n.quickCommandsTitle,
                  style: Theme.of(ctx).textTheme.titleSmall),
              dense: true,
            ),
            for (final c in _quickCommands)
              ListTile(
                dense: true,
                leading: const Icon(Icons.bolt, size: 18),
                title: Text(c,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 13)),
                onTap: () {
                  _consoleInput.text = c;
                  Navigator.pop(ctx);
                },
              ),
            ListTile(
              dense: true,
              title: Text(ctx.l10n.customCommandsTitle,
                  style: Theme.of(ctx).textTheme.titleSmall),
              trailing: IconButton(
                key: const Key('addCustomCommand'),
                tooltip: ctx.l10n.tooltipAddCustomCommand,
                icon: const Icon(Icons.add, size: 20),
                onPressed: () => _addCustomCommand(setSheet),
              ),
            ),
            for (final c in _customCommands)
              ListTile(
                dense: true,
                leading: const Icon(Icons.star_outline, size: 18),
                title: Text(c,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 13)),
                onTap: () {
                  _consoleInput.text = c;
                  Navigator.pop(ctx);
                },
                trailing: IconButton(
                  key: ValueKey('delCustom-$c'),
                  tooltip: ctx.l10n.tooltipRemove,
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () {
                    setState(() => _customCommands =
                        _customCommands.where((x) => x != c).toList());
                    setSheet(() {});
                    _scheduleSave();
                  },
                ),
              ),
            if (_consoleHistory.isNotEmpty) ...[
              const Divider(),
              ListTile(
                title: Text(ctx.l10n.historyTitle,
                    style: Theme.of(ctx).textTheme.titleSmall),
                dense: true,
                trailing: TextButton.icon(
                  icon: const Icon(Icons.delete_sweep, size: 18),
                  label: Text(ctx.l10n.actionDelete),
                  onPressed: () {
                    setState(() => _consoleHistory = []);
                    _scheduleSave();
                    Navigator.pop(ctx);
                  },
                ),
              ),
              for (final c in _consoleHistory)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.history, size: 18),
                  title: Text(c,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 13)),
                  onTap: () {
                    _consoleInput.text = c;
                    Navigator.pop(ctx);
                  },
                ),
            ],
          ],
        ),
      ),
      ),
    );
  }

  /// Re-detects the services after a successful action so the cards (LED,
  /// version, installed-state) reflect the change instead of going stale.
  /// Best-effort: a failed refresh keeps the last snapshot.
  Future<void> _refreshServices(SshConfig config) async {
    try {
      final s = await _updater.detectServices(config: config, onLog: (_) {});
      final reconciled = await _reconcileEvcc(s);
      if (mounted) {
        setState(() {
          _services = reconciled;
          _rememberTailscaleIp(reconciled);
          _rememberLanHost();
          _connectionOk = true; // a successful detect proves the Pi is reachable
        });
      }
    } catch (_) {
      // keep the last snapshot
    }
  }

  /// Cross-checks the detected evcc against its latest GitHub release, so a stale
  /// apt index on the Pi can't hide an available evcc update (see
  /// applyLatestEvccVersion). The release is fetched once per session and reused;
  /// fail-soft — any error just leaves the apt-based result as is.
  /// Cross-checks apt-evcc AND Home Assistant currency against their latest
  /// GitHub releases (both cached per session, both fail-soft). Named for evcc
  /// historically; also reconciles HA so its card can show "Aktuell ✓" instead
  /// of always offering "Aktualisieren".
  Future<List<ServiceStatus>> _reconcileEvcc(
      List<ServiceStatus> services) async {
    var out = services;
    try {
      _evccLatest ??= await _fetchEvccRelease();
      out = applyLatestEvccVersion(out, _evccLatest?.version);
    } catch (_) {
      // fail-soft
    }
    try {
      if (out.any((s) => s.id == 'homeassistant' && s.installed)) {
        _haLatest ??= await _fetchHaLatest();
        out = applyLatestHomeAssistantVersion(out, _haLatest);
      }
    } catch (_) {
      // fail-soft
    }
    return out;
  }

  void _addHistory(String text) {
    _historyStore.add(HistoryEntry(
      when: formatTimestamp(DateTime.now()),
      text: text,
    ));
  }

  String _notesExcerpt(String s) {
    final t = s.trim();
    if (t.isEmpty) return context.l10n.evccNewVersionAvailable;
    return t.length > 500 ? '${t.substring(0, 500)} …' : t;
  }

  Future<void> _showHistory() async {
    final entries = await _historyStore.load();
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: entries.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(ctx.l10n.noHistoryYet),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    title: Text(ctx.l10n.historyTitle,
                        style: Theme.of(ctx).textTheme.titleMedium),
                    trailing: TextButton(
                      onPressed: () async {
                        await _historyStore.clear();
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      child: Text(ctx.l10n.actionClear),
                    ),
                  ),
                  for (final e in entries.reversed)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.history, size: 18),
                      title: Text(e.text),
                      subtitle: Text(e.when),
                    ),
                ],
              ),
      ),
    );
  }

  // ---- helpers -------------------------------------------------------------

  static const _kMaxLogLines = 2000;

  void _appendLog(String line) {
    if (!mounted) return;
    // Defense in depth: redact the live password from anything we log.
    setState(() {
      _log.add(redactPassword(line, _password.text));
      // Cap the buffer so a very chatty command can't grow it (and the log
      // view's render cost) without bound.
      if (_log.length > _kMaxLogLines) {
        _log.removeRange(0, _log.length - _kMaxLogLines);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  String _evccUiUrl() {
    final port = _uiPort.text.trim().isEmpty ? '7070' : _uiPort.text.trim();
    return '$_uiScheme://${_host.text.trim()}:$port';
  }

  void _openEvccUi() {
    if (_host.text.trim().isEmpty) {
      _snack(context.l10n.snackEnterHostFirst);
      return;
    }
    _openUrl(_evccUiUrl());
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) _snack(context.l10n.snackCouldNotOpenLink);
    }
  }

  Future<bool> _confirm(String title, String body,
      {String? confirmLabel, bool destructive = false}) async {
    final cs = Theme.of(context).colorScheme;
    final confirmText = confirmLabel ?? context.l10n.actionContinue;
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            // Destructive actions get an error-coloured button + an explicit verb
            // so they're clearly distinct from a neutral "Weiter".
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: cs.error, foregroundColor: cs.onError)
                : null,
            child: Text(confirmText),
          ),
        ],
      ),
    );
    return r == true && mounted;
  }

  /// Shown on the FIRST connection to a host: display the presented SSH
  /// fingerprint and let the user confirm before it is trusted (TOFU). Returns
  /// false (abort, no password sent) if declined or the UI is gone.
  Future<bool> _confirmFirstHostKey(String fingerprint) async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.dialogTrustPiTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(ctx.l10n.dialogTrustPiBody(_host.text.trim())),
            const SizedBox(height: 10),
            SelectableText(
              fingerprint,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            const SizedBox(height: 10),
            Text(
              ctx.l10n.dialogTrustPiWarning,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l10n.cancel),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.verified_user_outlined, size: 18),
            label: Text(ctx.l10n.actionTrust),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _snack(String msg, {String? actionLabel, VoidCallback? onAction}) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        action: (actionLabel != null && onAction != null)
            ? SnackBarAction(label: actionLabel, onPressed: onAction)
            : null,
      ));
  }

  void _openSetupGuide() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _SetupGuidePage(onDownloadImager: () => _openUrl(kImagerUrl)),
    ));
  }

  // Small, muted footer link (Datenschutz/Impressum/Lizenzen) shown under the
  // version line.
  Widget _legalLink(String label, VoidCallback onTap) {
    final theme = Theme.of(context);
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        minimumSize: Size.zero,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: theme.colorScheme.onSurfaceVariant,
        textStyle: theme.textTheme.bodySmall,
      ),
      child: Text(label),
    );
  }

  void _showLicenses() {
    showLicensePage(
      context: context,
      applicationName: context.l10n.licenseAppName,
      applicationIcon: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: _PromptMark(
            size: 56, chevronColor: Theme.of(context).colorScheme.onSurface),
      ),
      applicationLegalese:
          '© 2026 KYTH. Systems UG (haftungsbeschränkt)',
    );
  }

  void _openSettings() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // Scrollable, but capped below full height so a scrim strip stays tappable
      // to dismiss; the port field still rises above the keyboard.
      isScrollControlled: true,
      constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.9),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Pinned header with an always-visible close button — the (tall)
                // list can be dismissed without the phone back button.
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 4, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(ctx.l10n.settingsTitle,
                            style: Theme.of(ctx).textTheme.titleMedium),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        tooltip:
                            MaterialLocalizations.of(ctx).closeButtonTooltip,
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(ctx.l10n.settingsLockTitle),
                            subtitle: Text(ctx.l10n.settingsLockSubtitle),
                            value: _lockEnabled,
                            onChanged: (v) async {
                              final l10n = ctx.l10n;
                              if (v && !await _authenticator.canAuthenticate()) {
                                _snack(l10n.snackNoBiometrics);
                                return;
                              }
                              setState(() => _lockEnabled = v);
                              setSheet(() {});
                              _scheduleSave();
                            },
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(ctx.l10n.settingsBackupBeforeUpdateTitle),
                            subtitle: Text(ctx.l10n.settingsBackupBeforeUpdateSubtitle),
                            value: _backupBeforeUpdate,
                            onChanged: (v) {
                              setState(() => _backupBeforeUpdate = v);
                              setSheet(() {});
                              _scheduleSave();
                            },
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(ctx.l10n.settingsHttpsTitle),
                            subtitle: Text(_uiScheme == 'https'
                                ? 'https://…'
                                : ctx.l10n.settingsHttpsSubtitleOff),
                            value: _uiScheme == 'https',
                            onChanged: (v) {
                              setState(() => _uiScheme = v ? 'https' : 'http');
                              setSheet(() {});
                              _scheduleSave();
                            },
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _uiPort,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: ctx.l10n.settingsPortLabel,
                              helperText: ctx.l10n.settingsPortHelper,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(ctx.l10n.settingsThemeTitle,
                              style: Theme.of(ctx).textTheme.labelLarge),
                          const SizedBox(height: 6),
                          SegmentedButton<String>(
                            segments: [
                              ButtonSegment(
                                  value: 'system', label: Text(ctx.l10n.optionSystem)),
                              ButtonSegment(
                                  value: 'light', label: Text(ctx.l10n.themeLight)),
                              ButtonSegment(
                                  value: 'dark', label: Text(ctx.l10n.themeDark)),
                            ],
                            selected: {_themeMode},
                            onSelectionChanged: (s) {
                              setState(() => _themeMode = s.first);
                              themeModeNotifier.value = parseThemeMode(s.first);
                              setSheet(() {});
                              _scheduleSave();
                            },
                          ),
                          const SizedBox(height: 16),
                          Text(ctx.l10n.settingsLanguageTitle,
                              style: Theme.of(ctx).textTheme.labelLarge),
                          const SizedBox(height: 6),
                          SegmentedButton<String>(
                            segments: [
                              ButtonSegment(
                                  value: 'system', label: Text(ctx.l10n.optionSystem)),
                              ButtonSegment(value: 'de', label: Text(ctx.l10n.langGerman)),
                              ButtonSegment(
                                  value: 'en', label: Text(ctx.l10n.langEnglish)),
                            ],
                            selected: {_languageMode},
                            onSelectionChanged: (s) {
                              setState(() => _languageMode = s.first);
                              localeNotifier.value = localeForLanguageMode(s.first);
                              setSheet(() {});
                              _scheduleSave();
                            },
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(ctx.l10n.settingsNightlyTitle),
                            subtitle: Text(ctx.l10n.settingsNightlySubtitle),
                            value: _channel == 'unstable',
                            onChanged: (v) {
                              setState(() => _channel = v ? 'unstable' : 'stable');
                              setSheet(() {});
                              _scheduleSave();
                            },
                          ),
                          const Divider(),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.upload_file_outlined),
                            title: Text(ctx.l10n.exportProfilesTitle),
                            subtitle: Text(ctx.l10n.settingsExportSubtitle),
                            onTap: () {
                              Navigator.pop(ctx);
                              _exportProfiles();
                            },
                          ),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.download_outlined),
                            title: Text(ctx.l10n.importProfilesTitle),
                            onTap: () {
                              Navigator.pop(ctx);
                              _importProfiles();
                            },
                          ),
                          const Divider(),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.support_agent),
                            title: Text(ctx.l10n.settingsContactSupport),
                            subtitle: const Text(kSupportEmail),
                            onTap: () {
                              Navigator.pop(ctx);
                              _contactSupport();
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Builds a card per detected service (or a hint before the first test).
  /// The "Fernzugriff" card — offered only while it is actually useful: a live
  /// connection and no tailnet IP known yet, or the Pi is ready but this phone
  /// isn't on the tailnet. Once remote access works the card disappears instead
  /// of sitting there as permanent furniture.
  Widget? _remoteAccessCard() {
    if (!_connected) return null;
    if (_remoteAccessPhase == _RemoteAccessPhase.done) return null;
    final phoneMissing = _remoteAccessPhase == _RemoteAccessPhase.phoneMissing;
    // Proven once (persisted) → gone for good. A "check it again" card on a
    // working setup is the kind of permanent furniture people learn to ignore.
    if (_remoteAccessProven && !phoneMissing) return null;

    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final awaiting = _remoteAccessPhase == _RemoteAccessPhase.awaitingBrowser;
    // The Pi already carries a tailnet IP, but nothing proved that THIS phone
    // can use it — that gap is the whole point of the check.
    final piReady = _tailscaleIp.isNotEmpty;
    final body = phoneMissing
        ? context.l10n.remoteAccessPhoneMissing
        : awaiting
            ? context.l10n.remoteAccessConfirmInBrowser
            : piReady
                ? context.l10n.remoteAccessCheckPhone
                : context.l10n.remoteAccessIntro;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: dark ? kCard : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: dark ? Colors.white10 : cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.travel_explore, size: 20, color: cs.onSurfaceVariant),
              const SizedBox(width: 10),
              Text(context.l10n.remoteAccessTitle,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 8),
          Text(body, style: TextStyle(color: cs.onSurfaceVariant)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (phoneMissing)
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _openUrl(
                          'https://play.google.com/store/apps/details?id=com.tailscale.ipn'),
                  child: Text(context.l10n.actionGetTailscaleApp),
                ),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _proGate(awaiting || phoneMissing || piReady
                        ? _checkRemoteAccess
                        : _setupRemoteAccess),
                child: Text(awaiting || phoneMissing || piReady
                    ? context.l10n.actionCheckRemoteAccess
                    : context.l10n.actionSetupRemoteAccess),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _serviceCards() {
    if (_services.isEmpty) {
      final cs = Theme.of(context).colorScheme;
      // After a failed connect, don't tell the user to just do the thing that
      // failed — point them at the likely cause instead.
      final failed = _connectionOk == false;
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Icon(failed ? Icons.error_outline : Icons.lan_outlined,
                  size: 18, color: failed ? cs.error : cs.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  failed
                      ? context.l10n.serviceCardsFailedHint
                      : context.l10n.serviceCardsConnectHint,
                  style:
                      TextStyle(color: failed ? cs.error : cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ];
    }
    final cards = <Widget>[];
    final remote = _remoteAccessCard();
    if (remote != null) cards.add(remote);
    final addable = <_AddableService>[];
    // System (Pi) card always first; the rest keep their detected order.
    for (final s in orderServicesForDisplay(_services)) {
      // The overview shows only what's actually running: a not-installed
      // evcc/Pi-hole/HA goes into the "Dienst hinzufügen" picker, not a card.
      // (System is the Pi itself — always shown. apt services only ever appear
      // here when installed.)
      if (!s.installed && s.id != 'system') {
        switch (s.id) {
          case 'evcc':
            addable.add(_AddableService('evcc', Icons.bolt, _install));
          case 'pihole':
            addable.add(
                _AddableService('Pi-hole', Icons.shield_outlined, _installPihole));
          case 'homeassistant':
            addable.add(_AddableService(
                'Home Assistant', Icons.cottage_outlined, _installHomeAssistant));
          case 'piconnect':
            // Shown even when incompatible (greyed), so the customer knows why.
            addable.add(_AddableService(
              'Raspberry Pi Connect',
              Icons.cast,
              s.compatible
                  ? _installPiConnect
                  : () => _snack(context.l10n.snackPiConnectNeedsBookworm),
              subtitle: s.compatible
                  ? context.l10n.piConnectSubtitleInstall
                  : context.l10n.piConnectSubtitleIncompatible,
              enabled: s.compatible,
            ));
          case 'tailscale':
            addable.add(_AddableService(
              'Tailscale',
              Icons.vpn_key_outlined,
              _installTailscale,
              subtitle: context.l10n.tailscaleSubtitle,
            ));
        }
        continue;
      }
      // Known up to date → the primary becomes a disabled "Aktuell"; a forced
      // update is offered in the ⋮ menu instead.
      final upToDate = s.installed && s.updateKnown && !s.updateAvailable;
      switch (s.id) {
        case 'evcc':
          cards.add(_ServiceCard(
            isPro: _unlocked,
            status: s,
            icon: Icons.bolt,
            enabled: !_busy,
            primaryLabel: context.l10n.actionUpdate,
            onPrimary: () => _run(dryRun: false),
            onOpenWeb: _openEvccUi,
            actions: s.installed
                ? [
                    _CardAction(
                        context.l10n.actionShowLogs, () => _showServiceLogs(s)),
                    if (upToDate)
                      _CardAction(context.l10n.actionUpdateAnyway,
                          () => _run(dryRun: false)),
                    _CardAction(
                        context.l10n.actionDryRun, () => _run(dryRun: true)),
                    _CardAction(context.l10n.actionLiveStatus, _showApiStatus),
                    _CardAction(
                        context.l10n.actionRestartService, _restartService),
                    // Backups are made only for apt installs; restore would also
                    // `systemctl start evcc`, which has no unit on a Docker host.
                    if (s.detail.startsWith('apt')) ...[
                      _CardAction(
                          context.l10n.actionEditConfig,
                          () => _proGate(
                              () => _editConfig('/etc/evcc.yaml', 'evcc.yaml')),
                          pro: true),
                      _CardAction(context.l10n.actionRestoreBackup,
                          () => _proGate(_restoreBackup), pro: true),
                    ],
                    _CardAction(context.l10n.actionOfficialEvccApp,
                        () => _openUrl(kEvccPlayStoreUrl)),
                  ]
                : const [],
          ));
        case 'pihole':
          cards.add(_ServiceCard(
            isPro: _unlocked,
            status: s,
            icon: Icons.shield_outlined,
            enabled: !_busy,
            primaryLabel: context.l10n.actionUpdate,
            onPrimary: _updatePihole,
            onOpenWeb: _openPiholeAdmin,
            actions: [
              _CardAction(
                  context.l10n.actionShowLogs, () => _showServiceLogs(s)),
              if (upToDate)
                _CardAction(context.l10n.actionUpdateAnyway, _updatePihole),
              _CardAction(context.l10n.actionBackupTeleporter,
                  () => _proGate(_backupPihole), pro: true),
              _CardAction(context.l10n.actionManageBackups,
                  () => _proGate(_managePiholeBackups), pro: true),
              _CardAction(context.l10n.actionUpdateBlocklists, _piholeGravity),
              _CardAction(context.l10n.actionRestartDns, _piholeRestartDns),
            ],
          ));
        case 'homeassistant':
          cards.add(_ServiceCard(
            isPro: _unlocked,
            status: s,
            icon: Icons.cottage_outlined,
            enabled: !_busy,
            primaryLabel: context.l10n.actionUpdate,
            onPrimary: _updateHomeAssistant,
            onOpenWeb: _openHomeAssistant,
            actions: [
              _CardAction(
                  context.l10n.actionShowLogs, () => _showServiceLogs(s)),
              _CardAction(context.l10n.actionBackupConfig,
                  () => _proGate(_backupHomeAssistant), pro: true),
              _CardAction(context.l10n.actionManageBackups,
                  () => _proGate(_manageHomeAssistantBackups), pro: true),
            ],
          ));
        case 'piconnect':
          final signedIn = s.active; // active == signed in
          cards.add(_ServiceCard(
            isPro: _unlocked,
            status: s,
            icon: Icons.cast,
            enabled: !_busy,
            // A pending update takes over the primary button, like on every
            // other card — the amber LED alone was too quiet, and "Web öffnen"
            // sat there while 2.12.2 was waiting. The displaced action moves
            // into ⋮ and comes back once the update is done.
            primaryLabel: s.updateAvailable
                ? context.l10n.actionUpdate
                : signedIn
                    ? context.l10n.actionOpenWeb
                    : context.l10n.actionSignIn,
            onPrimary: s.updateAvailable
                ? () => _updateAptService(s)
                : signedIn
                    ? () => _openUrl('https://connect.raspberrypi.com')
                    : _piConnectSignin,
            actions: [
              if (s.updateAvailable)
                _CardAction(
                    signedIn
                        ? context.l10n.actionOpenWeb
                        : context.l10n.actionSignIn,
                    signedIn
                        ? () => _openUrl('https://connect.raspberrypi.com')
                        : _piConnectSignin),
              if (signedIn) ...[
                _CardAction(context.l10n.actionEnableRemoteAccess,
                    () => _piConnectSet(true)),
                _CardAction(context.l10n.actionPauseRemoteAccess,
                    () => _piConnectSet(false)),
                _CardAction(context.l10n.actionSignOut, _piConnectSignout),
              ],
            ],
          ));
        case 'tailscale':
          final up = s.active;
          cards.add(_ServiceCard(
            isPro: _unlocked,
            status: s,
            icon: Icons.vpn_key,
            enabled: !_busy,
            // Same rule as Pi Connect: the button shows what is next in line.
            primaryLabel: s.updateAvailable
                ? context.l10n.actionUpdate
                : up
                    ? context.l10n.actionDisconnect
                    : context.l10n.actionConnect,
            onPrimary: s.updateAvailable
                ? () => _updateAptService(s)
                : up
                    ? () => _tailscaleSet(logout: false)
                    : _tailscaleUp,
            onOpenWeb: up
                ? () => _openUrl('https://login.tailscale.com/admin/machines')
                : null,
            actions: [
              if (s.updateAvailable)
                _CardAction(
                    up
                        ? context.l10n.actionDisconnect
                        : context.l10n.actionConnect,
                    up
                        ? () => _tailscaleSet(logout: false)
                        : _tailscaleUp),
              if (up && s.version != null)
                _CardAction(context.l10n.actionUseIpAsHost(s.version!),
                    () => _useTailscaleIp(s.version!)),
              // "Trennen" (primary) = tailscale down; this is the account-level
              // logout — labelled distinctly so the two aren't confused.
              _CardAction(context.l10n.actionSignOutTailscale,
                  () => _tailscaleSet(logout: true)),
            ],
          ));
        case 'system':
          cards.add(_ServiceCard(
            isPro: _unlocked,
            status: s,
            icon: Icons.memory,
            enabled: !_busy,
            primaryLabel: context.l10n.actionInstallUpdates,
            onPrimary: _upgradeSystem,
            actions: [
              _CardAction(
                  context.l10n.actionShowLogs, () => _showServiceLogs(s)),
              if (upToDate)
                _CardAction(context.l10n.actionUpdateAnyway, _upgradeSystem),
              // The remedy for "Stand unbekannt": refresh the index the whole
              // update detection reads from, then re-read the cards.
              _CardAction(
                  context.l10n.actionRefreshPackageLists, _refreshAptIndex),
              // The way out of "dpkg was interrupted" — without it apt refuses
              // every install on this Pi and the user is simply stuck.
              _CardAction(
                  context.l10n.actionRepairPackages, _repairPackageState),
              _CardAction(context.l10n.actionCleanup,
                  () => _proGate(_cleanupSystem), pro: true),
              _CardAction(context.l10n.actionSecurityCheck, _securityCheck),
              _CardAction(context.l10n.actionAnalyzeStorage, _storageExplorer),
              _CardAction(context.l10n.actionDockerContainers, _dockerContainers),
              _CardAction(context.l10n.actionRebootPi, _reboot),
              _CardAction(context.l10n.actionShutdownPi, _shutdown,
                  destructive: true),
            ],
          ));
        case 'adguard':
        case 'nodered':
        case 'zigbee2mqtt':
          // Detected systemd services (not app-installed): manage only —
          // restart, open web, logs. No apt update path.
          cards.add(_ServiceCard(
            isPro: _unlocked,
            status: s,
            icon: _serviceIcon(s.id),
            enabled: !_busy,
            primaryLabel: context.l10n.actionRestart,
            onPrimary: () => _restartSystemdService(s),
            onOpenWeb:
                s.webPort != null ? () => _openServiceWeb(s.webPort!) : null,
            actions: [
              _CardAction(
                  context.l10n.actionShowLogs, () => _showServiceLogs(s)),
            ],
          ));
        default:
          // Generic apt service (Grafana, InfluxDB, …): update via apt,
          // optional web UI. Only ever emitted when installed.
          cards.add(_ServiceCard(
            isPro: _unlocked,
            status: s,
            icon: _serviceIcon(s.id),
            enabled: !_busy,
            primaryLabel: context.l10n.actionUpdate,
            onPrimary: () => _updateAptService(s),
            onOpenWeb:
                s.webPort != null ? () => _openServiceWeb(s.webPort!) : null,
            actions: [
              _CardAction(
                  context.l10n.actionShowLogs, () => _showServiceLogs(s)),
              if (upToDate)
                _CardAction(context.l10n.actionUpdateAnyway,
                    () => _updateAptService(s)),
            ],
          ));
      }
    }
    // apt services that aren't installed yet also join the "Dienst hinzufügen"
    // list (they only appear in _services once installed).
    final present = _services.map((s) => s.id).toSet();
    for (final svc in knownInstallableServices) {
      if (present.contains(svc.id)) continue;
      addable.add(_AddableService(
        svc.name,
        _serviceIcon(svc.id),
        () => _installAptService(svc),
        subtitle: svc.webPort != null
            ? context.l10n.webUiOnPort(svc.webPort!)
            : null,
      ));
    }
    // Guided one-flow setup of the evcc monitoring stack, offered at the top of
    // the picker when at least two of its parts are still missing.
    final stackMissing = knownInstallableServices
        .where((s) =>
            _stackIds.contains(s.id) && !present.contains(s.id))
        .toList();
    if (stackMissing.length >= 2) {
      addable.insert(
        0,
        _AddableService(
          context.l10n.energyMonitoringStack,
          Icons.auto_awesome,
          _guidedSetup,
          subtitle: context.l10n.energyStackSubtitle,
        ),
      );
    }
    if (addable.isNotEmpty) {
      cards.add(Padding(
        padding: const EdgeInsets.only(top: 4),
        child: OutlinedButton.icon(
          onPressed: _busy ? null : () => _showAddServicePicker(addable),
          icon: const Icon(Icons.add, size: 18),
          label: Text(context.l10n.addService),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(44),
          ),
        ),
      ));
    }
    return cards;
  }

  /// Bottom-sheet picker of every not-installed service (evcc, Pi-hole, Home
  /// Assistant, Grafana, InfluxDB, Mosquitto). Each routes to its own install.
  void _showAddServicePicker(List<_AddableService> items) {
    showModalBottomSheet<void>(
      context: context,
      // Dark → the card tone; light → the theme default. Hardcoding kCard here
      // made the sheet dark in light mode → dark-on-dark, invisible content.
      backgroundColor:
          Theme.of(context).brightness == Brightness.dark ? kCard : null,
      showDragHandle: true,
      isScrollControlled: true, // don't clip the (up to ~10) service tiles
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                child: Text(sheetContext.l10n.addService,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(sheetContext.l10n.addServiceDescription),
            ),
            for (final item in items)
              ListTile(
                enabled: item.enabled,
                leading: Icon(item.icon),
                title: Text(item.name),
                subtitle: item.subtitle != null ? Text(item.subtitle!) : null,
                trailing: item.enabled
                    ? null
                    : const Icon(Icons.block, size: 18),
                // Incompatible items stay tappable so the reason can be shown.
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  item.onAdd();
                },
              ),
          ],
          ),
        ),
      ),
    );
  }

  /// Installs an on-demand apt service (Grafana, InfluxDB, Mosquitto), then
  /// re-detects so the new card appears.
  // The evcc "monitoring stack": time-series DB + dashboards + MQTT broker.
  static const _stackIds = ['influxdb', 'grafana', 'mosquitto'];

  /// Guided one-flow install of the (still-missing) monitoring-stack services.
  Future<void> _guidedSetup() async {
    if (_busy) return;
    final l10n = context.l10n;
    final config = _prepare();
    if (config == null) return;
    // _prepare() set _busy; the install path re-acquires it via _guard, so
    // release it now — otherwise cancelling the picker deadlocks the whole UI.
    if (mounted) setState(() => _busy = false);
    final present = _services.where((s) => s.installed).map((s) => s.id).toSet();
    final stack = knownInstallableServices
        .where((s) => _stackIds.contains(s.id) && !present.contains(s.id))
        .toList();
    if (stack.isEmpty) {
      _snack(context.l10n.snackStackAlreadyInstalled);
      return;
    }
    final chosen = await _showGuidedSetupSheet(stack);
    if (chosen == null || chosen.isEmpty || !mounted) return;
    _lastAction = _guidedSetup;
    _beginBusy();
    await _guard(() async {
      for (final svc in chosen) {
        _appendLog(l10n.logInstalling(svc.name));
        await _updater.installAptService(
            config: config, service: svc, onLog: _appendLog);
      }
      if (!mounted) return;
      final names = chosen.map((s) => s.name).join(', ');
      setState(() {
        _statusMessage = context.l10n.statusStackInstalled(names);
        _statusOk = true;
      });
      _addHistory(context.l10n.historyStackInstalled(names));
      await _refreshServices(config);
    }, backgroundMessage: context.l10n.busyInstallingStack);
  }

  String _stackRole(String id) {
    switch (id) {
      case 'influxdb':
        return context.l10n.stackRoleInfluxdb;
      case 'grafana':
        return context.l10n.stackRoleGrafana;
      case 'mosquitto':
        return context.l10n.stackRoleMosquitto;
      default:
        return '';
    }
  }

  Future<List<AptService>?> _showGuidedSetupSheet(List<AptService> services) {
    final selected = services.map((s) => s.id).toSet();
    return showModalBottomSheet<List<AptService>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(ctx.l10n.energyMonitoringStack,
                    style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(ctx.l10n.guidedSetupDescription),
                const SizedBox(height: 12),
                for (final svc in services)
                  CheckboxListTile(
                    value: selected.contains(svc.id),
                    onChanged: (v) => setSheet(() =>
                        v == true ? selected.add(svc.id) : selected.remove(svc.id)),
                    title: Text(svc.name),
                    subtitle: Text(_stackRole(svc.id)),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                  ),
                const SizedBox(height: 8),
                Text(
                  ctx.l10n.guidedSetupNote,
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.download),
                    label: Text(ctx.l10n.actionInstall),
                    onPressed: selected.isEmpty
                        ? null
                        : () => Navigator.pop(
                            ctx,
                            services
                                .where((s) => selected.contains(s.id))
                                .toList()),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- Raspberry Pi Connect (official remote access) ----

  Future<void> _installPiConnect() async {
    if (_busy) return;
    final config = _prepare();
    if (config == null) return;
    _lastAction = _installPiConnect;
    await _guard(() async {
      await _updater.installPiConnect(config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = context.l10n.statusPiConnectInstalled;
        _statusOk = true;
      });
      _addHistory(context.l10n.historyPiConnectInstalled);
      await _refreshServices(config);
    }, backgroundMessage: context.l10n.busyInstallingPiConnect);
  }

  Future<void> _piConnectSignin() async {
    if (_busy) return;
    final config = _prepare();
    if (config == null) return;
    _lastAction = _piConnectSignin;
    String? url;
    await _guard(() async {
      url = await _updater.piConnectSignin(config: config, onLog: _appendLog);
    }, backgroundMessage: context.l10n.busyStartingSignin);
    if (!mounted) return;
    if (url == null) {
      _snack(context.l10n.snackNoSigninLink);
      return;
    }
    await _openUrl(url!);
    if (mounted) {
      _snack(context.l10n.snackPiConnectSignin);
    }
  }

  Future<void> _piConnectSet(bool on) async {
    if (_busy) return;
    final config = _prepare();
    if (config == null) return;
    _lastAction = () => _piConnectSet(on);
    await _guard(() async {
      await _updater.piConnectSet(config: config, on: on, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = on
            ? context.l10n.statusPiConnectEnabled
            : context.l10n.statusPiConnectDisabled;
        _statusOk = true;
      });
      await _refreshServices(config);
    },
        backgroundMessage: on
            ? context.l10n.busyEnablingPiConnect
            : context.l10n.busyDisablingPiConnect);
  }

  Future<void> _piConnectSignout() async {
    if (_busy) return;
    final l10n = context.l10n;
    if (!await _confirm(context.l10n.dialogSignOutTitle,
        context.l10n.dialogSignOutPiConnectBody)) {
      return;
    }
    final config = _prepare();
    if (config == null) return;
    _lastAction = _piConnectSignout;
    await _guard(() async {
      await _updater.piConnectSignout(config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = context.l10n.statusPiConnectSignedOut;
        _statusOk = true;
      });
      await _refreshServices(config);
    }, backgroundMessage: l10n.busySigningOut);
  }

  // ---- Tailscale (VPN/mesh) ----

  Future<void> _installTailscale() async {
    if (_busy) return;
    final config = _prepare();
    if (config == null) return;
    _lastAction = _installTailscale;
    await _guard(() async {
      await _updater.installTailscale(config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = context.l10n.statusTailscaleInstalled;
        _statusOk = true;
      });
      _addHistory(context.l10n.historyTailscaleInstalled);
      await _refreshServices(config);
    }, backgroundMessage: context.l10n.busyInstallingTailscale);
  }

  /// Phase 1 of the remote-access setup: get Tailscale onto the Pi and signed
  /// in. When `tailscale up` returns a login URL the user has to confirm it in
  /// a browser, so the phase ends there; an already-authenticated node skips
  /// straight to the check.
  Future<void> _setupRemoteAccess() async {
    if (_busy) return;
    final l10n = context.l10n;
    final config = _prepare();
    if (config == null) return;
    _lastAction = _setupRemoteAccess;
    String? url;
    await _guard(() async {
      final installed =
          _services.any((s) => s.id == 'tailscale' && s.installed);
      if (!installed) {
        await _updater.installTailscale(config: config, onLog: _appendLog);
      }
      url = await _updater.tailscaleUp(config: config, onLog: _appendLog);
    }, backgroundMessage: l10n.busySettingUpRemoteAccess);
    if (!mounted || !_statusOk) return;
    if (url == null) {
      await _checkRemoteAccess(); // already signed in — no browser detour
      return;
    }
    setState(() => _remoteAccessPhase = _RemoteAccessPhase.awaitingBrowser);
    await _openUrl(url!);
  }

  /// Phase 2: read the tailnet IP — and PROVE this phone reaches it. Without
  /// that proof the user would believe they are done and only find out on the
  /// road, where nothing can be fixed.
  Future<void> _checkRemoteAccess() async {
    if (_busy) return;
    final l10n = context.l10n;
    final config = _prepare();
    if (config == null) return;
    _lastAction = _checkRemoteAccess;
    await _guard(() async {
      final services =
          await _updater.detectServices(config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _services = services;
        _rememberTailscaleIp(services);
      });
      if (_tailscaleIp.isEmpty) {
        // Sign-in not finished yet — stay on "confirm in the browser".
        setState(() => _remoteAccessPhase = _RemoteAccessPhase.awaitingBrowser);
        return;
      }
      final reachable = await _updater.probeConnection(
        config: config.copyWith(
            host: _tailscaleIp, timeout: const Duration(seconds: 8)),
        onLog: _appendLog,
      );
      if (!mounted) return;
      setState(() {
        _remoteAccessPhase = reachable
            ? _RemoteAccessPhase.done
            : _RemoteAccessPhase.phoneMissing;
        if (reachable) {
          _remoteAccessProven = true;
          _statusMessage = context.l10n.statusRemoteAccessReady(_tailscaleIp);
          _statusOk = true;
        }
      });
      if (reachable) _scheduleSave();
    }, backgroundMessage: l10n.busySettingUpRemoteAccess);
  }

  Future<void> _tailscaleUp() async {
    if (_busy) return;
    final config = _prepare();
    if (config == null) return;
    _lastAction = _tailscaleUp;
    String? url;
    await _guard(() async {
      url = await _updater.tailscaleUp(config: config, onLog: _appendLog);
    }, backgroundMessage: context.l10n.busyConnectingTailscale);
    if (!mounted) return;
    if (url != null) {
      await _openUrl(url!);
      if (mounted) {
        _snack(context.l10n.snackTailscaleSignin);
      }
    } else {
      // Already authenticated → just re-detect to show the new state.
      await _refreshServices(config);
      if (mounted) _snack(context.l10n.snackTailscaleConnected);
    }
  }

  Future<void> _tailscaleSet({required bool logout}) async {
    if (_busy) return;
    final l10n = context.l10n;
    if (logout &&
        !await _confirm(context.l10n.dialogSignOutTitle,
            context.l10n.dialogSignOutTailscaleBody)) {
      return;
    }
    final config = _prepare();
    if (config == null) return;
    _lastAction = () => _tailscaleSet(logout: logout);
    await _guard(() async {
      await _updater.tailscaleSet(
          config: config, logout: logout, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = logout
            ? context.l10n.statusTailscaleSignedOut
            : context.l10n.statusTailscaleDisconnected;
        _statusOk = true;
      });
      await _refreshServices(config);
    },
        backgroundMessage: logout
            ? l10n.busyTailscaleSigningOut
            : l10n.busyTailscaleDisconnecting);
  }

  /// Puts the Pi's tailnet IP into the host field (the bonus: connect from
  /// anywhere without hunting for the 100.x address).
  void _useTailscaleIp(String ip) {
    setState(() {
      _host.text = ip;
      _tab = kTabVerwaltung;
      _connExpanded = true; // show the changed host so it's not silently swapped
    });
    _scheduleSave();
    _snack(context.l10n.snackHostSetConnect(ip));
  }

  /// The undo for the Tailscale switch: puts the remembered home/LAN address
  /// back into the host field (used when you're back on the local network).
  void _useHomeHost() {
    if (_lanHost.isEmpty) return;
    setState(() {
      _host.text = _lanHost;
      _tab = kTabVerwaltung;
      _connExpanded = true; // show the changed host so it's not silently swapped
    });
    _scheduleSave();
    _snack(context.l10n.snackHostResetConnect(_lanHost));
  }

  /// One-tap remote access: pre-fills the Pi's tailnet IP as host, then opens the
  /// Tailscale app so the user can enable the phone-side VPN (Android won't let
  /// us toggle it ourselves). Play Store fallback if Tailscale isn't installed.
  Future<void> _remoteAccessViaTailscale(String tailnetIp) async {
    final hasIp = tailnetIp.trim().isNotEmpty;
    if (hasIp) {
      setState(() {
        _host.text = tailnetIp.trim();
        _tab = kTabVerwaltung;
        _connExpanded = true; // show the changed host so it's not silently swapped
      });
      _scheduleSave();
    }
    final opened = await _appLauncher.openApp(
      'com.tailscale.ipn',
      fallbackUrl:
          'https://play.google.com/store/apps/details?id=com.tailscale.ipn',
    );
    if (!mounted) return;
    _snack(!opened
        ? context.l10n.snackTailscaleNotInstalled
        : hasIp
            ? context.l10n.snackTailscaleOpenedWithHost(tailnetIp)
            : context.l10n.snackTailscaleOpenedTip);
  }

  Future<void> _installAptService(AptService service) async {
    if (_busy) return;
    final config = _prepare();
    if (config == null) return;
    _lastAction = () => _installAptService(service);
    await _guard(() async {
      await _updater.installAptService(
          config: config, service: service, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = context.l10n.statusServiceInstalled(service.name);
        _statusOk = true;
      });
      _addHistory(context.l10n.statusServiceInstalled(service.name));
      await _refreshServices(config);
    }, backgroundMessage: context.l10n.busyInstallingService(service.name));
  }

  /// Icon for an installable service (matches the card icons).
  IconData _serviceIcon(String id) {
    switch (id) {
      case 'grafana':
        return Icons.insights;
      case 'influxdb':
        return Icons.storage;
      case 'mosquitto':
        return Icons.sensors;
      case 'adguard':
        return Icons.shield_outlined;
      case 'nodered':
        return Icons.hub_outlined;
      case 'zigbee2mqtt':
        return Icons.settings_input_antenna;
      default:
        return Icons.apps;
    }
  }

  /// Restarts a detected systemd service (AdGuard Home, Node-RED, Zigbee2MQTT).
  Future<void> _restartSystemdService(ServiceStatus s) async {
    if (_busy) return;
    SystemdService? svc;
    for (final x in knownSystemdServices) {
      if (x.id == s.id) svc = x;
    }
    if (svc == null) return;
    final unit = svc.unit;
    final config = _prepare();
    if (config == null) return;
    _lastAction = () => _restartSystemdService(s);
    await _guard(() async {
      await _updater.restartSystemdUnit(
          config: config, unit: unit, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = context.l10n.statusServiceRestarted(s.name);
        _statusOk = true;
      });
      _addHistory(context.l10n.statusServiceRestarted(s.name));
      await _refreshServices(config);
    }, backgroundMessage: context.l10n.busyRestartingService(s.name));
  }

  /// Update a generic apt service card (Grafana, InfluxDB, …).
  Future<void> _updateAptService(ServiceStatus s) async {
    if (_busy) return;
    final config = _prepare();
    if (config == null) return;
    _lastAction = () => _updateAptService(s);
    await _guard(() async {
      await _updater.updateAptPackage(
          config: config, package: s.aptPackage ?? s.id, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = context.l10n.statusServiceUpdated(s.name);
        _statusOk = true;
      });
      _addHistory(context.l10n.statusServiceUpdated(s.name));
      await _refreshServices(config);
    }, backgroundMessage: context.l10n.busyUpdatingService(s.name));
  }

  void _openServiceWeb(int port) {
    if (_host.text.trim().isEmpty) {
      _snack(context.l10n.snackEnterHostFirst);
      return;
    }
    _openUrl('http://${_host.text.trim()}:$port');
  }

  // ---- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Until settings load we don't yet know if app-lock is on — show a neutral
    // brand splash rather than flashing the unlocked shell for a few frames.
    if (_booting) {
      return const Scaffold(
        backgroundColor: kBlack,
        body: Center(child: _PromptMark(size: 64)),
      );
    }
    if (_locked) return _LockScreen(onUnlock: _tryUnlock);
    // First run: require accepting the disclaimer before anything else.
    if (!_disclaimerAccepted) {
      return _DisclaimerScreen(
        onAccept: _acceptDisclaimer,
        onDecline: () => SystemNavigator.pop(),
        onPrivacy: () => _openUrl(kPrivacyUrl),
      );
    }
    // App shell is about to show → check for a "What's New" popup once.
    if (!_whatsNewChecked) {
      _whatsNewChecked = true;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _maybeShowWhatsNew());
    }

    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PromptMark(size: 22, chevronColor: theme.colorScheme.onSurface),
            const SizedBox(width: 8),
            Text('Pi-Tool',
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                    color: theme.colorScheme.primary)),
          ],
        ),
        // The active Pi, always visible on every tab + a tap to switch/manage.
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(38),
          child: InkWell(
            key: const Key('profileSwitcher'),
            onTap: _busy ? null : _showProfileSwitcher,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 12, 8),
              child: Row(
                children: [
                  Icon(Icons.dns_outlined,
                      size: 16, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(_activeProfileName,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 13)),
                  ),
                  if (_connected)
                    const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Icon(Icons.check_circle,
                          key: Key('sessionConnected'),
                          size: 14,
                          color: Colors.green),
                    ),
                  Icon(Icons.arrow_drop_down,
                      size: 22, color: theme.colorScheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'api':
                  _showApiStatus();
                case 'reboot':
                  _reboot();
                case 'shutdown':
                  _shutdown();
                case 'setup':
                  _openSetupGuide();
                case 'remote':
                  _remoteAccessViaTailscale(_tailscaleIp);
                case 'homeip':
                  _useHomeHost();
                case 'find':
                  _findPi();
                case 'dashboard':
                  _proGate(_showMultiPiDashboard);
                case 'share':
                  _shareLog();
                case 'history':
                  _showHistory();
                case 'checkUpdate':
                  _checkUpdatesNow();
                case 'changelog':
                  _openUrl(kReleasesUrl);
                case 'settings':
                  _openSettings();
              }
            },
            // Read-only / local items stay usable during an action; only the
            // SSH-mutating items (reboot/find) are disabled while busy.
            itemBuilder: (_) => [
              PopupMenuItem(
                  value: 'api', child: Text(context.l10n.menuApiStatus)),
              // The two SSH-mutating Pi actions follow the session model: like
              // the tabs they need an explicit connection first (greyed with a
              // hint until then, same pattern as the remote-access item below).
              PopupMenuItem(
                  value: 'reboot',
                  enabled: !_busy && _connected,
                  child: _connected
                      ? Text(context.l10n.actionRebootPi)
                      : _menuChildNeedsConnection(
                          theme, context.l10n.actionRebootPi)),
              PopupMenuItem(
                  value: 'shutdown',
                  enabled: !_busy && _connected,
                  child: _connected
                      ? Text(context.l10n.actionShutdownPi,
                          style: TextStyle(color: theme.colorScheme.error))
                      : _menuChildNeedsConnection(
                          theme, context.l10n.actionShutdownPi)),
              const PopupMenuDivider(),
              PopupMenuItem(
                  value: 'setup', child: Text(context.l10n.menuSetupPi)),
              // SSH-Key setup is per-Pi, not global: it lives inline in the
              // connection form (tap the SSH-Key segment), not in this menu.
              // Always listed so the feature is discoverable and the menu stays
              // predictable; reachable even when NOT connected (the whole point
              // of remote access). Disabled with a hint until the app has learned
              // this Pi's Tailscale IP (one connection at home populates it).
              PopupMenuItem(
                  value: 'remote',
                  enabled: _tailscaleIp.isNotEmpty,
                  child: _tailscaleIp.isNotEmpty
                      ? Text(context.l10n.menuRemoteAccess)
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(context.l10n.menuRemoteAccess),
                            Text(
                              context.l10n.menuRemoteAccessHint,
                              style: TextStyle(
                                  fontSize: 11,
                                  color: theme.colorScheme.onSurfaceVariant),
                            ),
                          ],
                        )),
              // The undo for the switch above: once the host is a tailnet
              // address, offer a one-tap way back to the remembered home/LAN
              // address (e.g. when you're back on the local network).
              if (_lanHost.isNotEmpty && isTailnetHost(_host.text.trim()))
                PopupMenuItem(
                    value: 'homeip',
                    child: Text(context.l10n.menuBackToHomeIp(_lanHost))),
              PopupMenuItem(
                  value: 'find',
                  enabled: !_busy,
                  child: Text(context.l10n.menuFindPi)),
              if (_profiles.length > 1)
                PopupMenuItem(
                    value: 'dashboard',
                    enabled: !_busy,
                    child: Text(context.l10n.menuAllPis)),
              PopupMenuItem(
                  value: 'share', child: Text(context.l10n.menuShareLog)),
              PopupMenuItem(
                  value: 'history', child: Text(context.l10n.historyTitle)),
              const PopupMenuDivider(),
              PopupMenuItem(
                  value: 'checkUpdate', child: Text(context.l10n.menuCheckUpdate)),
              const PopupMenuItem(value: 'changelog', child: Text('Changelog')),
              PopupMenuItem(
                  value: 'settings', child: Text(context.l10n.settingsTitle)),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Shared action bar above ALL tabs: a running action, host-key
            // recovery and the status banner used to live only on the Dienste
            // tab, but actions launch from every tab — so surface them globally.
            // Keyed on _busyMessage (set inside _guard for a named operation) so
            // it shows for real SSH work, not while a confirm dialog is open.
            if (_demoMode) _demoBar(theme),
            if (_busyMessage != null) _runningBar(theme),
            if (!_busy && _hostKeyIssue) _hostKeyBar(theme),
            if (_statusMessage != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: _StatusBanner(message: _statusMessage!, ok: _statusOk),
              ),
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: [
                  // ---- Tab 0: Dienste ----
                  ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // App-Update-Hinweis immer ganz oben.
            if (_update != null) ...[
              _UpdateBanner(
                release: _update!,
                onDownload: () => _openUrl(_update!.downloadUrl),
                onDismiss: () => setState(() => _update = null),
              ),
              const SizedBox(height: 8),
            ],
            // Profile management moved to the app-bar switcher (visible on every
            // tab). The Dienste tab goes straight to the connection settings.
            _ConnectionCard(
              host: _host,
              port: _port,
              user: _user,
              password: _password,
              privateKey: _privateKey,
              keyPassphrase: _keyPassphrase,
              authMode: _authMode,
              obscure: _obscure,
              enabled: !_busy,
              onToggleObscure: () => setState(() => _obscure = !_obscure),
              onAuthMode: (m) {
                setState(() => _authMode = m);
                _scheduleSave();
              },
              onSetupKey: _setupSshKey,
              expanded: _connExpanded,
              onToggleExpanded: () =>
                  setState(() => _connExpanded = !_connExpanded),
            ),
            const SizedBox(height: 8),
            // Connect. The cancel affordance lives in the shared running bar
            // above the tabs now (an action can be started from any tab).
            _TestButton(
              testing: _testing,
              result: _connectionOk,
              enabled: !_busy,
              onTap: _testConnection,
            ),
            // No usable Pi yet → offer the demo, the network scan and the setup
            // guide. Hidden once the profile is REALLY set up (`_credsComplete`:
            // host + the secret the auth mode needs) or a session is live, so it
            // never clutters a returning user's screen — nor the demo view.
            //
            // Deliberately NOT "host field non-empty": tapping a device in the
            // Wi-Fi-search sheet fills only the host, and that used to make the
            // demo entry vanish mid-flow. That is the dead end Google's reviewer
            // hit — their screenshot shows "Host set to 192.168.97.1" and no way
            // into the app left. Rebuilds live on host/password/key edits.
            AnimatedBuilder(
              animation: Listenable.merge([_host, _password, _privateKey]),
              builder: (context, _) {
                if (_connected || _credsComplete()) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Column(
                    children: [
                      // FIRST and a real button, not fine print: without a Pi
                      // this is the only way into the app — for a curious user
                      // AND for the Play reviewer. v0.63.0 was rejected because
                      // v0.62.0 had demoted it to a quiet text link below two
                      // other entries: on the reviewer's small screen it sat
                      // under the fold and they never found it (LoginWall.png),
                      // so the connect form read as a login wall. Keep it above
                      // "Pi im WLAN suchen" and keep it looking tappable.
                      FilledButton.tonalIcon(
                        key: const Key('demoEntry'),
                        onPressed: _busy ? null : _startDemo,
                        icon: const Icon(Icons.play_circle_outline, size: 18),
                        label: Text(context.l10n.demoButton),
                        style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(44)),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 2, bottom: 2),
                        child: Text(
                          context.l10n.demoEntryHint,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _findPi,
                        icon: const Icon(Icons.wifi_find, size: 18),
                        label: Text(context.l10n.menuFindPi),
                        style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(44)),
                      ),
                      // Beginners without a ready Pi: link the Imager guide.
                      TextButton.icon(
                        onPressed: _openSetupGuide,
                        icon: const Icon(Icons.menu_book_outlined, size: 18),
                        label: Text(context.l10n.noPiYetSetup),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            ..._serviceCards(),
            if (_setupUrl != null) ...[
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: () => _openUrl(_setupUrl!),
                icon: const Icon(Icons.open_in_new),
                label: Text(context.l10n.openEvccSetup),
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
              ),
            ],
                    // Legal / Version am Ende der Kartenliste — scrollt mit dem
                    // Inhalt mit, statt fix Platz vom Hauptbereich zu nehmen.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(0, 8, 0, 2),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Divider(height: 1),
                          const SizedBox(height: 8),
                          Text(
                            context.l10n.disclaimerFooter,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            context.l10n.unofficialFooter,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.7)),
                          ),
                          const SizedBox(height: 6),
                          InkWell(
                            onTap: () => _openUrl(kKythUrl),
                            child: Text.rich(
                              TextSpan(
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color:
                                        theme.colorScheme.onSurfaceVariant),
                                children: [
                                  TextSpan(
                                      text: _appVersion.isEmpty
                                          ? 'by '
                                          : 'Pi-Tool v$_appVersion · by '),
                                  WidgetSpan(
                                    alignment: PlaceholderAlignment.middle,
                                    child: KythWordmark(
                                        fontSize: 12,
                                        product: 'Systems',
                                        color: theme
                                            .colorScheme.onSurfaceVariant),
                                  ),
                                ],
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                          Wrap(
                            alignment: WrapAlignment.center,
                            children: [
                              _legalLink(context.l10n.legalTerms,
                                  () => _openUrl(kAgbUrl)),
                              _legalLink(context.l10n.legalPrivacy,
                                  () => _openUrl(kPrivacyUrl)),
                              _legalLink(context.l10n.legalImprint,
                                  () => _openUrl(kImpressumUrl)),
                              _legalLink(
                                  context.l10n.legalLicenses, _showLicenses),
                              // Ratings are what Play actually ranks on. Here in
                              // the footer, deliberately not in the ⋮ menu —
                              // that one is full, and an extra entry pushed
                              // others out of view (26.07.2026, 15 red tests).
                              _legalLink(context.l10n.legalRateApp,
                                  () => _openUrl(kPlayStoreUrl)),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                  ),
                  // ---- Tab 1: Automatik ----
                  _automatikTab(theme),
                  // ---- Tab 2: Terminal ----
                  _terminalTab(theme),
                  // ---- Tab 3: Dateien ----
                  _dateienTab(theme),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) {
          // Gated tabs (Automatik/Terminal/Dateien) stay locked until an
          // explicit connection exists — tapping one just hints, no switch.
          if (!tabAllowed(i, connected: _connected)) {
            _snack(context.l10n.snackConnectFirst);
            return;
          }
          setState(() {
            _tab = i;
            // Don't carry a stale result banner (e.g. "Verbindung OK") onto
            // another tab — file ops don't run through _guard, so it would
            // otherwise stick on the Dateien/Terminal tabs.
            _statusMessage = null;
          });
        },
        destinations: [
          NavigationDestination(
              icon: const Icon(Icons.tune_outlined),
              selectedIcon: const Icon(Icons.tune),
              label: context.l10n.tabManagement),
          _navDest(kTabAutomatik, Icons.bolt_outlined, Icons.bolt,
              context.l10n.tabAutomation),
          _navDest(kTabTerminal, Icons.terminal_outlined, Icons.terminal,
              context.l10n.tabTerminal),
          _navDest(kTabDateien, Icons.folder_outlined, Icons.folder,
              context.l10n.tabFiles),
        ],
      ),
    );
  }

  /// A bottom-nav destination that greys out + shows a small lock while the
  /// session gate blocks it (Automatik/Terminal/Dateien until connected). Kept
  /// as a NavigationDestination so the label stays findable; the icon is
  /// wrapped, so `find.byIcon(...)` still resolves it.
  NavigationDestination _navDest(
      int index, IconData icon, IconData selected, String label) {
    final locked = !tabAllowed(index, connected: _connected);
    Widget wrap(Widget child) => locked
        ? Opacity(
            opacity: 0.38,
            child: Stack(clipBehavior: Clip.none, children: [
              child,
              const Positioned(
                  right: -6, top: -4, child: Icon(Icons.lock, size: 11)),
            ]),
          )
        : child;
    return NavigationDestination(
      icon: wrap(Icon(icon)),
      selectedIcon: wrap(Icon(selected)),
      label: label,
    );
  }

  /// Menu-item body for an SSH action that is locked until connected: the
  /// label plus a small "connect first" hint (same look as the remote-access
  /// item's hint).
  Widget _menuChildNeedsConnection(ThemeData theme, String label) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          Text(
            context.l10n.menuNeedsConnectionHint,
            style: TextStyle(
                fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      );

  // ---- Automatik tab: cross-cutting automation (updates, alerts) ----

  Widget _automatikTab(ThemeData theme) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(context.l10n.tabAutomation, style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            context.l10n.automationDescription,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          _AutomationTile(
            icon: Icons.update,
            title: context.l10n.autoUpdatesTitle,
            subtitle: context.l10n.autoUpdatesTileSubtitle,
            locked: !_unlocked,
            onTap: () => _proGate(_configureAutoUpdate),
          ),
          _AutomationTile(
            icon: Icons.backup_outlined,
            title: context.l10n.scheduledBackupsTitle,
            subtitle: context.l10n.scheduledBackupsTileSubtitle,
            locked: !_unlocked,
            onTap: () => _proGate(_configureScheduledBackup),
          ),
          _AutomationTile(
            icon: Icons.notifications_active_outlined,
            title: context.l10n.healthAlertsTitle,
            subtitle: context.l10n.healthAlertsTileSubtitle,
            locked: !_unlocked,
            // The topic is the only protection on ntfy (no account, no auth), so
            // flag a guessable one here too — someone who set alerts up once may
            // never open the sheet again.
            warning: isWeakNtfyTopic(_alertsTopic)
                ? context.l10n.alertsWeakTopicCardHint
                : null,
            onTap: () => _proGate(_configureAlerts),
          ),
        ],
      );

  // ---- Terminal tab: console (later: logs, files) ----

  Widget _terminalTab(ThemeData theme) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(context.l10n.tabTerminal, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          _LogView(lines: _log, controller: _logScroll),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('consoleField'),
                  controller: _consoleInput,
                  enabled: !_busy,
                  textInputAction: TextInputAction.send,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  onSubmitted: _busy ? null : (v) => _runConsoleCommand(v),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixText: '\$ ',
                    hintText: context.l10n.consoleHint,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                onPressed: _busy ? null : _showConsoleHistory,
                icon: const Icon(Icons.history),
                tooltip: context.l10n.tooltipHistoryQuickCommands,
              ),
              const SizedBox(width: 4),
              IconButton.filledTonal(
                onPressed:
                    _busy ? null : () => _runConsoleCommand(_consoleInput.text),
                // Lock hint for free users (Konsole is Pro; the tap opens the
                // paywall via _runConsoleCommand's gate).
                icon: Icon(_unlocked ? Icons.keyboard_return : Icons.lock_outline),
                tooltip: _unlocked
                    ? context.l10n.tooltipSendCommand
                    : context.l10n.tooltipProFeature,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            context.l10n.terminalFooter,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      );

  // ---- Dateien tab: browse / preview / upload / delete on the Pi ----

  Widget _dateienTab(ThemeData theme) {
    if (!_unlocked) {
      return _filesPlaceholder(
        theme,
        icon: Icons.lock_outline,
        title: context.l10n.filesExplorerProTitle,
        body: context.l10n.filesExplorerProBody,
        actionLabel: context.l10n.unlockPro,
        onAction: _showPaywall,
      );
    }
    if (_filesConfig() == null) {
      return _filesPlaceholder(
        theme,
        icon: Icons.dns_outlined,
        title: context.l10n.filesNoPiTitle,
        body: context.l10n.filesNoPiBody,
      );
    }
    return _FilesView(
      // Rebuild (→ re-list) when the target Pi changes, so a profile switch or
      // host edit can't leave the previous Pi's listing + _path in place (which
      // would make the next upload/delete hit the new Pi at the old path).
      key: ValueKey('$_activeIndex:${_host.text.trim()}:${_port.text.trim()}'),
      startPath: '/home',
      onList: _filesList,
      onOpenFile: _filesOpen,
      onUpload: _filesUpload,
      onDelete: _filesDelete,
    );
  }

  Widget _filesPlaceholder(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String body,
    String? actionLabel,
    VoidCallback? onAction,
  }) =>
      Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 44, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(title, style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(body,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 16),
                FilledButton(onPressed: onAction, child: Text(actionLabel)),
              ],
            ],
          ),
        ),
      );
}

