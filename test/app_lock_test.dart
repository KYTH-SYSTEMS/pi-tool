// The app lock as the app wires it: EvccPiToolApp with its lock layer above
// the Navigator and its back observer above MaterialApp, around an UpdaterPage
// with fake collaborators. What a lock does to open routes, what is reachable
// beneath it, what system back does while it is up — and the two things the
// lock asks of the platform (recent-apps picture, file picker time limit).
import 'dart:async';

import 'package:evcc_updater/main.dart';
import 'package:evcc_updater/src/app_lock.dart';
import 'package:evcc_updater/src/authenticator.dart';
import 'package:evcc_updater/src/evcc_api.dart';
import 'package:evcc_updater/src/evcc_updater.dart';
import 'package:evcc_updater/src/file_pick.dart';
import 'package:evcc_updater/src/history.dart';
import 'package:evcc_updater/src/l10n.dart';
import 'package:evcc_updater/src/profiles.dart';
import 'package:evcc_updater/src/secure_screen.dart';
import 'package:evcc_updater/src/services/pi_service.dart';
import 'package:evcc_updater/src/settings_store.dart';
import 'package:evcc_updater/src/ssh_runner.dart';
import 'package:evcc_updater/src/update_check.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

const _version = '0.71.0';

class _Store extends AppConfigStore {
  _Store(this._initial);
  final AppConfig _initial;
  AppConfig? saved;
  @override
  Future<AppConfig> load() async => _initial;
  @override
  Future<void> save(AppConfig c) async => saved = c;
}

/// Authenticator whose answer the test sets. [open] keeps a prompt on screen
/// until the test answers it.
class _Auth implements Authenticator {
  bool allow = true;
  int prompts = 0;
  Completer<bool>? open;

  @override
  Future<bool> canAuthenticate() async => true;

  @override
  Future<bool> authenticate(String reason) {
    prompts++;
    return open?.future ?? Future<bool>.value(allow);
  }
}

/// History store whose [load] waits for [gate] — an action that finishes
/// while the app is locked.
class _History extends HistoryStore {
  Completer<void>? gate;

  @override
  Future<List<HistoryEntry>> load() async {
    await gate?.future;
    return const [];
  }

  @override
  Future<void> add(HistoryEntry entry) async {}

  @override
  Future<void> clear() async {}
}

/// Just enough updater for "connect, then open evcc.yaml in the editor".
class _Updater extends EvccUpdater {
  _Updater() : super(runnerFactory: _noRunner);
  static SshRunner _noRunner(SshConfig c) => throw UnimplementedError();

  int detectCalls = 0;

