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
import 'package:evcc_updater/src/l10n.dart';

import 'package:evcc_updater/main.dart';
import 'package:evcc_updater/src/evcc_updater.dart';
import 'package:evcc_updater/src/profiles.dart';
import 'package:evcc_updater/src/services/pi_service.dart';
import 'package:evcc_updater/src/ssh_runner.dart';
import 'package:evcc_updater/src/update_check.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Every font comes from the Flutter SDK itself. The previous build pointed at a
// throwaway scratch directory, and those files were gone by the next session —
// the generator then failed for a reason that had nothing to do with the app.
const _sdkFonts =
    r'C:\Users\stefa\flutterdev\flutter\bin\cache\artifacts\material_fonts';
const _materialIcons = '$_sdkFonts\\materialicons-regular.otf';

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

/// English detail lines for the English screenshot set (the detail/health text
/// comes from the Pi and isn't localized by the app, so the fixtures provide it).
const _richServicesEn = <ServiceStatus>[
  ServiceStatus(id: 'evcc', name: 'evcc', installed: true, version: '0.310.0', active: true, updateKnown: true, detail: 'apt · service active'),
  ServiceStatus(id: 'pihole', name: 'Pi-hole', installed: true, version: 'v6.0.4', active: true, detail: 'service active · DNS ok'),
  ServiceStatus(id: 'homeassistant', name: 'Home Assistant', installed: true, version: '2026.6', active: true, detail: 'Docker · active'),
  ServiceStatus(id: 'tailscale', name: 'Tailscale', installed: true, version: '100.101.102.103', active: true, detail: 'connected · remote access'),
  ServiceStatus(id: 'adguard', name: 'AdGuard Home', installed: true, version: 'v0.107.68', active: true, detail: 'service active'),
  ServiceStatus(id: 'system', name: 'System (Pi)', installed: true, version: 'Debian 12', active: true, updateKnown: true, updateAvailable: true, detail: '3 updates available', health: '48 °C · 62% free · 1.4 GB RAM · Up 12d'),
];
const _healthyServicesEn = <ServiceStatus>[
  ServiceStatus(id: 'evcc', name: 'evcc', installed: true, version: '0.310.0', active: true, updateKnown: true, detail: 'apt · service active'),
  ServiceStatus(id: 'system', name: 'System (Pi)', installed: true, version: 'Debian 12', active: true, updateKnown: true, detail: 'up to date', health: '39 °C · 78% free · 0.9 GB RAM · Up 43d'),
];

class _ShotUpdater extends EvccUpdater {
  _ShotUpdater([this.lang = 'de']) : super(runnerFactory: _noRunner);
  final String lang;
  static SshRunner _noRunner(SshConfig c) => throw UnimplementedError();

