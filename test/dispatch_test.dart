import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:evcc_updater/main.dart';
import 'package:evcc_updater/src/alerts.dart';
import 'package:evcc_updater/src/authenticator.dart';
import 'package:evcc_updater/src/files.dart';
import 'package:evcc_updater/src/auto_update.dart';
import 'package:evcc_updater/src/commands.dart';
import 'package:evcc_updater/src/entitlement.dart';
import 'package:evcc_updater/src/evcc_updater.dart';
import 'package:evcc_updater/src/file_pick.dart';
import 'package:evcc_updater/src/keep_alive.dart';
import 'package:evcc_updater/src/parsing.dart';
import 'package:evcc_updater/src/profiles.dart';
import 'package:evcc_updater/src/services/apt_services.dart';
import 'package:evcc_updater/src/services/pi_service.dart';
import 'package:evcc_updater/src/ssh_runner.dart';
import 'package:evcc_updater/src/update_check.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeFilePicker implements FilePickerService {
  _FakeFilePicker(this.file);
  final PickedFile? file;
  @override
  Future<PickedFile?> pick() async => file;
}

/// Picker that runs [duringPick] before returning — used to simulate the system
/// picker backgrounding the app (paused → resumed) while a pick is in flight.
class _BackgroundingPicker implements FilePickerService {
  _BackgroundingPicker(this.file, this.duringPick);
  final PickedFile? file;
  final Future<void> Function() duringPick;
  @override
  Future<PickedFile?> pick() async {
    await duringPick();
    return file;
  }
}

/// Authenticator that always succeeds — the app auto-unlocks on load.
class _AllowAuth implements Authenticator {
  @override
  Future<bool> canAuthenticate() async => true;
  @override
  Future<bool> authenticate(String reason) async => true;
}

class _FakeEntitlement implements EntitlementService {
  _FakeEntitlement({this.pro = true});
  bool pro;
  int buyCalls = 0;
  @override
  Future<bool> isPro() async => pro;
  @override
  Future<bool> buyPro() async {
    buyCalls++;
    pro = true;
    return true;
  }

  @override
  Future<bool> restore() async => pro;
}

class _FakeStore extends AppConfigStore {
  _FakeStore([this._initial = AppConfig.initial]);
  final AppConfig _initial;
  AppConfig saved = AppConfig.initial;
  @override
  Future<AppConfig> load() async => _initial;
  @override
  Future<void> save(AppConfig c) async => saved = c;
}

/// Updater test double — overrides the public surface the UI dispatches to.
class FakeEvccUpdater extends EvccUpdater {
  FakeEvccUpdater() : super(runnerFactory: _noRunner);
  static SshRunner _noRunner(SshConfig c) => throw UnimplementedError();

  List<ServiceStatus> services = const [
    ServiceStatus(
        id: 'evcc',
        name: 'evcc',
        installed: true,
        version: '0.310.0',
        active: true,
        detail: 'apt · Dienst aktiv'),
    ServiceStatus(
        id: 'system',
        name: 'System (Pi)',
        installed: true,
        version: 'Debian 12',
        active: true,
        detail: 'aktuell'),
  ];
  Object? detectError; // thrown by detect* (e.g. hostKeyChanged)
  Completer<void>? detectGate; // if set, detectServices awaits it (stay busy)
  int cancelCalls = 0;
  InstallDetection detection = const InstallDetection(
      kind: InstallKind.apt, aptVersion: '0.310.0', serviceActive: true);
  UpdateSummary summary = const UpdateSummary(
      status: UpdateStatus.updated,
      message: 'evcc 0.310.0 → 0.311.0 aktualisiert.',
      before: '0.310.0',
      after: '0.311.0');
  Object? backupError;

  int runCalls = 0, dockerCalls = 0, backupCalls = 0, forgetCalls = 0;
  int piholeUpdateCalls = 0, systemUpgradeCalls = 0;
  int haInstallCalls = 0, haUpdateCalls = 0;
  SshConfig? forgotConfig;

  @override
  Future<List<ServiceStatus>> detectServices({
    required SshConfig config,
    required void Function(String line) onLog,
    bool allowSudoForDocker = true,
    void Function()? onConnected,
  }) async {
    if (detectGate != null) await detectGate!.future;
    onConnected?.call();
    if (detectError != null) throw detectError!;
    return services;
  }

  @override
  Future<void> cancel() async => cancelCalls++;

