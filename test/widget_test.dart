import 'dart:async';
import 'dart:io' show Directory, File, FileSystemException, HttpException;
import 'dart:typed_data';

import 'package:evcc_updater/main.dart';
import 'package:evcc_updater/src/l10n.dart';
import 'package:evcc_updater/src/authenticator.dart';
import 'package:evcc_updater/src/early_adopter.dart';
import 'package:evcc_updater/src/evcc_api.dart';
import 'package:evcc_updater/src/evcc_updater.dart';
import 'package:evcc_updater/src/history.dart';
import 'package:evcc_updater/src/kyth_wordmark.dart';
import 'package:evcc_updater/src/profiles.dart';
import 'package:evcc_updater/src/secure_screen.dart';
import 'package:evcc_updater/src/services/pi_service.dart';
import 'package:evcc_updater/src/settings_store.dart';
import 'package:evcc_updater/src/ssh_runner.dart';
import 'package:evcc_updater/src/update_check.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Default config for tests: like AppConfig.initial but with the first-run
/// disclaimer already accepted, so tests land on the app, not the gate.
const _acceptedInitial = AppConfig(
  profiles: [Profile(name: 'Standard')],
  activeIndex: 0,
  disclaimerAccepted: true,
);

/// In-memory config store so the widget test never touches platform channels.
class _FakeStore extends AppConfigStore {
  _FakeStore([this._initial = _acceptedInitial]);

  final AppConfig _initial;
  AppConfig saved = AppConfig.initial;

  @override
  Future<AppConfig> load() async => _initial;

  @override
  Future<void> save(AppConfig c) async => saved = c;
}

/// Store for the startup path: [load] waits for [gate] and throws while
/// [failures] is positive (like secure storage reporting a keystore error).
class _StartupStore extends AppConfigStore {
  _StartupStore(this._config, {this.failures = 0, bool held = false}) {
    if (!held) gate.complete();
  }

  AppConfig _config;
  final gate = Completer<void>();
  int failures;
  int loadCalls = 0, saveCalls = 0, resetCalls = 0;
  bool resetFails = false; // the storage does not even let itself be deleted
  AppConfig? saved;

  @override
  Future<AppConfig> load() async {
    loadCalls++;
    await gate.future;
    if (failures > 0) {
      failures--;
      throw PlatformException(
          code: 'Exception encountered', message: 'KeyStoreException');
    }
    return _config;
  }

  @override
  Future<void> save(AppConfig c) async {
    saveCalls++;
    saved = c;
  }

  @override
  Future<void> reset() async {
    resetCalls++;
    if (resetFails) {
      throw PlatformException(
          code: 'Exception encountered', message: 'KeyStoreException');
    }
    // What was stored is gone: reading works again and finds a first start.
    failures = 0;
    _config = AppConfig.initial;
  }
}

/// History kept in memory. [unreadable] makes it throw the way secure storage
/// does for a value it cannot decrypt — until it is cleared.
class _MemoryHistory extends HistoryStore {
  _MemoryHistory([List<HistoryEntry>? initial]) : entries = [...?initial];

  final List<HistoryEntry> entries;
  bool unreadable = false;

  PlatformException get _error => PlatformException(
      code: 'Exception encountered', message: 'AEADBadTagException');

  @override
  Future<List<HistoryEntry>> load() async {
    if (unreadable) throw _error;
    return List.of(entries);
  }

  @override
  Future<void> add(HistoryEntry entry) async {
    if (unreadable) throw _error; // reads first, as the real store does
    entries.add(entry);
  }

  @override
  Future<void> clear() async {
    unreadable = false;
    entries.clear();
  }
}

/// Just enough updater to connect and restart the Pi — the shortest action
/// that writes a history entry.
class _RebootUpdater extends EvccUpdater {
  _RebootUpdater() : super(runnerFactory: _noRunner);
  static SshRunner _noRunner(SshConfig c) => throw UnimplementedError();

  int reboots = 0;

  @override
  Future<List<ServiceStatus>> detectServices({
    required SshConfig config,
    required void Function(String line) onLog,
    bool allowSudoForDocker = true,
    void Function()? onConnected,
  }) async {
    onConnected?.call();
    return const [];
  }

