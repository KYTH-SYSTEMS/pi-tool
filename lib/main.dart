import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'src/authenticator.dart';
import 'src/alerts.dart';
import 'src/auto_update.dart';
import 'src/commands.dart';
import 'src/entitlement.dart';
import 'src/file_pick.dart';
import 'src/files.dart';
import 'src/kyth_splash.dart';
import 'src/whats_new.dart';
import 'src/evcc_api.dart';
import 'src/evcc_updater.dart';
import 'src/history.dart';
import 'src/keep_alive.dart';
import 'src/network_scan.dart';
import 'src/parsing.dart';
import 'src/profiles.dart';
import 'src/services/apt_services.dart';
import 'src/services/pi_service.dart';
import 'src/settings_store.dart';
import 'src/ssh_runner.dart';
import 'src/update_check.dart';

part 'src/ui_widgets.dart';

void main() {
  runApp(const EvccPiToolApp());
}

/// Clean minimal dark: near-black canvas, a single vivid green accent.
const kGreen = Color(0xFF1FD65F);
const kBlack = Color(0xFF0B0E0C);
const kCard = Color(0xFF161A17);

const kEvccPlayStoreUrl =
    'https://play.google.com/store/apps/details?id=io.evcc.android';
const kPrivacyUrl = 'https://profex1337.github.io/evcc-pi-tool/privacy.html';
const kImpressumUrl = 'https://profex1337.github.io/evcc-pi-tool/impressum.html';
const kReleasesUrl = 'https://github.com/profex1337/evcc-pi-tool/releases';
const kImagerUrl = 'https://www.raspberrypi.com/software/';

/// Drives MaterialApp.themeMode; updated from the loaded setting + the picker.
final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier<ThemeMode>(ThemeMode.system);

ThemeMode parseThemeMode(String s) => switch (s) {
      'dark' => ThemeMode.dark,
      'light' => ThemeMode.light,
      _ => ThemeMode.system,
    };

ThemeData _buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = dark
      ? ColorScheme.fromSeed(seedColor: kGreen, brightness: Brightness.dark)
          .copyWith(primary: kGreen, onPrimary: Colors.black, surface: kBlack)
      : ColorScheme.fromSeed(seedColor: kGreen, brightness: Brightness.light);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
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
      builder: (_, mode, _) => MaterialApp(
        title: 'Pi-Tool',
        debugShowCheckedModeBanner: false,
        themeMode: mode,
        theme: _buildTheme(Brightness.light),
        darkTheme: _buildTheme(Brightness.dark),
        home: const KythSplashGate(child: UpdaterPage()),
      ),
    );
  }
}

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

  @override
  State<UpdaterPage> createState() => _UpdaterPageState();
}