  @override
  Future<List<ServiceStatus>> detectServices({
    required SshConfig config,
    required void Function(String line) onLog,
    bool allowSudoForDocker = true,
    void Function()? onConnected,
  }) async {
    onConnected?.call();
    final en = lang == 'en';
    // Keller-Pi (…​.51) is up to date; the active Wohnzimmer-Pi has updates.
    if (config.host.endsWith('.51')) {
      return en ? _healthyServicesEn : _healthyServices;
    }
    return en ? _richServicesEn : _richServices;
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
    await _loadFont('Roboto', '$_sdkFonts\\roboto-regular.ttf');
    await _loadFont('monospace', '$_sdkFonts\\robotocondensed-regular.ttf');
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

  /// Wraps a rendered app frame in a caption band for the FIRST store
  /// screenshots. Someone arriving from a forum post decides in about three
  /// seconds, and a bare app screenshot makes them work out what they are
  /// looking at. The line says it for them; the app below proves it.
  ///
  /// Same 1080x2160 frame — the band takes its height from the app view, it is
  /// not added on top, so the 2:1 ratio Play requires still holds.
  Widget captioned(Widget child, String headline, String sub) => Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        key: const Key('shot'), // capture THIS, not just the app inside
        color: const Color(0xFF0A0A0B), // CI black, same as the legal pages
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 34, 28, 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    headline,
                    style: const TextStyle(
                      fontFamily: 'Bricolage Grotesque',
                      fontSize: 34,
                      height: 1.15,
                      letterSpacing: -0.8,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFFFFFFF),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    sub,
                    style: const TextStyle(
                      fontFamily: 'Roboto',
                      fontSize: 15,
                      height: 1.45,
                      color: Color(0xFF22C55E), // CI green
                    ),
                  ),
                ],
              ),
            ),
            // The app itself, clipped to whatever height is left.
            Expanded(child: ClipRect(child: child)),
          ],
        ),
      ));

  Widget app(EvccUpdater u, {Locale locale = const Locale('de')}) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      debugShowCheckedModeBanner: false,
      // The REAL app theme (single source of truth) — only the bundled test
      // font is injected so the goldens render text.
      theme: buildAppTheme(Brightness.dark, fontFamily: 'Roboto'),
      home: UpdaterPage(
          store: _ShotStore(_config), updater: u, updateChecker: _noUpdate),
    );
  }

  // Generate BOTH a German and an English set → shots/de/* and shots/en/*.
  // Tab switches use icons (locale-independent); button/menu taps use the
  // per-locale labels below.
  const sets = <({
    String lang,
    String connect,
    String addService,
    String allPis,
    String heroHead,
    String heroSub,
    String updHead,
    String updSub,
  })>[
    (
      lang: 'de',
      connect: 'Verbindung herstellen',
      addService: 'Dienst hinzufügen',
      allPis: 'Alle Pis (Überblick)',
      // Erste Zeile = das Versprechen, nicht der Funktionsumfang.
      heroHead: 'Dein Raspberry Pi,\nvom Sofa aus',
      heroSub: 'Verbinden — die App erkennt selbst, was läuft.',
      updHead: 'Updates mit\neinem Tipp',
      updSub: 'Backup davor — evcc, Pi-hole, Home Assistant, Docker.',
    ),
    (
      lang: 'en',
      connect: 'Connect',
      addService: 'Add service',
      allPis: 'All Pis (overview)',
      heroHead: 'Your Raspberry Pi,\nfrom the couch',
      heroSub: 'Connect — the app finds what is running by itself.',
      updHead: 'Updates in\none tap',
      updSub: 'With a backup first — evcc, Pi-hole, Home Assistant, Docker.',
    ),
  ];

  for (final s in sets) {
    final loc = Locale(s.lang);
    final dir = 'shots/${s.lang}';

    Future<void> connect(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(OutlinedButton, s.connect));
      await tester.pumpAndSettle();
    }

    // --- The two the store shows first, with a statement line on top. ---
    testWidgets('[${s.lang}] 00a hero (captioned)', (tester) async {
      phone(tester);
      await tester.pumpWidget(captioned(
          app(_ShotUpdater(s.lang), locale: loc), s.heroHead, s.heroSub));
      await tester.pumpAndSettle();
      await connect(tester);
      await expectLater(
          find.byKey(const Key('shot')), matchesGoldenFile('$dir/00a_hero.png'));
    });

    testWidgets('[${s.lang}] 00b updates (captioned)', (tester) async {
      phone(tester);
      await tester.pumpWidget(captioned(
          app(_ShotUpdater(s.lang), locale: loc), s.updHead, s.updSub));
      await tester.pumpAndSettle();
      await connect(tester);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -880));
      await tester.pumpAndSettle();
      await expectLater(find.byKey(const Key('shot')),
          matchesGoldenFile('$dir/00b_updates.png'));
    });

    testWidgets('[${s.lang}] 01 cockpit', (tester) async {
      phone(tester);
      await tester.pumpWidget(app(_ShotUpdater(s.lang), locale: loc));
      await tester.pumpAndSettle();
      await connect(tester);
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('$dir/01_cockpit.png'));
    });

    testWidgets('[${s.lang}] 02 services', (tester) async {
      phone(tester);
      await tester.pumpWidget(app(_ShotUpdater(s.lang), locale: loc));
      await tester.pumpAndSettle();
      await connect(tester);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -720));
      await tester.pumpAndSettle();
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('$dir/02_services.png'));
    });

    testWidgets('[${s.lang}] 03 add-service picker', (tester) async {
      phone(tester);
      await tester.pumpWidget(app(_ShotUpdater(s.lang), locale: loc));
      await tester.pumpAndSettle();
      await connect(tester);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -720));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining(s.addService).first);
      await tester.pumpAndSettle();
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('$dir/03_add.png'));
    });

    testWidgets('[${s.lang}] 04 automatik tab', (tester) async {
      phone(tester);
      await tester.pumpWidget(app(_ShotUpdater(s.lang), locale: loc));
      await tester.pumpAndSettle();
      await connect(tester);
      await tester.tap(find.byIcon(Icons.bolt_outlined));
      await tester.pumpAndSettle();
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('$dir/04_automatik.png'));
    });

    testWidgets('[${s.lang}] 05 terminal tab', (tester) async {
      phone(tester);
      await tester.pumpWidget(app(_ShotUpdater(s.lang), locale: loc));
      await tester.pumpAndSettle();
      await connect(tester);
      await tester.tap(find.byIcon(Icons.terminal_outlined));
      await tester.pumpAndSettle();
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('$dir/05_terminal.png'));
    });

    testWidgets('[${s.lang}] 06 multi-pi overview', (tester) async {
      phone(tester);
      await tester.pumpWidget(app(_ShotUpdater(s.lang), locale: loc));
      await tester.pumpAndSettle();
      await connect(tester);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(s.allPis));
      await tester.pumpAndSettle();
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('$dir/06_multipi.png'));
    });
  }
}