  @override
  Future<void> reboot({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async =>
      reboots++;
}

/// Authenticator that is available but always denies — keeps the app locked.
class _DenyAuth implements Authenticator {
  @override
  Future<bool> canAuthenticate() async => true;

  @override
  Future<bool> authenticate(String reason) async => false;
}

/// A device with no biometrics and no PIN set up.
class _NoAuth implements Authenticator {
  @override
  Future<bool> canAuthenticate() async => false;

  @override
  Future<bool> authenticate(String reason) async => false;
}

/// Authenticator whose answer the test sets.
class _SwitchAuth implements Authenticator {
  bool allow = true;

  @override
  Future<bool> canAuthenticate() async => true;

  @override
  Future<bool> authenticate(String reason) async => allow;
}

/// Records every FLAG_SECURE request instead of calling the platform channel.
class _RecordingSecureScreen implements SecureScreen {
  final calls = <bool>[];

  @override
  Future<void> setSecure(bool secure) async => calls.add(secure);
}

/// Update checker that never hits the network in tests.
final _noUpdateChecker =
    UpdateChecker(getJson: (_) async => <String, dynamic>{});

/// Update checker that always reports a much newer GitHub release.
final _newReleaseChecker = UpdateChecker(getJson: (_) async => {
      'tag_name': 'v9.9.9',
      'html_url': 'https://example.invalid/releases/tag/v9.9.9',
      'assets': [
        {
          'name': 'app-release.apk',
          'browser_download_url': 'https://example.invalid/app-release.apk',
        },
      ],
    });

/// Mocks PackageInfo for the app version + where the build was installed from.
/// [installerStore] null = sideload, 'com.android.vending' = Play.
void _mockPackageInfo({String version = '0.21.2', String? installerStore}) {
  PackageInfo.setMockInitialValues(
    appName: 'Pi-Tool',
    packageName: 'systems.kyth.pitool',
    version: version,
    buildNumber: '40',
    buildSignature: '',
    installerStore: installerStore,
  );
}

Widget _page() => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
    home: UpdaterPage(store: _FakeStore(), updateChecker: _noUpdateChecker));

/// Opens the top-right ⋮ and taps "Auf Update prüfen" on a sideload build
/// (v0.21.2) whose GitHub answer comes from [getJson].
Future<void> _checkForUpdateManually(
    WidgetTester tester, HttpGetJson getJson) async {
  _mockPackageInfo(); // installerStore null → sideload
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('de'),
    home: UpdaterPage(
        store: _FakeStore(), updateChecker: UpdateChecker(getJson: getJson)),
  ));
  await tester.pumpAndSettle();

  await tester.tap(find.byType(PopupMenuButton<String>)); // top-right ⋮
  await tester.pumpAndSettle();
  await tester.tap(find.text('Auf Update prüfen'));
  await tester.pump(); // kick off the async check
  await tester.pump(const Duration(milliseconds: 300)); // resolve + snackbar
}

