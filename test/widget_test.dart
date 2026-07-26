import 'package:evcc_updater/main.dart';
import 'package:evcc_updater/src/l10n.dart';
import 'package:evcc_updater/src/authenticator.dart';
import 'package:evcc_updater/src/evcc_api.dart';
import 'package:evcc_updater/src/kyth_wordmark.dart';
import 'package:evcc_updater/src/profiles.dart';
import 'package:evcc_updater/src/update_check.dart';
import 'package:flutter/material.dart';
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

/// Authenticator that is available but always denies — keeps the app locked.
class _DenyAuth implements Authenticator {
  @override
  Future<bool> canAuthenticate() async => true;

  @override
  Future<bool> authenticate(String reason) async => false;
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
  });

  testWidgets('⋮ → "Auf Update prüfen" reports up to date on the current version',
      (tester) async {
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

    await tester.tap(find.byType(PopupMenuButton<String>)); // top-right ⋮
    await tester.pumpAndSettle();
    await tester.tap(find.text('Auf Update prüfen'));
    await tester.pump(); // kick off the async check
    await tester.pump(const Duration(milliseconds: 300)); // resolve + snackbar
    expect(find.text('Aktuell – du hast die neueste Version (v0.21.2).'),
        findsOneWidget);
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
    // Once a host is set, the prominent button disappears.
    expect(find.widgetWithText(OutlinedButton, 'Pi im WLAN suchen'),
        findsNothing);
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
}
