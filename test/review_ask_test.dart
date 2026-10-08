// When the app asks Google Play for its in-app review card: the wiring of
// review_prompt.dart into the page. The decision itself is unit-tested in
// review_prompt_test.dart; here it is about the moment (after an action that
// worked), the bookkeeping, and that nothing but a Play build ever asks.
import 'package:evcc_updater/main.dart';
import 'package:evcc_updater/src/evcc_api.dart';
import 'package:evcc_updater/src/evcc_updater.dart';
import 'package:evcc_updater/src/files.dart';
import 'package:evcc_updater/src/history.dart';
import 'package:evcc_updater/src/l10n.dart';
import 'package:evcc_updater/src/profiles.dart';
import 'package:evcc_updater/src/review_prompt.dart';
import 'package:evcc_updater/src/services/pi_service.dart';
import 'package:evcc_updater/src/settings_store.dart';
import 'package:evcc_updater/src/ssh_runner.dart';
import 'package:evcc_updater/src/update_check.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Store extends AppConfigStore {
  _Store(this._initial);
  final AppConfig _initial;
  AppConfig? saved;
  @override
  Future<AppConfig> load() async => _initial;
  @override
  Future<void> save(AppConfig c) async => saved = c;
}

class _History extends HistoryStore {
  final added = <String>[];
  @override
  Future<List<HistoryEntry>> load() async => const [];
  @override
  Future<void> add(HistoryEntry entry) async => added.add(entry.text);
  @override
  Future<void> clear() async => added.clear();
}

class _Review implements ReviewRequester {
  int calls = 0;
  @override
  Future<bool> request() async {
    calls++;
    return true;
  }
}

/// Just enough updater for "connect, then restart the evcc service".
class _Updater extends EvccUpdater {
  _Updater() : super(runnerFactory: _noRunner);
  static SshRunner _noRunner(SshConfig c) => throw UnimplementedError();

  Object? restartError;

  @override
  Future<List<ServiceStatus>> detectServices({
    required SshConfig config,
    required void Function(String line) onLog,
    bool allowSudoForDocker = true,
    void Function()? onConnected,
  }) async {
    onConnected?.call();
    return const [
      ServiceStatus(
          id: 'evcc',
          name: 'evcc',
          installed: true,
          version: '0.310.0',
          active: true,
          detail: 'apt · Dienst aktiv'),
    ];
  }

  @override
  Future<void> restartService({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async {
    if (restartError != null) throw restartError!;
  }

  @override
  Future<List<DirEntry>> listDir({
    required SshConfig config,
    required String path,
    required void Function(String line) onLog,
  }) async =>
      const [];
}

final _now = DateTime(2026, 10, 20, 12);

/// Two successes on record, the first long enough ago: the next one is the
/// third and makes the ask due.
final _almostDue = ReviewPromptState.initial
    .recordSuccess(_now.subtract(const Duration(days: 10)))
    .recordSuccess(_now.subtract(const Duration(days: 9)));

AppConfig _config(ReviewPromptState review) => AppConfig(
      profiles: const [
        Profile(name: 'S', host: '192.168.178.64', password: 'pw')
      ],
      activeIndex: 0,
      disclaimerAccepted: true,
      reviewPrompt: review,
    );

void main() {
  Future<void> open(
    WidgetTester tester, {
    required _Store store,
    required _Review review,
    required InstallChannel channel,
    _Updater? updater,
    DateTime Function()? clock,
  }) async {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
        store: store,
        updater: updater ?? _Updater(),
        updateChecker: UpdateChecker(getJson: (_) async => <String, dynamic>{}),
        historyStore: _History(),
        apiClient: EvccApiClient(
            getJson: (_) async =>
                throw const EvccApiException('kein Netz im Test')),
        evccReleaseFetcher: () async => null,
        haVersionFetcher: () async => null,
        reviewRequester: review,
        installChannel: channel,
        clock: clock ?? () => _now,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> connect(WidgetTester tester) async {
    await tester
        .tap(find.widgetWithText(OutlinedButton, 'Verbindung herstellen'));
    await tester.pumpAndSettle();
  }

  Future<void> restartEvcc(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('menu-evcc')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dienst neu starten'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();
  }

  testWidgets('Play-Build: nach der Aktion, die die Schwelle erreicht, geht '
      'genau eine Anfrage an Play', (tester) async {
    final store = _Store(_config(_almostDue));
    final review = _Review();
    await open(tester,
        store: store, review: review, channel: InstallChannel.play);

    await connect(tester);
    expect(review.calls, 0); // connecting is not an action that counts

    await restartEvcc(tester);
    expect(find.text('evcc-Dienst neu gestartet.'), findsOneWidget);
    expect(review.calls, 1);
    // Recorded, so a card Play swallowed is not asked for again right away.
    expect(store.saved!.reviewPrompt.successes, 3);
    expect(store.saved!.reviewPrompt.asks, 1);
    expect(store.saved!.reviewPrompt.lastAskedAt, _now);

    await restartEvcc(tester);
    expect(review.calls, 1); // cooldown
    expect(store.saved!.reviewPrompt.successes, 4);
  });

  testWidgets('vor der Schwelle wird nur gezählt', (tester) async {
    final store = _Store(_config(ReviewPromptState.initial));
    final review = _Review();
    await open(tester,
        store: store, review: review, channel: InstallChannel.play);
    await connect(tester);
    await restartEvcc(tester);

    expect(review.calls, 0);
    expect(store.saved!.reviewPrompt.successes, 1);
    expect(store.saved!.reviewPrompt.firstSuccessAt, _now);
    expect(store.saved!.reviewPrompt.asks, 0);
  });

  testWidgets('Sideload-Build fragt nie – dort gibt es die Play-Karte nicht',
      (tester) async {
    final store = _Store(_config(_almostDue));
    final review = _Review();
    await open(tester,
        store: store, review: review, channel: InstallChannel.sideload);
    await connect(tester);
    await restartEvcc(tester);

    expect(review.calls, 0);
    expect(store.saved!.reviewPrompt.asks, 0);
  });

  testWidgets('eine gescheiterte Aktion zählt nicht und fragt nicht',
      (tester) async {
    final store = _Store(_config(_almostDue));
    final review = _Review();
    await open(tester,
        store: store,
        review: review,
        channel: InstallChannel.play,
        updater: _Updater()
          ..restartError = const EvccUpdateException(
              UpdateErrorKind.unknown, 'Neustart fehlgeschlagen'));
    await connect(tester);
    await restartEvcc(tester);

    expect(review.calls, 0);
    expect(store.saved?.reviewPrompt.successes ?? 2, 2);
  });

  testWidgets('im Demo-Modus wird weder gezählt noch gefragt', (tester) async {
    final store = _Store(AppConfig(
      profiles: const [Profile(name: 'S')],
      activeIndex: 0,
      disclaimerAccepted: true,
      reviewPrompt: _almostDue,
    ));
    final review = _Review();
    await open(tester,
        store: store, review: review, channel: InstallChannel.play);
    await tester.tap(find.byKey(const Key('demoEntry')));
    await tester.pumpAndSettle();
    await restartEvcc(tester);

    expect(find.text('evcc-Dienst neu gestartet.'), findsOneWidget);
    expect(review.calls, 0);
    expect(store.saved?.reviewPrompt.successes ?? 2, 2);
  });
}