class _UpdaterPageState extends State<UpdaterPage>
    with WidgetsBindingObserver {
  late final AppConfigStore _store = widget.store ?? AppConfigStore();
  late final EvccUpdater _updater =
      widget.updater ?? EvccUpdater.real(confirmFirstUse: _confirmFirstHostKey);
  late final UpdateChecker _updateChecker =
      widget.updateChecker ?? UpdateChecker();
  late final Authenticator _authenticator =
      widget.authenticator ?? LocalAuthenticator();
  late final EvccApiClient _apiClient = widget.apiClient ?? EvccApiClient();
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
  bool _obscure = true;
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
  String _channel = 'stable';
  bool _backupBeforeUpdate = true;
  bool _disclaimerAccepted = false; // first-run terms accepted
  String _lastSeenVersion = ''; // for the "What's New" popup after an update
  bool _whatsNewChecked = false; // one-shot guard for the popup
  List<String> _consoleHistory = []; // recent console commands, newest first
  String _alertsServer = 'https://ntfy.sh'; // Health-Alerts ntfy destination
  String _alertsTopic = '';
  bool _isPro = true; // Pro entitlement (dormant default: everyone Pro)
  int _tab = 0; // 0 = Dienste, 1 = Automatik, 2 = Terminal
  String? _busyMessage; // shown in the shared running bar while _busy
  bool _testing = false; // a "Verbindung herstellen" run is in flight
  bool? _connectionOk; // null=untested, true=ok, false=failed (Test-Button color)
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
      _channel = cfg.channel;
      _backupBeforeUpdate = cfg.backupBeforeUpdate;
      _disclaimerAccepted = cfg.disclaimerAccepted;
      _lastSeenVersion = cfg.lastSeenVersion;
      _consoleHistory = List.of(cfg.consoleHistory);
      _alertsServer = cfg.alertsNtfyServer;
      _alertsTopic = cfg.alertsNtfyTopic;
      _applyProfile(cfg.active);
      if (_lockEnabled) _locked = true;
      _booting = false; // settings + lock state resolved → reveal the UI
    });
    themeModeNotifier.value = parseThemeMode(_themeMode);
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
    if (_connectionOk != null && mounted) {
      setState(() => _connectionOk = null);
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
  }

  /// Switching to another Pi: drop everything tied to the previous host so
  /// nothing from it leaks into the new Pi's view — detected services, the
  /// connection indicator, banners, the host-key "trust new key" prompt and the
  /// stashed trust-and-retry target ([_lastConfig]/[_lastAction]).
  void _resetDetectionForNewPi() {
    _services = [];
    _connectionOk = null;
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
      );

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
      channel: _channel,
      backupBeforeUpdate: _backupBeforeUpdate,
      disclaimerAccepted: _disclaimerAccepted,
      lastSeenVersion: _lastSeenVersion,
      consoleHistory: _consoleHistory,
      alertsNtfyServer: _alertsServer,
      alertsNtfyTopic: _alertsTopic,
    );
  }

  /// Records first-run acceptance of the disclaimer and persists it.
  void _acceptDisclaimer() {
    setState(() => _disclaimerAccepted = true);
    _persistSettings();
  }

  /// Runs [action] for Pro users; otherwise opens the paywall. The single gate
  /// every Pro feature routes through.
  void _proGate(VoidCallback action) {
    if (_isPro) {
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
              const Text('Einmalig freischalten – kein Abo:'),
              const SizedBox(height: 10),
              for (final f in const [
                'Backups sichern, wiederherstellen & verwalten',
                'Konsole – eigene Befehle auf dem Pi',
                'Mehrere Pis (Profile) verwalten',
                'Aufräumen – Speicher freigeben',
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
                  label: const Text('Pro freischalten – 5 €'),
                  onPressed: () async {
                    final ok = await _entitlement.buyPro();
                    if (!ctx.mounted) return;
                    Navigator.pop(ctx);
                    if (ok && mounted) {
                      setState(() => _isPro = true);
                      _snack('Pro freigeschaltet – danke!');
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
                          ? 'Pro wiederhergestellt.'
                          : 'Kein früherer Kauf gefunden.');
                    }
                  },
                  child: const Text('Käufe wiederherstellen'),
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
      final current = (await PackageInfo.fromPlatform()).version;
      if (current.isEmpty) return;
      final last = _lastSeenVersion;
      final notes = whatsNewFor(current);
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
        title: Text('Neu in v$version'),
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
            child: const Text("Los geht's"),
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
              title:
                  Text('Pi wählen', style: Theme.of(ctx).textTheme.titleMedium),
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
                      tooltip: 'Profil-Aktionen',
                      onSelected: (v) {
                        Navigator.pop(ctx);
                        if (v == 'rename') _renameProfile(i);
                        if (v == 'delete') _deleteProfile(i);
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                            value: 'rename', child: Text('Umbenennen')),
                        if (_profiles.length > 1)
                          const PopupMenuItem(
                              value: 'delete', child: Text('Löschen')),
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
              title: const Text('Profil hinzufügen'),
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
    if (isAddProfileLocked(isPro: _isPro, profileCount: _profiles.length)) {
      _showPaywall(); // multiple Pis are a Pro feature
      return;
    }
    final name = await _promptName('Neues Profil', '');
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
    final name = await _promptName('Profil umbenennen', _profiles[i].name);
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
      'Profil „$name" löschen?',
      'Entfernt das Profil samt gespeicherter Zugangsdaten und SSH-Key. '
          'Das kann nicht rückgängig gemacht werden.',
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

  Future<void> _checkForUpdate() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _appVersion = info.version);
      final release = await _updateChecker.checkForUpdate(info.version);
      if (release != null && mounted) setState(() => _update = release);
    } catch (_) {
      // never let the update check disrupt the app
    }
  }

  /// Manual "Auf Update prüfen": re-checks GitHub and reports the outcome (an
  /// update banner if newer, else a snackbar). Fail-soft — a failed check just
  /// says so.
  Future<void> _checkUpdatesNow() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final release = await _updateChecker.checkForUpdate(info.version);
      if (!mounted) return;
      setState(() {
        _appVersion = info.version;
        if (release != null) _update = release;
      });
      _snack(release != null
          ? 'Update verfügbar: ${release.version}'
          : 'Aktuell – du hast die neueste Version (v${info.version}).');
    } catch (_) {
      if (mounted) {
        _snack('Update-Prüfung fehlgeschlagen – später erneut versuchen.');
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
      final ok = await _authenticator.authenticate('Pi-Tool entsperren');
      if (ok && mounted) setState(() => _locked = false);
    } finally {
      _unlocking = false;
    }
  }

  // ---- actions -------------------------------------------------------------

  int? _validatedPort() {
    if (_host.text.trim().isEmpty) {
      _snack('Bitte Host/IP eintragen.');
      return null;
    }
    if (_authMode == AuthMode.password && _password.text.isEmpty) {
      _snack('Bitte Pi-Passwort eintragen.');
      return null;
    }
    if (_authMode == AuthMode.key && _privateKey.text.trim().isEmpty) {
      _snack('Bitte privaten SSH-Key einfügen.');
      return null;
    }
    final port = int.tryParse(_port.text.trim());
    if (port == null || port <= 0 || port > 65535) {
      _snack('Port ist ungültig (1–65535).');
      return null;
    }
    return port;
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
    if (backgroundMessage != null) {
      await _keepAlive.begin(backgroundMessage);
      if (mounted) setState(() => _busyMessage = backgroundMessage);
    }
    try {
      await body();
    } on EvccUpdateException catch (e) {
      final cancelled = e.kind == UpdateErrorKind.cancelled;
      _appendLog(cancelled ? 'Abgebrochen.' : 'FEHLER: ${e.message}');
      if (!mounted) return;
      setState(() {
        _statusMessage = e.message;
        _statusOk = false;
        _hostKeyIssue = e.kind == UpdateErrorKind.hostKeyChanged;
      });
    } catch (e) {
      _appendLog('FEHLER: $e'); // _appendLog redacts the password
      if (!mounted) return;
      setState(() {
        // Keep the raw exception in the (redacted) log, not in the headline.
        _statusMessage = 'Unerwarteter Fehler – Details im Terminal-Log.';
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
    // Before a real update, show evcc's latest release notes (fail-soft). Mark
    // busy during the fetch/confirm so all action buttons disable — otherwise
    // the network await opens a window for double-taps / concurrent SSH ops.
    if (!dryRun) {
      setState(() => _busy = true);
      final rel = await _fetchEvccRelease();
      if (!mounted) return;
      // Always warn when full-upgrade is on (it touches ALL packages, not just
      // evcc) — even if the release-notes fetch failed.
      final warn = _fullUpgrade
          ? 'Achtung: „Komplettes System-Upgrade" aktualisiert ALLE '
              'System-Pakete auf dem Pi, nicht nur evcc.'
          : '';
      final notes = rel != null ? _notesExcerpt(rel.notes) : '';
      final body = [warn, notes].where((s) => s.isNotEmpty).join('\n\n');
      // Confirm whenever there's something to say (a warning or notes);
      // otherwise (plain evcc update, no notes) proceed silently as before.
      final proceed = body.isEmpty ||
          await _confirm(
            rel != null ? 'evcc ${rel.version} installieren?' : 'evcc aktualisieren?',
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
          throw const EvccUpdateException(
            UpdateErrorKind.packageMissing,
            'evcc wurde nicht gefunden – weder als apt-Paket noch als '
            'Docker-Container.',
          );
        case InstallKind.docker:
          if (dryRun) {
            if (!mounted) return;
            setState(() {
              _statusMessage =
                  'Probelauf für Docker-Installationen nicht verfügbar – evcc '
                  'läuft hier im Container "${detection.container!.name}".';
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
            _statusMessage =
                'evcc-Container aktualisiert (docker compose pull + up).';
            _statusOk = true;
          });
          _addHistory('evcc-Docker-Container aktualisiert.');
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
    }, backgroundMessage: dryRun ? null : 'evcc-Update läuft …');
  }

  Future<void> _testConnection() async {
    if (_busy) return;
    final config = _prepare();
    if (config == null) return;
    _lastAction = _testConnection;
    // Show the running bar + Abbrechen during connect, but WITHOUT a keep-alive
    // (connect is short); the finally in _guard clears _busyMessage.
    setState(() {
      _testing = true;
      _busyMessage = 'Verbinde …';
    });
    await _guard(() async {
      final detected = await _updater.detectServices(
        config: config,
        onLog: _appendLog,
        // Progressive: as soon as the SSH connection is up (before the service
        // probes run) show "Verbunden" so the wait feels shorter.
        onConnected: () {
          if (!mounted) return;
          setState(() {
            _statusMessage = 'Verbunden – erkenne Dienste …';
            _statusOk = true;
          });
        },
      );
      final services = await _reconcileEvcc(detected);
      if (!mounted) return;
      setState(() {
        _services = services;
        final found =
            services.where((s) => s.installed).map((s) => s.name).join(', ');
        _statusMessage = 'Verbindung OK – erkannt: $found.';
        _statusOk = true;
      });
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

  Future<void> _install() async {
    if (_busy) return;
    if (!await _confirm(
      'evcc installieren?',
      'Installiert evcc auf ${_host.text.trim()}: fügt das offizielle '
          'evcc-Repo hinzu, installiert das Paket und startet den Dienst.\n\n'
          'Experimentell: gegen eine frische Pi-Installation nicht vollständig '
          'getestet.',
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
        _statusMessage = 'evcc ${res.version} installiert, '
            'Dienst ${res.serviceActive ? 'aktiv' : 'inaktiv'}. '
            'Jetzt im Browser einrichten.';
        _statusOk = true;
        _setupUrl = _evccUiUrl();
      });
      _addHistory('evcc ${res.version} installiert.');
      await _refreshServices(config);
    }, backgroundMessage: 'evcc wird installiert …');
  }

  Future<void> _restartService() async {
    if (_busy) return;
    if (!await _confirm('evcc-Dienst neu starten?',
        'Laufende Ladevorgänge werden dabei kurz unterbrochen.')) {
      return;
    }
    final config = _prepare();
    if (config == null) return;
    _lastAction = _restartService;
    await _guard(() async {
      await _updater.restartService(config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = 'evcc-Dienst neu gestartet.';
        _statusOk = true;
      });
      _addHistory('evcc-Dienst neu gestartet.');
    });
  }

  Future<void> _reboot() async {
    if (_busy) return;
    if (!await _confirm(
      'Pi neu starten?',
      'Startet den Raspberry Pi neu. Die Verbindung bricht dabei kurz ab.',
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
        _statusMessage = 'Neustart ausgelöst – der Pi ist gleich kurz offline.';
        _statusOk = true;
      });
      _addHistory('Pi-Neustart ausgelöst.');
    });
  }

  /// Lists the evcc backups on the Pi, lets the user pick one, confirms, then
  /// restores it (stops evcc → extract → restart). Backups are made before apt
  /// updates (see the backup-before-update setting).
  Future<void> _restoreBackup() async {
    if (_busy) return;
    final config = _prepare();
    if (config == null) return;
    _lastAction = _restoreBackup; // before the first guard (trust-and-retry)
    List<String>? backups; // stays null if listing errored (surfaced by _guard)
    await _guard(() async {
      backups = await _updater.listBackups(config: config, onLog: _appendLog);
    });
    if (!mounted || backups == null) return;
    if (backups!.isEmpty) {
      _snack('Keine evcc-Backups auf dem Pi gefunden.');
      return;
    }
    final chosen = await _pickBackup(backups!);
    if (chosen == null || !mounted) return;
    if (!await _confirm(
      'Backup wiederherstellen?',
      'Überschreibt die aktuelle evcc-Konfiguration + Datenbank mit dem Stand '
          'vom ${_backupLabel(chosen)} und startet evcc neu.',
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
        _statusMessage = 'Backup wiederhergestellt (${_backupLabel(chosen)}).';
        _statusOk = true;
      });
      _addHistory('Backup wiederhergestellt: ${_backupLabel(chosen)}.');
      await _refreshServices(config);
    }, backgroundMessage: 'Backup wird wiederhergestellt …');
  }

  /// Human label for a backup archive path
  /// (.../evcc-backup-YYYYMMDD-HHMMSS.tar.gz → "DD.MM.YYYY HH:MM Uhr").
  String _backupLabel(String path) {
    final m = RegExp(r'(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})')
        .firstMatch(path);
    if (m == null) return path.split('/').last;
    return '${m[3]}.${m[2]}.${m[1]} ${m[4]}:${m[5]} Uhr';
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
              title: Text('Backup wiederherstellen',
                  style: Theme.of(ctx).textTheme.titleMedium),
              subtitle: const Text('Neuestes zuerst'),
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
      _snack('Keine $serviceName-Backups auf dem Pi gefunden.');
      return;
    }
    final choice = await _pickServiceBackup(serviceName, backups!);
    if (choice == null || !mounted) return;
    final (action, path) = choice;
    if (action == 'delete') {
      if (!await _confirm('Backup löschen?',
          'Löscht das $serviceName-Backup (${_backupLabel(path)}) endgültig '
          'vom Pi.')) {
        return;
      }
      _beginBusy();
      await _guard(() async {
        await _updater.deleteServiceBackup(
            config: config, path: path, onLog: _appendLog);
        if (!mounted) return;
        setState(() {
          _statusMessage = 'Backup gelöscht (${_backupLabel(path)}).';
          _statusOk = true;
        });
        _addHistory('$serviceName-Backup gelöscht (${_backupLabel(path)}).');
      }, backgroundMessage: 'Backup wird gelöscht …');
      return;
    }
    if (!await _confirm('Backup wiederherstellen?', restoreWarning)) return;
    _beginBusy();
    await _guard(() async {
      await restore(config, path);
      if (!mounted) return;
      setState(() {
        _statusMessage =
            '$serviceName wiederhergestellt (${_backupLabel(path)}).';
        _statusOk = true;
      });
      _addHistory('$serviceName-Backup wiederhergestellt.');
    }, backgroundMessage: '$serviceName wird wiederhergestellt …');
  }

  Future<void> _managePiholeBackups() => _manageServiceBackups(
        servicePrefix: 'pihole',
        serviceName: 'Pi-hole',
        restoreWarning:
            'Importiert das Teleporter-Backup und überschreibt die aktuelle '
            'Pi-hole-Konfiguration (Listen, Einstellungen). DNS wird kurz neu '
            'gestartet.',
        restore: (config, path) => _updater.restorePiholeBackup(
            config: config, path: path, onLog: _appendLog),
      );

  Future<void> _manageHomeAssistantBackups() => _manageServiceBackups(
        servicePrefix: 'homeassistant',
        serviceName: 'Home Assistant',
        restoreWarning:
            'Stoppt Home Assistant kurz, spielt das /config-Backup über die '
            'aktuelle Konfiguration ein und startet den Container wieder.',
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
              title: Text('$serviceName-Backups',
                  style: Theme.of(ctx).textTheme.titleMedium),
              subtitle:
                  const Text('Antippen = wiederherstellen · Neuestes zuerst'),
            ),
            for (final b in backups)
              ListTile(
                leading: const Icon(Icons.restore),
                title: Text(_backupLabel(b)),
                subtitle: Text(b,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 11)),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Backup löschen',
                  onPressed: () => Navigator.pop(ctx, ('delete', b)),
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
    if (!await _confirm(
      'Speicher freigeben?',
      'Räumt auf dem Pi auf: nicht mehr benötigte Pakete (apt autoremove + '
          'clean), ungenutzte Docker-Images und System-Journal älter als '
          '7 Tage. Deine Daten und laufenden Dienste bleiben unberührt.',
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
        _statusMessage = 'Aufgeräumt – ${_formatBytes(freed)} freigegeben.';
        _statusOk = true;
      });
      _addHistory('System aufgeräumt (${_formatBytes(freed)} freigegeben).');
      await _refreshServices(config);
    }, backgroundMessage: 'Speicher wird freigegeben …');
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
                  child: Text(_busyMessage ?? 'Vorgang läuft …',
                      style: theme.textTheme.bodyMedium,
                      overflow: TextOverflow.ellipsis),
                ),
                TextButton(
                  onPressed: () => setState(() => _tab = 2),
                  child: const Text('Log'),
                ),
                const SizedBox(width: 2),
                OutlinedButton.icon(
                  onPressed: _cancel,
                  icon: const Icon(Icons.close, size: 18),
                  label: const Text('Abbrechen'),
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
          label: const Text('Pi neu aufgesetzt → neuen Key vertrauen'),
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
      throw const EvccUpdateException(
          UpdateErrorKind.connection, 'Kein Pi verbunden.');
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
      _snack('Erst oben einen Pi verbinden.');
      return false;
    }
    PickedFile? picked;
    // The system picker backgrounds the app — hold off the auto-lock so the user
    // doesn't return from picking to the lock screen.
    _suppressLock = true;
    try {
      picked = await _filePicker.pick();
    } catch (_) {
      if (mounted) _snack('Dateiauswahl fehlgeschlagen.');
      return false;
    } finally {
      _suppressLock = false;
    }
    if (picked == null || !mounted) return false; // cancelled
    if (picked.bytes.length > kFileUploadLimit) {
      _snack('Datei zu groß (max ${kFileUploadLimit ~/ (1024 * 1024)} MB).');
      return false;
    }
    final target = joinRemotePath(dir, picked.name);
    try {
      _snack('Lädt „${picked.name}" hoch …');
      await _updater.uploadFile(
          config: c, path: target, bytes: picked.bytes, onLog: _appendLog);
      if (mounted) _snack('Hochgeladen: ${picked.name}');
    } catch (_) {
      if (mounted) _snack('Hochladen fehlgeschlagen (Rechte?).');
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
      '„${entry.name}" löschen?',
      entry.isDir
          ? 'Löscht den Ordner samt Inhalt. Das kann nicht rückgängig gemacht '
              'werden.'
          : 'Das kann nicht rückgängig gemacht werden.',
    )) {
      return false;
    }
    try {
      await _updater.deleteRemotePath(
          config: c,
          path: joinRemotePath(dir, entry.name),
          isDir: entry.isDir,
          onLog: _appendLog);
      if (mounted) _snack('Gelöscht: ${entry.name}');
      return true;
    } catch (_) {
      if (mounted) _snack('Löschen fehlgeschlagen (Rechte?).');
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
      await _showLogSheet('Datei: $name',
          text.length > 100000 ? '${text.substring(0, 100000)}\n…' : text);
    } catch (_) {
      if (mounted) _snack('Datei konnte nicht geladen werden.');
    }
  }

  // ---- config editor (read → edit → save with backup) ----

  Future<void> _editConfig(String path, String title) async {
    if (_busy) return;
    final config = _prepare();
    if (config == null) return;
    _lastAction = () => _editConfig(path, title);
    String? content;
    await _guard(() async {
      content =
          await _updater.readConfigFile(config: config, path: path, onLog: _appendLog);
    }, backgroundMessage: '$title wird geladen …');
    if (!mounted || content == null) return;
    final edited = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => _ConfigEditorPage(title: title, initial: content!),
      ),
    );
    if (edited == null || !mounted || edited == content) return; // cancel/no-op
    if (edited.trim().isEmpty) {
      _snack('Leerer Inhalt — nicht gespeichert (das würde $title zerstören).');
      return;
    }
    if (!await _confirm('Speichern?',
        'Überschreibt $path auf dem Pi (eine Sicherung wird vorher angelegt).')) {
      return;
    }
    _beginBusy();
    await _guard(() async {
      await _updater.saveConfigFile(
          config: config, path: path, content: edited, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = '$title gespeichert (Backup angelegt).';
        _statusOk = true;
      });
      _addHistory('$title bearbeitet.');
    }, backgroundMessage: '$title wird gespeichert …');
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
    }, backgroundMessage: 'Logs werden geladen …');
    if (!mounted || logs == null) return;
    await _showLogSheet('Logs: ${s.name}', logs!);
  }

  /// Scrollable read-only text sheet, reused for service logs and file preview.
  /// [header] is the full title (caller decides "Logs: …" vs "Datei: …").
  Future<void> _showLogSheet(String header, String logs) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.78,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(header,
                    style: Theme.of(ctx).textTheme.titleMedium),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  logs.trim().isEmpty ? 'Keine Ausgabe.' : logs,
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
        setState(() {
          _alertsServer = choice.server;
          _alertsTopic = choice.topic;
        });
        _persistSettings();
        await _updater.enableAlerts(
            config: config,
            ntfyServer: choice.server,
            ntfyTopic: choice.topic,
            onLog: _appendLog);
        if (!mounted) return;
        setState(() {
          _statusMessage = 'Health-Alerts aktiv (ntfy: ${choice.topic}).';
          _statusOk = true;
        });
        _addHistory('Health-Alerts eingerichtet (ntfy).');
      } else {
        await _updater.disableAlerts(config: config, onLog: _appendLog);
        if (!mounted) return;
        setState(() {
          _statusMessage = 'Health-Alerts deaktiviert.';
          _statusOk = true;
        });
        _addHistory('Health-Alerts deaktiviert.');
      }
    },
        backgroundMessage: choice.enable
            ? 'Richte Health-Alerts ein …'
            : 'Deaktiviere Health-Alerts …');
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
      _snack('Test-Benachrichtigung gesendet — prüf dein ntfy.');
    } catch (_) {
      if (!mounted) return;
      _snack('Test fehlgeschlagen (Details im Terminal-Log).');
    }
  }

  Future<({bool enable, String server, String topic})?> _showAlertsSheet(
      AlertsStatus status, SshConfig config) {
    final serverCtrl = TextEditingController(text: _alertsServer);
    final topicCtrl = TextEditingController(text: _alertsTopic);
    return showModalBottomSheet<({bool enable, String server, String topic})>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
        padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 4,
            bottom: 20 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Health-Alerts', style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text('Der Pi meldet sich per Push (via ntfy), wenn die Platte '
                'vollläuft, ein Dienst ausfällt, es zu heiß wird oder Updates '
                'anstehen — geprüft alle 30 Min. Kostenlos & ohne Konto.'),
            const SizedBox(height: 6),
            InkWell(
              onTap: () => _openUrl('https://ntfy.sh'),
              child: Text('So funktioniert ntfy (App installieren, Thema '
                  'abonnieren) →',
                  style: TextStyle(
                      color: Theme.of(ctx).colorScheme.primary, fontSize: 13)),
            ),
            const SizedBox(height: 12),
            Text(
              status.enabled
                  ? 'Aktuell aktiv · letzte Prüfung: ${status.lastCheck ?? '—'}'
                  : 'Aktuell aus.',
              style: TextStyle(
                  color: status.enabled ? kGreen : null,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: topicCtrl,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'ntfy-Thema (Topic)',
                hintText: 'z. B. mein-pi-a7Xk',
                helperText: 'Frei wählbar, aber schwer erratbar wählen.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: serverCtrl,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'ntfy-Server',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: () {
                      final topic = topicCtrl.text.trim();
                      if (topic.isEmpty) {
                        _snack('Bitte ein ntfy-Thema eingeben.');
                        return;
                      }
                      Navigator.pop(ctx, (
                        enable: true,
                        server: serverCtrl.text.trim().isEmpty
                            ? 'https://ntfy.sh'
                            : serverCtrl.text.trim(),
                        topic: topic
                      ));
                    },
                    child: Text(status.enabled ? 'Aktualisieren' : 'Einschalten'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () {
                    final topic = topicCtrl.text.trim();
                    if (topic.isEmpty) {
                      _snack('Bitte ein ntfy-Thema eingeben.');
                      return;
                    }
                    _sendTestAlert(
                        config,
                        serverCtrl.text.trim().isEmpty
                            ? 'https://ntfy.sh'
                            : serverCtrl.text.trim(),
                        topic);
                  },
                  child: const Text('Test'),
                ),
              ],
            ),
            if (status.enabled)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx,
                      (enable: false, server: '', topic: '')),
                  child: const Text('Ausschalten'),
                ),
              ),
          ],
        ),
      ),
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
          _statusMessage = 'Automatische Updates aktiv.';
          _statusOk = true;
        });
        _addHistory('Automatische Updates eingerichtet ($onCal).');
      } else {
        await _updater.disableAutoUpdate(config: config, onLog: _appendLog);
        if (!mounted) return;
        setState(() {
          _statusMessage = 'Automatische Updates deaktiviert.';
          _statusOk = true;
        });
        _addHistory('Automatische Updates deaktiviert.');
      }
    },
        backgroundMessage: choice.enable
            ? 'Richte automatische Updates ein …'
            : 'Deaktiviere automatische Updates …');
  }

  Future<({bool enable, bool weekly, int hour, int weekday})?>
      _showAutoUpdateSheet(AutoUpdateStatus status) {
    var weekly = false;
    var hour = 4;
    var weekday = 7;
    const days = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
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
                Text('Automatische Updates',
                    style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 8),
                const Text('Der Pi aktualisiert sich künftig selbst (System + '
                    'Dienste). evcc wird vorher gesichert und bei Problemen '
                    'automatisch neu gestartet.'),
                const SizedBox(height: 12),
                Text(
                  status.enabled
                      ? 'Aktuell aktiv · nächste: ${status.nextRun ?? '—'}'
                      : 'Aktuell aus.',
                  style: TextStyle(
                      color: status.enabled ? kGreen : null,
                      fontWeight: FontWeight.w600),
                ),
                if (status.lastResult != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('Zuletzt gelaufen: ${status.lastResult}',
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12)),
                  ),
                const Divider(height: 24),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Täglich')),
                    ButtonSegment(value: true, label: Text('Wöchentlich')),
                  ],
                  selected: {weekly},
                  onSelectionChanged: (s) => setSheet(() => weekly = s.first),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('Uhrzeit:  '),
                    DropdownButton<int>(
                      value: hour,
                      items: [
                        for (var h = 0; h < 24; h++)
                          DropdownMenuItem(
                              value: h,
                              child: Text(
                                  '${h.toString().padLeft(2, '0')}:00 Uhr')),
                      ],
                      onChanged: (v) => setSheet(() => hour = v ?? 4),
                    ),
                    if (weekly) ...[
                      const Spacer(),
                      const Text('Tag:  '),
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
                        child: Text(
                            status.enabled ? 'Zeitplan ändern' : 'Einschalten'),
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
                        child: const Text('Ausschalten'),
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
        _statusMessage = 'Pi-hole aktualisiert.';
        _statusOk = true;
      });
      _addHistory('Pi-hole aktualisiert.');
      await _refreshServices(config);
    }, backgroundMessage: 'Pi-hole wird aktualisiert …');
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
        _statusMessage = 'Pi-hole-Blocklisten aktualisiert.';
        _statusOk = true;
      });
    }, backgroundMessage: 'Blocklisten werden aktualisiert …');
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
        _statusMessage = 'Pi-hole-DNS neu gestartet.';
        _statusOk = true;
      });
    });
  }

  Future<void> _installPihole() async {
    if (_busy) return;
    if (!await _confirm(
      'Pi-hole installieren?',
      'Installiert Pi-hole unbeaufsichtigt auf ${_host.text.trim()}.\n\n'
          'Experimentell: nicht gegen jede Konfiguration getestet; die '
          'Einrichtung erfolgt danach im Browser unter /admin.',
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
        _statusMessage =
            'Pi-hole installiert – im Browser unter /admin einrichten.';
        _statusOk = true;
        _setupUrl = '$_uiScheme://${_host.text.trim()}/admin';
      });
      _addHistory('Pi-hole installiert.');
      await _refreshServices(config);
    }, backgroundMessage: 'Pi-hole wird installiert …');
  }

  Future<void> _upgradeSystem() async {
    if (_busy) return;
    if (!await _confirm(
      'System aktualisieren?',
      'Aktualisiert ALLE Pakete auf dem Pi (apt full-upgrade), nicht nur einen '
          'einzelnen Dienst.',
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
        _statusMessage = 'System aktualisiert.';
        _statusOk = true;
      });
      _addHistory('System-Upgrade ausgeführt.');
      await _refreshServices(config);
    }, backgroundMessage: 'System-Upgrade läuft …');
  }

  void _openPiholeAdmin() {
    if (_host.text.trim().isEmpty) {
      _snack('Bitte zuerst Host/IP eintragen.');
      return;
    }
    _openUrl('$_uiScheme://${_host.text.trim()}/admin');
  }

  Future<void> _backupPihole() => _runServiceBackup(
        label: 'Pi-hole',
        backgroundMessage: 'Pi-hole wird gesichert …',
        run: (config) =>
            _updater.backupPihole(config: config, onLog: _appendLog),
      );

  Future<void> _backupHomeAssistant() => _runServiceBackup(
        label: 'Home Assistant',
        backgroundMessage: 'Home Assistant wird gesichert …',
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
        _statusMessage = '$label gesichert: $path';
        _statusOk = true;
      });
      _addHistory('$label gesichert.');
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
        _statusMessage = 'Home Assistant aktualisiert.';
        _statusOk = true;
      });
      _addHistory('Home Assistant aktualisiert.');
      await _refreshServices(config);
    }, backgroundMessage: 'Home Assistant wird aktualisiert …');
  }

  Future<void> _installHomeAssistant() async {
    if (_busy) return;
    if (!await _confirm(
      'Home Assistant installieren?',
      'Installiert Home Assistant als Docker-Container auf '
          '${_host.text.trim()} (bei Bedarf wird zuerst Docker installiert).\n\n'
          'Experimentell: nicht gegen jede Konfiguration getestet; die '
          'Einrichtung erfolgt danach im Browser unter Port 8123.',
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
        _statusMessage =
            'Home Assistant installiert – im Browser unter Port 8123 einrichten.';
        _statusOk = true;
        _setupUrl = 'http://${_host.text.trim()}:8123';
      });
      _addHistory('Home Assistant installiert.');
      await _refreshServices(config);
    }, backgroundMessage: 'Home Assistant wird installiert …');
  }

  void _openHomeAssistant() {
    if (_host.text.trim().isEmpty) {
      _snack('Bitte zuerst Host/IP eintragen.');
      return;
    }
    _openUrl('http://${_host.text.trim()}:8123');
  }

  /// Cancels the in-flight action by closing its SSH connection; the running
  /// action then finishes as "Abgebrochen".
  Future<void> _cancel() async {
    _appendLog('Abbrechen angefordert …');
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
      _snack('Das Log ist leer.');
      return;
    }
    SharePlus.instance.share(ShareParams(text: _log.join('\n')));
  }

  /// Read-only live status straight from evcc's Web-API (no SSH, no creds).
  void _showApiStatus() {
    final host = _host.text.trim();
    if (host.isEmpty) {
      _snack('Bitte zuerst Host/IP eintragen.');
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
      _snack('Keine SSH-Geräte im WLAN gefunden – IP bitte manuell eintragen.');
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
              title: Text('Gefundene Geräte (SSH offen)',
                  style: Theme.of(ctx).textTheme.titleMedium),
              subtitle: const Text('Nur im selben WLAN. Tippen zum Übernehmen.'),
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
                  _snack('Host auf $ip gesetzt.');
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
    if (!_isPro) {
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
        _statusMessage = 'Interaktiver Befehl – nicht ausgeführt.';
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
        _statusMessage = 'Befehl ausgeführt: $cmd';
        _statusOk = true;
      });
    }, backgroundMessage: 'Befehl läuft …');
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

  /// Bottom sheet with quick commands + the recent-command history. Tapping an
  /// entry fills the input (deliberately does NOT auto-run it).
  void _showConsoleHistory() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text('Schnellbefehle',
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
            if (_consoleHistory.isNotEmpty) ...[
              const Divider(),
              ListTile(
                title: Text('Verlauf',
                    style: Theme.of(ctx).textTheme.titleSmall),
                dense: true,
                trailing: TextButton.icon(
                  icon: const Icon(Icons.delete_sweep, size: 18),
                  label: const Text('Löschen'),
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
    if (t.isEmpty) return 'Neue evcc-Version verfügbar.';
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
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Noch kein Verlauf.'),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    title: Text('Verlauf',
                        style: Theme.of(ctx).textTheme.titleMedium),
                    trailing: TextButton(
                      onPressed: () async {
                        await _historyStore.clear();
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      child: const Text('Leeren'),
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

  void _appendLog(String line) {
    if (!mounted) return;
    // Defense in depth: redact the live password from anything we log.
    setState(() => _log.add(redactPassword(line, _password.text)));
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
      _snack('Bitte zuerst Host/IP eintragen.');
      return;
    }
    _openUrl(_evccUiUrl());
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) _snack('Konnte den Link nicht öffnen.');
    }
  }

  Future<bool> _confirm(String title, String body) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Weiter'),
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
        title: const Text('Neuen Pi vertrauen?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Erste Verbindung zu ${_host.text.trim()}. Prüfe den '
                'SSH-Fingerprint des Pi:'),
            const SizedBox(height: 10),
            SelectableText(
              fingerprint,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            const SizedBox(height: 10),
            const Text(
              'Nur „Vertrauen", wenn der Fingerprint zu deinem Pi passt. Bei '
              '„Abbrechen" wird KEIN Passwort gesendet.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.verified_user_outlined, size: 18),
            label: const Text('Vertrauen'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  void _openSetupGuide() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _SetupGuidePage(onDownloadImager: () => _openUrl(kImagerUrl)),
    ));
  }

  void _openSettings() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // Scrollable + full-height allowed, so the (tall) list isn't clipped at
      // the bottom and the port field stays above the keyboard.
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Einstellungen',
                        style: Theme.of(ctx).textTheme.titleMedium),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('App mit Biometrie/PIN sperren'),
                  subtitle: const Text('Beim Öffnen & nach dem Wechsel'),
                  value: _lockEnabled,
                  onChanged: (v) async {
                    if (v && !await _authenticator.canAuthenticate()) {
                      _snack('Keine Biometrie/PIN auf dem Gerät eingerichtet.');
                      return;
                    }
                    setState(() => _lockEnabled = v);
                    setSheet(() {});
                    _scheduleSave();
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Vor Update Backup anlegen'),
                  subtitle: const Text(
                      'Sichert evcc.yaml + Datenbank auf dem Pi (apt-Update)'),
                  value: _backupBeforeUpdate,
                  onChanged: (v) {
                    setState(() => _backupBeforeUpdate = v);
                    setSheet(() {});
                    _scheduleSave();
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('evcc-Oberfläche über HTTPS'),
                  subtitle: Text(_uiScheme == 'https'
                      ? 'https://…'
                      : 'http://… (Standard)'),
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
                  decoration: const InputDecoration(
                    labelText: 'evcc-Oberfläche: Port',
                    helperText: 'Standard 7070',
                  ),
                ),
                const SizedBox(height: 16),
                Text('Design', style: Theme.of(ctx).textTheme.labelLarge),
                const SizedBox(height: 6),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'system', label: Text('System')),
                    ButtonSegment(value: 'light', label: Text('Hell')),
                    ButtonSegment(value: 'dark', label: Text('Dunkel')),
                  ],
                  selected: {_themeMode},
                  onSelectionChanged: (s) {
                    setState(() => _themeMode = s.first);
                    themeModeNotifier.value = parseThemeMode(s.first);
                    setSheet(() {});
                    _scheduleSave();
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('evcc-Nightly installieren'),
                  subtitle: const Text(
                      'unstable-Kanal statt stable (nur bei Neuinstallation)'),
                  value: _channel == 'unstable',
                  onChanged: (v) {
                    setState(() => _channel = v ? 'unstable' : 'stable');
                    setSheet(() {});
                    _scheduleSave();
                  },
                ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Builds a card per detected service (or a hint before the first test).
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
                      ? 'Verbindung fehlgeschlagen – Host/IP und Zugangsdaten '
                          'prüfen, dann erneut verbinden.'
                      : 'Tippe „Verbindung herstellen", um die Dienste auf dem '
                          'Pi zu erkennen.',
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
                  : () => _snack('Raspberry Pi Connect braucht Raspberry Pi OS '
                      'Bookworm oder neuer.'),
              subtitle: s.compatible
                  ? 'Offizieller Fernzugriff (Shell) – installieren'
                  : 'Nicht kompatibel – braucht Bookworm oder neuer',
              enabled: s.compatible,
            ));
          case 'tailscale':
            addable.add(_AddableService(
              'Tailscale',
              Icons.vpn_key_outlined,
              _installTailscale,
              subtitle: 'VPN/Mesh – den Pi von überall erreichen',
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
            isPro: _isPro,
            status: s,
            icon: Icons.bolt,
            enabled: !_busy,
            primaryLabel: 'Aktualisieren',
            onPrimary: () => _run(dryRun: false),
            onOpenWeb: _openEvccUi,
            actions: s.installed
                ? [
                    _CardAction('Logs anzeigen', () => _showServiceLogs(s)),
                    if (upToDate)
                      _CardAction(
                          'Trotzdem aktualisieren', () => _run(dryRun: false)),
                    _CardAction(
                        'Probelauf (ändert nichts)', () => _run(dryRun: true)),
                    _CardAction('Live-Status', _showApiStatus),
                    _CardAction('Dienst neu starten', _restartService),
                    // Backups are made only for apt installs; restore would also
                    // `systemctl start evcc`, which has no unit on a Docker host.
                    if (s.detail.startsWith('apt')) ...[
                      _CardAction(
                          'Konfiguration bearbeiten',
                          () => _proGate(
                              () => _editConfig('/etc/evcc.yaml', 'evcc.yaml')),
                          pro: true),
                      _CardAction('Backup wiederherstellen',
                          () => _proGate(_restoreBackup), pro: true),
                    ],
                    _CardAction('Offizielle evcc-App',
                        () => _openUrl(kEvccPlayStoreUrl)),
                  ]
                : const [],
          ));
        case 'pihole':
          cards.add(_ServiceCard(
            isPro: _isPro,
            status: s,
            icon: Icons.shield_outlined,
            enabled: !_busy,
            primaryLabel: 'Aktualisieren',
            onPrimary: _updatePihole,
            onOpenWeb: _openPiholeAdmin,
            actions: [
              _CardAction('Logs anzeigen', () => _showServiceLogs(s)),
              if (upToDate) _CardAction('Trotzdem aktualisieren', _updatePihole),
              _CardAction('Sichern (Teleporter)',
                  () => _proGate(_backupPihole), pro: true),
              _CardAction('Backups verwalten',
                  () => _proGate(_managePiholeBackups), pro: true),
              _CardAction('Blocklisten aktualisieren', _piholeGravity),
              _CardAction('DNS neu starten', _piholeRestartDns),
            ],
          ));
        case 'homeassistant':
          cards.add(_ServiceCard(
            isPro: _isPro,
            status: s,
            icon: Icons.cottage_outlined,
            enabled: !_busy,
            primaryLabel: 'Aktualisieren',
            onPrimary: _updateHomeAssistant,
            onOpenWeb: _openHomeAssistant,
            actions: [
              _CardAction('Logs anzeigen', () => _showServiceLogs(s)),
              _CardAction('Sichern (/config)',
                  () => _proGate(_backupHomeAssistant), pro: true),
              _CardAction('Backups verwalten',
                  () => _proGate(_manageHomeAssistantBackups), pro: true),
            ],
          ));
        case 'piconnect':
          final signedIn = s.active; // active == signed in
          cards.add(_ServiceCard(
            isPro: _isPro,
            status: s,
            icon: Icons.cast,
            enabled: !_busy,
            primaryLabel: signedIn ? 'Web öffnen' : 'Anmelden',
            onPrimary: signedIn
                ? () => _openUrl('https://connect.raspberrypi.com')
                : _piConnectSignin,
            actions: signedIn
                ? [
                    _CardAction(
                        'Fernzugriff aktivieren', () => _piConnectSet(true)),
                    _CardAction(
                        'Fernzugriff pausieren', () => _piConnectSet(false)),
                    _CardAction('Abmelden', _piConnectSignout),
                  ]
                : const [],
          ));
        case 'tailscale':
          final up = s.active;
          cards.add(_ServiceCard(
            isPro: _isPro,
            status: s,
            icon: Icons.vpn_key,
            enabled: !_busy,
            primaryLabel: up ? 'Trennen' : 'Verbinden',
            onPrimary:
                up ? () => _tailscaleSet(logout: false) : _tailscaleUp,
            onOpenWeb: up
                ? () => _openUrl('https://login.tailscale.com/admin/machines')
                : null,
            actions: [
              if (up && s.version != null)
                _CardAction('Diese IP als Host übernehmen (${s.version})',
                    () => _useTailscaleIp(s.version!)),
              _CardAction('Abmelden', () => _tailscaleSet(logout: true)),
            ],
          ));
        case 'system':
          cards.add(_ServiceCard(
            isPro: _isPro,
            status: s,
            icon: Icons.memory,
            enabled: !_busy,
            primaryLabel: 'Updates installieren',
            onPrimary: _upgradeSystem,
            actions: [
              _CardAction('Logs anzeigen', () => _showServiceLogs(s)),
              if (upToDate)
                _CardAction('Trotzdem aktualisieren', _upgradeSystem),
              _CardAction('Aufräumen (Speicher freigeben)',
                  () => _proGate(_cleanupSystem), pro: true),
              _CardAction('Pi neu starten', _reboot),
            ],
          ));
        default:
          // Generic apt service (Grafana, InfluxDB, …): update via apt,
          // optional web UI. Only ever emitted when installed.
          cards.add(_ServiceCard(
            isPro: _isPro,
            status: s,
            icon: _serviceIcon(s.id),
            enabled: !_busy,
            primaryLabel: 'Aktualisieren',
            onPrimary: () => _updateAptService(s),
            onOpenWeb:
                s.webPort != null ? () => _openServiceWeb(s.webPort!) : null,
            actions: [
              _CardAction('Logs anzeigen', () => _showServiceLogs(s)),
              if (upToDate)
                _CardAction(
                    'Trotzdem aktualisieren', () => _updateAptService(s)),
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
        subtitle:
            svc.webPort != null ? 'Web-Oberfläche auf Port ${svc.webPort}' : null,
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
          'Energie-Monitoring-Stack',
          Icons.auto_awesome,
          _guidedSetup,
          subtitle: 'InfluxDB + Grafana + Mosquitto in einem Schritt',
        ),
      );
    }
    if (addable.isNotEmpty) {
      cards.add(Padding(
        padding: const EdgeInsets.only(top: 4),
        child: OutlinedButton.icon(
          onPressed: _busy ? null : () => _showAddServicePicker(addable),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Dienst hinzufügen'),
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
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 4, 20, 4),
                child: Text('Dienst hinzufügen',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Installiert den Dienst auf dem Pi (experimentell).'),
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
      _snack('Der Monitoring-Stack ist bereits installiert.');
      return;
    }
    final chosen = await _showGuidedSetupSheet(stack);
    if (chosen == null || chosen.isEmpty || !mounted) return;
    _lastAction = _guidedSetup;
    _beginBusy();
    await _guard(() async {
      for (final svc in chosen) {
        _appendLog('== Installiere ${svc.name} ==');
        await _updater.installAptService(
            config: config, service: svc, onLog: _appendLog);
      }
      if (!mounted) return;
      final names = chosen.map((s) => s.name).join(', ');
      setState(() {
        _statusMessage = 'Monitoring-Stack installiert: $names.';
        _statusOk = true;
      });
      _addHistory('Energie-Stack installiert: $names.');
      await _refreshServices(config);
    }, backgroundMessage: 'Monitoring-Stack wird installiert …');
  }

  String _stackRole(String id) {
    switch (id) {
      case 'influxdb':
        return 'Zeitreihen-Datenbank (speichert die Messwerte)';
      case 'grafana':
        return 'Dashboards (visualisiert die Daten)';
      case 'mosquitto':
        return 'MQTT-Broker (Datenverteilung)';
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
                Text('Energie-Monitoring-Stack',
                    style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 8),
                const Text('Installiert die Bausteine, um deine '
                    'evcc-Energiedaten zu speichern und als Dashboard zu sehen '
                    '— in einem Schritt.'),
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
                  'Danach in evcc InfluxDB + MQTT eintragen (siehe evcc-Doku). '
                  'Experimentell — installiert aus den offiziellen apt-Quellen.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.download),
                    label: const Text('Installieren'),
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
        _statusMessage = 'Raspberry Pi Connect installiert – jetzt anmelden.';
        _statusOk = true;
      });
      _addHistory('Raspberry Pi Connect installiert.');
      await _refreshServices(config);
    }, backgroundMessage: 'Raspberry Pi Connect wird installiert …');
  }

  Future<void> _piConnectSignin() async {
    if (_busy) return;
    final config = _prepare();
    if (config == null) return;
    _lastAction = _piConnectSignin;
    String? url;
    await _guard(() async {
      url = await _updater.piConnectSignin(config: config, onLog: _appendLog);
    }, backgroundMessage: 'Anmeldung wird gestartet …');
    if (!mounted) return;
    if (url == null) {
      _snack('Kein Anmelde-Link erhalten (Details im Terminal-Log).');
      return;
    }
    await _openUrl(url!);
    if (mounted) {
      _snack('Im Browser mit deiner Raspberry Pi ID anmelden, dann erneut '
          '„Verbindung herstellen".');
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
        _statusMessage = on ? 'Pi Connect aktiviert.' : 'Pi Connect deaktiviert.';
        _statusOk = true;
      });
      await _refreshServices(config);
    },
        backgroundMessage:
            on ? 'Pi Connect wird aktiviert …' : 'Pi Connect wird deaktiviert …');
  }

  Future<void> _piConnectSignout() async {
    if (_busy) return;
    if (!await _confirm('Abmelden?',
        'Trennt den Pi von deinem Raspberry-Pi-Connect-Konto.')) {
      return;
    }
    final config = _prepare();
    if (config == null) return;
    _lastAction = _piConnectSignout;
    await _guard(() async {
      await _updater.piConnectSignout(config: config, onLog: _appendLog);
      if (!mounted) return;
      setState(() {
        _statusMessage = 'Von Pi Connect abgemeldet.';
        _statusOk = true;
      });
      await _refreshServices(config);
    }, backgroundMessage: 'Abmeldung läuft …');
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
        _statusMessage = 'Tailscale installiert – jetzt „Verbinden".';
        _statusOk = true;
      });
      _addHistory('Tailscale installiert.');
      await _refreshServices(config);
    }, backgroundMessage: 'Tailscale wird installiert …');
  }

  Future<void> _tailscaleUp() async {
    if (_busy) return;
    final config = _prepare();
    if (config == null) return;
    _lastAction = _tailscaleUp;
    String? url;
    await _guard(() async {
      url = await _updater.tailscaleUp(config: config, onLog: _appendLog);
    }, backgroundMessage: 'Tailscale wird verbunden …');
    if (!mounted) return;
    if (url != null) {
      await _openUrl(url!);
      if (mounted) {
        _snack('Im Browser bei Tailscale anmelden, dann erneut „Verbindung '
            'herstellen".');
      }
    } else {
      // Already authenticated → just re-detect to show the new state.
      await _refreshServices(config);
      if (mounted) _snack('Tailscale verbunden.');
    }
  }

  Future<void> _tailscaleSet({required bool logout}) async {
    if (_busy) return;
    if (logout &&
        !await _confirm('Abmelden?',
            'Entfernt den Pi aus deinem Tailnet (neue Anmeldung nötig).')) {
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
        _statusMessage = logout ? 'Tailscale abgemeldet.' : 'Tailscale getrennt.';
        _statusOk = true;
      });
      await _refreshServices(config);
    },
        backgroundMessage:
            logout ? 'Tailscale-Abmeldung läuft …' : 'Tailscale wird getrennt …');
  }

  /// Puts the Pi's tailnet IP into the host field (the bonus: connect from
  /// anywhere without hunting for the 100.x address).
  void _useTailscaleIp(String ip) {
    setState(() {
      _host.text = ip;
      _tab = 0;
    });
    _scheduleSave();
    _snack('Host auf $ip gesetzt – jetzt „Verbindung herstellen".');
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
        _statusMessage = '${service.name} installiert.';
        _statusOk = true;
      });
      _addHistory('${service.name} installiert.');
      await _refreshServices(config);
    }, backgroundMessage: '${service.name} wird installiert …');
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
      default:
        return Icons.apps;
    }
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
        _statusMessage = '${s.name} aktualisiert.';
        _statusOk = true;
      });
      _addHistory('${s.name} aktualisiert.');
      await _refreshServices(config);
    }, backgroundMessage: '${s.name} wird aktualisiert …');
  }

  void _openServiceWeb(int port) {
    if (_host.text.trim().isEmpty) {
      _snack('Bitte zuerst Host/IP eintragen.');
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
                case 'setup':
                  _openSetupGuide();
                case 'find':
                  _findPi();
                case 'share':
                  _shareLog();
                case 'history':
                  _showHistory();
                case 'settings':
                  _openSettings();
              }
            },
            // Read-only / local items stay usable during an action; only the
            // SSH-mutating items (reboot/find) are disabled while busy.
            itemBuilder: (_) => [
              const PopupMenuItem(
                  value: 'api', child: Text('evcc-Status (Live)')),
              PopupMenuItem(
                  value: 'reboot',
                  enabled: !_busy,
                  child: const Text('Pi neu starten')),
              const PopupMenuDivider(),
              const PopupMenuItem(
                  value: 'setup', child: Text('Pi einrichten')),
              PopupMenuItem(
                  value: 'find',
                  enabled: !_busy,
                  child: const Text('Pi im WLAN suchen')),
              const PopupMenuItem(value: 'share', child: Text('Log teilen')),
              const PopupMenuItem(value: 'history', child: Text('Verlauf')),
              const PopupMenuDivider(),
              const PopupMenuItem(
                  value: 'settings', child: Text('Einstellungen')),
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
            // No host yet (first start, or a freshly added profile) → offer a
            // prominent network scan. Rebuilds live as the host field changes.
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _host,
              builder: (context, value, _) {
                if (value.text.trim().isNotEmpty) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Column(
                    children: [
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _findPi,
                        icon: const Icon(Icons.wifi_find, size: 18),
                        label: const Text('Pi im WLAN suchen'),
                        style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(44)),
                      ),
                      // Beginners without a ready Pi: link the Imager guide.
                      TextButton.icon(
                        onPressed: _openSetupGuide,
                        icon: const Icon(Icons.menu_book_outlined, size: 18),
                        label: const Text('Noch keinen Pi? So richtest du einen ein'),
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
                label: const Text('evcc-Einrichtung öffnen'),
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: () => _openUrl(kReleasesUrl),
                  icon: const Icon(Icons.history, size: 18),
                  label: const Text('Changelog'),
                ),
                TextButton.icon(
                  onPressed: _checkUpdatesNow,
                  icon: const Icon(Icons.system_update, size: 18),
                  label: const Text('Auf Update prüfen'),
                ),
                TextButton.icon(
                  onPressed: () => _openUrl(kPrivacyUrl),
                  icon: const Icon(Icons.privacy_tip_outlined, size: 18),
                  label: const Text('Datenschutz'),
                ),
                TextButton.icon(
                  onPressed: () => _openUrl(kImpressumUrl),
                  icon: const Icon(Icons.info_outline, size: 18),
                  label: const Text('Impressum'),
                ),
                TextButton.icon(
                  onPressed: () => showLicensePage(
                    context: context,
                    applicationName: 'Pi-Tool (inoffiziell)',
                    applicationIcon: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: _PromptMark(
                          size: 56,
                          chevronColor: theme.colorScheme.onSurface),
                    ),
                    applicationLegalese:
                        '© 2026 KYTH. Systems UG (haftungsbeschränkt) i.G.',
                  ),
                  icon: const Icon(Icons.description_outlined, size: 18),
                  label: const Text('Open-Source-Lizenzen'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Nutzung auf eigene Gefahr. Wir übernehmen keine Haftung für '
              'Schäden an System, Daten oder Hardware.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(
              'Inoffizielles Tool, nicht mit evcc oder Pi-hole verbunden.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant
                      .withValues(alpha: 0.7)),
            ),
            const SizedBox(height: 8),
            Text(
              _appVersion.isEmpty
                  ? 'by KYTH. Systems'
                  : 'Pi-Tool v$_appVersion · by KYTH. Systems',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
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
        onDestinationSelected: (i) => setState(() {
          _tab = i;
          // Don't carry a stale result banner (e.g. "Verbindung OK") onto
          // another tab — file ops don't run through _guard, so it would
          // otherwise stick on the Dateien/Terminal tabs.
          _statusMessage = null;
        }),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.dns_outlined),
              selectedIcon: Icon(Icons.dns),
              label: 'Dienste'),
          NavigationDestination(
              icon: Icon(Icons.bolt_outlined),
              selectedIcon: Icon(Icons.bolt),
              label: 'Automatik'),
          NavigationDestination(
              icon: Icon(Icons.terminal_outlined),
              selectedIcon: Icon(Icons.terminal),
              label: 'Terminal'),
          NavigationDestination(
              icon: Icon(Icons.folder_outlined),
              selectedIcon: Icon(Icons.folder),
              label: 'Dateien'),
        ],
      ),
    );
  }

  // ---- Automatik tab: cross-cutting automation (updates, alerts) ----

  Widget _automatikTab(ThemeData theme) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Automatik', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Läuft autonom auf dem Pi — kein Hintergrunddienst auf dem Handy '
            'nötig.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          _AutomationTile(
            icon: Icons.update,
            title: 'Automatische Updates',
            subtitle: 'Zeitplan-Updates mit evcc-Backup + Selbstheilung',
            locked: !_isPro,
            onTap: () => _proGate(_configureAutoUpdate),
          ),
          _AutomationTile(
            icon: Icons.notifications_active_outlined,
            title: 'Health-Alerts',
            subtitle: 'Push bei voller Platte, totem Dienst, Hitze, Updates '
                '(via ntfy)',
            locked: !_isPro,
            onTap: () => _proGate(_configureAlerts),
          ),
        ],
      );

  // ---- Terminal tab: console (later: logs, files) ----

  Widget _terminalTab(ThemeData theme) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Konsole', style: theme.textTheme.titleSmall),
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
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixText: '\$ ',
                    hintText: 'Befehl absetzen … (z. B. df -h)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                onPressed: _busy ? null : _showConsoleHistory,
                icon: const Icon(Icons.history),
                tooltip: 'Verlauf + Schnellbefehle',
              ),
              const SizedBox(width: 4),
              IconButton.filledTonal(
                onPressed:
                    _busy ? null : () => _runConsoleCommand(_consoleInput.text),
                // Lock hint for free users (Konsole is Pro; the tap opens the
                // paywall via _runConsoleCommand's gate).
                icon: Icon(_isPro ? Icons.keyboard_return : Icons.lock_outline),
                tooltip: _isPro ? 'Befehl absetzen' : 'Pro-Funktion',
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Befehle laufen mit deinen Rechten direkt auf dem Pi (sudo wird '
            'unterstützt). Auf eigene Gefahr.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      );

  // ---- Dateien tab: browse / preview / upload / delete on the Pi ----

  Widget _dateienTab(ThemeData theme) {
    if (!_isPro) {
      return _filesPlaceholder(
        theme,
        icon: Icons.lock_outline,
        title: 'Datei-Explorer (Pro)',
        body: 'Die Dateien deines Pi durchsuchen, hochladen und löschen ist '
            'Teil von Pro.',
        actionLabel: 'Pro freischalten',
        onAction: _showPaywall,
      );
    }
    if (_filesConfig() == null) {
      return _filesPlaceholder(
        theme,
        icon: Icons.dns_outlined,
        title: 'Kein Pi verbunden',
        body: 'Trage im Tab „Dienste" Host + Zugangsdaten ein — dann kannst du '
            'hier die Dateien deines Pi durchsuchen und hochladen.',
      );
    }
    return _FilesView(
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