void main() {
  // A tall phone-sized surface so the whole single screen fits (the ListView
  // builds lazily, so off-screen widgets wouldn't exist on the default surface).
  void useTallScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('"What\'s New" popup shows after a version change, then records',
      (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'Pi-Tool',
      packageName: 'systems.kyth.pitool',
      version: '0.21.14',
      buildNumber: '52',
      buildSignature: '',
    );
    useTallScreen(tester);
    final store = _FakeStore(const AppConfig(
      profiles: [Profile(name: 'Standard', host: '1.2.3.4')],
      activeIndex: 0,
      disclaimerAccepted: true,
      lastSeenVersion: '0.21.13', // updated FROM this
    ));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(store: store, updateChecker: _noUpdateChecker),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Neu in v0.21.14'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, "Los geht's"));
    await tester.pumpAndSettle();
    expect(find.text('Neu in v0.21.14'), findsNothing);
    expect(store.saved.lastSeenVersion, '0.21.14'); // recorded
  });

  testWidgets('first run shows the disclaimer; accepting reveals + saves it',
      (tester) async {
    useTallScreen(tester);
    // A config that has NOT accepted the disclaimer yet.
    final store = _FakeStore(const AppConfig(
      profiles: [Profile(name: 'Standard')],
      activeIndex: 0,
    ));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(store: store, updateChecker: _noUpdateChecker),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Willkommen bei Pi-Tool'), findsOneWidget);
    expect(find.text('Verbindung herstellen'), findsNothing); // app is gated

    await tester
        .tap(find.widgetWithText(FilledButton, 'Akzeptieren und starten'));
    await tester.pumpAndSettle();

    expect(find.text('Verbindung herstellen'), findsWidgets); // app revealed
    expect(store.saved.disclaimerAccepted, isTrue); // persisted
  });

  testWidgets('renders the connection screen with the detect hint',
      (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    expect(find.text('Pi-Tool'), findsOneWidget); // app bar wordmark
    expect(find.text('Verbindung herstellen'),
        findsOneWidget); // compact connect button
    expect(find.textContaining('Verbindung herstellen'),
        findsWidgets); // + hint
    // Bottom-nav cockpit: Verwaltung (tab 0) + the gated tabs.
    expect(find.text('Verwaltung'), findsOneWidget);
    expect(find.text('Automatik'), findsOneWidget);
    expect(find.text('Terminal'), findsOneWidget);
    // Verwaltung tab has the 4 connection fields; the console lives on Terminal.
    expect(find.byType(TextField), findsNWidgets(4));
    expect(find.text('Konsole'), findsNothing);

    // Disconnected: the gated Terminal tab won't open — tapping it hints instead
    // of switching, so the console field never appears.
    await tester.tap(find.byIcon(Icons.terminal_outlined));
    await tester.pump();
    expect(find.byKey(const Key('consoleField')), findsNothing);
    expect(find.textContaining('Zuerst verbinden'), findsWidgets);
  });

  testWidgets('footer shows the app version + KYTH branding', (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'Pi-Tool',
      packageName: 'systems.kyth.pitool',
      version: '0.21.2',
      buildNumber: '40',
      buildSignature: '',
    );
    useTallScreen(tester);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(store: _FakeStore(), updateChecker: _noUpdateChecker),
    ));
    await tester.pumpAndSettle();

    final version = find.textContaining('Pi-Tool v0.21.2');
    await tester.scrollUntilVisible(version, 300,
        scrollable: find.byType(Scrollable).first);
    expect(version, findsOneWidget);
    // Dezentes KYTH-Branding (Wortmarke) + die kleinen Legal-Links in der Fußzeile.
    expect(find.textContaining('by '), findsWidgets);
    expect(find.byType(KythWordmark), findsOneWidget);
    expect(find.text('Datenschutz'), findsOneWidget);
    expect(find.text('Open-Source-Lizenzen'), findsOneWidget);
    // Bewertungen treiben das Play-Ranking; der Link gehört in die Fußzeile.
    // NICHT ins ⋮-Menü — der Versuch am 26.07.2026 kippte 15 Tests, weil das
    // Menü voll ist und andere Einträge aus dem Bild geschoben wurden.
    expect(find.text('App bewerten'), findsOneWidget);
  });

  testWidgets('⋮ → "Auf Update prüfen" reports up to date on the current version',
      (tester) async {
    useTallScreen(tester);
    // GitHub's latest release IS the installed version.
    await _checkForUpdateManually(
        tester,
        (_) async => {
              'tag_name': 'v0.21.2',
              'html_url': 'https://example.invalid/releases/tag/v0.21.2',
            });
    expect(find.text('Aktuell – du hast die neueste Version (v0.21.2).'),
        findsOneWidget);
  });

  // A failed check used to pass as "no update": offline, a GitHub rate limit
  // (HTTP 403/429) or an answer without a tag all reported "Aktuell".
  testWidgets('⋮ → "Auf Update prüfen" says so when the check itself failed',
      (tester) async {
    useTallScreen(tester);
    await _checkForUpdateManually(
        tester, (_) async => throw const HttpException('GitHub API 403'));
    expect(find.text('Update-Prüfung fehlgeschlagen – später erneut versuchen.'),
        findsOneWidget);
    expect(find.textContaining('du hast die neueste Version'), findsNothing);
  });

  testWidgets('⋮ → "Auf Update prüfen": an answer without a release tag is a '
      'failed check, not "up to date"', (tester) async {
    useTallScreen(tester);
    await _checkForUpdateManually(tester, (_) async => <String, dynamic>{});
    expect(find.text('Update-Prüfung fehlgeschlagen – später erneut versuchen.'),
        findsOneWidget);
    expect(find.textContaining('du hast die neueste Version'), findsNothing);
  });

  // The early-adopter marker is what makes the later Pro grandfathering
  // possible: it must be stamped and PERSISTED while the app is still free.
  // The pure resolve/decide logic is covered in early_adopter_test.dart — these
  // two prove the wiring actually reaches the store.
  testWidgets('a fresh install records the current versionCode as first-seen',
      (tester) async {
    _mockPackageInfo(); // buildNumber '40'
    useTallScreen(tester);
    final store = _FakeStore(const AppConfig(
      profiles: [Profile(name: 'Standard')],
      activeIndex: 0,
      disclaimerAccepted: false, // nothing persisted yet → genuine fresh install
    ));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(store: store, updateChecker: _noUpdateChecker),
    ));
    await tester.pumpAndSettle();

    expect(store.saved.firstSeenVersionCode, 40);
  });

  testWidgets('a user from before the marker is stamped as pre-marker (0)',
      (tester) async {
    _mockPackageInfo();
    useTallScreen(tester);
    // Disclaimer already accepted → the app was clearly used before the marker
    // shipped, so this user must land below any future paywall versionCode.
    final store = _FakeStore();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(store: store, updateChecker: _noUpdateChecker),
    ));
    await tester.pumpAndSettle();

    expect(store.saved.firstSeenVersionCode, kPreMarkerFirstSeen);
  });

  testWidgets('a sideload build shows the GitHub update banner', (tester) async {
    _mockPackageInfo(); // installerStore null → sideload
    useTallScreen(tester);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(store: _FakeStore(), updateChecker: _newReleaseChecker),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Update v9.9.9 verfügbar'), findsOneWidget);
  });

  testWidgets('a Play build never shows the GitHub APK update banner',
      (tester) async {
    // Play re-signs the bundle, so the GitHub APK cannot install over a Play
    // build — and Play requires updates to come through Play.
    _mockPackageInfo(installerStore: 'com.android.vending');
    useTallScreen(tester);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(store: _FakeStore(), updateChecker: _newReleaseChecker),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Update v9.9.9 verfügbar'), findsNothing);
  });

  testWidgets('⋮ → "Auf Update prüfen" points a Play build at Google Play',
      (tester) async {
    _mockPackageInfo(installerStore: 'com.android.vending');
    useTallScreen(tester);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(store: _FakeStore(), updateChecker: _newReleaseChecker),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>)); // top-right ⋮
    await tester.pumpAndSettle();
    await tester.tap(find.text('Auf Update prüfen'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Updates kommen automatisch über Google Play.'),
        findsOneWidget);
    expect(find.text('Play öffnen'), findsOneWidget); // snackbar action
  });

  testWidgets('warns when testing the connection with an empty host',
      (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    await tester
        .tap(find.widgetWithText(OutlinedButton, 'Verbindung herstellen'));
    await tester.pump(); // surface the SnackBar

    expect(find.text('Bitte Host/IP eintragen.'), findsOneWidget);
  });

  testWidgets('auto-saves the active profile shortly after a field is edited',
      (tester) async {
    useTallScreen(tester);
    final store = _FakeStore();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(store: store, updateChecker: _noUpdateChecker),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Host / IP'), '192.168.1.50');
    await tester.pump(const Duration(seconds: 1)); // past the 800ms debounce

    expect(store.saved.active.host, '192.168.1.50');
  });

  testWidgets('adds a profile from the default config without crashing',
      (tester) async {
    useTallScreen(tester);
    final store = _FakeStore(); // AppConfig.initial → const profiles list
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(store: store, updateChecker: _noUpdateChecker),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('profileSwitcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Profil hinzufügen'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Eltern');
    await tester.tap(find.widgetWithText(FilledButton, 'OK'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1)); // drain the auto-save debounce

    expect(store.saved.profiles.length, 2);
    expect(store.saved.profiles.last.name, 'Eltern');
  });

  testWidgets('opens the bundled open-source licenses page', (tester) async {
    // Extra-tall surface so the footer (bottom of the ListView) is built.
    tester.view.physicalSize = const Size(1080, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open-Source-Lizenzen'));
    await tester.pumpAndSettle();

    expect(find.byType(LicensePage), findsOneWidget);
  });

  testWidgets('the settings sheet scrolls so bottom items are reachable',
      (tester) async {
    // Deliberately SHORT screen so the settings list exceeds the sheet height.
    tester.view.physicalSize = const Size(400, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    // On a 640px-high screen the ⋮ menu is longer than the viewport, so its
    // last item has to be scrolled into view first — the menu itself scrolls
    // (verified here: ensureVisible throws if it does not).
    await tester.ensureVisible(find.text('Einstellungen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Einstellungen'));
    await tester.pumpAndSettle();

    // The last item must be scroll-reachable — ensureVisible throws if the
    // sheet has no Scrollable (the pre-fix bug: content clipped at the bottom).
    await tester.ensureVisible(find.text('evcc-Nightly installieren'));
    await tester.pumpAndSettle();
    expect(find.text('evcc-Nightly installieren'), findsOneWidget);

    // Support entry (mailto kSupportEmail) lives at the sheet's bottom.
    await tester.ensureVisible(find.text('Support kontaktieren'));
    expect(find.text(kSupportEmail), findsOneWidget);

    // The pinned header's close button dismisses the (tall) sheet — no reliance
    // on the phone back button.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('Support kontaktieren'), findsNothing);
  });

  // A snack is drawn by the page's Scaffold — beneath the open settings sheet.
  testWidgets(
      'the lock switch says inside the sheet why it stays off without '
      'biometrics/PIN', (tester) async {
    useTallScreen(tester);
    final store = _FakeStore();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
        store: store,
        updateChecker: _noUpdateChecker,
        authenticator: _NoAuth(),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester
        .tap(find.widgetWithText(PopupMenuItem<String>, 'Einstellungen'));
    await tester.pumpAndSettle();

    final lockSwitch =
        find.widgetWithText(SwitchListTile, 'App mit Biometrie/PIN sperren');
    await tester.tap(lockSwitch);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1)); // past the save debounce

    expect(
        find.descendant(
            of: lockSwitch,
            matching:
                find.text('Keine Biometrie/PIN auf dem Gerät eingerichtet.')),
        findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.widget<SwitchListTile>(lockSwitch).value, isFalse);
    expect(store.saved.lockEnabled, isFalse);
  });

  testWidgets('the ⋮ menu opens the Pi setup guide', (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pi einrichten'));
    await tester.pumpAndSettle();

    // The guide shows the Imager download action.
    expect(find.text('Raspberry Pi Imager laden'), findsOneWidget);
  });

  testWidgets('the app-bar switcher switches the active Pi', (tester) async {
    useTallScreen(tester);
    final store = _FakeStore(const AppConfig(
      profiles: [
        Profile(name: 'Standard', host: '1.1.1.1'),
        Profile(name: 'Eltern', host: '2.2.2.2'),
      ],
      activeIndex: 0,
      disclaimerAccepted: true,
    ));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(store: store, updateChecker: _noUpdateChecker),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('profileSwitcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Eltern')); // the inactive profile in the sheet
    await tester.pumpAndSettle();

    expect(store.saved.activeIndex, 1); // switch persisted immediately
    expect(store.saved.active.host, '2.2.2.2');
  });

  testWidgets('deleting a profile via its ⋮ removes it', (tester) async {
    useTallScreen(tester);
    final store = _FakeStore(const AppConfig(
      profiles: [
        Profile(name: 'Standard', host: '1.1.1.1'),
        Profile(name: 'Eltern', host: '2.2.2.2'),
      ],
      activeIndex: 0,
      disclaimerAccepted: true,
    ));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(store: store, updateChecker: _noUpdateChecker),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('profileSwitcher')));
    await tester.pumpAndSettle();
    // Open the ⋮ on the 'Eltern' row (not the active one) and delete it.
    await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, 'Eltern'),
        matching: find.byIcon(Icons.more_vert)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Löschen'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter')); // confirm
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1)); // drain the save debounce

    expect(store.saved.profiles.length, 1);
    expect(store.saved.profiles.first.name, 'Standard');
  });

  testWidgets('Pi finden fills the host field from a scan result',
      (tester) async {
    useTallScreen(tester);
    final store = _FakeStore();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
        store: store,
        updateChecker: _noUpdateChecker,
        piFinder: () async => ['192.168.178.50'],
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    // Tap the ⋮-menu entry specifically (the prominent scan button shows the
    // same text while the host is empty).
    await tester.tap(
        find.widgetWithText(PopupMenuItem<String>, 'Pi im WLAN suchen'));
    await tester.pumpAndSettle();

    // Results sheet lists the host; tapping it adopts the IP.
    await tester.tap(find.text('192.168.178.50'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1)); // drain the auto-save debounce

    expect(store.saved.active.host, '192.168.178.50');
  });

  testWidgets('offers a prominent network scan when no host is set yet',
      (tester) async {
    useTallScreen(tester);
    final store = _FakeStore(); // fresh config → empty host
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
        store: store,
        updateChecker: _noUpdateChecker,
        piFinder: () async => ['192.168.178.77'],
      ),
    ));
    await tester.pumpAndSettle();

    // The button is shown because the host is empty (first start / new Pi).
    final scanButton =
        find.widgetWithText(OutlinedButton, 'Pi im WLAN suchen');
    expect(scanButton, findsOneWidget);

    await tester.tap(scanButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('192.168.178.77')); // adopt the result
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1)); // drain auto-save debounce

    expect(store.saved.active.host, '192.168.178.77');
    // The block does NOT disappear yet: adopting a scan result fills only the
    // host, so there is still no usable Pi — and the demo entry next to the
    // scan button is the only way into the app. It used to vanish here, which
    // is the dead end Google's reviewer got stuck in (see dispatch_test).
    expect(find.widgetWithText(OutlinedButton, 'Pi im WLAN suchen'),
        findsOneWidget);
    expect(find.byKey(const Key('demoEntry')), findsOneWidget);
  });

  testWidgets('evcc-Status sheet renders live values from the API',
      (tester) async {
    useTallScreen(tester);
    final api = EvccApiClient(getJson: (_) async => {
          'result': {
            'version': '0.123.1',
            'siteTitle': 'Zuhause',
            'pvPower': 2500,
            'gridPower': -1000,
            'homePower': 800,
            'loadpoints': [
              {
                'title': 'Garage',
                'charging': true,
                'chargePower': 11000,
                'vehicleSoc': 62,
                'mode': 'pv',
              }
            ],
          }
        });
    final store = _FakeStore(const AppConfig(
      profiles: [Profile(name: 'Standard', host: '192.168.178.64')],
      activeIndex: 0,
      disclaimerAccepted: true,
    ));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
        store: store,
        updateChecker: _noUpdateChecker,
        apiClient: api,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('evcc-Status (Live)'));
    await tester.pumpAndSettle();

    expect(find.text('Zuhause'), findsOneWidget);
    expect(find.text('Garage'), findsOneWidget);
    expect(find.text('2,5 kW'), findsOneWidget); // PV
  });

  testWidgets('shows the lock screen when app-lock is on and not unlocked',
      (tester) async {
    useTallScreen(tester);
    final store = _FakeStore(const AppConfig(
      profiles: [Profile(name: 'Standard')],
      activeIndex: 0,
      lockEnabled: true,
    ));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
        store: store,
        updateChecker: _noUpdateChecker,
        authenticator: _DenyAuth(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Gesperrt'), findsOneWidget);
    expect(find.text('Entsperren'), findsOneWidget);
    // Branding is the prompt mark, not the old evcc bolt.
    expect(find.byKey(const Key('promptMark')), findsOneWidget);
    expect(find.byIcon(Icons.bolt), findsNothing);
    // Main UI must be hidden behind the lock.
    expect(find.text('evcc aktualisieren'), findsNothing);
  });

  testWidgets('the lock/fingerprint screen stays dark under a light app theme',
      (tester) async {
    useTallScreen(tester);
    final store = _FakeStore(const AppConfig(
      profiles: [Profile(name: 'Standard')],
      activeIndex: 0,
      lockEnabled: true,
    ));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      // Light app theme — the lock screen must NOT follow it (it sits right
      // after the dark splash video).
      theme: ThemeData(brightness: Brightness.light),
      home: UpdaterPage(
        store: store,
        updateChecker: _noUpdateChecker,
        authenticator: _DenyAuth(),
      ),
    ));
    await tester.pumpAndSettle();

    final ctx = tester.element(find.byKey(const Key('promptMark')));
    expect(Theme.of(ctx).brightness, Brightness.dark);
  });

  testWidgets(
      'a locked app never asks to allow screenshots — not even on the way to '
      'the lock screen', (tester) async {
    useTallScreen(tester);
    final secure = _RecordingSecureScreen();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
        // A set-up profile: its connection card starts collapsed, which on its
        // own would mean "screenshots allowed".
        store: _FakeStore(const AppConfig(
          profiles: [Profile(name: 'Standard', host: '1.2.3.4', password: 'pw')],
          activeIndex: 0,
          disclaimerAccepted: true,
          lockEnabled: true,
        )),
        updateChecker: _noUpdateChecker,
        authenticator: _DenyAuth(),
        secureScreen: secure,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Gesperrt'), findsOneWidget);
    expect(secure.calls, isNotEmpty);
    expect(secure.calls, everyElement(isTrue));
  });

  // ---- Startpfad: vor dem Laden wird nichts geschrieben ----

  // Ein Profil, das sich vom eingebauten Startzustand („Standard", Benutzer
  // „pi") unterscheidet. Bewusst ohne Host — diese Tests nutzen den echten
  // Updater.
  const stored = AppConfig(
    profiles: [Profile(name: 'Zuhause', username: 'admin')],
    activeIndex: 0,
    disclaimerAccepted: true,
    firstSeenVersionCode: 40,
  );

  Widget startupPage(AppConfigStore store) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('de'),
        home: UpdaterPage(store: store, updateChecker: _noUpdateChecker),
      );

  // Out to the background and back; ends on `resumed` so later tests start
  // from the normal state. Valid transitions only (the framework asserts them).
  void backgroundAndReturn(WidgetTester tester) {
    for (final s in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
  }

  testWidgets(
      'going to the background before the settings have loaded saves nothing',
      (tester) async {
    _mockPackageInfo();
    useTallScreen(tester);
    final store = _StartupStore(stored, held: true);
    await tester.pumpWidget(startupPage(store));
    await tester.pump();

    // Still loading: the state in memory is the built-in default, and saving
    // it would replace the stored profiles with one empty "Standard".
    backgroundAndReturn(tester);
    await tester.pump();
    expect(store.saveCalls, 0);

    store.gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Verbindung herstellen'), findsOneWidget);

    // Once loaded, the same transition saves again — the loaded profile.
    backgroundAndReturn(tester);
    await tester.pump();
    expect(store.saveCalls, greaterThan(0));
    expect(store.saved!.active.name, 'Zuhause');
    expect(store.saved!.active.username, 'admin');
  });

  testWidgets('leaving the page before the settings have loaded saves nothing',
      (tester) async {
    _mockPackageInfo();
    final store = _StartupStore(stored, held: true);
    await tester.pumpWidget(startupPage(store));
    await tester.pump();

    await tester.pumpWidget(const SizedBox()); // dispose() saves on the way out
    store.gate.complete();
    await tester.pump();

    expect(store.saveCalls, 0);
  });

  testWidgets(
      'a failing settings store shows an error state with a retry, not the '
      'boot mark forever', (tester) async {
    _mockPackageInfo();
    useTallScreen(tester);
    final store = _StartupStore(stored, failures: 2);
    await tester.pumpWidget(startupPage(store));
    await tester.pumpAndSettle();

    expect(find.text('Einstellungen konnten nicht geladen werden'),
        findsOneWidget);
    expect(find.text('Verbindung herstellen'), findsNothing);

    // What is stored is unknown at this point — so nothing may be written.
    backgroundAndReturn(tester);
    await tester.pump();
    expect(store.saveCalls, 0);

    // A retry that fails again stays on the error state …
    await tester.tap(find.widgetWithText(FilledButton, 'Erneut versuchen'));
    await tester.pumpAndSettle();
    expect(store.loadCalls, 2);
    expect(find.text('Einstellungen konnten nicht geladen werden'),
        findsOneWidget);
    expect(store.saveCalls, 0);

    // … and one that succeeds loads the stored settings.
    await tester.tap(find.widgetWithText(FilledButton, 'Erneut versuchen'));
    await tester.pumpAndSettle();
    expect(store.loadCalls, 3);
    expect(find.text('Einstellungen konnten nicht geladen werden'),
        findsNothing);
    expect(find.text('Verbindung herstellen'), findsOneWidget);
    expect(find.text('Zuhause'), findsOneWidget); // the loaded profile's name
  });

  // Secure storage no longer deletes what it cannot decrypt (resetOnError is
  // off), so a storage that stays unreadable needs a way out the user takes
  // knowingly.
  const resetButton = 'Gespeicherte Daten zurücksetzen';
  const loadFailedTitle = 'Einstellungen konnten nicht geladen werden';

  testWidgets(
      'the error state offers a reset behind a confirmation that says what is '
      'lost; confirmed, it deletes the stored data and starts like a first run',
      (tester) async {
    _mockPackageInfo();
    useTallScreen(tester);
    final store = _StartupStore(stored, failures: 99);
    await tester.pumpWidget(startupPage(store));
    await tester.pumpAndSettle();
    expect(find.text(loadFailedTitle), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, resetButton));
    await tester.pumpAndSettle();

    // The confirmation names the consequence and the way back.
    expect(find.text('Gespeicherte Daten zurücksetzen?'), findsOneWidget);
    final body = find.textContaining('Profile samt Passwörtern und SSH-Keys');
    expect(body, findsOneWidget);
    final bodyText = tester.widget<Text>(body).data!;
    expect(bodyText, contains('Das kann nicht rückgängig gemacht werden.'));
    expect(bodyText, contains('Einstellungen → „Profile importieren“'));
    // … and that a retry after a device restart comes first.
    expect(bodyText, contains('vor dem Zurücksetzen das Gerät neu starten'));

    // Cancelled: nothing is deleted, nothing is read or written.
    await tester.tap(find.widgetWithText(TextButton, 'Abbrechen'));
    await tester.pumpAndSettle();
    expect(store.resetCalls, 0);
    expect(store.loadCalls, 1);
    expect(find.text(loadFailedTitle), findsOneWidget);

    // Confirmed: the stored data is deleted, then read again.
    await tester.tap(find.widgetWithText(TextButton, resetButton));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Zurücksetzen'));
    await tester.pumpAndSettle();
    expect(store.resetCalls, 1);
    expect(store.loadCalls, 2);
    expect(find.text(loadFailedTitle), findsNothing);
    expect(find.text('Willkommen bei Pi-Tool'), findsOneWidget); // first run
  });

  testWidgets(
      'a reset that fails as well stays on the error state, says so and '
      'writes nothing', (tester) async {
    _mockPackageInfo();
    useTallScreen(tester);
    final store = _StartupStore(stored, failures: 99)..resetFails = true;
    await tester.pumpWidget(startupPage(store));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, resetButton));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Zurücksetzen'));
    await tester.pumpAndSettle();

    expect(store.resetCalls, 1);
    expect(store.loadCalls, 1); // nothing to read again
    expect(store.saveCalls, 0);
    expect(find.text(loadFailedTitle), findsOneWidget);
    expect(find.textContaining('Zurücksetzen fehlgeschlagen.'), findsOneWidget);
    // Both ways on are still there.
    expect(find.widgetWithText(FilledButton, 'Erneut versuchen'),
        findsOneWidget);
    expect(find.widgetWithText(TextButton, resetButton), findsOneWidget);
  });

  // ---- Verlauf ----

  const twoPis = AppConfig(
    profiles: [
      Profile(name: 'Keller', host: '192.0.2.10', password: 'pw'),
      Profile(name: 'Garage', host: '192.0.2.11', password: 'pw'),
    ],
    activeIndex: 0,
    disclaimerAccepted: true,
  );
  const onePi = AppConfig(
    profiles: [Profile(name: 'Keller', host: '192.0.2.10', password: 'pw')],
    activeIndex: 0,
    disclaimerAccepted: true,
  );
  const tagged = HistoryEntry(
      when: '2026-10-09 08:15',
      text: 'Pi-hole aktualisiert.',
      profile: 'Garage');
  const untagged =
      HistoryEntry(when: '2026-06-29 14:00', text: 'evcc 0.1 → 0.2');

  // The addresses are from the documentation range; the fake updater never
  // opens a connection.
  Widget historyPage(AppConfig config, HistoryStore history,
          {EvccUpdater? updater}) =>
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('de'),
        home: UpdaterPage(
          store: _FakeStore(config),
          updater: updater ?? _RebootUpdater(),
          updateChecker: _noUpdateChecker,
          historyStore: history,
          apiClient: EvccApiClient(
              getJson: (_) async =>
                  throw const EvccApiException('kein Netz im Test')),
          evccReleaseFetcher: () async => null,
          haVersionFetcher: () async => null,
        ),
      );

  Future<void> openMenuItem(WidgetTester tester, String item) async {
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, item));
    await tester.pumpAndSettle();
  }

  testWidgets('with several profiles the history names the Pi of an entry',
      (tester) async {
    _mockPackageInfo();
    useTallScreen(tester);
    await tester.pumpWidget(
        historyPage(twoPis, _MemoryHistory([untagged, tagged])));
    await tester.pumpAndSettle();

    await openMenuItem(tester, 'Verlauf');

    expect(find.text('2026-10-09 08:15 · Garage'), findsOneWidget);
    // An entry from before the profile was recorded shows its time alone.
    expect(find.text('2026-06-29 14:00'), findsOneWidget);
  });

  testWidgets('with a single profile the history shows the time alone',
      (tester) async {
    _mockPackageInfo();
    useTallScreen(tester);
    await tester
        .pumpWidget(historyPage(onePi, _MemoryHistory([untagged, tagged])));
    await tester.pumpAndSettle();

    await openMenuItem(tester, 'Verlauf');

    expect(find.text('2026-10-09 08:15'), findsOneWidget);
    expect(find.textContaining('Garage'), findsNothing);
  });

  testWidgets('an action is recorded with the Pi it ran on', (tester) async {
    _mockPackageInfo();
    useTallScreen(tester);
    final history = _MemoryHistory();
    final updater = _RebootUpdater();
    await tester.pumpWidget(historyPage(twoPis, history, updater: updater));
    await tester.pumpAndSettle();

    await tester
        .tap(find.widgetWithText(OutlinedButton, 'Verbindung herstellen'));
    await tester.pumpAndSettle();
    await openMenuItem(tester, 'Pi neu starten');
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();

    expect(updater.reboots, 1);
    expect(history.entries.single.text, 'Pi-Neustart ausgelöst.');
    expect(history.entries.single.profile, 'Keller'); // the active profile
  });

  testWidgets(
      'a history that cannot be read does not turn an action that worked '
      'into an error', (tester) async {
    _mockPackageInfo();
    useTallScreen(tester);
    final history = _MemoryHistory([untagged])..unreadable = true;
    final updater = _RebootUpdater();
    await tester.pumpWidget(historyPage(onePi, history, updater: updater));
    await tester.pumpAndSettle();

    await tester
        .tap(find.widgetWithText(OutlinedButton, 'Verbindung herstellen'));
    await tester.pumpAndSettle();
    await openMenuItem(tester, 'Pi neu starten');
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();

    // The failed add is nobody's unhandled error (the test would fail on it),
    // the action's own result stands, and the stored list is as it was.
    expect(updater.reboots, 1);
    expect(find.textContaining('Neustart ausgelöst'), findsWidgets);
    expect(history.entries, [untagged]);
  });

  testWidgets(
      'a history that cannot be read says so instead of "no history yet", and '
      'clearing it is the way back', (tester) async {
    _mockPackageInfo();
    useTallScreen(tester);
    final history = _MemoryHistory([untagged])..unreadable = true;
    await tester.pumpWidget(historyPage(onePi, history));
    await tester.pumpAndSettle();

    await openMenuItem(tester, 'Verlauf');

    expect(find.text('Der Verlauf ließ sich nicht lesen.'), findsOneWidget);
    expect(find.text('Noch kein Verlauf.'), findsNothing);
    expect(history.entries, [untagged]); // nothing written over it

    await tester.tap(find.widgetWithText(SnackBarAction, 'Leeren'));
    await tester.pumpAndSettle();
    expect(history.unreadable, isFalse);

    await openMenuItem(tester, 'Verlauf');
    expect(find.text('Noch kein Verlauf.'), findsOneWidget);
  });

  // ---- Teilen: die Temp-Datei bleibt nicht im App-Cache liegen ----

  group('shareTemporaryFile', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('pitool_share_'));
    tearDown(() => dir.deleteSync(recursive: true));

    final bytes = Uint8List.fromList([1, 2, 3, 4]);

    test('the file is there while it is shared and gone once that returns',
        () async {
      String? shared;
      List<int>? seen;

      await shareTemporaryFile('pihole-backup.zip', bytes, dir: dir,
          share: (path) async {
        shared = path;
        seen = File(path).readAsBytesSync();
      });

      expect(shared, '${dir.path}/pihole-backup.zip');
      expect(seen, [1, 2, 3, 4]);
      expect(dir.listSync(), isEmpty);
    });

    test('a share that fails leaves no file behind either, and still fails',
        () async {
      await expectLater(
          shareTemporaryFile('pihole-backup.zip', bytes,
              dir: dir,
              share: (_) async =>
                  throw PlatformException(code: 'Share failed')),
          throwsA(isA<PlatformException>()));

      expect(dir.listSync(), isEmpty);
    });

    test('a file that could not even be written is reported as that',
        () async {
      var shared = false;
      final missing = Directory('${dir.path}/gone');

      await expectLater(
          shareTemporaryFile('pihole-backup.zip', bytes,
              dir: missing, share: (_) async => shared = true),
          throwsA(isA<FileSystemException>()));

      expect(shared, isFalse);
    });
  });

  // ---- App lock without the lock layer ----

  // The app draws the lock above the Navigator and keeps every route beneath
  // it (app_lock_test.dart). A page pumped on its own, as in this file, has no
  // such layer: locked, it must keep its content — and what it opened — away
  // by itself.
  testWidgets(
      'without the lock layer the page draws the lock in its route and closes '
      'what lies above it', (tester) async {
    _mockPackageInfo();
    useTallScreen(tester);
    final auth = _SwitchAuth();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
        store: _FakeStore(const AppConfig(
          profiles: [Profile(name: 'Standard')],
          activeIndex: 0,
          disclaimerAccepted: true,
          lockEnabled: true,
        )),
        updateChecker: _noUpdateChecker,
        authenticator: auth,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Entsperren'), findsNothing); // the prompt went through

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester
        .tap(find.widgetWithText(PopupMenuItem<String>, 'Einstellungen'));
    await tester.pumpAndSettle();
    expect(find.text('App mit Biometrie/PIN sperren'), findsOneWidget);

    auth.allow = false;
    backgroundAndReturn(tester);
    await tester.pumpAndSettle();

    expect(find.text('Entsperren'), findsOneWidget);
    expect(find.text('Verbindung herstellen'), findsNothing);
    expect(find.text('App mit Biometrie/PIN sperren', skipOffstage: false),
        findsNothing);

    // Unlocking brings the page back — without the sheet.
    auth.allow = true;
    await tester.tap(find.text('Entsperren'));
    await tester.pumpAndSettle();
    expect(find.text('Verbindung herstellen'), findsOneWidget);
    expect(find.text('App mit Biometrie/PIN sperren'), findsNothing);
  });
}
