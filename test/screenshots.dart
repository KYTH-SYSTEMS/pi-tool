// Manual store-screenshot generator (NOT a CI test — the filename deliberately
// lacks the `_test.dart` suffix so `flutter test` skips it). It renders the app
// with fake data (no real Pi, no emulator) and captures PNGs. Run:
//   flutter test test/screenshots.dart --update-goldens
// Output PNGs land in test/shots/ (git-ignored); the chosen ones are copied to
// fastlane/…/images/phoneScreenshots/.
//
// Prerequisite: three font files must exist at the paths in the consts below —
// MaterialIcons (Flutter SDK), Roboto + Roboto Mono (fetch from google/fonts),
// Bricolage (already in assets/fonts). Adjust the absolute paths per machine.
@Tags(['screenshots'])
library;

import 'dart:io';

import 'package:evcc_updater/main.dart';
import 'package:evcc_updater/src/evcc_updater.dart';
import 'package:evcc_updater/src/profiles.dart';
import 'package:evcc_updater/src/services/pi_service.dart';
import 'package:evcc_updater/src/ssh_runner.dart';
import 'package:evcc_updater/src/update_check.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _scratch =
    r'C:\Users\stefa\AppData\Local\Temp\claude\C--EVCC-Updater\79a77802-f206-4f4d-bc62-b61342f0388e\scratchpad';
const _materialIcons =
    r'C:\Users\stefa\flutterdev\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf';

Future<void> _loadFont(String family, String path) async {
  final bytes = await File(path).readAsBytes();
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.sublistView(bytes)));
  await loader.load();
}

/// Rich, realistic detection result for a well-populated cockpit.
const _richServices = <ServiceStatus>[
  ServiceStatus(
      id: 'evcc',
      name: 'evcc',
      installed: true,
      version: '0.310.0',
      active: true,
      updateKnown: true,
      detail: 'apt · Dienst aktiv'),
  ServiceStatus(
      id: 'pihole',
      name: 'Pi-hole',
      installed: true,
      version: 'v6.0.4',
      active: true,
      detail: 'Dienst aktiv · DNS ok'),
  ServiceStatus(
      id: 'homeassistant',
      name: 'Home Assistant',
      installed: true,
      version: '2026.6',
      active: true,
      detail: 'Docker · aktiv'),
  ServiceStatus(
      id: 'tailscale',
      name: 'Tailscale',
      installed: true,
      version: '100.101.102.103',
      active: true,
      detail: 'verbunden · Fernzugriff'),
  ServiceStatus(
      id: 'adguard',
      name: 'AdGuard Home',
      installed: true,
      version: 'v0.107.68',
      active: true,
      detail: 'Dienst aktiv'),
  ServiceStatus(
      id: 'system',
      name: 'System (Pi)',
      installed: true,
      version: 'Debian 12',
      active: true,
      updateKnown: true,
      updateAvailable: true,
      detail: '3 Updates verfügbar',
      health: '48 °C · 62 % frei · 1,4 GB RAM · Up 12 T'),
];

/// A second Pi that is fully up to date → shows GREEN in the "All Pis" overview,
/// so the traffic light isn't monotone (the active Pi above has updates = amber).
const _healthyServices = <ServiceStatus>[
  ServiceStatus(
      id: 'evcc',
      name: 'evcc',
      installed: true,
      version: '0.310.0',
      active: true,
      updateKnown: true,
      detail: 'apt · Dienst aktiv'),
  ServiceStatus(
      id: 'system',
      name: 'System (Pi)',
      installed: true,
      version: 'Debian 12',
      active: true,
      updateKnown: true,
      detail: 'aktuell',
      health: '39 °C · 78 % frei · 0,9 GB RAM · Up 43 T'),
];

class _ShotUpdater extends EvccUpdater {
  _ShotUpdater() : super(runnerFactory: _noRunner);
  static SshRunner _noRunner(SshConfig c) => throw UnimplementedError();