  @override
  Future<List<ServiceStatus>> detectServices({
    required SshConfig config,
    required void Function(String line) onLog,
    bool allowSudoForDocker = true,
    void Function()? onConnected,
  }) async {
    detectCalls++;
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
  Future<String> readConfigFile({
    required SshConfig config,
    required String path,
    required void Function(String line) onLog,
  }) async =>
      'network:\n  schema: http';
}

class _Secure implements SecureScreen {
  final calls = <bool>[];
  @override
  Future<void> setSecure(bool secure) async => calls.add(secure);
}

class _Recents implements RecentsPreview {
  final calls = <bool>[];
  @override
  Future<void> setRecentsHidden(bool hidden) async => calls.add(hidden);
}

/// The system file picker, left open until the test closes it.
class _OpenPicker implements FilePickerService {
  final closed = Completer<PickedFile?>();
  @override
  Future<PickedFile?> pick() => closed.future;
}

/// A set-up Pi (the connection card starts collapsed). The address is from
/// the documentation range; nothing here ever connects.
AppConfig _config({bool lock = true, bool autoConnect = false}) => AppConfig(
      profiles: [
        Profile(
            name: 'S',
            host: '192.0.2.10',
            password: 'pw',
            autoConnect: autoConnect),
      ],
      activeIndex: 0,
      disclaimerAccepted: true,
      lockEnabled: lock,
      languageMode: 'de',
      lastSeenVersion: _version, // no "What's new" on top of the test
    );

void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Pi-Tool',
      packageName: 'systems.kyth.pitool',
      version: _version,
      buildNumber: '71',
      buildSignature: '',
    );
  });

  // The page writes theme and language into the app-wide notifiers.
  tearDown(() {
    themeModeNotifier.value = ThemeMode.system;
    localeNotifier.value = null;
  });

  Future<void> pumpApp(
    WidgetTester tester, {
    AppConfig? config,
    _Store? store,
    _Auth? auth,
    _Updater? updater,
    _History? history,
    UpdateChecker? updateChecker,
    FilePickerService? filePicker,
    Future<List<String>> Function()? piFinder,
    SecureScreen? secureScreen,
    RecentsPreview? recentsPreview,
    DateTime Function()? clock,
  }) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(EvccPiToolApp(
      splash: false,
      home: UpdaterPage(
        store: store ?? _Store(config ?? _config()),
        updater: updater ?? _Updater(),
        updateChecker: updateChecker ??
            UpdateChecker(getJson: (_) async => <String, dynamic>{}),
        authenticator: auth ?? _Auth(),
        apiClient: EvccApiClient(
            getJson: (_) async =>
                throw const EvccApiException('kein Netz im Test')),
        evccReleaseFetcher: () async => null,
        haVersionFetcher: () async => null,
        historyStore: history ?? _History(),
        filePicker: filePicker,
        piFinder: piFinder ?? () async => const [],
        secureScreen: secureScreen ?? _Secure(),
        recentsPreview: recentsPreview ?? _Recents(),
        clock: clock,
      ),
    ));
    await tester.pumpAndSettle();
  }

  // Valid lifecycle transitions only. The app locks in the background
  // (hidden/paused) and draws no frame there.
  void toBackground(WidgetTester tester) {
    for (final s in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
  }

  void toForeground(WidgetTester tester) {
    for (final s in const [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
  }

  /// Locks the app the way a user does: away and back, with a prompt that is
  /// turned down on return.
  Future<void> lockByLeaving(WidgetTester tester, _Auth auth) async {
    auth.allow = false;
    toBackground(tester);
    toForeground(tester);
    await tester.pumpAndSettle();
  }

  final unlock = find.widgetWithText(FilledButton, 'Entsperren');

  Future<void> tapUnlock(WidgetTester tester, _Auth auth) async {
    auth.allow = true;
    await tester.tap(unlock);
    await tester.pumpAndSettle();
  }

  // Something of the settings sheet to look for.
  const lockSwitch = 'App mit Biometrie/PIN sperren';

  Future<void> openMenu(WidgetTester tester, String item) async {
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, item));
    await tester.pumpAndSettle();
  }

  /// Everything the app tells the platform over the system channel (system
  /// back among it), in order.
  List<MethodCall> recordPlatformCalls(WidgetTester tester) {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    return calls;
  }

  group('the lock covers the Navigator', () {
    testWidgets(
        'locking keeps an open sheet and hides it: not painted, not tappable, '
        'not in the semantics tree — and it is back after the unlock',
        (tester) async {
      final semantics = tester.ensureSemantics();
      final auth = _Auth();
      await pumpApp(tester, auth: auth);
      expect(unlock, findsNothing); // the prompt at the start went through

      await openMenu(tester, 'Einstellungen');
      expect(find.text(lockSwitch).hitTestable(), findsOneWidget);
      expect(find.semantics.byLabel(RegExp(lockSwitch)), findsOneWidget);

      await lockByLeaving(tester, auth);

      expect(unlock.hitTestable(), findsOneWidget);
      // The sheet is still there, beneath the lock …
      expect(find.text(lockSwitch, skipOffstage: false), findsOneWidget);
      // … and out of reach.
      expect(find.text(lockSwitch), findsNothing);
      expect(find.text(lockSwitch, skipOffstage: false).hitTestable(),
          findsNothing);
      expect(find.semantics.byLabel(RegExp(lockSwitch)), findsNothing);

      await tapUnlock(tester, auth);

      expect(unlock, findsNothing);
      expect(find.text(lockSwitch).hitTestable(), findsOneWidget);
      expect(find.semantics.byLabel(RegExp(lockSwitch)), findsOneWidget);
      semantics.dispose();
    });

    testWidgets(
        'a sheet an action opens while the app is locked stays beneath the '
        'lock and is there after the unlock', (tester) async {
      final auth = _Auth();
      final history = _History();
      await pumpApp(tester, auth: auth, history: history);

      // ⋮ → Verlauf reads the store first; the app goes away meanwhile.
      history.gate = Completer<void>();
      await openMenu(tester, 'Verlauf');
      auth.allow = false;
      toBackground(tester);
      history.gate!.complete();
      await tester.pump(); // the sheet is pushed — in the background
      toForeground(tester);
      await tester.pumpAndSettle();

      expect(unlock.hitTestable(), findsOneWidget);
      expect(find.text('Noch kein Verlauf.'), findsNothing);
      expect(find.text('Noch kein Verlauf.', skipOffstage: false),
          findsOneWidget);

      await tapUnlock(tester, auth);

      expect(find.text('Noch kein Verlauf.').hitTestable(), findsOneWidget);
    });

    testWidgets(
        'a network scan that finishes while the app is locked shows its '
        'result after the unlock', (tester) async {
      final auth = _Auth();
      final scan = Completer<List<String>>();
      await pumpApp(tester, auth: auth, piFinder: () => scan.future);

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(
          find.widgetWithText(PopupMenuItem<String>, 'Pi im WLAN suchen'));
      await tester.pump(); // the progress dialog spins — nothing to settle
      await tester.pump(const Duration(milliseconds: 500));
      auth.allow = false;
      toBackground(tester);
      scan.complete(['192.0.2.77']);
      await tester.pump();
      toForeground(tester);
      await tester.pumpAndSettle();

      expect(unlock.hitTestable(), findsOneWidget);
      expect(find.text('192.0.2.77'), findsNothing);

      await tapUnlock(tester, auth);

      expect(find.text('192.0.2.77').hitTestable(), findsOneWidget);
    });

    testWidgets('the config editor keeps its unsaved text over lock and unlock',
        (tester) async {
      final auth = _Auth();
      await pumpApp(tester, auth: auth);
      await tester
          .tap(find.widgetWithText(OutlinedButton, 'Verbindung herstellen'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-evcc')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Konfiguration bearbeiten'));
      await tester.pumpAndSettle();
      const edited = 'network:\n  schema: https';
      await tester.enterText(find.byType(TextField).first, edited);
      await tester.pump();

      await lockByLeaving(tester, auth);

      expect(unlock.hitTestable(), findsOneWidget);
      expect(find.text(edited), findsNothing);

      await tapUnlock(tester, auth);

      // Still in the editor, with what was typed.
      expect(find.text('evcc.yaml'), findsOneWidget);
      expect(find.text(edited).hitTestable(), findsOneWidget);
      expect(find.byIcon(Icons.save).hitTestable(), findsOneWidget);
    });

    testWidgets(
        'cold start with the lock on: nothing of the page is in reach, the '
        'prompt comes by itself, and no Pi is contacted', (tester) async {
      final auth = _Auth()..allow = false;
      final updater = _Updater();
      final secure = _Secure();
      await pumpApp(tester,
          config: _config(autoConnect: true),
          auth: auth,
          updater: updater,
          secureScreen: secure);

      expect(unlock.hitTestable(), findsOneWidget);
      expect(auth.prompts, 1);
      expect(find.text('Verbindung herstellen'), findsNothing);
      expect(find.byType(PopupMenuButton<String>), findsNothing);
      expect(updater.detectCalls, 0); // auto-connect stays behind the lock
      expect(secure.calls, isNotEmpty);
      expect(secure.calls, everyElement(isTrue));
    });

    testWidgets(
        '"What\'s new" waits for the unlock, and so does its "seen" mark',
        (tester) async {
      PackageInfo.setMockInitialValues(
        appName: 'Pi-Tool',
        packageName: 'systems.kyth.pitool',
        version: '0.21.14',
        buildNumber: '52',
        buildSignature: '',
      );
      final auth = _Auth()..allow = false;
      final store = _Store(const AppConfig(
        profiles: [Profile(name: 'S', host: '192.0.2.10', password: 'pw')],
        activeIndex: 0,
        disclaimerAccepted: true,
        lockEnabled: true,
        languageMode: 'de',
        lastSeenVersion: '0.21.13', // updated FROM this
      ));
      await pumpApp(tester, store: store, auth: auth);

      expect(unlock.hitTestable(), findsOneWidget);
      expect(find.text('Neu in v0.21.14', skipOffstage: false), findsNothing);
      expect(store.saved?.lastSeenVersion, isNot('0.21.14'));

      await tapUnlock(tester, auth);

      expect(find.text('Neu in v0.21.14').hitTestable(), findsOneWidget);
      expect(store.saved!.lastSeenVersion, '0.21.14');
    });

    testWidgets(
        'a failed or cancelled prompt keeps the app locked, and the button '
        'asks again', (tester) async {
      final auth = _Auth()..allow = false;
      await pumpApp(tester, auth: auth);
      expect(unlock.hitTestable(), findsOneWidget);
      expect(auth.prompts, 1);

      // Failed.
      await tester.tap(unlock);
      await tester.pumpAndSettle();
      expect(auth.prompts, 2);
      expect(unlock.hitTestable(), findsOneWidget);

      // A prompt that is still open: a second tap does not stack another one.
      auth.open = Completer<bool>();
      await tester.tap(unlock);
      await tester.pump();
      await tester.tap(unlock);
      await tester.pump();
      expect(auth.prompts, 3);
      auth.open!.complete(false); // cancelled
      await tester.pumpAndSettle();
      expect(unlock.hitTestable(), findsOneWidget);

      // And it works again.
      auth.open = null;
      await tapUnlock(tester, auth);
      expect(auth.prompts, 4);
      expect(unlock, findsNothing);
      expect(
          find
              .widgetWithText(OutlinedButton, 'Verbindung herstellen')
              .hitTestable(),
          findsOneWidget);
    });

    testWidgets(
        'the keyboard closes when the lock engages, and nothing beneath takes '
        'the focus while locked', (tester) async {
      final auth = _Auth();
      await pumpApp(tester, auth: auth);
      await openMenu(tester, 'Einstellungen');
      final port = find.descendant(
          of: find.byType(BottomSheet), matching: find.byType(TextField));
      await tester.ensureVisible(port.first);
      await tester.tap(port.first); // the web UI port
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);

      // Closed with the lock itself — in the background, before any frame.
      auth.allow = false;
      toBackground(tester);
      await tester.pump();
      expect(tester.testTextInput.isVisible, isFalse);
      toForeground(tester);
      await tester.pumpAndSettle();
      expect(unlock.hitTestable(), findsOneWidget);

      // A dialog that wants the keyboard, opened beneath the lock.
      final navigator = tester
          .state<NavigatorState>(find.byType(Navigator, skipOffstage: false));
      unawaited(navigator.push(DialogRoute<void>(
        context: navigator.context,
        builder: (_) => const AlertDialog(
          content: TextField(key: Key('beneath'), autofocus: true),
        ),
      )));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      expect(find.byKey(const Key('beneath')), findsNothing);

      // After the unlock the field is an ordinary field again.
      await tapUnlock(tester, auth);
      await tester.tap(find.byKey(const Key('beneath')));
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
    });

    testWidgets(
        'a message an action raises beneath the lock does not appear on the '
        'lock screen', (tester) async {
      final auth = _Auth();
      Completer<Map<String, dynamic>>? gate;
      await pumpApp(tester,
          auth: auth,
          updateChecker: UpdateChecker(
              getJson: (_) =>
                  gate?.future ?? Future.value(<String, dynamic>{})));

      // ⋮ → Auf Update prüfen answers with a snackbar — after the app locked.
      gate = Completer<Map<String, dynamic>>();
      await openMenu(tester, 'Auf Update prüfen');
      auth.allow = false;
      toBackground(tester);
      gate.complete({
        'tag_name': 'v$_version', // the installed version: "up to date"
        'html_url': 'https://example.invalid/releases/tag/v$_version',
      });
      await tester.pump();
      toForeground(tester);
      await tester.pumpAndSettle();

      expect(unlock.hitTestable(), findsOneWidget);
      expect(find.textContaining('neueste Version', skipOffstage: false),
          findsOneWidget); // raised …
      expect(find.textContaining('neueste Version'), findsNothing); // … beneath

      await tester.pump(const Duration(seconds: 5)); // let the snackbar expire
      await tester.pumpAndSettle();
    });
  });

  testWidgets(
      'a lock scope without the layer in the builder: the page keeps its '
      'content away by itself while locked', (tester) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = _Auth()..allow = false;
    await tester.pumpWidget(AppLockScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('de'),
        home: UpdaterPage(
          store: _Store(_config()),
          updater: _Updater(),
          updateChecker:
              UpdateChecker(getJson: (_) async => <String, dynamic>{}),
          authenticator: auth,
          historyStore: _History(),
          secureScreen: _Secure(),
          recentsPreview: _Recents(),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(unlock.hitTestable(), findsOneWidget);
    expect(find.text('Verbindung herstellen', skipOffstage: false),
        findsNothing);
    expect(find.byType(PopupMenuButton<String>, skipOffstage: false),
        findsNothing);

    await tapUnlock(tester, auth);
    expect(find.text('Verbindung herstellen').hitTestable(), findsOneWidget);
  });

  group('system back while locked', () {
    testWidgets('leaves the app and pops nothing beneath', (tester) async {
      final platform = recordPlatformCalls(tester);
      final auth = _Auth();
      await pumpApp(tester, auth: auth);
      await openMenu(tester, 'Einstellungen');
      await lockByLeaving(tester, auth);
      expect(unlock.hitTestable(), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(platform.where((c) => c.method == 'SystemNavigator.pop'),
          hasLength(1));
      expect(find.text(lockSwitch, skipOffstage: false), findsOneWidget);
      expect(unlock.hitTestable(), findsOneWidget);

      // Unlocked, back is the Navigator's again: it closes the sheet and the
      // app stays.
      await tapUnlock(tester, auth);
      expect(find.text(lockSwitch).hitTestable(), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text(lockSwitch, skipOffstage: false), findsNothing);
      expect(platform.where((c) => c.method == 'SystemNavigator.pop'),
          hasLength(1));
    });

    testWidgets(
        'the platform handles back itself while locked — also for a route '
        'opened beneath the lock — and the framework takes over again with '
        'the unlock', (tester) async {
      final platform = recordPlatformCalls(tester);
      Object? lastBackReport() => platform
          .lastWhere(
              (c) => c.method == 'SystemNavigator.setFrameworkHandlesBack')
          .arguments;
      // The framework reports to the platform only once the app has a
      // lifecycle state.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final auth = _Auth();
      await pumpApp(tester, auth: auth);

      await openMenu(tester, 'Einstellungen');
      expect(lastBackReport(), isTrue); // a sheet to close

      await lockByLeaving(tester, auth);
      expect(unlock.hitTestable(), findsOneWidget);
      expect(lastBackReport(), isFalse);

      final navigator = tester
          .state<NavigatorState>(find.byType(Navigator, skipOffstage: false));
      unawaited(navigator.push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('beneath')))));
      await tester.pumpAndSettle();
      expect(lastBackReport(), isFalse);

      await tapUnlock(tester, auth);
      expect(find.text('beneath').hitTestable(), findsOneWidget);
      expect(lastBackReport(), isTrue);

      navigator
        ..pop()
        ..pop();
      await tester.pumpAndSettle();
      expect(lastBackReport(), isFalse); // only the home route is left
    });
  });

  group('app lock switched off', () {
    testWidgets(
        'leaving and returning locks nothing, and system back closes a sheet '
        'and then leaves the app, as without the lock layer', (tester) async {
      final platform = recordPlatformCalls(tester);
      Iterable<MethodCall> exits() =>
          platform.where((c) => c.method == 'SystemNavigator.pop');
      final auth = _Auth();
      await pumpApp(tester, config: _config(lock: false), auth: auth);
      await openMenu(tester, 'Einstellungen');

      toBackground(tester);
      toForeground(tester);
      await tester.pumpAndSettle();
      expect(unlock, findsNothing);
      expect(auth.prompts, 0);
      expect(find.text(lockSwitch).hitTestable(), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text(lockSwitch, skipOffstage: false), findsNothing);
      expect(exits(), isEmpty);

      await tester.binding.handlePopRoute(); // only the home route is left
      await tester.pumpAndSettle();
      expect(exits(), hasLength(1));
    });
  });

  group('file picker and the lock', () {
    testWidgets(
        'an open file picker holds the lock off, but not beyond five minutes',
        (tester) async {
      var now = DateTime(2026, 10, 8, 12);
      final auth = _Auth();
      final picker = _OpenPicker();
      await pumpApp(tester, auth: auth, filePicker: picker, clock: () => now);

      // Einstellungen → Profile importieren opens the system picker.
      await openMenu(tester, 'Einstellungen');
      await tester.ensureVisible(find.text('Profile importieren'));
      await tester.tap(find.text('Profile importieren'));
      await tester.pumpAndSettle();
      auth.allow = false;

      // Picked a while, came back in time: no lock.
      toBackground(tester);
      now = now.add(const Duration(minutes: 4));
      toForeground(tester);
      await tester.pumpAndSettle();
      expect(unlock, findsNothing);
      expect(auth.prompts, 1); // only the one at the start

      // Left open for longer: locked on the way back — with the first frame,
      // before the app is in front again.
      toBackground(tester);
      now = now.add(const Duration(minutes: 6));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(unlock.hitTestable(), findsOneWidget);
      expect(
          find.widgetWithText(OutlinedButton, 'Verbindung herstellen'),
          findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(auth.prompts, 2); // and it asks
      expect(unlock.hitTestable(), findsOneWidget);

      picker.closed.complete(null); // the user cancels the picker
      await tester.pumpAndSettle();
      expect(unlock.hitTestable(), findsOneWidget);
    });
  });

  group('recent-apps overview', () {
    testWidgets('app lock on: the picture of the app is turned off',
        (tester) async {
      final recents = _Recents();
      await pumpApp(tester, recentsPreview: recents);
      expect(recents.calls, [true]);
    });

    testWidgets('no app lock: the platform is not called at all',
        (tester) async {
      final recents = _Recents();
      await pumpApp(tester,
          config: _config(lock: false), recentsPreview: recents);
      expect(recents.calls, isEmpty);
    });

    testWidgets('the switch in the settings turns it off and on again',
        (tester) async {
      final recents = _Recents();
      await pumpApp(tester,
          config: _config(lock: false), recentsPreview: recents);
      await openMenu(tester, 'Einstellungen');

      await tester.tap(find.widgetWithText(SwitchListTile, lockSwitch));
      await tester.pumpAndSettle();
      expect(recents.calls, [true]);

      await tester.tap(find.widgetWithText(SwitchListTile, lockSwitch));
      await tester.pumpAndSettle();
      expect(recents.calls, [true, false]);
      await tester.pump(const Duration(seconds: 1)); // drain the save debounce
    });

    group('ChannelSecureScreen', () {
      const channel = MethodChannel('pi_tool/secure');

      testWidgets('asks the secure channel with its own method',
          (tester) async {
        final calls = <MethodCall>[];
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
        addTearDown(() => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null));

        await const ChannelSecureScreen().setRecentsHidden(true);
        await const ChannelSecureScreen().setRecentsHidden(false);

        expect([for (final c in calls) c.method],
            ['setRecentsHidden', 'setRecentsHidden']);
        expect([
          for (final c in calls) c.arguments
        ], [
          {'hidden': true},
          {'hidden': false},
        ]);
      });

      testWidgets('a platform that turns the call down does not reach the app',
          (tester) async {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            (call) async => throw PlatformException(code: 'unavailable'));
        addTearDown(() => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null));

        await const ChannelSecureScreen().setRecentsHidden(true);
      });
    });
  });
}