  int shutdownCalls = 0;
  @override
  Future<void> shutdown({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async =>
      shutdownCalls++;

  final aptUpdates = <String>[]; // packages updated via updateAptPackage
  final aptInstalls = <String>[]; // service ids installed via installAptService
  int piholeBackupCalls = 0, haBackupCalls = 0;

  @override
  Future<void> updateAptPackage({
    required SshConfig config,
    required String package,
    required void Function(String line) onLog,
  }) async =>
      aptUpdates.add(package);

  @override
  Future<void> installAptService({
    required SshConfig config,
    required AptService service,
    required void Function(String line) onLog,
  }) async =>
      aptInstalls.add(service.id);

  List<String> serviceBackups = const [];
  final restoredPihole = <String>[];
  final restoredHa = <String>[];
  final deletedBackups = <String>[];
  int cleanupCalls = 0;

  @override
  Future<List<String>> listServiceBackups({
    required SshConfig config,
    required String servicePrefix,
    required void Function(String line) onLog,
  }) async =>
      serviceBackups;

  @override
  Future<void> deleteServiceBackup({
    required SshConfig config,
    required String path,
    required void Function(String line) onLog,
  }) async =>
      deletedBackups.add(path);

  @override
  Future<void> restorePiholeBackup({
    required SshConfig config,
    required String path,
    required void Function(String line) onLog,
  }) async =>
      restoredPihole.add(path);

  @override
  Future<void> restoreHomeAssistantBackup({
    required SshConfig config,
    required String path,
    required void Function(String line) onLog,
  }) async =>
      restoredHa.add(path);

  @override
  Future<int> cleanupSystem({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async {
    cleanupCalls++;
    return 250000000; // 250 MB
  }

  String? enabledOnCalendar;
  bool autoUpdateDisabled = false;
  AutoUpdateStatus autoStatus =
      (enabled: false, nextRun: null, lastResult: null);

  @override
  Future<void> enableAutoUpdate({
    required SshConfig config,
    required String onCalendar,
    required void Function(String line) onLog,
  }) async =>
      enabledOnCalendar = onCalendar;

  @override
  Future<void> disableAutoUpdate({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async =>
      autoUpdateDisabled = true;

  @override
  Future<AutoUpdateStatus> readAutoUpdateStatus({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async =>
      autoStatus;

  bool piConnectInstalled = false;
  int piConnectSigninCalls = 0;
  String? piConnectSigninUrl;
  bool? piConnectSetOn;
  bool piConnectSignedOut = false;

  @override
  Future<void> installPiConnect({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async =>
      piConnectInstalled = true;

  @override
  Future<String?> piConnectSignin({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async {
    piConnectSigninCalls++;
    return piConnectSigninUrl;
  }

  @override
  Future<void> piConnectSet({
    required SshConfig config,
    required bool on,
    required void Function(String line) onLog,
  }) async =>
      piConnectSetOn = on;

  @override
  Future<void> piConnectSignout({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async =>
      piConnectSignedOut = true;

  bool tailscaleInstalled = false;
  int tailscaleUpCalls = 0;
  String? tailscaleUpUrl;
  bool? tailscaleLoggedOut;

  @override
  Future<void> installTailscale({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async =>
      tailscaleInstalled = true;

  @override
  Future<String?> tailscaleUp({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async {
    tailscaleUpCalls++;
    return tailscaleUpUrl;
  }

  @override
  Future<void> tailscaleSet({
    required SshConfig config,
    required bool logout,
    required void Function(String line) onLog,
  }) async =>
      tailscaleLoggedOut = logout;

  List<DirEntry> dirEntries = const [];
  Uint8List fileBytes = Uint8List(0);
  final uploadedTo = <String>[];
  final deletedPaths = <String>[];

  @override
  Future<List<DirEntry>> listDir({
    required SshConfig config,
    required String path,
    required void Function(String line) onLog,
  }) async =>
      dirEntries;

  bool uploadThrows = false;

  @override
  Future<void> uploadFile({
    required SshConfig config,
    required String path,
    required Uint8List bytes,
    required void Function(String line) onLog,
  }) async {
    uploadedTo.add(path);
    // Simulate the file now existing on the Pi (a reload should surface it).
    dirEntries = [...dirEntries, (name: path.split('/').last, isDir: false)];
    // Simulate a lost success marker (file written, but reported as a failure).
    if (uploadThrows) {
      throw const EvccUpdateException(UpdateErrorKind.unknown, 'Marker verpasst');
    }
  }

  @override
  Future<void> deleteRemotePath({
    required SshConfig config,
    required String path,
    required bool isDir,
    required void Function(String line) onLog,
  }) async =>
      deletedPaths.add(path);

  final downloadedPaths = <String>[];
  Uint8List downloadBytes = Uint8List(0);

  @override
  Future<Uint8List> downloadFile({
    required SshConfig config,
    required String path,
    required void Function(String line) onLog,
  }) async {
    downloadedPaths.add(path);
    return downloadBytes;
  }

  @override
  Future<Uint8List> readFileBytes({
    required SshConfig config,
    required String path,
    required void Function(String line) onLog,
  }) async =>
      fileBytes;

  String configText = 'network:\n  schema: http\n';
  String? savedConfig;

  @override
  Future<String> readConfigFile({
    required SshConfig config,
    required String path,
    required void Function(String line) onLog,
  }) async =>
      configText;

  @override
  Future<void> saveConfigFile({
    required SshConfig config,
    required String path,
    required String content,
    required void Function(String line) onLog,
  }) async =>
      savedConfig = content;

  String serviceLogs = '-- journal --\n';

  @override
  Future<String> fetchServiceLogs({
    required SshConfig config,
    required String id,
    required String detail,
    required void Function(String line) onLog,
  }) async =>
      serviceLogs;

  String? alertsTopic;
  bool alertsDisabled = false;
  int testAlertCalls = 0;
  AlertsStatus alertsStatus = (enabled: false, lastCheck: null);

  @override
  Future<void> enableAlerts({
    required SshConfig config,
    required String ntfyServer,
    required String ntfyTopic,
    required void Function(String line) onLog,
  }) async =>
      alertsTopic = ntfyTopic;

  @override
  Future<void> disableAlerts({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async =>
      alertsDisabled = true;

  @override
  Future<AlertsStatus> readAlertsStatus({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async =>
      alertsStatus;

  @override
  Future<void> sendTestAlert({
    required SshConfig config,
    required String ntfyServer,
    required String ntfyTopic,
    required void Function(String line) onLog,
  }) async =>
      testAlertCalls++;

  final consoleCommands = <String>[];

  @override
  Future<String> runConsoleCommand({
    required SshConfig config,
    required String command,
    required void Function(String line) onLog,
  }) async {
    consoleCommands.add(command);
    onLog('\$ $command');
    return 'ok';
  }


  @override
  Future<String> backupPihole({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async {
    piholeBackupCalls++;
    return '/var/backups/pi-tool/pihole-backup-x.tar.gz';
  }

  @override
  Future<String> backupHomeAssistant({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async {
    haBackupCalls++;
    return '/var/backups/pi-tool/homeassistant-backup-x.tar.gz';
  }

  List<String> backups = const [];
  int restoreCalls = 0;
  String? restoredPath;

  @override
  Future<List<String>> listBackups({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async =>
      backups;

  @override
  Future<void> restoreBackup({
    required SshConfig config,
    required String path,
    required void Function(String line) onLog,
  }) async {
    restoreCalls++;
    restoredPath = path;
  }

  @override
  Future<InstallDetection> detectInstall({
    required SshConfig config,
    required void Function(String line) onLog,
    bool allowSudoForDocker = true,
  }) async {
    if (detectError != null) throw detectError!;
    return detection;
  }

  @override
  Future<UpdateSummary> run({
    required SshConfig config,
    required bool fullUpgrade,
    required bool dryRun,
    required void Function(String line) onLog,
  }) async {
    runCalls++;
    return summary;
  }

  @override
  Future<void> updateDocker({
    required SshConfig config,
    required InstallDetection detection,
    required void Function(String line) onLog,
  }) async {
    dockerCalls++;
  }

  @override
  Future<String?> backup({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async {
    backupCalls++;
    if (backupError != null) throw backupError!;
    return '/var/backups/evcc/x.tar.gz';
  }

  @override
  Future<void> forgetHostKey(SshConfig config) async {
    forgetCalls++;
    forgotConfig = config;
  }

  @override
  Future<void> updatePihole({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async =>
      piholeUpdateCalls++;

  @override
  Future<void> upgradeSystem({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async =>
      systemUpgradeCalls++;

  @override
  Future<void> installHomeAssistant({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async =>
      haInstallCalls++;

  @override
  Future<void> updateHomeAssistant({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async =>
      haUpdateCalls++;
}

/// Records keep-alive start/stop so tests can assert a long action runs behind
/// a foreground service while a quick one does not.
class _FakeKeepAlive implements KeepAliveService {
  int beginCount = 0, endCount = 0;
  String? lastMessage;
  @override
  Future<void> begin(String message) async {
    beginCount++;
    lastMessage = message;
  }

  @override
  Future<void> end() async => endCount++;
}

final _noUpdateChecker =
    UpdateChecker(getJson: (_) async => <String, dynamic>{});

const _ready = AppConfig(
  profiles: [Profile(name: 'S', host: '192.168.178.64', password: 'pw')],
  activeIndex: 0,
  disclaimerAccepted: true,
);

void main() {
  void useTallScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget page(FakeEvccUpdater updater,
          {Future<EvccRelease?> Function()? rel,
          Future<String?> Function()? haLatest,
          EntitlementService? entitlement,
          KeepAliveService? keepAlive,
          FilePickerService? filePicker,
          Future<void> Function(String name, Uint8List bytes)? fileSaver}) =>
      MaterialApp(
        home: UpdaterPage(
          store: _FakeStore(_ready),
          updater: updater,
          updateChecker: _noUpdateChecker,
          evccReleaseFetcher: rel ?? () async => null,
          haVersionFetcher: haLatest ?? () async => null,
          entitlement: entitlement,
          keepAlive: keepAlive,
          filePicker: filePicker,
          fileSaver: fileSaver,
        ),
      );

  // Establish the connection → populates the service cards.
  Future<void> detect(WidgetTester tester) async {
    await tester
        .tap(find.widgetWithText(OutlinedButton, 'Verbindung herstellen'));
    await tester.pumpAndSettle();
  }

  // Bottom-nav helpers (Dienste = default; Automatik/Terminal are separate tabs).
  Future<void> goTerminal(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.terminal_outlined));
    await tester.pumpAndSettle();
  }

  Future<void> goAutomatik(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.bolt_outlined));
    await tester.pumpAndSettle();
  }

  Future<void> goDateien(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.folder_outlined));
    await tester.pumpAndSettle();
  }

  testWidgets('Dateien tab: lists entries and deletes a file', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..dirEntries = const [
        (name: 'projects', isDir: true),
        (name: 'notes.txt', isDir: false),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await goDateien(tester);

    expect(find.text('projects'), findsOneWidget);
    expect(find.text('notes.txt'), findsOneWidget);

    // Delete the file via its ⋮ → confirm.
    await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, 'notes.txt'),
        matching: find.byIcon(Icons.more_vert)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Löschen'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter')); // confirm
    await tester.pumpAndSettle();

    expect(u.deletedPaths, ['/home/notes.txt']);
  });

  testWidgets('Dateien tab: upload writes the picked file to the current dir',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()..dirEntries = const [(name: 'x', isDir: false)];
    final picker = _FakeFilePicker(
        (name: 'config.yaml', bytes: Uint8List.fromList([1, 2, 3])));
    await tester.pumpWidget(page(u, filePicker: picker));
    await tester.pumpAndSettle();
    await goDateien(tester);

    await tester.tap(find.byIcon(Icons.upload_file));
    await tester.pumpAndSettle();

    expect(u.uploadedTo, ['/home/config.yaml']); // written into the browsed dir
  });

  testWidgets('Dateien tab: the list refreshes right after an upload (no manual refresh)',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..dirEntries = const [(name: 'old.txt', isDir: false)];
    final picker = _FakeFilePicker(
        (name: 'new.txt', bytes: Uint8List.fromList([1, 2, 3])));
    await tester.pumpWidget(page(u, filePicker: picker));
    await tester.pumpAndSettle();
    await goDateien(tester);

    expect(find.text('new.txt'), findsNothing); // not there before upload
    await tester.tap(find.byIcon(Icons.upload_file));
    await tester.pumpAndSettle();

    expect(find.text('new.txt'), findsOneWidget); // auto-reloaded, no manual tap
  });

  testWidgets('Dateien tab: reloads even if the upload marker is lost',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..dirEntries = const [(name: 'old.txt', isDir: false)]
      ..uploadThrows = true; // file written on the Pi, but reported as failure
    final picker = _FakeFilePicker(
        (name: 'new.txt', bytes: Uint8List.fromList([1])));
    await tester.pumpWidget(page(u, filePicker: picker));
    await tester.pumpAndSettle();
    await goDateien(tester);

    await tester.tap(find.byIcon(Icons.upload_file));
    await tester.pumpAndSettle();

    // The reload still surfaces the written file (the reported failure aside).
    expect(find.text('new.txt'), findsOneWidget);
  });

  testWidgets('Dateien tab: upload does not trip the app lock', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()..dirEntries = const [(name: 'x', isDir: false)];
    // The picker backgrounds the app (paused → resumed) while picking; with
    // app-lock ON, that must NOT drop the user back to the lock screen.
    final picker = _BackgroundingPicker(
      (name: 'a.txt', bytes: Uint8List.fromList([1])),
      () async {
        // Valid transitions only (the framework asserts them); `hidden` is one
        // of the states the lock triggers on.
        for (final s in const [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden, // → lock check happens here
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(s);
        }
      },
    );
    await tester.pumpWidget(MaterialApp(
      home: UpdaterPage(
        store: _FakeStore(const AppConfig(
          profiles: [Profile(name: 'S', host: '1.1.1.1', password: 'pw')],
          activeIndex: 0,
          disclaimerAccepted: true,
          lockEnabled: true,
        )),
        updater: u,
        updateChecker: _noUpdateChecker,
        authenticator: _AllowAuth(),
        filePicker: picker,
      ),
    ));
    await tester.pumpAndSettle(); // loads + auto-unlocks
    expect(find.text('Entsperren'), findsNothing); // unlocked to start

    await goDateien(tester);
    await tester.tap(find.byIcon(Icons.upload_file));
    await tester.pumpAndSettle();

    expect(u.uploadedTo, ['/home/a.txt']); // upload happened
    expect(find.text('Entsperren'), findsNothing); // and it did NOT re-lock
  });

  testWidgets('Einstellungen offers profile export + import', (tester) async {
    // The crypto round-trip is covered in profile_transfer_test; here we just
    // confirm the two entry points are wired into the settings sheet.
    useTallScreen(tester);
    await tester.pumpWidget(page(FakeEvccUpdater()));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Einstellungen'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Profile exportieren'));
    expect(find.text('Profile exportieren'), findsOneWidget);
    expect(find.text('Profile importieren'), findsOneWidget);
  });

  testWidgets('switching tabs clears the stale connection banner',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester); // sets the "Verbindung OK – erkannt: …" banner

    expect(find.textContaining('Verbindung OK'), findsOneWidget);
    await goDateien(tester);
    expect(find.textContaining('Verbindung OK'), findsNothing); // gone on switch
  });

  testWidgets('Dateien tab re-lists after switching Pi (no stale listing)',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..dirEntries = const [(name: 'piA.txt', isDir: false)];
    await tester.pumpWidget(MaterialApp(
      home: UpdaterPage(
        store: _FakeStore(const AppConfig(
          profiles: [
            Profile(name: 'A', host: '1.1.1.1', password: 'pw'),
            Profile(name: 'B', host: '2.2.2.2', password: 'pw'),
          ],
          activeIndex: 0,
          disclaimerAccepted: true,
        )),
        updater: u,
        updateChecker: _noUpdateChecker,
      ),
    ));
    await tester.pumpAndSettle();
    await goDateien(tester);
    expect(find.text('piA.txt'), findsOneWidget);

    u.dirEntries = const [(name: 'piB.txt', isDir: false)];
    await tester.tap(find.byKey(const Key('profileSwitcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();

    // Auto-re-listed for Pi B — the old Pi's entry must not linger.
    expect(find.text('piB.txt'), findsOneWidget);
    expect(find.text('piA.txt'), findsNothing);
  });

  testWidgets('Dateien tab: upload rejects a file over the size limit',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()..dirEntries = const [(name: 'x', isDir: false)];
    final picker = _FakeFilePicker(
        (name: 'big.bin', bytes: Uint8List(kFileUploadLimit + 1)));
    await tester.pumpWidget(page(u, filePicker: picker));
    await tester.pumpAndSettle();
    await goDateien(tester);

    await tester.tap(find.byIcon(Icons.upload_file));
    await tester.pumpAndSettle();

    expect(u.uploadedTo, isEmpty); // rejected before hitting the Pi
    expect(find.textContaining('zu groß'), findsWidgets);
  });

  testWidgets('Dateien tab: free user sees the Pro placeholder', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()..dirEntries = const [(name: 'x', isDir: false)];
    await tester.pumpWidget(page(u, entitlement: _FakeEntitlement(pro: false)));
    await tester.pumpAndSettle();
    await goDateien(tester);

    expect(find.text('Datei-Explorer (Pro)'), findsOneWidget);
    expect(find.text('x'), findsNothing); // no browsing for free users
  });

  testWidgets('test shows "Verbunden" and reveals the service cards',
      (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(page(FakeEvccUpdater()));
    await tester.pumpAndSettle();

    expect(find.text('Verbindung herstellen'), findsOneWidget);
    await detect(tester);

    expect(find.text('Verbunden'), findsOneWidget);
    expect(find.text('evcc'), findsWidgets); // evcc card
    expect(find.text('System (Pi)'), findsOneWidget);
  });

  testWidgets('a failed test shows the red "Keine Verbindung" state',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..detectError =
          const EvccUpdateException(UpdateErrorKind.connection, 'offline');
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    expect(find.text('Keine Verbindung'), findsWidgets);
  });

  testWidgets("switching the Pi profile clears the previous Pi's cards",
      (tester) async {
    useTallScreen(tester);
    const cfg = AppConfig(
      profiles: [
        Profile(name: 'S', host: '192.168.178.64', password: 'pw'),
        Profile(name: 'Eltern', host: '10.0.0.9', password: 'pw'),
      ],
      activeIndex: 0,
      disclaimerAccepted: true,
    );
    await tester.pumpWidget(MaterialApp(
      home: UpdaterPage(
        store: _FakeStore(cfg),
        updater: FakeEvccUpdater(),
        updateChecker: _noUpdateChecker,
      ),
    ));
    await tester.pumpAndSettle();

    await detect(tester); // connect → cards for the active Pi
    expect(find.text('System (Pi)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('profileSwitcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Eltern')); // switch to the other Pi
    await tester.pumpAndSettle();

    // The previous Pi's cards must be gone until the user reconnects.
    expect(find.text('System (Pi)'), findsNothing);
    expect(find.text('Verbindung herstellen'), findsOneWidget);
  });

  testWidgets('Home Assistant card "Aktualisieren" updates the container',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'homeassistant',
            name: 'Home Assistant',
            installed: true,
            version: 'stable',
            active: true,
            detail: 'Docker · homeassistant'),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    expect(find.text('Home Assistant'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Aktualisieren'));
    await tester.pumpAndSettle();

    expect(u.haUpdateCalls, 1);
  });

  testWidgets('an absent service is offered under „Dienst hinzufügen", not a card',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'homeassistant', name: 'Home Assistant', installed: false),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    // Not installed → no update card, only the add button.
    expect(find.widgetWithText(OutlinedButton, 'Aktualisieren'), findsNothing);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Dienst hinzufügen'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Home Assistant')); // picker row
    await tester.pumpAndSettle();
    // Install is destructive-ish → confirm dialog.
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();

    expect(u.haInstallCalls, 1);
  });

  testWidgets('evcc card "Aktualisieren" backs up then runs the update',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Aktualisieren'));
    await tester.pumpAndSettle();

    expect(u.backupCalls, 1);
    expect(u.runCalls, 1);
    expect(find.text('evcc 0.310.0 → 0.311.0 aktualisiert.'), findsOneWidget);
  });

  testWidgets('an update runs behind a foreground keep-alive (begin + end)',
      (tester) async {
    useTallScreen(tester);
    final ka = _FakeKeepAlive();
    await tester.pumpWidget(page(FakeEvccUpdater(), keepAlive: ka));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Aktualisieren'));
    await tester.pumpAndSettle();

    expect(ka.beginCount, 1);
    expect(ka.endCount, 1);
    expect(ka.lastMessage, contains('Update'));
  });

  testWidgets('Abbrechen appears while busy and cancels the connection',
      (tester) async {
    useTallScreen(tester);
    final gate = Completer<void>();
    final u = FakeEvccUpdater()..detectGate = gate;
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();

    // Start connecting; detectServices hangs on the gate, so it stays busy.
    await tester
        .tap(find.widgetWithText(OutlinedButton, 'Verbindung herstellen'));
    await tester.pump();

    expect(find.widgetWithText(OutlinedButton, 'Abbrechen'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Abbrechen'));
    await tester.pump();
    expect(u.cancelCalls, 1);

    gate.complete(); // release the pending future so the test settles cleanly
    await tester.pumpAndSettle();
  });

  testWidgets('an up-to-date service shows "Aktuell", update moves to ⋮',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'evcc',
            name: 'evcc',
            installed: true,
            version: '0.310.0',
            active: true,
            updateAvailable: false,
            updateKnown: true,
            detail: 'apt · Dienst aktiv'),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    expect(find.widgetWithText(OutlinedButton, 'Aktuell'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Aktualisieren'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('menu-evcc')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Trotzdem aktualisieren'));
    await tester.pumpAndSettle();

    expect(u.runCalls, 1); // forced update still works
  });

  testWidgets('evcc ⋮ → Backup wiederherstellen lists, picks and restores',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..backups = const [
        '/var/backups/evcc/evcc-backup-20260630-120000.tar.gz'
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-evcc'))); // evcc card ⋮
    await tester.pumpAndSettle();
    await tester.tap(find.text('Backup wiederherstellen'));
    await tester.pumpAndSettle();

    // The picker shows the formatted timestamp; choose it.
    expect(find.text('30.06.2026 12:00 Uhr'), findsOneWidget);
    await tester.tap(find.text('30.06.2026 12:00 Uhr'));
    await tester.pumpAndSettle();

    // Destructive → confirm.
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();

    expect(u.restoreCalls, 1);
    expect(u.restoredPath,
        '/var/backups/evcc/evcc-backup-20260630-120000.tar.gz');
  });

  testWidgets('keep-alive is released (end) even when the action fails',
      (tester) async {
    useTallScreen(tester);
    final ka = _FakeKeepAlive();
    final u = FakeEvccUpdater()
      ..backupError =
          const EvccUpdateException(UpdateErrorKind.unknown, 'backup boom');
    await tester.pumpWidget(page(u, keepAlive: ka));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Aktualisieren'));
    await tester.pumpAndSettle();

    expect(ka.beginCount, 1);
    expect(ka.endCount, 1); // foreground service released despite the failure
  });

  testWidgets('Grafana card updates via the generic apt path', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'grafana',
            name: 'Grafana',
            installed: true,
            version: '13.1.0',
            active: true,
            updateAvailable: true,
            updateKnown: true,
            detail: 'apt · grafana · Dienst aktiv',
            webPort: 3000,
            aptPackage: 'grafana'),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    expect(find.text('Grafana'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Aktualisieren'));
    await tester.pumpAndSettle();

    expect(u.aptUpdates, ['grafana']);
    expect(find.text('Grafana aktualisiert.'), findsOneWidget);
  });

  testWidgets('free user: Konsole is gated → paywall, command not run',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u, entitlement: _FakeEntitlement(pro: false)));
    await tester.pumpAndSettle();
    await goTerminal(tester);

    final field = find.byKey(const Key('consoleField'));
    await tester.ensureVisible(field);
    await tester.enterText(field, 'df -h');
    // The send button shows a lock for free users (Konsole is Pro).
    expect(find.byIcon(Icons.keyboard_return), findsNothing);
    await tester.tap(find.byIcon(Icons.lock_outline).first);
    await tester.pumpAndSettle();

    expect(find.text('Pi-Tool Pro'), findsOneWidget); // paywall
    expect(u.consoleCommands, isEmpty); // gated, never sent to the Pi
  });

  testWidgets('free user: Aufräumen shows a lock and opens the paywall',
      (tester) async {
    useTallScreen(tester);
    final ent = _FakeEntitlement(pro: false);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u, entitlement: ent));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-system')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aufräumen (Speicher freigeben)'));
    await tester.pumpAndSettle();

    expect(find.text('Pi-Tool Pro'), findsOneWidget);
    expect(u.cleanupCalls, 0);

    // Unlocking runs it: buy, then re-open the menu and tap again.
    await tester.tap(find.widgetWithText(FilledButton, 'Pro freischalten – 5 €'));
    await tester.pumpAndSettle();
    expect(ent.buyCalls, 1);
    await tester.tap(find.byKey(const ValueKey('menu-system')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aufräumen (Speicher freigeben)'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();
    expect(u.cleanupCalls, 1);
  });

  testWidgets('Home Assistant on the latest version shows "Aktuell"',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'homeassistant',
            name: 'Home Assistant',
            installed: true,
            version: '2026.6.3', // real version from /config/.HA_VERSION
            active: true,
            detail: 'Docker · homeassistant'),
      ];
    await tester.pumpWidget(page(u, haLatest: () async => '2026.6.3'));
    await tester.pumpAndSettle();
    await detect(tester);

    // Currency now KNOWN and current → "Aktuell", not a nagging "Aktualisieren".
    expect(find.text('Aktuell'), findsOneWidget);
  });

  testWidgets('System ⋮ → Automatische Updates schedules a daily timer',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u)); // dormant entitlement → Pro
    await tester.pumpAndSettle();
    await goAutomatik(tester);

    await tester.tap(find.text('Automatische Updates'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Einschalten'));
    await tester.pumpAndSettle();

    expect(u.enabledOnCalendar, '*-*-* 04:00:00'); // default: daily 04:00
  });

  testWidgets('free user: Automatische Updates is gated behind the paywall',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u, entitlement: _FakeEntitlement(pro: false)));
    await tester.pumpAndSettle();
    await goAutomatik(tester);

    await tester.tap(find.text('Automatische Updates'));
    await tester.pumpAndSettle();

    expect(find.text('Pi-Tool Pro'), findsOneWidget);
    expect(u.enabledOnCalendar, isNull);
  });

  testWidgets('guided setup installs the selected monitoring stack in one flow',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater(); // default: evcc + system → the stack is missing
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Dienst hinzufügen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Energie-Monitoring-Stack'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Installieren'));
    await tester.pumpAndSettle();

    // All three stack parts installed in sequence.
    expect(u.aptInstalls, containsAll(['influxdb', 'grafana', 'mosquitto']));
  });

  testWidgets('evcc ⋮ → Konfiguration bearbeiten edits and saves (with backup)',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'evcc',
            name: 'evcc',
            installed: true,
            version: '0.310.0',
            active: true,
            detail: 'apt · Dienst aktiv'),
      ]
      ..configText = 'network:\n  schema: http';
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-evcc')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Konfiguration bearbeiten'));
    await tester.pumpAndSettle();