  @override
  Future<List<ServiceStatus>> detectServices({
    required SshConfig config,
    required void Function(String line) onLog,
    bool allowSudoForDocker = true,
    void Function()? onConnected,
  }) async {
    onConnected?.call();
    // Keller-Pi (…​.51) is up to date; the active Wohnzimmer-Pi has updates.
    if (config.host.endsWith('.51')) return _healthyServices;
    return _richServices;
  }
}

class _ShotStore extends AppConfigStore {
  _ShotStore(this._c);
  final AppConfig _c;
  @override
  Future<AppConfig> load() async => _c;
  @override
  Future<void> save(AppConfig c) async {}
}

final _noUpdate = UpdateChecker(getJson: (_) async => <String, dynamic>{});

const _config = AppConfig(
  profiles: [
    Profile(name: 'Wohnzimmer-Pi', host: '192.168.1.50', password: 'x'),
    Profile(name: 'Keller-Pi', host: '192.168.1.51', password: 'x'),
  ],
  activeIndex: 0,
  disclaimerAccepted: true,
);

void main() {
  setUpAll(() async {
    await _loadFont('Roboto', '$_scratch\\Roboto.ttf');
    await _loadFont('monospace', '$_scratch\\RobotoMono.ttf');
    await _loadFont('Bricolage Grotesque', 'assets/fonts/BricolageGrotesque.ttf');
    await _loadFont('MaterialIcons', _materialIcons);
  });

  void phone(WidgetTester tester) {
    // 1080x2160 = exactly 2:1 — the max aspect ratio Google Play allows for
    // phone screenshots (longer side ≤ 2× shorter side).
    tester.view.physicalSize = const Size(1080, 2160);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget app(EvccUpdater u) {
    final scheme = ColorScheme.fromSeed(
            seedColor: const Color(0xFF1FD65F), brightness: Brightness.dark)
        .copyWith(
            primary: const Color(0xFF1FD65F),
            onPrimary: Colors.black,
            surface: const Color(0xFF0B0E0C));
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFF0B0E0C),
        fontFamily: 'Roboto',
        appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF0B0E0C),
            foregroundColor: Colors.white,
            elevation: 0),
      ),
      home: UpdaterPage(
          store: _ShotStore(_config), updater: u, updateChecker: _noUpdate),
    );
  }

  Future<void> connect(WidgetTester tester) async {
    await tester
        .tap(find.widgetWithText(OutlinedButton, 'Verbindung herstellen'));
    await tester.pumpAndSettle();
  }

  testWidgets('01 cockpit top (connect + status)', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(_ShotUpdater()));
    await tester.pumpAndSettle();
    await connect(tester);
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('shots/01_cockpit.png'));
  });

  testWidgets('02 services (scrolled to cards)', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(_ShotUpdater()));
    await tester.pumpAndSettle();
    await connect(tester);
    // Scroll past the connection card so the service cards fill the frame.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -720));
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('shots/02_services.png'));
  });

  testWidgets('03 add-service picker', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(_ShotUpdater()));
    await tester.pumpAndSettle();
    await connect(tester);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -720));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Dienst hinzufügen').first);
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('shots/03_add.png'));
  });

  testWidgets('04 automatik tab', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(_ShotUpdater()));
    await tester.pumpAndSettle();
    await connect(tester);
    await tester.tap(find.text('Automatik'));
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('shots/04_automatik.png'));
  });

  testWidgets('05 terminal tab', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(_ShotUpdater()));
    await tester.pumpAndSettle();
    await connect(tester);
    await tester.tap(find.text('Terminal'));
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('shots/05_terminal.png'));
  });

  testWidgets('06 multi-pi overview', (tester) async {
    phone(tester);
    await tester.pumpWidget(app(_ShotUpdater()));
    await tester.pumpAndSettle();
    await connect(tester);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alle Pis (Überblick)'));
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('shots/06_multipi.png'));
  });
}
