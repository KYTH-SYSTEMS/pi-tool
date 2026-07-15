import 'package:evcc_updater/main.dart';
import 'package:evcc_updater/src/l10n.dart';
import 'package:evcc_updater/src/profiles.dart';
import 'package:evcc_updater/src/update_check.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory store so the app boots straight onto the cockpit (no platform).
class _FakeStore extends AppConfigStore {
  @override
  Future<AppConfig> load() async => const AppConfig(
        profiles: [Profile(name: 'Standard')],
        activeIndex: 0,
        disclaimerAccepted: true,
      );
  @override
  Future<void> save(AppConfig c) async {}
}

void main() {
  testWidgets('English locale renders the whole UI in English', (tester) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: UpdaterPage(
        store: _FakeStore(),
        updateChecker: UpdateChecker(getJson: (_) async => <String, dynamic>{}),
      ),
    ));
    await tester.pumpAndSettle();

    // Bottom-nav + connect button render in English, not German.
    expect(find.text('Management'), findsOneWidget); // tab „Verwaltung"
    expect(find.text('Connect'), findsWidgets); // „Verbindung herstellen"
    expect(find.text('Verwaltung'), findsNothing);
    expect(find.text('Verbindung herstellen'), findsNothing);
  });
}