    expect(find.text('evcc.yaml'), findsOneWidget); // editor page opened
    await tester.enterText(
        find.byType(TextField).first, 'network:\n  schema: https');
    await tester.tap(find.byIcon(Icons.save));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();

    expect(u.savedConfig, contains('https'));
  });

  testWidgets('Dateien tab lists dirs + previews a file', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..dirEntries = const [(name: 'notes.txt', isDir: false)]
      ..fileBytes = Uint8List.fromList(utf8.encode('hallo pi'));
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await goDateien(tester);

    expect(find.text('notes.txt'), findsOneWidget); // listing
    await tester.tap(find.text('notes.txt'));
    await tester.pumpAndSettle();
    expect(find.textContaining('hallo pi'), findsOneWidget); // preview
  });

  testWidgets('Tailscale: adopt the tailnet IP into the host field',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'tailscale',
            name: 'Tailscale',
            installed: true,
            active: true,
            version: '100.101.102.103',
            detail: 'Verbunden · 100.101.102.103'),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-tailscale')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Diese IP als Host übernehmen'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Host auf 100.101.102.103'), findsOneWidget);
  });

  testWidgets('Tailscale: Verbinden triggers up when disconnected',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'tailscale',
            name: 'Tailscale',
            installed: true,
            active: false,
            detail: 'Getrennt'),
      ]
      ..tailscaleUpUrl = null; // already authed → just connects
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Verbinden'));
    await tester.pumpAndSettle();
    expect(u.tailscaleUpCalls, 1);
  });

  testWidgets('Pi Connect: incompatible OS is greyed out with a reason',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'system', name: 'System (Pi)', installed: true, active: true),
        ServiceStatus(
            id: 'piconnect',
            name: 'Raspberry Pi Connect',
            installed: false,
            compatible: false),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Dienst hinzufügen'));
    await tester.pumpAndSettle();
    // Shown (customer knows it exists) but tapping explains why, no install.
    expect(find.text('Raspberry Pi Connect'), findsOneWidget);
    await tester.tap(find.text('Raspberry Pi Connect'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Bookworm'), findsWidgets);
    expect(u.piConnectInstalled, isFalse);
  });

  testWidgets('Pi Connect: a signed-in node shows aktiv + can pause remote',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'piconnect',
            name: 'Raspberry Pi Connect',
            installed: true,
            active: true, // signed in → active (green), NOT "inaktiv"
            detail: 'Angemeldet'),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    expect(find.text('aktiv'), findsOneWidget); // was falsely "inaktiv" before
    await tester.tap(find.byKey(const ValueKey('menu-piconnect')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fernzugriff pausieren'));
    await tester.pumpAndSettle();
    expect(u.piConnectSetOn, isFalse);
  });

  testWidgets('service ⋮ → Logs anzeigen shows the log sheet', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()..serviceLogs = 'evcc[1]: charging started';
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-evcc')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Logs anzeigen'));
    await tester.pumpAndSettle();

    expect(find.textContaining('charging started'), findsOneWidget);
  });

  testWidgets('evcc ⋮ links the official evcc app', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-evcc')));
    await tester.pumpAndSettle();
    // Moved out of the footer into the evcc card's ⋮ menu.
    expect(find.text('Offizielle evcc-App'), findsOneWidget);
  });

  testWidgets('Automatik → Health-Alerts: enable installs with the topic',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await goAutomatik(tester);

    await tester.tap(find.text('Health-Alerts'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'mein-pi-a7Xk');
    await tester.tap(find.widgetWithText(FilledButton, 'Einschalten'));
    await tester.pumpAndSettle();

    expect(u.alertsTopic, 'mein-pi-a7Xk');
  });

  testWidgets('Automatik → auto-updates: turn OFF when currently active',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..autoStatus = (enabled: true, nextRun: 'So 04:00', lastResult: 'ok');
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await goAutomatik(tester);

    await tester.tap(find.text('Automatische Updates'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Ausschalten'));
    await tester.pumpAndSettle();

    expect(u.autoUpdateDisabled, isTrue);
  });

  testWidgets('Automatik → Health-Alerts: send a test push, then turn OFF',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..alertsStatus = (enabled: true, lastCheck: '12:00');
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await goAutomatik(tester);

    await tester.tap(find.text('Health-Alerts'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'mein-topic-xyz');
    await tester.tap(find.widgetWithText(OutlinedButton, 'Test'));
    await tester.pumpAndSettle();
    expect(u.testAlertCalls, 1);

    await tester.tap(find.widgetWithText(TextButton, 'Ausschalten'));
    await tester.pumpAndSettle();
    expect(u.alertsDisabled, isTrue);
  });

  testWidgets('System ⋮ → Aufräumen frees space after a confirm',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-system')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aufräumen (Speicher freigeben)'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();

    expect(u.cleanupCalls, 1);
    expect(find.textContaining('250 MB freigegeben'), findsOneWidget);
  });

  testWidgets('Pi-hole ⋮ → Backups verwalten → restore flow', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'pihole',
            name: 'Pi-hole',
            installed: true,
            version: 'v6.0.4',
            active: true),
      ]
      ..serviceBackups = const [
        '/var/backups/pi-tool/pihole-backup-20260706-090000.zip'
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-pihole')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Backups verwalten'));
    await tester.pumpAndSettle();

    // The sheet lists the backup with its formatted timestamp → tap = restore.
    await tester.tap(find.text('06.07.2026 09:00 Uhr'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();

    expect(u.restoredPihole,
        ['/var/backups/pi-tool/pihole-backup-20260706-090000.zip']);
    expect(find.textContaining('wiederhergestellt'), findsWidgets);
  });

  testWidgets('backup manager: trash icon deletes after a confirm',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'pihole',
            name: 'Pi-hole',
            installed: true,
            version: 'v6.0.4',
            active: true),
      ]
      ..serviceBackups = const [
        '/var/backups/pi-tool/pihole-backup-20260706-090000.zip'
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-pihole')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Backups verwalten'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();

    expect(u.deletedBackups,
        ['/var/backups/pi-tool/pihole-backup-20260706-090000.zip']);
    expect(u.restoredPihole, isEmpty);
  });

  testWidgets('backup manager: download icon fetches + hands off to the saver',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'pihole',
            name: 'Pi-hole',
            installed: true,
            version: 'v6.0.4',
            active: true),
      ]
      ..serviceBackups = const [
        '/var/backups/pi-tool/pihole-backup-20260706-090000.zip'
      ]
      ..downloadBytes = Uint8List.fromList([9, 9, 9]);
    final saved = <(String, int)>[];
    await tester.pumpWidget(page(u,
        fileSaver: (name, bytes) async => saved.add((name, bytes.length))));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-pihole')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Backups verwalten'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.download_outlined));
    await tester.pumpAndSettle();

    expect(u.downloadedPaths,
        ['/var/backups/pi-tool/pihole-backup-20260706-090000.zip']);
    expect(saved, [('pihole-backup-20260706-090000.zip', 3)]);
    expect(u.restoredPihole, isEmpty); // tap on the icon must not restore
  });

  testWidgets('console history: a run command is persisted and re-offered',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await goTerminal(tester);

    final field = find.byKey(const Key('consoleField'));
    await tester.ensureVisible(field);
    await tester.enterText(field, 'free -h');
    await tester.tap(find.byIcon(Icons.keyboard_return));
    await tester.pumpAndSettle();

    // History sheet offers the command; tapping fills the field (not run).
    await tester.tap(find.byIcon(Icons.history).first);
    await tester.pumpAndSettle();
    expect(find.text('Verlauf'), findsOneWidget);
    await tester.tap(find.text('free -h').last);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, 'free -h');
    expect(u.consoleCommands, ['free -h']); // not re-run by the tap

    // The history can be cleared (privacy: commands may contain secrets).
    await tester.tap(find.byIcon(Icons.history).first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Löschen'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.history).first);
    await tester.pumpAndSettle();
    expect(find.text('Verlauf'), findsNothing); // history section gone
  });

  testWidgets('console: a typed command is run on the Pi', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await goTerminal(tester);

    final field = find.byKey(const Key('consoleField'));
    await tester.ensureVisible(field);
    await tester.enterText(field, 'df -h');
    await tester.tap(find.byIcon(Icons.keyboard_return));
    await tester.pumpAndSettle();

    expect(u.consoleCommands, ['df -h']);
    expect(find.textContaining(r'$ df -h'), findsWidgets); // echoed in console
  });

  testWidgets('console: an interactive command (htop) is not run, shows a hint',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await goTerminal(tester);

    final field = find.byKey(const Key('consoleField'));
    await tester.ensureVisible(field);
    await tester.enterText(field, 'htop');
    await tester.tap(find.byIcon(Icons.keyboard_return));
    await tester.pumpAndSettle();

    expect(u.consoleCommands, isEmpty); // never sent to the Pi
    expect(find.textContaining('top -bn1'), findsWidgets); // helpful hint shown
  });

  testWidgets('the System (Pi) card is rendered first', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater(); // default: evcc + system, in that order
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    final systemMenu = find.byKey(const ValueKey('menu-system'));
    final evccMenu = find.byKey(const ValueKey('menu-evcc'));
    expect(systemMenu, findsOneWidget);
    expect(evccMenu, findsOneWidget);
    // System sits above evcc even though it was detected second.
    expect(tester.getTopLeft(systemMenu).dy,
        lessThan(tester.getTopLeft(evccMenu).dy));
  });

  testWidgets('„Dienst hinzufügen" picker installs the chosen apt service',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater(); // default services: evcc + system installed
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    // Not-yet-installed services live behind one button.
    final addBtn = find.widgetWithText(OutlinedButton, 'Dienst hinzufügen');
    expect(addBtn, findsOneWidget);
    await tester.ensureVisible(addBtn);
    await tester.tap(addBtn);
    await tester.pumpAndSettle();

    // Picker lists Grafana, InfluxDB and Mosquitto (none present yet).
    expect(find.text('Grafana'), findsOneWidget);
    expect(find.text('InfluxDB'), findsOneWidget);
    expect(find.text('Mosquitto'), findsOneWidget);

    await tester.tap(find.text('Grafana'));
    await tester.pumpAndSettle();

    expect(u.aptInstalls, ['grafana']);
    expect(find.textContaining('Grafana installiert'), findsOneWidget);
  });

  testWidgets('a not-installed bespoke service (evcc) routes to its install',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(id: 'evcc', name: 'evcc', installed: false),
        ServiceStatus(
            id: 'system', name: 'System (Pi)', installed: true, active: true),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Dienst hinzufügen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('evcc')); // picker row
    await tester.pumpAndSettle();

    // Routes to the evcc install flow (its confirm dialog).
    expect(find.text('evcc installieren?'), findsOneWidget);
  });

  testWidgets('installed services are not offered in the add picker',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'grafana',
            name: 'Grafana',
            installed: true,
            version: '11.0.0',
            active: true,
            webPort: 3000),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Dienst hinzufügen'));
    await tester.pumpAndSettle();

    // Grafana already runs → only InfluxDB + Mosquitto remain installable.
    expect(find.text('InfluxDB'), findsOneWidget);
    expect(find.text('Mosquitto'), findsOneWidget);
  });

  testWidgets('Pi-hole ⋮ → Sichern runs the teleporter backup', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'pihole',
            name: 'Pi-hole',
            installed: true,
            version: 'v6.0.4',
            active: true,
            updateKnown: true,
            detail: 'Blocking aktiv'),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-pihole'))); // Pi-hole ⋮
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sichern (Teleporter)'));
    await tester.pumpAndSettle();

    expect(u.piholeBackupCalls, 1);
    expect(find.textContaining('Pi-hole gesichert'), findsOneWidget);
  });

  testWidgets('a dry-run (Probelauf) does NOT start the keep-alive',
      (tester) async {
    useTallScreen(tester);
    final ka = _FakeKeepAlive();
    await tester.pumpWidget(page(FakeEvccUpdater(), keepAlive: ka));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-evcc'))); // evcc card ⋮
    await tester.pumpAndSettle();
    await tester.tap(find.text('Probelauf (ändert nichts)'));
    await tester.pumpAndSettle();

    expect(ka.beginCount, 0);
  });

  testWidgets('evcc card on a docker install recreates the container',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..detection = const InstallDetection(
          kind: InstallKind.docker,
          container: EvccDocker(name: 'evcc', image: 'evcc/evcc:latest'));
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Aktualisieren'));
    await tester.pumpAndSettle();

    expect(u.dockerCalls, 1);
    expect(u.runCalls, 0);
    expect(find.textContaining('Container aktualisiert'), findsOneWidget);
  });

  testWidgets('evcc card ⋮ → Probelauf on docker reports it is unavailable',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..detection = const InstallDetection(
          kind: InstallKind.docker,
          container: EvccDocker(name: 'evcc', image: 'evcc/evcc:latest'));
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    // Target the evcc card's menu by its stable key (order-independent).
    await tester.tap(find.byKey(const ValueKey('menu-evcc')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Probelauf (ändert nichts)'));
    await tester.pumpAndSettle();

    expect(u.dockerCalls, 0);
    expect(find.textContaining('Docker-Installationen nicht verfügbar'),
        findsOneWidget);
  });

  testWidgets('a changed host key surfaces the trust-and-retry button',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..detectError = const EvccUpdateException(
          UpdateErrorKind.hostKeyChanged, 'Host-Key geändert!');
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    expect(find.textContaining('neuen Key vertrauen'), findsOneWidget);
  });

  testWidgets('switching Pi clears a pending host-key trust prompt',
      (tester) async {
    useTallScreen(tester);
    const cfg = AppConfig(
      profiles: [
        Profile(name: 'S', host: '192.168.178.64', password: 'pw'),
        Profile(name: 'Eltern', host: '10.0.0.9', password: 'pw'),
      ],
      activeIndex: 0,
      disclaimerAccepted: true,
    );
    final u = FakeEvccUpdater()
      ..detectError = const EvccUpdateException(
          UpdateErrorKind.hostKeyChanged, 'Host-Key geändert!');
    await tester.pumpWidget(MaterialApp(
      home: UpdaterPage(
        store: _FakeStore(cfg),
        updater: u,
        updateChecker: _noUpdateChecker,
      ),
    ));
    await tester.pumpAndSettle();

    await detect(tester); // host-key prompt for the active Pi
    expect(find.textContaining('neuen Key vertrauen'), findsOneWidget);

    // Switch to the other Pi via the app-bar profile switcher.
    await tester.tap(find.byKey(const Key('profileSwitcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Eltern'));
    await tester.pumpAndSettle();

    // The stale trust prompt (pointed at the previous Pi) must be gone.
    expect(find.textContaining('neuen Key vertrauen'), findsNothing);
  });

  testWidgets('trust-and-retry forgets the key and replays the test',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..detectError = const EvccUpdateException(
          UpdateErrorKind.hostKeyChanged, 'Host-Key geändert!');
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    u.detectError = null; // retry now succeeds
    await tester.tap(find.byIcon(Icons.verified_user_outlined));
    await tester.pumpAndSettle();

    expect(u.forgetCalls, 1);
    expect(u.forgotConfig!.host, '192.168.178.64');
    expect(find.text('Verbunden'), findsOneWidget);
  });

  testWidgets('update is cancellable from the release-notes confirm',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u,
        rel: () async => const EvccRelease(version: '0.311.0', notes: 'x')));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Aktualisieren'));
    await tester.pumpAndSettle();
    expect(find.text('evcc 0.311.0 installieren?'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Abbrechen'));
    await tester.pumpAndSettle();
    expect(u.runCalls, 0); // cancelled → no SSH run
  });

  testWidgets('Pi finden with no results shows the manual-entry hint',
      (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(MaterialApp(
      home: UpdaterPage(
        store: _FakeStore(_ready),
        updater: FakeEvccUpdater(),
        updateChecker: _noUpdateChecker,
        piFinder: () async => <String>[],
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pi im WLAN suchen'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Keine SSH-Geräte'), findsOneWidget);
  });

  testWidgets(
      'Multi-Pi overview probes every profile and shows traffic-light status',
      (tester) async {
    useTallScreen(tester);
    // System card reports a pending update → the reachable Pi should be flagged.
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
          id: 'system',
          name: 'System (Pi)',
          installed: true,
          active: true,
          updateAvailable: true,
          updateKnown: true,
          health: '48 Grad · 12% belegt',
        ),
      ];
    await tester.pumpWidget(MaterialApp(
      home: UpdaterPage(
        store: _FakeStore(const AppConfig(
          profiles: [
            Profile(name: 'Wohnzimmer', host: '10.0.0.5', password: 'pw'),
            Profile(name: 'Keller'), // no host → unreachable (red)
          ],
          activeIndex: 0,
          disclaimerAccepted: true,
        )),
        updater: u,
        updateChecker: _noUpdateChecker,
      ),
    ));
    await tester.pumpAndSettle();

    // The overview entry only appears with more than one profile.
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alle Pis (Überblick)'));
    await tester.pumpAndSettle();

    // Both profiles listed; the reachable one flags its update, the host-less
    // one is reported unreachable — fail-soft, not an exception.
    expect(find.text('Wohnzimmer'), findsOneWidget);
    expect(find.text('Keller'), findsOneWidget);
    expect(find.textContaining('Updates verfügbar'), findsWidgets);
    expect(find.textContaining('Kein Host'), findsOneWidget);
  });

  testWidgets('⋮ → Pi herunterfahren confirms, then powers the Pi off',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pi herunterfahren'));
    await tester.pumpAndSettle();

    // A destructive confirm gates the shutdown — nothing runs until confirmed.
    expect(find.text('Pi herunterfahren?'), findsOneWidget);
    expect(u.shutdownCalls, 0);
    await tester.tap(find.widgetWithText(FilledButton, 'Herunterfahren'));
    await tester.pumpAndSettle();
    expect(u.shutdownCalls, 1);
  });
}
