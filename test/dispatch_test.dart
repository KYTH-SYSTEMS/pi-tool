import 'dart:async';
import 'package:evcc_updater/src/l10n.dart';
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
import 'package:evcc_updater/src/history.dart';
import 'package:evcc_updater/src/keep_alive.dart';
import 'package:evcc_updater/src/parsing.dart';
import 'package:evcc_updater/src/pi_job.dart';
import 'package:evcc_updater/src/profile_transfer.dart';
import 'package:evcc_updater/src/profiles.dart';
import 'package:evcc_updater/src/secure_screen.dart';
import 'package:evcc_updater/src/services/apt_services.dart';
import 'package:evcc_updater/src/app_launcher.dart';
import 'package:evcc_updater/src/docker_containers.dart';
import 'package:evcc_updater/src/scheduled_backup.dart';
import 'package:evcc_updater/src/security_check.dart';
import 'package:evcc_updater/src/storage_explorer.dart';
import 'package:evcc_updater/src/evcc_api.dart';
import 'package:evcc_updater/src/services/pi_service.dart';
import 'package:evcc_updater/src/services/stack_wiring.dart';
import 'package:evcc_updater/src/services/tailscale.dart';
import 'package:evcc_updater/src/settings_store.dart';
import 'package:evcc_updater/src/ssh_runner.dart';
import 'package:evcc_updater/src/update_check.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';

class _FakeFilePicker implements FilePickerService {
  _FakeFilePicker(this.file);
  final PickedFile? file;
  @override
  Future<PickedFile?> pick() async => file;
}

/// Picker that fails the way the native side does (a PlatformException with
/// its error code, e.g. `too_large` for a file over the upload limit).
class _ThrowingPicker implements FilePickerService {
  _ThrowingPicker(this.error);
  final Object error;
  @override
  Future<PickedFile?> pick() async => throw error;
}

/// Records every FLAG_SECURE request, so tests can see whether screenshots are
/// blocked right now ([calls].last) without a platform channel.
class _RecordingSecureScreen implements SecureScreen {
  final calls = <bool>[];
  @override
  Future<void> setSecure(bool secure) async => calls.add(secure);
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

class _FakeLauncher implements AppLauncher {
  final opened = <String>[];
  bool installed = true; // does openApp find the app?
  @override
  Future<bool> openApp(String package, {required String fallbackUrl}) async {
    opened.add(package);
    return installed;
  }
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

/// History store that records what the UI adds, without secure storage.
class _RecordingHistory extends HistoryStore {
  final added = <String>[];
  @override
  Future<List<HistoryEntry>> load() async => const [];
  @override
  Future<void> add(HistoryEntry entry) async => added.add(entry.text);
  @override
  Future<void> clear() async => added.clear();
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
  /// What detection sees on one particular host instead of [services] — for
  /// flows across two Pis (the migration helper's source and target).
  Map<String, List<ServiceStatus>> servicesByHost = {};
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
  int detectCalls = 0, aptRefreshCalls = 0;

  /// Hosts that answer [probeConnection]; everything else is "unreachable".
  Set<String> reachableHosts = {};
  final List<String> probedHosts = [];
  final List<String> detectHosts = []; // which address detection actually used
  int haInstallCalls = 0, haUpdateCalls = 0;
  SshConfig? forgotConfig;

  @override
  Future<List<ServiceStatus>> detectServices({
    required SshConfig config,
    required void Function(String line) onLog,
    bool allowSudoForDocker = true,
    void Function()? onConnected,
  }) async {
    detectCalls++;
    detectHosts.add(config.host);
    if (detectGate != null) await detectGate!.future;
    onConnected?.call();
    if (detectError != null) throw detectError!;
    return servicesByHost[config.host] ?? services;
  }

  @override
  Future<void> cancel() async => cancelCalls++;

  int restartServiceCalls = 0;
  Completer<void>? restartGate; // if set, restartService awaits it (stay busy)
  @override
  Future<void> restartService({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async {
    restartServiceCalls++;
    if (restartGate != null) await restartGate!.future;
  }

  int rebootCalls = 0;
  @override
  Future<void> reboot({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async =>
      rebootCalls++;

  int shutdownCalls = 0;
  @override
  Future<void> shutdown({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async =>
      shutdownCalls++;

  ScheduledBackupStatus scheduledBackupStatus =
      (
        enabled: false,
        nextRun: null,
        lastResult: null,
        wrapperOutdated: false
      );
  String? scheduledBackupOnCal;
  int? scheduledBackupKeep;
  bool scheduledBackupDisabled = false;
  @override
  Future<ScheduledBackupStatus> readScheduledBackupStatus({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async =>
      scheduledBackupStatus;
  @override
  Future<void> enableScheduledBackup({
    required SshConfig config,
    required String onCalendar,
    required int keep,
    required void Function(String line) onLog,
  }) async {
    scheduledBackupOnCal = onCalendar;
    scheduledBackupKeep = keep;
  }

  @override
  Future<void> disableScheduledBackup({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async =>
      scheduledBackupDisabled = true;

  final restartedUnits = <String>[];
  @override
  Future<void> restartSystemdUnit({
    required SshConfig config,
    required String unit,
    required void Function(String line) onLog,
  }) async =>
      restartedUnits.add(unit);

  List<DockerContainer> containers = const [];
  final restartedContainers = <String>[];
  final updatedContainers = <String>[];

  @override
  Future<void> updateDockerContainer({
    required SshConfig config,
    required String name,
    required void Function(String line) onLog,
  }) async =>
      updatedContainers.add(name);
  @override
  Future<List<DockerContainer>> dockerContainers({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async =>
      containers;
  Object? restartContainerError;

  @override
  Future<void> restartDockerContainer({
    required SshConfig config,
    required String name,
    required void Function(String line) onLog,
  }) async {
    restartedContainers.add(name);
    if (restartContainerError != null) throw restartContainerError!;
  }
  @override
  Future<String> fetchDockerLogs({
    required SshConfig config,
    required String name,
    required void Function(String line) onLog,
  }) async =>
      'docker logs of $name';

  List<DiskEntry> disk = const [];

  /// Per-path answers and failures of the drill-down; [disk] is the default.
  final diskByPath = <String, List<DiskEntry>>{};
  final diskErrors = <String, Object>{};
  @override
  Future<List<DiskEntry>> diskUsage({
    required SshConfig config,
    required String path,
    required void Function(String line) onLog,
  }) async {
    final error = diskErrors[path];
    if (error != null) throw error;
    return diskByPath[path] ?? disk;
  }

  int stackWirings = 0;
  StackWiringOutcome stackOutcome = StackWiringOutcome.wired;

  @override
  Future<StackWiringOutcome> wireMonitoringStack({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async {
    stackWirings++;
    return stackOutcome;
  }

  List<SecurityFinding> securityFindings = const [];
  final securityFixes = <SecurityFix>[];

  /// What the Pi-hole password fix / install "sets" (null = one existed).
  String? piholeWebPassword;
  int piholeInstallCalls = 0;
  final piholeInstallHosts = <String>[]; // which Pi got Pi-hole installed

  @override
  Future<String?> installPihole({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async {
    piholeInstallCalls++;
    piholeInstallHosts.add(config.host);
    return piholeWebPassword;
  }

  @override
  Future<String?> fixSecurity(
      {required SshConfig config,
      required SecurityFix fix,
      required void Function(String line) onLog}) async {
    securityFixes.add(fix);
    if (fix == SecurityFix.piholePassword) {
      securityFindings = const [
        (
          title: 'Pi-hole-Weboberfläche',
          level: SecurityLevel.ok,
          detail: 'Die Weboberfläche ist passwortgeschützt.'
        ),
      ];
      return piholeWebPassword;
    }
    // The fix worked: the re-check that follows sees the finding green.
    securityFindings = const [
      (
        title: 'SSH-Root-Login',
        level: SecurityLevel.ok,
        detail: 'Root-Login per SSH ist deaktiviert.'
      ),
    ];
    return null;
  }
  @override
  Future<List<SecurityFinding>> runSecurityCheck({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async =>
      securityFindings;

  final installedKeys = <String>[];
  @override
  Future<void> installSshKey({
    required SshConfig config,
    required String publicKeyLine,
    required void Function(String line) onLog,
  }) async =>
      installedKeys.add(publicKeyLine);

  bool keyAuthOk = true; // does the Pi accept the freshly installed key?
  @override
  Future<bool> verifyKeyAuth({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async =>
      keyAuthOk;

  final aptUpdates = <String>[]; // packages updated via updateAptPackage
  final aptInstalls = <String>[]; // service ids installed via installAptService
  int piholeBackupCalls = 0, haBackupCalls = 0;

  @override
  Future<void> updateAptPackage({
    required SshConfig config,
    required String package,
    required void Function(String line) onLog,
    void Function(JobRef ref)? onJobStarted,
  }) async {
    aptUpdates.add(package);
    await _jobHooks(onJobStarted);
  }

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

  Object? piholeRestoreError; // thrown by restorePiholeBackup

  @override
  Future<void> restorePiholeBackup({
    required SshConfig config,
    required String path,
    required void Function(String line) onLog,
  }) async {
    if (piholeRestoreError != null) throw piholeRestoreError!;
    restoredPihole.add(path);
  }

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
      (
        enabled: false,
        nextRun: null,
        lastResult: null,
        wrapperOutdated: false
      );

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
  int tailscaleInstallCalls = 0;
  int tailscaleUpCalls = 0;
  String? tailscaleUpUrl;
  Object? tailscaleUpError; // thrown by tailscaleUp (sudo refused, cancelled …)
  bool? tailscaleLoggedOut;

  @override
  Future<void> installTailscale({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async {
    tailscaleInstallCalls++;
    tailscaleInstalled = true;
  }

  @override
  Future<String?> tailscaleUp({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async {
    tailscaleUpCalls++;
    if (tailscaleUpError != null) throw tailscaleUpError!;
    return tailscaleUpUrl;
  }

  @override
  Future<void> tailscaleSet({
    required SshConfig config,
    required bool logout,
    required void Function(String line) onLog,
  }) async =>
      tailscaleLoggedOut = logout;

  final uninstalled = <(String, bool)>[];
  Object? uninstallError;

  @override
  Future<void> uninstallService({
    required SshConfig config,
    required String id,
    required bool purge,
    required void Function(String line) onLog,
  }) async {
    if (uninstallError != null) throw uninstallError!;
    uninstalled.add((id, purge));
    services = [for (final s in services) if (s.id != id) s];
  }

  int shareLanCalls = 0, unshareLanCalls = 0;

  /// What the next detection sees after sharing (the Pi's new state).
  List<ServiceStatus>? servicesAfterShare;

  @override
  Future<List<String>> tailscaleShareLan({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async {
    shareLanCalls++;
    if (servicesAfterShare != null) services = servicesAfterShare!;
    return const ['192.168.178.0/24'];
  }

  @override
  Future<void> tailscaleUnshareLan({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async =>
      unshareLanCalls++;

  List<DirEntry> dirEntries = const [];
  Uint8List fileBytes = Uint8List(0);
  final uploadedTo = <String>[];
  final deletedPaths = <String>[];
  int listDirCalls = 0; // every listing is an SSH login with the sudo password
  // Thrown by the file operations of the Dateien tab.
  Object? listDirError, deleteError, readFileError;

  @override
  Future<List<DirEntry>> listDir({
    required SshConfig config,
    required String path,
    required void Function(String line) onLog,
  }) async {
    listDirCalls++;
    if (listDirError != null) throw listDirError!;
    return dirEntries;
  }

  bool uploadThrows = false;
  Object? uploadError; // thrown before anything reaches the Pi

  @override
  Future<void> uploadFile({
    required SshConfig config,
    required String path,
    required Uint8List bytes,
    required void Function(String line) onLog,
  }) async {
    if (uploadError != null) throw uploadError!;
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
  }) async {
    if (deleteError != null) throw deleteError!;
    deletedPaths.add(path);
  }

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
  }) async {
    if (readFileError != null) throw readFileError!;
    return fileBytes;
  }

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
  int logFetches = 0;
  Object? logError; // thrown by fetchServiceLogs (a poll that fails)

  @override
  Future<String> fetchServiceLogs({
    required SshConfig config,
    required String id,
    required String detail,
    required void Function(String line) onLog,
  }) async {
    logFetches++;
    if (logError != null) throw logError!;
    return serviceLogs;
  }

  String? alertsTopic, alertsServer;
  bool alertsDisabled = false;
  int testAlertCalls = 0;
  AlertsStatus alertsStatus =
      (enabled: false, lastCheck: null, wrapperOutdated: false);
  Completer<void>? testAlertGate; // if set, sendTestAlert awaits it (in flight)
  // What sendTestAlert logs / throws, given the topic it was called with.
  String Function(String topic)? testAlertLog;
  Object Function(String topic)? testAlertError;
  // What enableAlerts logs, given the topic it was called with.
  String Function(String topic)? enableAlertsLog;

  @override
  Future<void> enableAlerts({
    required SshConfig config,
    required String ntfyServer,
    required String ntfyTopic,
    required void Function(String line) onLog,
  }) async {
    alertsServer = ntfyServer;
    alertsTopic = ntfyTopic;
    if (enableAlertsLog != null) onLog(enableAlertsLog!(ntfyTopic));
  }

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
  }) async {
    testAlertCalls++;
    if (testAlertGate != null) await testAlertGate!.future;
    if (testAlertLog != null) onLog(testAlertLog!(ntfyTopic));
    if (testAlertError != null) throw testAlertError!(ntfyTopic);
  }

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


  /// The archive [backupPihole] reports: Pi-hole v6 writes a `.zip`, v5 a
  /// `.tar.gz` (which only the web interface can import).
  String piholeBackupPath = '/var/backups/pi-tool/pihole-backup-x.zip';

  @override
  Future<String> backupPihole({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async {
    piholeBackupCalls++;
    return piholeBackupPath;
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
    void Function(JobRef ref)? onJobStarted,
  }) async {
    runCalls++;
    if (!dryRun) await _jobHooks(onJobStarted);
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
    void Function(JobRef ref)? onJobStarted,
  }) async {
    piholeUpdateCalls++;
    await _jobHooks(onJobStarted);
  }

  SystemUpgradeResult systemUpgradeResult = const SystemUpgradeResult();

  @override
  Future<SystemUpgradeResult> upgradeSystem({
    required SshConfig config,
    required void Function(String line) onLog,
    void Function(JobRef ref)? onJobStarted,
  }) async {
    systemUpgradeCalls++;
    await _jobHooks(onJobStarted);
    return systemUpgradeResult;
  }

  // ---- Pi-Jobs --------------------------------------------------------------
  /// When set, every job-backed action reports this job as started…
  JobRef? startedJob;

  /// …then waits here (the UI sits in the "job runs" phase)…
  Completer<void>? jobGate;

  /// …and finally throws this (e.g. a JobException for detached/busy).
  Object? jobError;

  Future<void> _jobHooks(void Function(JobRef ref)? onJobStarted) async {
    final r = startedJob;
    if (r != null) onJobStarted?.call(r);
    if (jobGate != null) await jobGate!.future;
    if (jobError != null) throw jobError!;
  }

  int followCalls = 0;
  String? followedJobId;
  Object? followError;
  Completer<void>? followGate;
  JobOutcome followOutcome = const JobOutcome(
      kind: jobKindSystemUpgrade,
      success: true,
      message: 'System aktualisiert.');

  @override
  Future<JobOutcome> followJob({
    required SshConfig config,
    required String jobId,
    required void Function(String line) onLog,
    void Function(JobRef ref)? onJobStarted,
  }) async {
    followCalls++;
    followedJobId = jobId;
    onJobStarted?.call(JobRef(id: jobId, kind: followOutcome.kind));
    if (followGate != null) await followGate!.future;
    if (followError != null) throw followError!;
    return followOutcome;
  }

  Completer<void>? aptRefreshGate; // if set, refreshAptIndex awaits it

  @override
  Future<void> refreshAptIndex({
    required SshConfig config,
    required void Function(String line) onLog,
  }) async {
    aptRefreshCalls++;
    if (aptRefreshGate != null) await aptRefreshGate!.future;
  }

  int repairPackageCalls = 0;

  @override
  Future<void> repairPackageState({
    required SshConfig config,
    required void Function(String line) onLog,
    void Function(JobRef ref)? onJobStarted,
  }) async {
    repairPackageCalls++;
    await _jobHooks(onJobStarted);
  }

  /// Thrown by [probeConnection] — the real one rethrows only a changed host
  /// key; everything else (a cancel included) comes back as "unreachable".
  Object? probeError;
  Completer<void>? probeGate; // if set, a probe awaits it (stay busy)

  @override
  Future<bool> probeConnection({
    required SshConfig config,
    void Function(String line)? onLog,
  }) async {
    probedHosts.add(config.host);
    if (probeGate != null) await probeGate!.future;
    if (probeError != null) throw probeError!;
    return reachableHosts.contains(config.host);
  }

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
  String? lastMessage, lastChannelName, lastChannelDescription;
  @override
  Future<void> begin(String message,
      {required String channelName,
      required String channelDescription}) async {
    beginCount++;
    lastMessage = message;
    lastChannelName = channelName;
    lastChannelDescription = channelDescription;
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

/// [_ready] with the remote-access offer dismissed. For layout tests that
/// connect on a narrow surface: in the test font the offer's own row does not
/// fit there, and it is not what those tests are about.
const _readyNoOffer = AppConfig(
  profiles: [Profile(name: 'S', host: '192.168.178.64', password: 'pw')],
  activeIndex: 0,
  disclaimerAccepted: true,
  remoteAccessDismissed: true,
);

void main() {
  void useTallScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('Demo-Modus: „Demo ausprobieren" schaltet die App ohne Pi frei',
      (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
        store: _FakeStore(const AppConfig(
          profiles: [Profile(name: 'S')],
          activeIndex: 0,
          disclaimerAccepted: true,
        )),
        updateChecker: _noUpdateChecker,
      ),
    ));
    await tester.pumpAndSettle();

    // Starts disconnected: no session badge, the demo entry is offered.
    expect(find.byKey(const Key('sessionConnected')), findsNothing);
    expect(find.text('Demo ausprobieren'), findsOneWidget);

    // Tap it → the demo backend's canned detection populates the cards.
    await tester.tap(find.text('Demo ausprobieren'));
    await tester.pumpAndSettle();

    // Demo banner + session badge (tabs unlocked) + the canned evcc service.
    expect(find.text('Demo-Modus – Beispieldaten, kein echter Pi.'),
        findsOneWidget);
    expect(find.byKey(const Key('sessionConnected')), findsOneWidget);
    expect(find.textContaining('evcc'), findsWidgets);

    // A previously-gated tab (Terminal) is reachable AND Pro-unlocked in demo —
    // the send button shows the unlocked icon, not a lock.
    await tester.tap(find.byIcon(Icons.terminal_outlined));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.keyboard_return), findsOneWidget);

    // Leaving demo returns to the connect screen.
    await tester.tap(find.text('Beenden'));
    await tester.pumpAndSettle();
    expect(find.text('Demo ausprobieren'), findsOneWidget);
  });

  // Googles Prüfer-Pfad, belegt durch den Screenshot zu versionCode 115:
  // WLAN-Suche öffnen, ein gefundenes Gerät antippen. Das setzt NUR den Host —
  // die Zugangsdaten fehlen weiter, es gibt also immer noch keinen nutzbaren Pi.
  // Verschwindet der Demo-Einstieg hier, sitzt der Prüfer in der Sackgasse.
  testWidgets(
      'Demo-Einstieg bleibt stehen, wenn die WLAN-Suche nur den Host füllt',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
        store: _FakeStore(const AppConfig(
          profiles: [Profile(name: 'Standard')],
          activeIndex: 0,
          disclaimerAccepted: true,
        )),
        updater: FakeEvccUpdater(),
        updateChecker: _noUpdateChecker,
        piFinder: () async => const ['192.168.97.1', '192.168.97.5'],
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('demoEntry')), findsOneWidget);

    // Der Auto-Verbinden-Schalter hat die Zugangsdaten-Karte höher gemacht —
    // der Knopf liegt jetzt unterhalb des gebauten Bereichs und muss erst
    // herangeholt werden, sonst findet die ListView ihn gar nicht.
    final wifi = find.widgetWithText(OutlinedButton, 'Pi im WLAN suchen');
    await tester.scrollUntilVisible(wifi, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(wifi);
    await tester.pumpAndSettle();
    await tester.tap(find.text('192.168.97.1'));
    await tester.pumpAndSettle();

    // Zurück nach oben: der Einstieg steht über den Zugangsdaten, und die
    // ListView baut nur, was sichtbar ist. Weit genug für jede Listenlänge —
    // wie weit der Knopf oben herangeholt wurde, hängt an der Fußzeile.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('demoEntry')), findsOneWidget,
        reason: 'Host gesetzt, aber keine Zugangsdaten — genau der Zustand aus '
            'Googles Screenshot; der Weg in die App muss bleiben');
  });

  // Ausgefüllte Zugangsdaten dürfen den Einstieg NICHT schließen. Genau daran
  // scheiterte die Prüfung am 31.07.2026 (dritte Ablehnung derselben Art): Der
  // Prüfer tippte Host UND Passwort ein — damit galt der Pi als „fertig
  // konfiguriert", der Demo-Knopf verschwand, und die App war für ihn eine
  // Anmeldewand ohne Ausweg. Bequemlichkeit für eingerichtete Nutzer wiegt das
  // nicht auf: solange keine Sitzung steht, bleibt der Weg in die App offen.
  testWidgets('Demo-Einstieg bleibt, auch wenn Host UND Passwort gesetzt sind',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
        store: _FakeStore(const AppConfig(
          profiles: [
            Profile(name: 'S', host: '192.168.178.64', password: 'pw')
          ],
          activeIndex: 0,
          disclaimerAccepted: true,
        )),
        updater: FakeEvccUpdater(),
        updateChecker: _noUpdateChecker,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('demoEntry')), findsOneWidget,
        reason: 'ohne stehende Verbindung muss der Weg in die App offen sein');
  });

  // Wer den Pi WIRKLICH eingerichtet hat (schon mal verbunden), braucht den
  // Einstieg nie wieder — auch nicht nach einem Neustart der App.
  testWidgets('Demo-Einstieg ist dauerhaft weg, wenn schon mal verbunden wurde',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
        store: _FakeStore(const AppConfig(
          profiles: [
            Profile(name: 'S', host: '192.168.178.64', password: 'pw')
          ],
          activeIndex: 0,
          disclaimerAccepted: true,
          everConnected: true, // frühere Sitzung, aus dem Speicher geladen
        )),
        updater: FakeEvccUpdater(),
        updateChecker: _noUpdateChecker,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('demoEntry')), findsNothing);
  });

  // Erst eine echte Sitzung räumt ihn weg — dann ist der Nutzer ohnehin drin.
  testWidgets('Demo-Einstieg verschwindet erst nach dem Verbinden',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
        store: _FakeStore(const AppConfig(
          profiles: [
            Profile(name: 'S', host: '192.168.178.64', password: 'pw')
          ],
          activeIndex: 0,
          disclaimerAccepted: true,
        )),
        updater: FakeEvccUpdater(),
        updateChecker: _noUpdateChecker,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('demoEntry')), findsOneWidget);

    await tester
        .tap(find.widgetWithText(OutlinedButton, 'Verbindung herstellen'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('demoEntry')), findsNothing);
  });

  // Nutzerwunsch: der Verbinden-Knopf ist die Hauptaktion des Formulars und
  // steht deshalb so breit wie die Knöpfe darunter — nicht als kleiner Knopf
  // links. Pinnt Breite und Höhe gegen „Pi im WLAN suchen" fest.
  testWidgets('„Verbindung herstellen" nimmt die volle Breite ein',
      (tester) async {
    // Breit genug, dass die Beschriftung (Test-Schrift: 14 px je Zeichen) den
    // Knopf nicht schon von selbst auf volle Breite drückt.
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
        store: _FakeStore(const AppConfig(
          profiles: [
            Profile(name: 'S', host: '192.168.178.64', password: 'pw')
          ],
          activeIndex: 0,
          disclaimerAccepted: true,
        )),
        updater: FakeEvccUpdater(),
        updateChecker: _noUpdateChecker,
      ),
    ));
    await tester.pumpAndSettle();

    final connect = tester.getRect(
        find.widgetWithText(OutlinedButton, 'Verbindung herstellen'));
    final findPi =
        tester.getRect(find.widgetWithText(OutlinedButton, 'Pi im WLAN suchen'));
    expect(connect.width, findPi.width);
    expect(connect.left, findPi.left);
    expect(connect.height, greaterThanOrEqualTo(44));
  });

  // The Play reviewer's exact situation: fresh install, small screen, no Pi.
  // The demo entry is their only way past the connect form — if it sits below
  // the fold they never find it and the password field reads as a login wall.
  // That is why versionCode 114 was rejected (LoginWall.png showed the connect
  // screen with the entry out of view), so pin both position and prominence.
  testWidgets(
      'Demo-Einstieg ist bei einer Frisch-Installation ohne Scrollen sichtbar '
      'und steht VOR den Zugangsdaten', (tester) async {
    tester.view.physicalSize = const Size(1080, 1920); // 360x640 logisch
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
        store: _FakeStore(const AppConfig(
          profiles: [Profile(name: 'S')], // kein Host → wie frisch installiert
          activeIndex: 0,
          disclaimerAccepted: true,
        )),
        updater: FakeEvccUpdater(),
        updateChecker: _noUpdateChecker,
      ),
    ));
    await tester.pumpAndSettle();

    final demo = find.byKey(const Key('demoEntry'));
    expect(demo, findsOneWidget);

    final demoRect = tester.getRect(demo);
    final screenHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(demoRect.bottom, lessThanOrEqualTo(screenHeight),
        reason: 'Demo-Einstieg liegt unter der Falz — genau der Ablehnungsgrund '
            'von versionCode 114');

    // VOR dem Anmeldeformular. Genau das ist der Unterschied zwischen
    // „theoretisch erreichbar" und „der Prüfer sieht es sofort": Wer erst am
    // Passwortfeld vorbeiscrollen muss, hält den Bildschirm für eine
    // Anmeldewand — dreimal so passiert (versionCode 114, v0.63.0, v0.64.2).
    expect(demoRect.top, lessThan(tester.getRect(find.text('Host / IP')).top),
        reason: 'der Weg in die App gehört über die Zugangsdaten, nicht darunter');
  });

  Widget page(FakeEvccUpdater updater,
          {EvccApiClient? apiClient,
          Future<EvccRelease?> Function()? rel,
          Future<String?> Function()? haLatest,
          EntitlementService? entitlement,
          KeepAliveService? keepAlive,
          FilePickerService? filePicker,
          AppConfig? config,
          AppConfigStore? store,
          AppLauncher? appLauncher,
          Future<bool> Function(Uri uri)? urlOpener,
          Authenticator? authenticator,
          SecureScreen? secureScreen,
          Future<void> Function(String name, Uint8List bytes)? fileSaver}) =>
      MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
        home: UpdaterPage(
          store: store ?? _FakeStore(config ?? _ready),
          updater: updater,
          updateChecker: _noUpdateChecker,
          // Default: an API that answers "unreachable" immediately. Since the
          // evcc card fetches live values after every detection, the real
          // client would otherwise do actual HTTP in widget tests (pending
          // timers, flakiness). Tests that care inject their own.
          apiClient: apiClient ??
              EvccApiClient(
                  getJson: (_) async =>
                      throw const EvccApiException('kein Netz im Test')),
          evccReleaseFetcher: rel ?? () async => null,
          haVersionFetcher: haLatest ?? () async => null,
          entitlement: entitlement,
          keepAlive: keepAlive,
          filePicker: filePicker,
          appLauncher: appLauncher,
          urlOpener: urlOpener,
          authenticator: authenticator,
          secureScreen: secureScreen,
          fileSaver: fileSaver,
        ),
      );

  // Establish the connection → populates the service cards.
  Future<void> detect(WidgetTester tester) async {
    await tester
        .tap(find.widgetWithText(OutlinedButton, 'Verbindung herstellen'));
    await tester.pumpAndSettle();
  }

  // Bottom-nav helpers (Verwaltung = default; the others are gated behind an
  // active connection, so connect first if we aren't already).
  Future<void> ensureConnected(WidgetTester tester) async {
    if (tester.any(find.byKey(const Key('sessionConnected')))) return;
    await tester
        .tap(find.widgetWithText(OutlinedButton, 'Verbindung herstellen'));
    await tester.pumpAndSettle();
  }

  Future<void> goTerminal(WidgetTester tester) async {
    await ensureConnected(tester);
    await tester.tap(find.byIcon(Icons.terminal_outlined));
    await tester.pumpAndSettle();
  }

  Future<void> goAutomatik(WidgetTester tester) async {
    await ensureConnected(tester);
    await tester.tap(find.byIcon(Icons.bolt_outlined));
    await tester.pumpAndSettle();
  }

  Future<void> goDateien(WidgetTester tester) async {
    await ensureConnected(tester);
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

  // ---- Dateien: why an operation failed is told and logged ----

  // The terminal log as the Terminal tab holds it — the IndexedStack builds
  // that tab even while another one is shown.
  String logText(WidgetTester tester) => tester
      .widgetList<SelectableText>(
          find.byType(SelectableText, skipOffstage: false))
      .map((w) => w.data ?? '')
      .join('\n');

  // The file operations run outside _guard and used to swallow the cause:
  // `catch (_)` and a fixed text, nothing in the log.
  testWidgets(
      'Dateien: scheitert das Listing, steht der Grund in der Ansicht und im '
      'Log', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..dirEntries = const [(name: 'projects', isDir: true)];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await goDateien(tester);

    u.listDirError = const EvccUpdateException(UpdateErrorKind.connection,
        'Zeitüberschreitung – Pi nicht erreichbar.');
    await tester.tap(find.text('projects'));
    await tester.pumpAndSettle();

    expect(find.text('Zeitüberschreitung – Pi nicht erreichbar.'),
        findsOneWidget);
    expect(find.text('Verzeichnis konnte nicht geladen werden.'), findsNothing);
    expect(logText(tester),
        contains('FEHLER: Zeitüberschreitung – Pi nicht erreichbar.'));
    // One failed listing does not end the session, and no key is in doubt.
    expect(find.byKey(const Key('sessionConnected')), findsOneWidget);
    expect(find.textContaining('neuen Key vertrauen'), findsNothing);
  });

  testWidgets(
      'Dateien: ein Fehler ohne Meldung der Logik-Schicht behält den festen '
      'Text, die Ursache steht im Log', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..dirEntries = const [(name: 'projects', isDir: true)];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await goDateien(tester);

    u.listDirError = const FormatException('kaputte Antwort');
    await tester.tap(find.text('projects'));
    await tester.pumpAndSettle();

    expect(find.text('Verzeichnis konnte nicht geladen werden.'),
        findsOneWidget);
    expect(logText(tester), contains('kaputte Antwort'));
  });

  testWidgets('Dateien: ein gescheiterter Upload nennt den Grund, auch im Log',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..dirEntries = const [(name: 'old.txt', isDir: false)]
      ..uploadThrows = true; // throws 'Marker verpasst'
    final picker = _FakeFilePicker(
        (name: 'new.txt', bytes: Uint8List.fromList([1])));
    await tester.pumpWidget(page(u, filePicker: picker));
    await tester.pumpAndSettle();
    await goDateien(tester);

    await tester.tap(find.byIcon(Icons.upload_file));
    await tester.pumpAndSettle();

    expect(find.text('Marker verpasst'), findsOneWidget);
    expect(find.text('Hochladen fehlgeschlagen (Rechte?).'), findsNothing);
    expect(logText(tester), contains('FEHLER: Marker verpasst'));
  });

  testWidgets('Dateien: ein gescheitertes Löschen nennt den Grund, auch im Log',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..dirEntries = const [(name: 'notes.txt', isDir: false)]
      ..deleteError = const EvccUpdateException(
          UpdateErrorKind.sudo, 'sudo-Passwort abgelehnt.');
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await goDateien(tester);

    await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, 'notes.txt'),
        matching: find.byIcon(Icons.more_vert)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Löschen'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();

    expect(find.text('sudo-Passwort abgelehnt.'), findsOneWidget);
    expect(find.text('Löschen fehlgeschlagen (Rechte?).'), findsNothing);
    expect(logText(tester), contains('FEHLER: sudo-Passwort abgelehnt.'));
    expect(find.text('notes.txt'), findsOneWidget); // still listed
  });

  testWidgets(
      'Dateien: lässt sich eine Datei nicht öffnen, nennt die Meldung den '
      'Grund, auch im Log', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..dirEntries = const [(name: 'notes.txt', isDir: false)]
      ..readFileError = const EvccUpdateException(UpdateErrorKind.unknown,
          'Datei konnte nicht gelesen werden (Rechte? Binärdatei?).');
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await goDateien(tester);

    await tester.tap(find.text('notes.txt'));
    await tester.pumpAndSettle();

    expect(find.text('Datei konnte nicht gelesen werden (Rechte? Binärdatei?).'),
        findsOneWidget);
    expect(find.text('Datei konnte nicht geladen werden.'), findsNothing);
    expect(logText(tester),
        contains('FEHLER: Datei konnte nicht gelesen werden'));
  });

  // A changed host key used to end as "fehlgeschlagen" here: no banner, no
  // way to trust the new key from where it was noticed.
  testWidgets(
      'Dateien: ein geänderter Host-Key beendet die Sitzung, zeigt Banner und '
      '„neuen Key vertrauen" — das verbindet neu', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..dirEntries = const [(name: 'projects', isDir: true)];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await goDateien(tester);
    expect(u.detectCalls, 1);

    u.listDirError = const EvccUpdateException(
        UpdateErrorKind.hostKeyChanged, 'Host-Key geändert!');
    await tester.tap(find.text('projects'));
    await tester.pumpAndSettle();

    expect(find.text('Host-Key geändert!'), findsOneWidget); // the banner
    expect(find.textContaining('neuen Key vertrauen'), findsOneWidget);
    expect(find.byKey(const Key('sessionConnected')), findsNothing);
    // Back on Verwaltung, and the connect button no longer claims a session.
    expect(find.widgetWithText(OutlinedButton, 'Verbindung herstellen'),
        findsOneWidget);
    expect(logText(tester), contains('FEHLER: Host-Key geändert!'));

    // Trusting the key forgets the old one and connects again — it does not
    // replay whatever action happened to run last.
    u.listDirError = null;
    await tester.tap(find.byIcon(Icons.verified_user_outlined));
    await tester.pumpAndSettle();

    expect(u.forgetCalls, 1);
    expect(u.forgotConfig!.host, '192.168.178.64');
    expect(u.detectCalls, 2);
    expect(find.byKey(const Key('sessionConnected')), findsOneWidget);
    expect(find.textContaining('neuen Key vertrauen'), findsNothing);
  });

  testWidgets(
      'Dateien: ein geänderter Host-Key beim Upload — „neuen Key vertrauen" '
      'wiederholt nicht die zuletzt gelaufene Aktion', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..dirEntries = const [(name: 'old.txt', isDir: false)];
    final picker = _FakeFilePicker(
        (name: 'new.txt', bytes: Uint8List.fromList([1])));
    await tester.pumpWidget(page(u, filePicker: picker));
    await tester.pumpAndSettle();
    await detect(tester);
    // The last action that ran through _guard: restart evcc.
    await tester.tap(find.byKey(const ValueKey('menu-evcc')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dienst neu starten'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();
    expect(u.restartServiceCalls, 1);
    await goDateien(tester);
    final listed = u.listDirCalls;

    u.uploadError = const EvccUpdateException(
        UpdateErrorKind.hostKeyChanged, 'Host-Key geändert!');
    await tester.tap(find.byIcon(Icons.upload_file));
    await tester.pumpAndSettle();

    expect(find.text('Host-Key geändert!'), findsOneWidget);
    expect(find.textContaining('neuen Key vertrauen'), findsOneWidget);
    // The session is gone — no listing goes to a Pi whose key is in doubt.
    expect(u.listDirCalls, listed);

    u.uploadError = null;
    await tester.tap(find.byIcon(Icons.verified_user_outlined));
    await tester.pumpAndSettle();

    expect(u.forgetCalls, 1);
    expect(u.restartServiceCalls, 1, reason: 'kein zweiter Neustart von evcc');
    expect(find.byKey(const Key('sessionConnected')), findsOneWidget);
  });

  // ---- Dateien: an upload asks before it replaces a file ----

  testWidgets(
      'Dateien: liegt eine Datei gleichen Namens im Ordner, fragt der Upload '
      'vorher nach — Abbrechen lädt nichts hoch', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..dirEntries = const [(name: '.env', isDir: false)];
    final picker =
        _FakeFilePicker((name: '.env', bytes: Uint8List.fromList([1, 2])));
    await tester.pumpWidget(page(u, filePicker: picker));
    await tester.pumpAndSettle();
    await goDateien(tester);

    await tester.tap(find.byIcon(Icons.upload_file));
    await tester.pumpAndSettle();

    expect(find.text('„.env" überschreiben?'), findsOneWidget);
    expect(u.uploadedTo, isEmpty, reason: 'vor der Bestätigung geht nichts raus');

    await tester.tap(find.widgetWithText(TextButton, 'Abbrechen'));
    await tester.pumpAndSettle();
    expect(u.uploadedTo, isEmpty);
    expect(find.text('„.env" überschreiben?'), findsNothing);

    // Confirmed, it uploads.
    await tester.tap(find.byIcon(Icons.upload_file));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Überschreiben'));
    await tester.pumpAndSettle();
    expect(u.uploadedTo, ['/home/.env']);
  });

  testWidgets('Dateien: ein neuer Dateiname lädt ohne Rückfrage hoch',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      // Same letters, other case: on the Pi that is another file.
      ..dirEntries = const [(name: 'Config.yaml', isDir: false)];
    final picker = _FakeFilePicker(
        (name: 'config.yaml', bytes: Uint8List.fromList([1])));
    await tester.pumpWidget(page(u, filePicker: picker));
    await tester.pumpAndSettle();
    await goDateien(tester);

    await tester.tap(find.byIcon(Icons.upload_file));
    await tester.pumpAndSettle();

    expect(find.textContaining('überschreiben?'), findsNothing);
    expect(u.uploadedTo, ['/home/config.yaml']);
  });

  testWidgets(
      'Dateien: heißt ein Ordner wie die gewählte Datei, wird nichts '
      'hochgeladen', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..dirEntries = const [(name: 'backup', isDir: true)];
    final picker =
        _FakeFilePicker((name: 'backup', bytes: Uint8List.fromList([1])));
    await tester.pumpWidget(page(u, filePicker: picker));
    await tester.pumpAndSettle();
    await goDateien(tester);

    await tester.tap(find.byIcon(Icons.upload_file));
    await tester.pumpAndSettle();

    expect(u.uploadedTo, isEmpty);
    expect(find.textContaining('überschreiben?'), findsNothing);
    expect(
        find.text('Hier gibt es bereits einen Ordner „backup" — eine Datei '
            'kann ihn nicht ersetzen.'),
        findsOneWidget);
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
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
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
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
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

    // Switching Pi ends the session + snaps back to Verwaltung; reconnecting and
    // reopening Dateien lists Pi B fresh — the old Pi's entry must not linger.
    await goDateien(tester);
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

  // Der verdeckte Dateien-Tab wird vom IndexedStack immer mitgebaut. Ein
  // gespeichertes Profil allein darf deshalb kein Listing auslösen — das wäre
  // ein SSH-Login samt sudo-Passwort, ohne dass jemand „Verbindung herstellen"
  // getippt hat (und ohne Auto-Connect).
  testWidgets(
      'Dateien: ohne „Verbindung herstellen" geht kein Listing an den Pi',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()..dirEntries = const [(name: 'x', isDir: false)];
    await tester.pumpWidget(page(u)); // gespeichertes Profil: Host + Passwort
    await tester.pumpAndSettle();

    expect(u.detectCalls, 0);
    expect(u.listDirCalls, 0);

    // Mit Sitzung listet der Tab wie gewohnt.
    await goDateien(tester);
    expect(u.listDirCalls, greaterThan(0));
    expect(find.text('x'), findsOneWidget);
  });

  testWidgets(
      'Dateien: nach der Demo zeigt der echte Pi nicht das Demo-Listing',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..dirEntries = const [(name: 'echt.txt', isDir: false)];
    await tester.pumpWidget(page(u)); // Host + Passwort, nie verbunden
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('demoEntry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.folder_outlined));
    await tester.pumpAndSettle();
    expect(find.text('evcc.yaml'), findsOneWidget); // Demo-Dateien
    expect(u.listDirCalls, 0, reason: 'die Demo fasst das echte Backend nicht an');

    // Zurück zur Verwaltung und echt verbinden (der Knopf zeigt im Demo
    // „Verbunden"), ohne die Demo vorher zu beenden.
    await tester.tap(find.byIcon(Icons.tune_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Verbunden'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.folder_outlined));
    await tester.pumpAndSettle();

    expect(find.text('echt.txt'), findsOneWidget);
    expect(find.text('evcc.yaml'), findsNothing,
        reason: 'Demo-Einträge als Inhalt des echten Pi wären Ziel von '
            'Öffnen/Löschen mit falschen Pfaden');
  });

  testWidgets(
      'Verbinden aus der Demo heraus beendet die Demo sofort: keine '
      'Beispielkarten, keine Sitzung und kein Listing, bevor der Pi antwortet',
      (tester) async {
    useTallScreen(tester);
    final gate = Completer<void>();
    final u = FakeEvccUpdater()
      ..detectGate = gate // der echte Connect bleibt hängen
      ..dirEntries = const [(name: 'echt.txt', isDir: false)];
    await tester.pumpWidget(page(u)); // Host + Passwort, nie verbunden
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('demoEntry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('menu-pihole')), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Verbunden'));
    await tester.pump();
    await tester.pump();

    // Der Connect läuft noch — die Sitzung der Demo darf ihm nichts vorgreifen.
    expect(find.text('Demo-Modus – Beispieldaten, kein echter Pi.'),
        findsNothing);
    expect(find.byKey(const ValueKey('menu-pihole')), findsNothing);
    expect(find.byKey(const Key('sessionConnected')), findsNothing);
    expect(u.listDirCalls, 0);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sessionConnected')), findsOneWidget);
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
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
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

  // Android lists the channel of the ongoing notification in the system
  // settings, under the name the app created it with.
  for (final (locale, connect, update, name, description) in const [
    (
      Locale('de'),
      'Verbindung herstellen',
      'Aktualisieren',
      'Laufende Aktionen',
      'Zeigt an, dass Pi-Tool gerade eine Aktion auf dem Pi ausführt.'
    ),
    (
      Locale('en'),
      'Connect',
      'Update',
      'Running actions',
      'Shows that Pi-Tool is running an action on the Pi.'
    ),
  ]) {
    testWidgets(
        'keep-alive: the notification channel is named in the app language '
        '(${locale.languageCode})', (tester) async {
      useTallScreen(tester);
      final ka = _FakeKeepAlive();
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: UpdaterPage(
          store: _FakeStore(_ready),
          updater: FakeEvccUpdater(),
          updateChecker: _noUpdateChecker,
          apiClient: EvccApiClient(
              getJson: (_) async =>
                  throw const EvccApiException('kein Netz im Test')),
          evccReleaseFetcher: () async => null,
          haVersionFetcher: () async => null,
          keepAlive: ka,
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, connect));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, update));
      await tester.pumpAndSettle();

      expect(ka.beginCount, 1);
      expect(ka.lastChannelName, name);
      expect(ka.lastChannelDescription, description);
    });
  }

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
    // The connect names itself in the running bar (and on its button) — the
    // default text does not replace that.
    expect(find.text('Verbinde …'), findsNWidgets(2));
    expect(find.text('Vorgang läuft …'), findsNothing);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Abbrechen'));
    await tester.pump();
    expect(u.cancelCalls, 1);

    gate.complete(); // release the pending future so the test settles cleanly
    await tester.pumpAndSettle();
  });

  testWidgets(
      'eine Aktion ohne eigenen Lauftext (evcc-Dienst neu starten) zeigt die '
      'Laufleiste mit „Abbrechen" — aber ohne Keep-Alive', (tester) async {
    useTallScreen(tester);
    final gate = Completer<void>();
    final ka = _FakeKeepAlive();
    final u = FakeEvccUpdater()..restartGate = gate;
    await tester.pumpWidget(page(u, keepAlive: ka));
    await tester.pumpAndSettle();
    await detect(tester);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    await tester.tap(find.byKey(const ValueKey('menu-evcc')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dienst neu starten'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500)); // dialog is gone

    // The restart hangs on the gate: buttons are locked, and the bar says so.
    expect(u.restartServiceCalls, 1);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Vorgang läuft …'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Log'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Abbrechen'));
    await tester.pump();
    expect(u.cancelCalls, 1);
    // A short action: no foreground service for it.
    expect(ka.beginCount, 0);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('evcc-Dienst neu gestartet.'), findsOneWidget);
    expect(ka.beginCount, 0);
    expect(ka.endCount, 0);
  });

  // ---- running bar: narrow display, large font ----

  // An ordinary phone at the default font size keeps the labelled button.
  testWidgets('Laufleiste auf 360 dp: „Abbrechen“ bleibt beschriftet',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final gate = Completer<void>();
    final u = FakeEvccUpdater()..detectGate = gate;
    await tester.pumpWidget(page(u, config: _readyNoOffer));
    await tester.pumpAndSettle();

    await tester
        .tap(find.widgetWithText(OutlinedButton, 'Verbindung herstellen'));
    await tester.pump();

    expect(find.widgetWithText(OutlinedButton, 'Abbrechen'), findsOneWidget);
    expect(find.text('Log'), findsOneWidget);
    expect(tester.takeException(), isNull);

    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets(
      'Laufleiste bei großer Schrift: läuft nicht über, „Abbrechen“ wird zum '
      'Symbol mit Tooltip und bricht weiter ab', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final gate = Completer<void>();
    final u = FakeEvccUpdater()..detectGate = gate;
    await tester.pumpWidget(page(u, config: _readyNoOffer));
    await tester.pumpAndSettle();
    await tester
        .tap(find.widgetWithText(OutlinedButton, 'Verbindung herstellen'));
    await tester.pump();

    // The system font size goes up while the action runs.
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pump();

    // A RenderFlex overflow in the bar would be reported here.
    expect(tester.takeException(), isNull);
    final bar = find.ancestor(
        of: find.byType(LinearProgressIndicator),
        matching: find.byType(Material)).first;
    // What is running stays readable next to the two actions.
    final message =
        find.descendant(of: bar, matching: find.text('Verbinde …'));
    expect(tester.getSize(message).width, greaterThan(100));
    expect(find.descendant(of: bar, matching: find.text('Log')),
        findsOneWidget);
    expect(find.descendant(of: bar, matching: find.text('Abbrechen')),
        findsNothing);

    await tester.tap(find.byTooltip('Abbrechen'));
    await tester.pump();
    expect(u.cancelCalls, 1);

    gate.complete();
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
    final launcher = _FakeLauncher();
    await tester.pumpWidget(page(u, appLauncher: launcher));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-evcc')));
    await tester.pumpAndSettle();
    // Moved out of the footer into the evcc card's ⋮ menu.
    expect(find.text('Offizielle evcc-App'), findsOneWidget);

    // Opens the installed app (Play listing only as the fallback), so it is
    // useful to someone who already has it — not just an install link.
    await tester.tap(find.text('Offizielle evcc-App'));
    await tester.pumpAndSettle();
    expect(launcher.opened, ['io.evcc.android']);
  });

  testWidgets('evcc-Karte zeigt die Live-Werte direkt auf dem Haupt-Tab',
      (tester) async {
    // GitHub issue #22: die Karte nannte nur Version und Dienststatus, die
    // Live-Werte lagen zwei Taps entfernt im ⋮.
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    final api = EvccApiClient(getJson: (_) async => {
          'pvPower': 3400,
          'gridPower': -1200,
          'homePower': 900,
          'batteryConfigured': true,
          'batterySoc': 78,
          'loadpoints': [
            {
              'title': 'Garage',
              'charging': true,
              'connected': true,
              'chargePower': 7200,
            }
          ],
        });
    await tester.pumpWidget(page(u, apiClient: api));
    await tester.pumpAndSettle();
    await detect(tester);

    expect(find.textContaining('PV 3,4 kW'), findsOneWidget);
    expect(find.textContaining('Netz -1,2 kW'), findsOneWidget);
    expect(find.textContaining('Batterie 78 %'), findsOneWidget);
    expect(find.textContaining('Garage: 7,2 kW'), findsOneWidget);
  });

  testWidgets('evcc-Karte bleibt unverändert, wenn die API nicht antwortet',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    final api = EvccApiClient(
        getJson: (_) async => throw const EvccApiException('nicht erreichbar'));
    await tester.pumpWidget(page(u, apiClient: api));
    await tester.pumpAndSettle();
    await detect(tester);

    // Kein Fehlerbanner, keine leere Zeile — nur die Karte wie zuvor.
    expect(find.textContaining('PV '), findsNothing);
    expect(find.textContaining('nicht erreichbar'), findsNothing);
    expect(find.text('evcc'), findsWidgets);
  });

  testWidgets('evcc ⋮ → Release-Notes zeigt die GitHub-Notes im Sheet',
      (tester) async {
    // Wunsch v0.66.0: die Notes auch OHNE Update-Absicht lesen können — bisher
    // gab es nur den 500-Zeichen-Auszug im Bestätigungsdialog des Updates.
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u,
        rel: () async => const EvccRelease(
            version: '0.212.0',
            notes: 'Neue Ladeplanung\n- PV-Ueberschuss besser verteilt')));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-evcc')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Release-Notes'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Neue Ladeplanung'), findsOneWidget);
    expect(find.textContaining('0.212.0'), findsOneWidget);
  });

  testWidgets('every service card ⋮ jumps to the project behind it',
      (tester) async {
    // User wish (2026-08-14): from the card to the application's own site.
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'pihole',
            name: 'Pi-hole',
            installed: true,
            version: 'v6.0.4',
            active: true),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-pihole')));
    await tester.pumpAndSettle();

    expect(find.text('Projekt-Website'), findsOneWidget);
    // Pi-hole ships no official Android app — a third-party one must never be
    // offered as "the official app", so that entry stays away.
    expect(find.text('Offizielle App'), findsNothing);
  });

  // ---- „Oberfläche öffnen": the address each card hands to the browser ----

  const webServices = [
    ServiceStatus(
        id: 'evcc',
        name: 'evcc',
        installed: true,
        version: '0.310.0',
        active: true,
        detail: 'apt · Dienst aktiv'),
    ServiceStatus(
        id: 'pihole',
        name: 'Pi-hole',
        installed: true,
        version: 'v6.0.4',
        active: true),
    ServiceStatus(
        id: 'homeassistant',
        name: 'Home Assistant',
        installed: true,
        version: '2026.7.1',
        active: true),
    ServiceStatus(
        id: 'grafana',
        name: 'Grafana',
        installed: true,
        version: '13.1.0',
        active: true,
        detail: 'apt · grafana · Dienst aktiv',
        webPort: 3000,
        aptPackage: 'grafana'),
  ];

  // The „Oberfläche öffnen" button of one card (found through its ⋮ key).
  Finder openWebOf(String id) => find.descendant(
      of: find
          .ancestor(
              of: find.byKey(ValueKey('menu-$id')),
              matching: find.byType(Container))
          .first,
      matching: find.byIcon(Icons.open_in_browser));

  testWidgets(
      '„Oberfläche öffnen": der HTTPS-Schalter gilt nur für evcc — Pi-hole '
      'bleibt http', (tester) async {
    useTallScreen(tester);
    final opened = <String>[];
    final u = FakeEvccUpdater()..services = webServices;
    await tester.pumpWidget(page(u,
        config: const AppConfig(
          profiles: [Profile(name: 'S', host: '192.168.178.64', password: 'pw')],
          activeIndex: 0,
          disclaimerAccepted: true,
          uiScheme: 'https',
        ),
        urlOpener: (uri) async {
          opened.add('$uri');
          return true;
        }));
    await tester.pumpAndSettle();
    await detect(tester);

    for (final id in ['evcc', 'pihole', 'homeassistant', 'grafana']) {
      await tester.tap(openWebOf(id));
      await tester.pumpAndSettle();
    }
    expect(opened, [
      'https://192.168.178.64:7070',
      'http://192.168.178.64/admin',
      'http://192.168.178.64:8123',
      'http://192.168.178.64:3000',
    ]);
  });

  testWidgets(
      '„Oberfläche öffnen": eine IPv6-Adresse als Host steht in Klammern in '
      'der Adresse', (tester) async {
    useTallScreen(tester);
    final opened = <Uri>[];
    final u = FakeEvccUpdater()..services = webServices;
    await tester.pumpWidget(page(u,
        config: const AppConfig(
          profiles: [Profile(name: 'S', host: 'fd00::64', password: 'pw')],
          activeIndex: 0,
          disclaimerAccepted: true,
        ),
        urlOpener: (uri) async {
          opened.add(uri);
          return true;
        }));
    await tester.pumpAndSettle();
    await detect(tester);

    for (final id in ['evcc', 'pihole', 'homeassistant', 'grafana']) {
      await tester.tap(openWebOf(id));
      await tester.pumpAndSettle();
    }
    expect([for (final uri in opened) '$uri'], [
      'http://[fd00::64]:7070',
      'http://[fd00::64]/admin',
      'http://[fd00::64]:8123',
      'http://[fd00::64]:3000',
    ]);
    // What the browser makes of it: the address, and the port apart from it.
    expect([for (final uri in opened) uri.host], everyElement('fd00::64'));
    expect([for (final uri in opened) uri.port], [7070, 80, 8123, 3000]);
  });

  testWidgets(
      '„Oberfläche öffnen": ein Host, aus dem keine Adresse wird, meldet das '
      'statt nichts zu tun', (tester) async {
    useTallScreen(tester);
    final opened = <Uri>[];
    final u = FakeEvccUpdater()..services = webServices;
    await tester.pumpWidget(page(u,
        config: const AppConfig(
          // A bracket that is never closed.
          profiles: [Profile(name: 'S', host: '[fd00::64', password: 'pw')],
          activeIndex: 0,
          disclaimerAccepted: true,
        ),
        urlOpener: (uri) async {
          opened.add(uri);
          return true;
        }));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(openWebOf('pihole'));
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(find.text('Konnte den Link nicht öffnen.'), findsOneWidget);
  });

  testWidgets(
      'nach „Pi-hole installieren" führt der Einrichtungs-Knopf über http zur '
      'Pi-hole-Oberfläche, auch mit evcc auf HTTPS', (tester) async {
    useTallScreen(tester);
    final opened = <String>[];
    final u = FakeEvccUpdater()
      ..services = [
        ServiceStatus.absent('pihole', 'Pi-hole'),
        const ServiceStatus(
            id: 'system', name: 'System (Pi)', installed: true, active: true),
      ];
    await tester.pumpWidget(page(u,
        config: const AppConfig(
          profiles: [Profile(name: 'S', host: '192.168.178.64', password: 'pw')],
          activeIndex: 0,
          disclaimerAccepted: true,
          uiScheme: 'https',
        ),
        urlOpener: (uri) async {
          opened.add('$uri');
          return true;
        }));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.textContaining('Dienst hinzufügen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pi-hole'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();
    expect(u.piholeInstallCalls, 1);

    await tester.tap(find.widgetWithText(FilledButton, 'evcc-Einrichtung öffnen'));
    await tester.pumpAndSettle();
    expect(opened, ['http://192.168.178.64/admin']);
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

  // An ntfy topic IS the password (ntfy.sh has no account and no auth): whoever
  // knows or guesses the name reads which services run on the Pi and which
  // updates are pending. So the sheet says so and hands out a strong name.
  testWidgets(
      'Automatik → Health-Alerts: Sheet warnt vor öffentlichen Themen und '
      'belegt ein starkes Zufallsthema vor', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await goAutomatik(tester);

    // Nothing configured yet → the card carries no warning.
    expect(find.textContaining('leicht erratbar'), findsNothing);

    await tester.tap(find.text('Health-Alerts'));
    await tester.pumpAndSettle();

    final prefilled =
        tester.widget<TextField>(find.byType(TextField).first).controller!.text;
    expect(prefilled, startsWith('pi-tool-'));
    expect(isWeakNtfyTopic(prefilled), isFalse);
    expect(find.textContaining('öffentlich'), findsOneWidget);

    // The lazy path — tap "Einschalten", touch nothing — installs that topic.
    await tester.tap(find.widgetWithText(FilledButton, 'Einschalten'));
    await tester.pumpAndSettle();
    expect(u.alertsTopic, prefilled);
  });

  testWidgets('Health-Alerts: der Würfel erzeugt ein neues starkes Thema',
      (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(page(FakeEvccUpdater()));
    await tester.pumpAndSettle();
    await goAutomatik(tester);
    await tester.tap(find.text('Health-Alerts'));
    await tester.pumpAndSettle();

    final ctrl =
        tester.widget<TextField>(find.byType(TextField).first).controller!;
    final before = ctrl.text;
    await tester.tap(find.byIcon(Icons.casino_outlined));
    await tester.pumpAndSettle();

    expect(ctrl.text, isNot(before));
    expect(isWeakNtfyTopic(ctrl.text), isFalse);
  });

  testWidgets('Health-Alerts-Sheet läuft auf einem kleinen Display nicht über',
      (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(page(FakeEvccUpdater()));
    await tester.pumpAndSettle();
    await goAutomatik(tester);
    await tester.tap(find.text('Health-Alerts'));
    await tester.pumpAndSettle();

    // Shrink to a small phone (360x640 logical): the warning block made the
    // sheet taller, so it has to scroll — a RenderFlex overflow fails here.
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsWidgets);
  });

  testWidgets('Health-Alerts: ein kurzes Wunsch-Thema wird sofort als leicht '
      'erratbar markiert', (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(page(FakeEvccUpdater()));
    await tester.pumpAndSettle();
    await goAutomatik(tester);
    await tester.tap(find.text('Health-Alerts'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'pi');
    await tester.pump();
    expect(find.textContaining('leicht zu erraten'), findsOneWidget);
  });

  testWidgets(
      'Automatik-Karte warnt bei einem bereits eingerichteten, schwachen '
      'ntfy-Thema (wer das Sheet nie wieder öffnet, sieht es sonst nie)',
      (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
        store: _FakeStore(const AppConfig(
          profiles: [Profile(name: 'S', host: '192.168.178.64', password: 'pw')],
          activeIndex: 0,
          disclaimerAccepted: true,
          alertsNtfyTopic: 'mein-pi',
        )),
        updater: FakeEvccUpdater(),
        updateChecker: _noUpdateChecker,
      ),
    ));
    await tester.pumpAndSettle();
    await goAutomatik(tester);

    expect(find.textContaining('leicht erratbar'), findsOneWidget);
  });

  testWidgets('Automatik → auto-updates: turn OFF when currently active',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..autoStatus = (
        enabled: true,
        nextRun: 'So 04:00',
        lastResult: 'ok',
        wrapperOutdated: false
      );
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
      ..alertsStatus =
          (enabled: true, lastCheck: '12:00', wrapperOutdated: false);
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

  // ---- Health-Alerts: what happens in the sheet is shown in the sheet ----

  Future<void> openAlertsSheet(WidgetTester tester) async {
    await goAutomatik(tester);
    await tester.tap(find.text('Health-Alerts'));
    await tester.pumpAndSettle();
  }

  String topicField(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField).first).controller!.text;

  Finder inSheet(Finder what) =>
      find.descendant(of: find.byType(BottomSheet), matching: what);

  // A snack is drawn by the page's Scaffold, beneath the modal sheet.
  testWidgets(
      'Health-Alerts: das Ergebnis des Tests steht im Sheet, nicht als Snack '
      'darunter', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await openAlertsSheet(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Test'));
    await tester.pumpAndSettle();

    expect(u.testAlertCalls, 1);
    expect(
        inSheet(find.text('Test-Benachrichtigung gesendet — prüf dein ntfy.')),
        findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets(
      'Health-Alerts: ein gescheiterter Test nennt den Grund im Sheet und im '
      'Log', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..testAlertError = (_) => const EvccUpdateException(
          UpdateErrorKind.unknown,
          'Test-Benachrichtigung fehlgeschlagen: curl: (6) Could not resolve '
          'host: ntfy.example');
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await openAlertsSheet(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Test'));
    await tester.pumpAndSettle();

    expect(
        tester.widget<Text>(find.byKey(const Key('alertsTestResult'))).data,
        'Test-Benachrichtigung fehlgeschlagen: curl: (6) Could not resolve '
        'host: ntfy.example');
    expect(find.byType(SnackBar), findsNothing);
    expect(logText(tester),
        contains('FEHLER: Test-Benachrichtigung fehlgeschlagen: curl: (6)'));
  });

  testWidgets(
      'Health-Alerts: solange ein Test läuft, ist der Test-Knopf gesperrt',
      (tester) async {
    useTallScreen(tester);
    final gate = Completer<void>();
    final u = FakeEvccUpdater()..testAlertGate = gate;
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await openAlertsSheet(tester);

    OutlinedButton testButton() => tester.widget<OutlinedButton>(
        inSheet(find.byType(OutlinedButton)));

    await tester.tap(inSheet(find.byType(OutlinedButton)));
    await tester.pump();
    expect(u.testAlertCalls, 1);
    expect(testButton().onPressed, isNull);

    // Impatient taps start no further SSH connection.
    await tester.tap(inSheet(find.byType(OutlinedButton)), warnIfMissed: false);
    await tester.tap(inSheet(find.byType(OutlinedButton)), warnIfMissed: false);
    await tester.pump();
    expect(u.testAlertCalls, 1);

    gate.complete();
    await tester.pumpAndSettle();
    expect(testButton().onPressed, isNotNull);
    expect(find.byKey(const Key('alertsTestResult')), findsOneWidget);
  });

  testWidgets(
      'Health-Alerts: wird das Sheet während des Tests geschlossen, kommt das '
      'Ergebnis als Snack', (tester) async {
    useTallScreen(tester);
    final gate = Completer<void>();
    final u = FakeEvccUpdater()..testAlertGate = gate;
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await openAlertsSheet(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Test'));
    await tester.pump();
    await tester.tapAt(const Offset(10, 10)); // the scrim closes the sheet
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(BottomSheet), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.byType(SnackBar),
            matching:
                find.text('Test-Benachrichtigung gesendet — prüf dein ntfy.')),
        findsOneWidget);
  });

  // With the keyboard up the sheet scrolls. The result line is added below
  // the buttons — past the end of what was visible when "Test" was tapped.
  testWidgets(
      'Health-Alerts: bei offener Tastatur rollt das Ergebnis des Tests in den '
      'sichtbaren Teil des Sheets', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await openAlertsSheet(tester);

    tester.view.viewInsets = const FakeViewPadding(bottom: 2600);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    final scroller = inSheet(find.byType(SingleChildScrollView));
    final testButton = find.widgetWithText(OutlinedButton, 'Test');
    await tester.ensureVisible(testButton);
    await tester.pumpAndSettle();
    // The premise: the sheet does scroll, and is at its end.
    final position = tester
        .state<ScrollableState>(find
            .descendant(of: scroller, matching: find.byType(Scrollable))
            .first)
        .position;
    expect(position.maxScrollExtent, greaterThan(0));
    expect(position.pixels, position.maxScrollExtent);

    await tester.tap(testButton);
    await tester.pumpAndSettle();

    expect(u.testAlertCalls, 1);
    final line = tester.getRect(find.byKey(const Key('alertsTestResult')));
    expect(line.bottom, lessThanOrEqualTo(tester.getRect(scroller).bottom));
    expect(line.top, greaterThanOrEqualTo(tester.getRect(scroller).top));
  });

  testWidgets(
      'Health-Alerts: ohne Thema meldet das Feld selbst den Fehler — nichts '
      'wird eingerichtet oder gesendet', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await openAlertsSheet(tester);

    await tester.enterText(find.byType(TextField).first, '  ');
    await tester.tap(find.widgetWithText(FilledButton, 'Einschalten'));
    await tester.pumpAndSettle();

    expect(inSheet(find.text('Bitte ein ntfy-Thema eingeben.')), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(u.alertsTopic, isNull);

    // Typing clears the error; an empty field marks it again for "Test".
    await tester.enterText(find.byType(TextField).first, 'pi-tool-abc');
    await tester.pumpAndSettle(); // the error line fades out
    expect(find.text('Bitte ein ntfy-Thema eingeben.'), findsNothing);
    await tester.enterText(find.byType(TextField).first, '');
    await tester.tap(find.widgetWithText(OutlinedButton, 'Test'));
    await tester.pumpAndSettle();
    expect(inSheet(find.text('Bitte ein ntfy-Thema eingeben.')), findsOneWidget);
    expect(u.testAlertCalls, 0);
  });

  // The topic is the password: whatever the logic layer reports about a test
  // or an install, the topic itself stays out of the log.
  testWidgets('Health-Alerts: das Thema steht in keiner Log-Zeile',
      (tester) async {
    useTallScreen(tester);
    const topic = 'pi-tool-k7m2q9x4vb3dwz';
    final u = FakeEvccUpdater()
      ..testAlertLog = ((t) => 'curl: (22) https://ntfy.sh/$t returned 404')
      ..testAlertError = (t) => EvccUpdateException(UpdateErrorKind.unknown,
          'Test-Benachrichtigung fehlgeschlagen: https://ntfy.sh/$t');
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await openAlertsSheet(tester);

    await tester.enterText(find.byType(TextField).first, topic);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Test'));
    await tester.pumpAndSettle();

    final log = logText(tester);
    expect(log, contains('curl: (22) https://ntfy.sh/'));
    expect(log, contains('FEHLER: Test-Benachrichtigung fehlgeschlagen'));
    expect(log, isNot(contains(topic)));
    expect(
        tester.widget<Text>(find.byKey(const Key('alertsTestResult'))).data,
        isNot(contains(topic)));
  });

  testWidgets(
      'Health-Alerts: auch beim Einrichten steht das Thema in keiner Log-Zeile',
      (tester) async {
    useTallScreen(tester);
    const topic = 'pi-tool-k7m2q9x4vb3dwz';
    final u = FakeEvccUpdater()
      ..enableAlertsLog = ((t) => 'bash: line 9: TOPIC=$t: command not found');
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await openAlertsSheet(tester);

    await tester.enterText(find.byType(TextField).first, topic);
    await tester.tap(find.widgetWithText(FilledButton, 'Einschalten'));
    await tester.pumpAndSettle();

    expect(u.alertsTopic, topic);
    final log = logText(tester);
    expect(log, contains('bash: line 9: TOPIC='));
    expect(log, isNot(contains(topic)));
  });

  // ---- Health-Alerts: the ntfy destination belongs to the Pi ----

  const topicA = 'pi-tool-aaaa2222bbbb33';
  const topicB = 'pi-tool-cccc4444dddd55';
  const topicAppWide = 'pi-tool-eeee6666ffff77';

  AppConfig twoPis(
          {String a = '',
          String b = '',
          String appWide = '',
          int activeIndex = 0}) =>
      AppConfig(
        profiles: [
          Profile(
              name: 'A',
              host: '192.168.178.64',
              password: 'pw',
              alertsNtfyTopic: a,
              alertsNtfyServer: a.isEmpty ? '' : 'https://ntfy.example.org'),
          Profile(
              name: 'B',
              host: '192.168.178.65',
              password: 'pw',
              alertsNtfyTopic: b,
              alertsNtfyServer: b.isEmpty ? '' : 'https://ntfy.sh'),
        ],
        activeIndex: activeIndex,
        disclaimerAccepted: true,
        alertsNtfyTopic: appWide,
      );

  testWidgets(
      'Health-Alerts: jedes Profil zeigt sein eigenes Thema, nicht das '
      'app-weite', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..alertsStatus =
          (enabled: true, lastCheck: '12:00', wrapperOutdated: false);
    await tester.pumpWidget(page(u,
        config: twoPis(a: topicA, b: topicB, appWide: topicAppWide)));
    await tester.pumpAndSettle();

    await openAlertsSheet(tester);
    expect(topicField(tester), topicA);
    expect(find.text('https://ntfy.example.org'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10)); // close the sheet
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('profileSwitcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();

    await openAlertsSheet(tester);
    expect(topicField(tester), topicB);
    expect(find.text('https://ntfy.sh'), findsOneWidget);
  });

  // Whoever set alerts up before the destination was kept per profile still
  // sees that topic.
  testWidgets(
      'Health-Alerts: ein Profil ohne eigenes Thema zeigt das app-weite von '
      'früher', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..alertsStatus =
          (enabled: true, lastCheck: '12:00', wrapperOutdated: false);
    await tester.pumpWidget(page(u,
        config: twoPis(b: topicB, appWide: topicAppWide)));
    await tester.pumpAndSettle();

    await openAlertsSheet(tester);
    expect(topicField(tester), topicAppWide);
    expect(find.textContaining('nicht gespeichert'), findsNothing);
  });

  testWidgets(
      'Health-Alerts: Einschalten merkt das Thema beim aktiven Profil — das '
      'andere und der app-weite Wert bleiben', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    final store = _FakeStore(twoPis(b: topicB, appWide: topicAppWide));
    await tester.pumpWidget(page(u, store: store));
    await tester.pumpAndSettle();
    await openAlertsSheet(tester);

    await tester.enterText(find.byType(TextField).first, topicA);
    await tester.enterText(find.byType(TextField).at(1), 'https://ntfy.example.org');
    await tester.tap(find.widgetWithText(FilledButton, 'Einschalten'));
    await tester.pumpAndSettle();

    expect(u.alertsTopic, topicA);
    expect(u.alertsServer, 'https://ntfy.example.org');
    expect(store.saved.profiles[0].alertsNtfyTopic, topicA);
    expect(store.saved.profiles[0].alertsNtfyServer, 'https://ntfy.example.org');
    expect(store.saved.profiles[1].alertsNtfyTopic, topicB);
    expect(store.saved.alertsNtfyTopic, topicAppWide);

    // And the sheet shows it from then on.
    u.alertsStatus = (enabled: true, lastCheck: '12:00', wrapperOutdated: false);
    await tester.tap(find.text('Health-Alerts'));
    await tester.pumpAndSettle();
    expect(topicField(tester), topicA);
  });

  // Alerts set up from another device, or before a reinstall: the Pi pushes
  // to a topic this app never saw. A freshly rolled one next to "active" would
  // pass for it.
  testWidgets(
      'Health-Alerts: aktiv auf dem Pi, aber kein Thema bekannt — das Feld '
      'bleibt leer und ein Hinweis sagt warum', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..alertsStatus =
          (enabled: true, lastCheck: '12:00', wrapperOutdated: false);
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await openAlertsSheet(tester);

    expect(topicField(tester), '');
    expect(
        inSheet(find.textContaining(
            'Das ntfy-Thema dieses Pi ist in der App nicht gespeichert')),
        findsOneWidget);

    // Nothing is written to the Pi from the empty field.
    await tester.tap(find.widgetWithText(FilledButton, 'Aktualisieren'));
    await tester.pumpAndSettle();
    expect(u.alertsTopic, isNull);
    expect(inSheet(find.text('Bitte ein ntfy-Thema eingeben.')), findsOneWidget);

    // The dice still hands out a strong one.
    await tester.tap(find.byIcon(Icons.casino_outlined));
    await tester.pumpAndSettle();
    expect(topicField(tester), startsWith('pi-tool-'));
  });

  testWidgets(
      'Health-Alerts: nicht aktiv und nichts bekannt — wie bisher ein '
      'Zufallsthema, ohne Hinweis', (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(page(FakeEvccUpdater()));
    await tester.pumpAndSettle();
    await openAlertsSheet(tester);

    expect(topicField(tester), startsWith('pi-tool-'));
    expect(find.textContaining('nicht gespeichert'), findsNothing);
  });

  testWidgets(
      'Automatik-Karte bewertet das Thema des aktiven Profils, nicht das '
      'app-weite', (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(page(FakeEvccUpdater(),
        config: twoPis(a: topicA, appWide: 'mein-pi')));
    await tester.pumpAndSettle();
    await goAutomatik(tester);
    expect(find.textContaining('leicht erratbar'), findsNothing);

    // B has none of its own: the weak app-wide one stands in.
    await tester.tap(find.byKey(const Key('profileSwitcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    await goAutomatik(tester);
    expect(find.textContaining('leicht erratbar'), findsOneWidget);
  });

  testWidgets(
      'Demo: ein dort eingerichtetes Thema landet nicht beim echten Profil',
      (tester) async {
    useTallScreen(tester);
    final store = _FakeStore(_ready);
    await tester.pumpWidget(page(FakeEvccUpdater(), store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('demoEntry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.bolt_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Health-Alerts'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Einschalten'));
    await tester.pumpAndSettle();

    // Leave the demo and let the profile be saved.
    await tester.tap(find.text('Beenden'));
    await tester.pumpAndSettle();
    final hostField = find.widgetWithText(TextField, 'Host / IP');
    if (!tester.any(hostField)) {
      await tester.tap(find.byKey(const ValueKey('conn-card-header')));
      await tester.pumpAndSettle();
    }
    await tester.enterText(hostField, '192.168.178.99');
    await tester.pump(const Duration(seconds: 1)); // past the save debounce

    expect(store.saved.active.host, '192.168.178.99');
    expect(store.saved.active.alertsNtfyTopic, '');
    expect(store.saved.alertsNtfyTopic, '');
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

  testWidgets(
      'Terminal shows the "✓ Verbunden" confirmation, not the old "Verbinde mit" preamble',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester); // explicit "Verbindung herstellen"
    await goTerminal(tester); // the log persists across the tab switch

    // The explicit connect logs a single past-tense confirmation; the old
    // present-tense "Verbinde mit host…" preamble is gone (it used to linger on
    // the Terminal tab and look like a live connection on app open).
    expect(find.textContaining('✓ Verbunden'), findsWidgets);
    expect(find.textContaining('Verbinde mit'), findsNothing);
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
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
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
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
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
    // Der Text steht jetzt zweimal da: im ⋮-Menü und als Knopf unter dem
    // Demo-Einstieg (der bleibt seit v0.64.3 auch bei gesetzten Zugangsdaten).
    // Gemeint ist hier der Menüeintrag.
    await tester.tap(find.text('Pi im WLAN suchen').last);
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
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
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

  testWidgets('Multi-Pi: „Alle aktualisieren" aktualisiert jeden Pi mit Updates',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'system',
            name: 'System (Pi)',
            installed: true,
            active: true,
            updateAvailable: true,
            updateKnown: true),
      ];
    final store = _FakeStore(const AppConfig(
      profiles: [
        Profile(name: 'A', host: '1.1.1.1', password: 'pw'),
        Profile(name: 'B', host: '2.2.2.2', password: 'pw'),
      ],
      activeIndex: 0,
      disclaimerAccepted: true,
    ));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
          store: store, updater: u, updateChecker: _noUpdateChecker),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alle Pis (Überblick)'));
    await tester.pumpAndSettle();

    // Both reachable with updates → the bulk action appears; run it.
    await tester.tap(find.byTooltip('Alle mit Updates aktualisieren'));
    await tester.pumpAndSettle();
    expect(u.systemUpgradeCalls, 2); // one per Pi, sequential + fail-soft
  });

  testWidgets(
      '⋮ → Pi herunterfahren: gated until connected, confirms, then powers off '
      'and drops the session', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();

    // Disconnected: the SSH-mutating menu items are locked (like the tabs) —
    // tapping does nothing, and the "connect first" hint is shown.
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    expect(find.text('Zuerst mit dem Pi verbinden'), findsNWidgets(2));
    await tester.tap(find.text('Pi herunterfahren'));
    await tester.pumpAndSettle();
    expect(find.text('Pi herunterfahren?'), findsNothing);
    expect(u.shutdownCalls, 0);
    await tester.tapAt(const Offset(10, 600)); // dismiss the menu
    await tester.pumpAndSettle();

    // Connected: the action works — confirm gates it, then it runs.
    await detect(tester);
    expect(find.byKey(const Key('sessionConnected')), findsOneWidget);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pi herunterfahren'));
    await tester.pumpAndSettle();
    expect(find.text('Pi herunterfahren?'), findsOneWidget);
    expect(u.shutdownCalls, 0);
    await tester.tap(find.widgetWithText(FilledButton, 'Herunterfahren'));
    await tester.pumpAndSettle();
    expect(u.shutdownCalls, 1);

    // The Pi is off now — the session must not survive the shutdown.
    expect(find.byKey(const Key('sessionConnected')), findsNothing);
  });

  testWidgets(
      'gemerkte System-Karte ohne Sitzung: „Pi neu starten" und „Pi '
      'herunterfahren" sind gesperrt wie im App-Menü, bis verbunden ist',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    const system = ServiceStatus(
        id: 'system',
        name: 'System (Pi)',
        installed: true,
        version: 'Debian 12',
        active: true,
        detail: 'aktuell');
    await tester.pumpWidget(page(u,
        config: AppConfig(
          profiles: [
            Profile(
                name: 'S',
                host: '192.168.178.64',
                password: 'pw',
                cachedServices: [system.toJson()]),
          ],
          activeIndex: 0,
          disclaimerAccepted: true,
        )));
    await tester.pumpAndSettle();

    // The remembered card is on screen, no session yet.
    expect(find.textContaining('Stand von vorhin'), findsOneWidget);
    expect(find.byKey(const Key('sessionConnected')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('menu-system')));
    await tester.pumpAndSettle();
    expect(find.text('Zuerst mit dem Pi verbinden'), findsNWidgets(2));
    await tester.tap(find.text('Pi neu starten'));
    await tester.pumpAndSettle();
    expect(find.text('Pi neu starten?'), findsNothing);
    await tester.tap(find.text('Pi herunterfahren'));
    await tester.pumpAndSettle();
    expect(find.text('Pi herunterfahren?'), findsNothing);
    // The other entries of the card are not touched by this.
    expect(
        tester
            .widget<PopupMenuItem<int>>(
                find.widgetWithText(PopupMenuItem<int>, 'Sicherheits-Check'))
            .enabled,
        isTrue);
    await tester.tapAt(const Offset(10, 600)); // dismiss the menu
    await tester.pumpAndSettle();

    // Connected: both work, each behind its confirmation as before.
    await detect(tester);
    await tester.tap(find.byKey(const ValueKey('menu-system')));
    await tester.pumpAndSettle();
    expect(find.text('Zuerst mit dem Pi verbinden'), findsNothing);
    await tester.tap(find.text('Pi neu starten'));
    await tester.pumpAndSettle();
    expect(find.text('Pi neu starten?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();
    expect(u.rebootCalls, 1);
    expect(u.shutdownCalls, 0);
  });

  testWidgets(
      'Host geändert: die Karten des bisherigen Hosts stehen als „Stand von '
      'vorhin" da', (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(page(FakeEvccUpdater()));
    await tester.pumpAndSettle();
    await detect(tester);
    expect(find.byKey(const ValueKey('menu-system')), findsOneWidget);
    expect(find.textContaining('Stand von vorhin'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('conn-card-header')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Host / IP'), '192.168.178.99');
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1)); // drain the auto-save debounce

    // Still shown — but as what they are now: not this host's measured state.
    expect(find.byKey(const Key('sessionConnected')), findsNothing);
    expect(find.byKey(const ValueKey('menu-system')), findsOneWidget);
    expect(find.textContaining('Stand von vorhin'), findsOneWidget);
  });

  testWidgets(
      'Host geändert, nachdem die Sitzung schon beendet war (Pi '
      'heruntergefahren): die Karten stehen genauso als „Stand von vorhin" da',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);
    await tester.tap(find.byKey(const ValueKey('menu-system')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pi herunterfahren'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Herunterfahren'));
    await tester.pumpAndSettle();
    expect(u.shutdownCalls, 1);
    // No session any more, the cards of that Pi are still on screen.
    expect(find.byKey(const Key('sessionConnected')), findsNothing);
    expect(find.byKey(const ValueKey('menu-system')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('conn-card-header')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Host / IP'), '192.168.178.99');
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1)); // drain the auto-save debounce

    expect(find.byKey(const ValueKey('menu-system')), findsOneWidget);
    expect(find.textContaining('Stand von vorhin'), findsOneWidget);
  });

  testWidgets(
      'gemerkte Karten, Aktion ohne Verbinden: die danach neu gelesenen Karten '
      'sind kein „Stand von vorhin" mehr — bis der Host geändert wird',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    const system = ServiceStatus(
        id: 'system',
        name: 'System (Pi)',
        installed: true,
        version: 'Debian 12',
        active: true,
        detail: 'aktuell');
    await tester.pumpWidget(page(u,
        config: AppConfig(
          profiles: [
            Profile(
                name: 'S',
                host: '192.168.178.64',
                password: 'pw',
                cachedServices: [system.toJson()]),
          ],
          activeIndex: 0,
          disclaimerAccepted: true,
        )));
    await tester.pumpAndSettle();
    expect(find.textContaining('Stand von vorhin'), findsOneWidget);

    // A card action connects by itself and re-reads the cards afterwards.
    await tester.tap(find.byKey(const ValueKey('menu-system')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paketlisten aktualisieren'));
    await tester.pumpAndSettle();
    expect(u.aptRefreshCalls, 1);
    expect(find.text('Paketlisten aktualisiert.'), findsOneWidget);
    // Measured just now: not a remembered state — and still no session.
    expect(find.textContaining('Stand von vorhin'), findsNothing);
    expect(find.byKey(const Key('sessionConnected')), findsNothing);

    // Another address in the host field: they are the previous one's again.
    await tester.tap(find.byKey(const ValueKey('conn-card-header')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Host / IP'), '192.168.178.99');
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1)); // drain the auto-save debounce
    expect(find.textContaining('Stand von vorhin'), findsOneWidget);
  });

  testWidgets(
      'gemerkte Karten, „Fernzugriff einrichten" ohne Verbinden: die dabei neu '
      'gelesenen Karten sind kein „Stand von vorhin" mehr', (tester) async {
    useTallScreen(tester);
    const tailscale = ServiceStatus(
        id: 'tailscale',
        name: 'Tailscale',
        installed: true,
        active: true,
        version: '100.64.0.5');
    final u = FakeEvccUpdater()
      ..services = const [tailscale]
      ..tailscaleUpUrl = null // already signed in → straight to the check
      ..reachableHosts = {}; // this phone is not in the tailnet
    await tester.pumpWidget(page(u,
        config: AppConfig(
          profiles: [
            Profile(
                name: 'S',
                host: '192.168.178.64',
                password: 'pw',
                cachedServices: [tailscale.toJson()]),
          ],
          activeIndex: 0,
          disclaimerAccepted: true,
        )));
    await tester.pumpAndSettle();
    expect(find.textContaining('Stand von vorhin'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('menu-tailscale')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fernzugriff einrichten'));
    await tester.pumpAndSettle();
    expect(u.tailscaleUpCalls, 1);
    expect(u.probedHosts, ['100.64.0.5']); // the check ran, on fresh cards
    expect(find.textContaining('Stand von vorhin'), findsNothing);
  });

  testWidgets(
      'Zugangsdaten-Karte startet eingeklappt, wenn die Zugangsdaten vollständig '
      'sind (spart Platz, v. a. das SSH-Key-Feld)', (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(page(FakeEvccUpdater())); // _ready: host + password
    await tester.pumpAndSettle();

    // Fields are hidden; a compact summary stands in for them.
    expect(find.text('Host / IP'), findsNothing);
    expect(find.textContaining('192.168.178.64'), findsWidgets);
  });

  testWidgets('Tippen auf die Zugangsdaten-Kopfzeile klappt die Felder auf',
      (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(page(FakeEvccUpdater()));
    await tester.pumpAndSettle();
    expect(find.text('Host / IP'), findsNothing); // collapsed

    await tester.tap(find.byKey(const ValueKey('conn-card-header')));
    await tester.pumpAndSettle();
    expect(find.text('Host / IP'), findsOneWidget); // expanded
  });

  testWidgets('Ohne Zugangsdaten startet die Karte aufgeklappt', (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
        store: _FakeStore(const AppConfig(
          profiles: [Profile(name: 'Neu')], // no host, no secret yet
          activeIndex: 0,
          disclaimerAccepted: true,
        )),
        updater: FakeEvccUpdater(),
        updateChecker: _noUpdateChecker,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Host / IP'), findsOneWidget);
  });

  testWidgets(
      'SSH-Key: der Inline-Button im Formular richtet den Key automatisch ein',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u)); // _ready: password auth, host + pw set
    await tester.pumpAndSettle();

    // _ready has complete creds → the card starts collapsed; expand it first.
    await tester.tap(find.byKey(const ValueKey('conn-card-header')));
    await tester.pumpAndSettle();

    // The auto-setup lives per-Pi in the connection form: tapping the SSH-Key
    // segment (with no key yet) reveals the "automatisch einrichten" button.
    await tester.tap(find.text('SSH-Key'));
    await tester.pumpAndSettle();
    expect(find.text('SSH-Key automatisch einrichten'), findsOneWidget);

    await tester.tap(find.text('SSH-Key automatisch einrichten'));
    await tester.pumpAndSettle();
    expect(find.text('SSH-Key einrichten?'), findsOneWidget); // confirm gate
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();

    // A real generated public key was installed on the Pi.
    expect(u.installedKeys, hasLength(1));
    expect(u.installedKeys.single, startsWith('ssh-ed25519 '));
    // Only switches after verifying the Pi accepts the key.
    expect(find.textContaining('SSH-Key eingerichtet'), findsWidgets);
    // A key is set up now → the auto-setup button is gone.
    expect(find.text('SSH-Key automatisch einrichten'), findsNothing);
  });

  testWidgets(
      'SSH-Key: wird der Key vom Pi abgelehnt, bleibt das Profil auf Passwort',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()..keyAuthOk = false; // sshd rejects pubkey auth
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('conn-card-header'))); // expand
    await tester.pumpAndSettle();
    await tester.tap(find.text('SSH-Key'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SSH-Key automatisch einrichten'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();

    // Key was installed, but the switch is NOT committed (marker discipline).
    expect(u.installedKeys, hasLength(1));
    expect(find.textContaining('bleibt auf Passwort'), findsOneWidget);
    // No key committed → the inline setup button is still offered.
    expect(find.text('SSH-Key automatisch einrichten'), findsOneWidget);
  });

  testWidgets(
      '⋮-Menü führt zum GitHub-Projekt, nicht nur zu den Releases',
      (tester) async {
    // GitHub issue #23: das Projekt war nur über „Changelog" (Releases-Seite)
    // erreichbar.
    useTallScreen(tester);
    await tester.pumpWidget(page(FakeEvccUpdater()));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('Changelog'), findsOneWidget);
  });

  testWidgets(
      '⋮-Menü bietet keine SSH-Key-Einrichtung mehr (pro-Pi im Formular)',
      (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(page(FakeEvccUpdater()));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    expect(find.text('SSH-Key einrichten'), findsNothing);
  });

  testWidgets('Service-Logs: Live-Modus pollt periodisch nach', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-evcc')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Logs anzeigen'));
    await tester.pumpAndSettle();
    final afterOpen = u.logFetches; // initial load
    expect(find.text('Live'), findsOneWidget);

    // Live on → immediate refresh + a poll after 3s.
    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(u.logFetches, greaterThan(afterOpen));

    // Live off → cancels the timer (no lingering timers at test end).
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'Service-Logs: öffnet beim neuesten Eintrag und bleibt im Live-Modus '
      'dort – außer es wird gerade weiter oben gelesen', (tester) async {
    useTallScreen(tester);
    String lines(int n) => [for (var i = 0; i < n; i++) 'zeile $i'].join('\n');
    final u = FakeEvccUpdater()..serviceLogs = lines(400);
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);
    await tester.tap(find.byKey(const ValueKey('menu-evcc')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Logs anzeigen'));
    await tester.pumpAndSettle();

    ScrollPosition pos() => tester
        .state<ScrollableState>(find
            .descendant(
                of: find.descendant(
                    of: find.byType(BottomSheet),
                    matching: find.byType(SingleChildScrollView)),
                matching: find.byType(Scrollable))
            .first)
        .position;
    expect(pos().maxScrollExtent, greaterThan(0));
    expect(pos().pixels, pos().maxScrollExtent);

    // Following: a longer tail arrives, the view stays at its end.
    final before = pos().maxScrollExtent;
    u.serviceLogs = lines(450);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(pos().maxScrollExtent, greaterThan(before));
    expect(pos().pixels, pos().maxScrollExtent);

    // Scrolled up to read: the next poll does not pull the view away.
    pos().jumpTo(100);
    u.serviceLogs = lines(500);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(pos().pixels, 100);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'Service-Logs: ein fehlgeschlagener Abruf wird gemeldet, der letzte '
      'Stand bleibt stehen', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()..serviceLogs = 'evcc[1]: charging started';
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);
    await tester.tap(find.byKey(const ValueKey('menu-evcc')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Logs anzeigen'));
    await tester.pumpAndSettle();
    const hint = 'Abruf fehlgeschlagen – angezeigt wird der letzte Stand.';
    final refresh = find.descendant(
        of: find.byType(BottomSheet), matching: find.byTooltip('Aktualisieren'));
    expect(find.text(hint), findsNothing);

    u.logError =
        const EvccUpdateException(UpdateErrorKind.connection, 'Pi weg');
    await tester.tap(refresh);
    await tester.pumpAndSettle();
    expect(find.text(hint), findsOneWidget);
    expect(find.textContaining('charging started'), findsOneWidget);

    // The next poll that works takes the hint away again.
    u
      ..logError = null
      ..serviceLogs = 'evcc[1]: charging stopped';
    await tester.tap(refresh);
    await tester.pumpAndSettle();
    expect(find.text(hint), findsNothing);
    expect(find.textContaining('charging stopped'), findsOneWidget);
  });

  testWidgets('Automatik → Geplante Backups: Einschalten installiert den Timer',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await goAutomatik(tester);

    await tester.tap(find.text('Geplante Backups'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Einschalten'));
    await tester.pumpAndSettle();

    // The timer is installed with a daily schedule + a keep count.
    expect(u.scheduledBackupOnCal, isNotNull);
    expect(u.scheduledBackupOnCal, contains(':00:00'));
    expect(u.scheduledBackupKeep, 7);
  });

  // A wrapper lives on the Pi: fixes in the app reach it only when the timer
  // is set up again, so an active timer with an older wrapper has to say so.
  testWidgets(
      'Automatik: ein aktiver Timer mit älterem Skript auf dem Pi sagt, wie '
      'es erneuert wird', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..scheduledBackupStatus = (
        enabled: true,
        nextRun: 'Mo 03:00',
        lastResult: '2026-10-07 03:00:01 ok: nichts',
        wrapperOutdated: true
      )
      ..autoStatus = (
        enabled: true,
        nextRun: 'So 04:00',
        lastResult: 'ok',
        wrapperOutdated: true
      )
      ..alertsStatus =
          (enabled: true, lastCheck: '12:00', wrapperOutdated: true);
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await goAutomatik(tester);

    for (final (tile, action) in [
      ('Geplante Backups', 'Zeitplan ändern'),
      ('Automatische Updates', 'Zeitplan ändern'),
      ('Health-Alerts', 'Aktualisieren'),
    ]) {
      await tester.tap(find.text(tile));
      await tester.pumpAndSettle();
      final hint = find.byKey(const Key('wrapperOutdatedHint'));
      expect(hint, findsOneWidget, reason: tile);
      expect(tester.widget<Text>(hint).data, contains('„$action“'),
          reason: tile);
      // The button the hint names is the one in this sheet.
      expect(find.widgetWithText(FilledButton, action), findsOneWidget,
          reason: tile);
      Navigator.of(tester.element(hint)).pop();
      await tester.pumpAndSettle();
    }
  });

  // ---- contrast and tap targets ----

  // The bright brand green has about 1.9:1 against the white of the light
  // theme; the darkened one is for exactly that surface.
  for (final brightness in Brightness.values) {
    testWidgets(
        'Automatik-Sheets: der Aktiv-Status ist im Theme ${brightness.name} '
        'ein lesbares Grün', (tester) async {
      useTallScreen(tester);
      final u = FakeEvccUpdater()
        ..scheduledBackupStatus = (
          enabled: true,
          nextRun: 'Mo 03:00',
          lastResult: null,
          wrapperOutdated: false
        )
        ..autoStatus = (
          enabled: true,
          nextRun: 'So 04:00',
          lastResult: null,
          wrapperOutdated: false
        )
        ..alertsStatus =
            (enabled: true, lastCheck: '12:00', wrapperOutdated: false);
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(brightness),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('de'),
        home: UpdaterPage(
          store: _FakeStore(_ready),
          updater: u,
          updateChecker: _noUpdateChecker,
          apiClient: EvccApiClient(
              getJson: (_) async =>
                  throw const EvccApiException('kein Netz im Test')),
          evccReleaseFetcher: () async => null,
          haVersionFetcher: () async => null,
        ),
      ));
      await tester.pumpAndSettle();
      await goAutomatik(tester);

      final expected =
          brightness == Brightness.dark ? kGreen : const Color(0xFF15803D);
      for (final tile in [
        'Geplante Backups',
        'Automatische Updates',
        'Health-Alerts',
      ]) {
        await tester.tap(find.text(tile));
        await tester.pumpAndSettle();
        final status = find.textContaining('Aktuell aktiv');
        expect(tester.widget<Text>(status).style?.color, expected,
            reason: tile);
        Navigator.of(tester.element(status)).pop();
        await tester.pumpAndSettle();
      }
    });
  }

  testWidgets('Fußzeilen-Links und der ntfy-Link sind mindestens 48 dp hoch',
      (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(page(FakeEvccUpdater()));
    await tester.pumpAndSettle();

    for (final label in [
      'Nutzungsbedingungen',
      'Datenschutz',
      'Impressum',
      'Open-Source-Lizenzen',
      'App bewerten',
    ]) {
      expect(tester.getSize(find.widgetWithText(TextButton, label)).height,
          greaterThanOrEqualTo(48),
          reason: label);
    }

    await goAutomatik(tester);
    await tester.tap(find.text('Health-Alerts'));
    await tester.pumpAndSettle();
    final ntfy = find.ancestor(
        of: find.textContaining('So funktioniert ntfy'),
        matching: find.byType(InkWell));
    expect(tester.getSize(ntfy.first).height, greaterThanOrEqualTo(48));
  });

  testWidgets(
      'Status-Symbole sagen ihren Zustand auch ohne Farbe (Semantik-Label)',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'system',
            name: 'System (Pi)',
            installed: true,
            active: true,
            health: '81 Grad · 97% belegt',
            healthWarning: true),
      ];
    await tester.pumpWidget(page(u,
        config: const AppConfig(
          profiles: [
            Profile(name: 'A', host: '1.1.1.1', password: 'pw'),
            Profile(name: 'B'), // no host → not reachable
          ],
          activeIndex: 0,
          disclaimerAccepted: true,
        )));
    await tester.pumpAndSettle();
    await detect(tester);
    expect(
        tester
            .widget<Icon>(find.byKey(const Key('sessionConnected')))
            .semanticLabel,
        'Verbunden');

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alle Pis (Überblick)'));
    await tester.pumpAndSettle();
    List<String?> lights() => [
          for (final i in tester.widgetList<Icon>(find.byIcon(Icons.circle)))
            i.semanticLabel
        ];
    // Warning and OK are the same circle in another colour.
    expect(lights(), ['Warnung', 'Nicht erreichbar']);

    u.services = const [
      ServiceStatus(
          id: 'system',
          name: 'System (Pi)',
          installed: true,
          active: true,
          health: '48 Grad · 12% belegt'),
    ];
    await tester.tap(find.byTooltip('Neu prüfen'));
    await tester.pumpAndSettle();
    expect(lights(), ['In Ordnung', 'Nicht erreichbar']);

    u.services = const [
      ServiceStatus(
          id: 'system',
          name: 'System (Pi)',
          installed: true,
          active: true,
          updateAvailable: true,
          updateKnown: true),
    ];
    await tester.tap(find.byTooltip('Neu prüfen'));
    await tester.pumpAndSettle();
    expect(lights(), ['Updates verfügbar', 'Nicht erreichbar']);
  });

  // ---- dialogs on a small display with a large font ----

  /// A small phone (360x640) with the system font size turned up. Applied
  /// once the dialog is open, so the way to it is not part of the test.
  void shrinkWithLargeFont(WidgetTester tester) {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  Future<void> openExportPassphrase(WidgetTester tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(page(FakeEvccUpdater()));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Einstellungen'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Profile exportieren'));
    await tester.tap(find.text('Profile exportieren'));
    await tester.pumpAndSettle();
  }

  testWidgets('Passphrase-Dialog: der Sichtbarkeits-Schalter sagt, was er tut',
      (tester) async {
    await openExportPassphrase(tester);
    final dialog = find.byType(AlertDialog);

    final show =
        find.descendant(of: dialog, matching: find.byTooltip('Anzeigen'));
    expect(show, findsOneWidget);
    await tester.tap(show);
    await tester.pump();
    expect(find.descendant(of: dialog, matching: find.byTooltip('Verbergen')),
        findsOneWidget);
  });

  testWidgets(
      'Passphrase-Dialog (Export) auf kleinem Display mit großer Schrift und '
      'Tastatur: läuft nicht über, beide Felder bleiben erreichbar',
      (tester) async {
    await openExportPassphrase(tester);

    shrinkWithLargeFont(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 260); // keyboard
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();

    // A RenderFlex overflow in the dialog would be reported here.
    expect(tester.takeException(), isNull);
    final ok = find.widgetWithText(FilledButton, 'OK');
    expect(tester.getRect(ok).bottom, lessThanOrEqualTo(640 - 260));
    final repeat = find.widgetWithText(TextField, 'Passphrase wiederholen');
    await tester.ensureVisible(repeat);
    await tester.pumpAndSettle();
    expect(tester.getRect(repeat).bottom,
        lessThanOrEqualTo(tester.getRect(ok).top));
  });

  testWidgets(
      'Pi-hole-Passwort-Dialog auf kleinem Display mit großer Schrift: läuft '
      'nicht über, Passwort und „Fertig“ bleiben erreichbar', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'system', name: 'System (Pi)', installed: true, active: true)
      ]
      ..securityFindings = const [
        (
          title: 'Pi-hole-Weboberfläche',
          level: SecurityLevel.warn,
          detail: 'Kein Passwort gesetzt.'
        ),
      ]
      ..piholeWebPassword = 'Abc234xyzKLMN567';
    await tester.pumpWidget(page(u, config: _readyNoOffer));
    await tester.pumpAndSettle();
    await detect(tester);
    await tester.tap(find.byKey(const ValueKey('menu-system')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sicherheits-Check'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Beheben'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();
    expect(find.text('Pi-hole-Passwort'), findsOneWidget);

    shrinkWithLargeFont(tester);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final done = find.widgetWithText(FilledButton, 'Fertig');
    expect(tester.getRect(done).bottom, lessThanOrEqualTo(640));
    // The password is the point of this dialog: the app keeps no copy.
    final pw = find.byKey(const ValueKey('piholePassword'));
    await tester.ensureVisible(pw);
    await tester.pumpAndSettle();
    expect(
        tester.getRect(pw).bottom, lessThanOrEqualTo(tester.getRect(done).top));
  });

  testWidgets('Automatik: aktuelles Skript oder ausgeschalteter Timer – kein '
      'Hinweis', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..scheduledBackupStatus = (
        enabled: true,
        nextRun: 'Mo 03:00',
        lastResult: null,
        wrapperOutdated: false
      )
      // Switched off with the old file still lying around: nothing to renew.
      ..autoStatus = (
        enabled: false,
        nextRun: null,
        lastResult: null,
        wrapperOutdated: true
      );
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await goAutomatik(tester);

    for (final tile in ['Geplante Backups', 'Automatische Updates']) {
      await tester.tap(find.text(tile));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('wrapperOutdatedHint')), findsNothing,
          reason: tile);
      Navigator.of(tester.element(find.text(tile).last)).pop();
      await tester.pumpAndSettle();
    }
  });

  testWidgets(
      '⋮ → „Fernzugriff: Tailscale öffnen" (verfügbar OHNE Verbindung) öffnet die '
      'App + setzt die gemerkte Tailnet-IP', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'tailscale',
            name: 'Tailscale',
            installed: true,
            active: true,
            version: '100.64.1.5'),
      ];
    final launcher = _FakeLauncher();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
        store: _FakeStore(_ready),
        updater: u,
        updateChecker: _noUpdateChecker,
        appLauncher: launcher,
      ),
    ));
    await tester.pumpAndSettle();
    // Connect once (at home) → the Pi's tailnet IP is remembered.
    await detect(tester);

    // The remote-access entry lives in the ⋮ menu — reachable without a live
    // connection, which is the whole point of remote access.
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fernzugriff: Tailscale öffnen'));
    await tester.pumpAndSettle();

    expect(launcher.opened, contains('com.tailscale.ipn'));
    expect(find.text('100.64.1.5'), findsWidgets); // host pre-filled
  });

  testWidgets(
      '⋮: „Fernzugriff: Tailscale öffnen" ist immer sichtbar, aber ohne bekannte '
      'IP deaktiviert (auffindbar, kein toter Klick)', (tester) async {
    useTallScreen(tester);
    final launcher = _FakeLauncher();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
        store: _FakeStore(_ready), // no tailscaleIp remembered yet
        updater: FakeEvccUpdater(),
        updateChecker: _noUpdateChecker,
        appLauncher: launcher,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();

    // Discoverable even before any Tailscale IP is known …
    expect(find.text('Fernzugriff: Tailscale öffnen'), findsOneWidget);
    // … but disabled, so a tap does nothing (no app opened).
    final item = tester.widget<PopupMenuItem<String>>(
      find.ancestor(
        of: find.text('Fernzugriff: Tailscale öffnen'),
        matching: find.byType(PopupMenuItem<String>),
      ),
    );
    expect(item.enabled, isFalse);
    await tester.tap(find.text('Fernzugriff: Tailscale öffnen'));
    await tester.pumpAndSettle();
    expect(launcher.opened, isEmpty);
  });

  testWidgets(
      '⋮ → „Zurück auf Heim-IP" stellt nach dem Fernzugriff die LAN-IP wieder her',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'tailscale',
            name: 'Tailscale',
            installed: true,
            active: true,
            version: '100.64.1.5'),
      ];
    final launcher = _FakeLauncher();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
        store: _FakeStore(_ready), // host 192.168.178.64 (LAN)
        updater: u,
        updateChecker: _noUpdateChecker,
        appLauncher: launcher,
      ),
    ));
    await tester.pumpAndSettle();
    // Connect at home → remembers BOTH the LAN host and the tailnet IP.
    await detect(tester);

    // Go remote: switch the host to the tailnet IP.
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fernzugriff: Tailscale öffnen'));
    await tester.pumpAndSettle();
    expect(find.text('100.64.1.5'), findsWidgets); // now on the tailnet IP

    // Back home: one tap restores the remembered LAN address — no re-scan, no
    // manual retyping. The entry only shows while the host is a tailnet IP.
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zurück auf Heim-IP (192.168.178.64)'));
    await tester.pumpAndSettle();

    expect(find.text('192.168.178.64'), findsWidgets); // host back on LAN
  });

  testWidgets('erkannter systemd-Dienst (AdGuard Home) → Karte + Neustart',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'adguard',
            name: 'AdGuard Home',
            installed: true,
            active: true,
            detail: 'systemd · Dienst aktiv',
            webPort: 3000),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    expect(find.text('AdGuard Home'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Neustart'));
    await tester.pumpAndSettle();
    expect(u.restartedUnits, contains('AdGuardHome'));
  });

  testWidgets('System-Karte → Docker-Container: Liste + Neustart',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'system', name: 'System (Pi)', installed: true, active: true)
      ]
      ..containers = const [
        (
          name: 'evcc',
          state: 'running',
          status: 'Up 2 hours',
          image: 'evcc/evcc:latest'
        ),
        (
          name: 'pihole',
          state: 'exited',
          status: 'Exited (0)',
          image: 'pihole/pihole'
        ),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-system')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Docker-Container'));
    await tester.pumpAndSettle();
    expect(find.text('evcc'), findsOneWidget);
    expect(find.text('pihole'), findsOneWidget);

    // Restart evcc via its row menu.
    await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, 'evcc'),
        matching: find.byType(PopupMenuButton<String>)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Neustart'));
    await tester.pumpAndSettle();
    expect(u.restartedContainers, contains('evcc'));
  });

  testWidgets('Docker-Übersicht: ein gescheiterter Neustart wird gemeldet',
      (tester) async {
    // Audit 2026-08-15 (Altlast): der Fehler verschwand lautlos — der Spinner
    // drehte kurz, danach passierte nichts.
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'system', name: 'System (Pi)', installed: true, active: true)
      ]
      ..containers = const [
        (
          name: 'nodered',
          state: 'exited',
          status: 'Exited (1)',
          image: 'nodered/node-red:latest'
        ),
      ]
      ..restartContainerError = const EvccUpdateException(
          UpdateErrorKind.unknown, 'Neustart von nodered fehlgeschlagen.');
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-system')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Docker-Container'));
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, 'nodered'),
        matching: find.byType(PopupMenuButton<String>)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Neustart'));
    // No pumpAndSettle: the sheet's busy spinner keeps animating underneath
    // the error dialog, so settle would never return.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(u.restartedContainers, contains('nodered'));
    expect(find.textContaining('fehlgeschlagen'), findsWidgets);
  });

  testWidgets('Docker-Übersicht → Aktualisieren updated einen Container',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'system', name: 'System (Pi)', installed: true, active: true)
      ]
      ..containers = const [
        (
          name: 'nodered',
          state: 'running',
          status: 'Up 4 days',
          image: 'nodered/node-red:latest'
        ),
        (
          // Pi-Tool's own rollback container — must NOT offer an update.
          name: 'evcc-evccpitool-old',
          state: 'exited',
          status: 'Exited (0)',
          image: 'evcc/evcc:0.123'
        ),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-system')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Docker-Container'));
    await tester.pumpAndSettle();

    // The rollback container's menu has no update entry.
    await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, 'evcc-evccpitool-old'),
        matching: find.byType(PopupMenuButton<String>)));
    await tester.pumpAndSettle();
    expect(find.text('Aktualisieren'), findsNothing);
    await tester.tapAt(const Offset(5, 5)); // close the menu
    await tester.pumpAndSettle();

    // A normal container: update → confirm → the updater runs.
    await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, 'nodered'),
        matching: find.byType(PopupMenuButton<String>)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aktualisieren'));
    // No pumpAndSettle: the sheet's busy spinner animates while the confirm
    // dialog is open, so settle would time out. Pump the dialog in instead.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();
    expect(u.updatedContainers, ['nodered']);
  });

  testWidgets('System-Karte → Speicherplatz zeigt die größten Posten',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'system', name: 'System (Pi)', installed: true, active: true)
      ]
      ..disk = const [
        (name: 'var', bytes: 2 * 1024 * 1024 * 1024, isDir: true, path: '/var'),
        (
          name: 'huge.img',
          bytes: 500 * 1024 * 1024,
          isDir: false,
          path: '/huge.img'
        ),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-system')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Speicherplatz analysieren'));
    await tester.pumpAndSettle();

    expect(find.text('var'), findsOneWidget);
    expect(find.text('huge.img'), findsOneWidget);
    expect(find.text('2.0 GB'), findsOneWidget); // human-readable size
  });

  // At "/" there is no way up and nothing else to tap: a drill-down that
  // fails must leave the list standing and offer the folder again.
  testWidgets(
      'Speicherplatz analysieren: scheitert ein Unterordner, bleibt die Liste '
      'stehen und der Abruf lässt sich wiederholen', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'system', name: 'System (Pi)', installed: true, active: true)
      ]
      ..disk = const [
        (name: 'var', bytes: 2 * 1024 * 1024 * 1024, isDir: true, path: '/var'),
        (
          name: 'huge.img',
          bytes: 500 * 1024 * 1024,
          isDir: false,
          path: '/huge.img'
        ),
      ]
      ..diskByPath['/var'] = const [
        (name: 'log', bytes: 1024 * 1024 * 1024, isDir: true, path: '/var/log'),
      ]
      ..diskErrors['/var'] = const EvccUpdateException(
          UpdateErrorKind.connection, 'Pi nicht erreichbar.');
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);
    await tester.tap(find.byKey(const ValueKey('menu-system')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Speicherplatz analysieren'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('var'));
    await tester.pumpAndSettle();

    // Still the list of "/", with the folder that failed and the reason.
    expect(find.text('var'), findsOneWidget);
    expect(find.text('huge.img'), findsOneWidget);
    expect(find.text('/var: Pi nicht erreichbar.'), findsOneWidget);

    u.diskErrors.clear();
    await tester.tap(find.text('Erneut versuchen'));
    await tester.pumpAndSettle();
    expect(find.text('log'), findsOneWidget);
    expect(find.text('huge.img'), findsNothing);
    expect(find.textContaining('Pi nicht erreichbar.'), findsNothing);

    // An error that is not the updater's own keeps the generic text; going up
    // clears it.
    u.diskErrors['/var/log'] = StateError('x');
    await tester.tap(find.text('log'));
    await tester.pumpAndSettle();
    expect(find.text('log'), findsOneWidget);
    expect(find.text('/var/log: Konnte nicht geladen werden (Rechte?).'),
        findsOneWidget);
    await tester.tap(find.byTooltip('Übergeordneter Ordner'));
    await tester.pumpAndSettle();
    expect(find.text('huge.img'), findsOneWidget);
    expect(find.textContaining('Konnte nicht geladen werden'), findsNothing);
  });

  testWidgets('Pi Connect: anstehendes Update übernimmt den Primär-Knopf',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'piconnect',
            name: 'Raspberry Pi Connect',
            installed: true,
            active: true, // angemeldet → Primär wäre sonst „Web öffnen"
            updateAvailable: true,
            updateKnown: true,
            aptPackage: 'rpi-connect-lite'),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Aktualisieren'));
    await tester.pumpAndSettle();

    expect(u.aptUpdates, ['rpi-connect-lite']);
  });

  testWidgets('Pi Connect: „Web öffnen" geht dabei nicht verloren, es wandert ins ⋮',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'piconnect',
            name: 'Raspberry Pi Connect',
            installed: true,
            active: true,
            updateAvailable: true,
            updateKnown: true,
            aptPackage: 'rpi-connect-lite'),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-piconnect')));
    await tester.pumpAndSettle();
    expect(find.text('Web öffnen'), findsOneWidget);
  });

  testWidgets('Pi Connect ohne anstehendes Update: Primär bleibt „Web öffnen"',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        // updateKnown: false = Stand unbekannt (z. B. veralteter apt-Index).
        // Der Fall „bekannt aktuell" steht weiter unten („Karten-Regel").
        ServiceStatus(
            id: 'piconnect',
            name: 'Raspberry Pi Connect',
            installed: true,
            active: true),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    expect(find.widgetWithText(OutlinedButton, 'Web öffnen'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Aktualisieren'), findsNothing);
  });

  testWidgets('Tailscale: anstehendes Update übernimmt den Primär-Knopf',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'tailscale',
            name: 'Tailscale',
            installed: true,
            active: true,
            version: '100.64.0.5',
            updateAvailable: true,
            updateKnown: true,
            aptPackage: 'tailscale'),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Aktualisieren'));
    await tester.pumpAndSettle();

    expect(u.aptUpdates, ['tailscale']);
  });

  testWidgets('Auto-Verbinden: gesetzter Pi verbindet beim Start von allein',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u,
        config: const AppConfig(
          profiles: [
            Profile(
                name: 'S',
                host: '192.168.178.64',
                password: 'pw',
                autoConnect: true)
          ],
          activeIndex: 0,
          disclaimerAccepted: true,
        )));
    await tester.pumpAndSettle();

    // Ohne einen einzigen Tipp: die Erkennung lief.
    expect(u.detectCalls, greaterThan(0));
  });

  testWidgets('Auto-Verbinden: ohne Schalter passiert beim Start nichts',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    expect(u.detectCalls, 0);
  });

  testWidgets('Auto-Verbinden: Einschalten nimmt es dem anderen Pi weg',
      (tester) async {
    useTallScreen(tester);
    final store = _FakeStore(const AppConfig(
      profiles: [
        Profile(name: 'A', host: '192.168.178.64', password: 'pw'),
        Profile(name: 'B', host: '192.168.178.65', password: 'pw',
            autoConnect: true),
      ],
      activeIndex: 0,
      disclaimerAccepted: true,
    ));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
        store: store,
        updater: FakeEvccUpdater(),
        updateChecker: _noUpdateChecker,
      ),
    ));
    await tester.pumpAndSettle();

    // Zugangsdaten aufklappen, damit der Schalter sichtbar ist.
    await tester.tap(find.text('Zugangsdaten'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.byKey(const Key('autoConnectSwitch')), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const Key('autoConnectSwitch')));
    await tester.pumpAndSettle();

    // Genau einer darf es sein — A an, B automatisch aus.
    expect(store.saved.profiles.where((p) => p.autoConnect).length, 1);
    expect(store.saved.profiles.firstWhere((p) => p.name == 'A').autoConnect,
        isTrue);
    expect(store.saved.profiles.firstWhere((p) => p.name == 'B').autoConnect,
        isFalse);
  });

  testWidgets('Fernzugriff: ✕ blendet den Einstieg dauerhaft aus',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'system', name: 'System (Pi)', installed: true, active: true),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);
    expect(find.text('Fernzugriff einrichten'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('remoteAccessDismiss')));
    await tester.pumpAndSettle();
    expect(find.text('Fernzugriff einrichten'), findsNothing);
  });

  testWidgets('Fernzugriff: einmal ausgeblendet bleibt über Neustarts weg',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'system', name: 'System (Pi)', installed: true, active: true),
      ];
    await tester.pumpWidget(page(u,
        config: const AppConfig(
          profiles: [Profile(name: 'S', host: '192.168.178.64', password: 'pw')],
          activeIndex: 0,
          disclaimerAccepted: true,
          remoteAccessDismissed: true,
        )));
    await tester.pumpAndSettle();
    await detect(tester);
    expect(find.text('Fernzugriff einrichten'), findsNothing);
  });

  testWidgets('Fernzugriff bleibt über die Tailscale-Karte erreichbar',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'tailscale',
            name: 'Tailscale',
            installed: true,
            active: true,
            version: '100.64.0.5',
            updateKnown: true),
      ];
    await tester.pumpWidget(page(u,
        config: const AppConfig(
          profiles: [Profile(name: 'S', host: '192.168.178.64', password: 'pw')],
          activeIndex: 0,
          disclaimerAccepted: true,
          remoteAccessDismissed: true, // weggetippt — das ✕ ist keine Sackgasse
        )));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-tailscale')));
    await tester.pumpAndSettle();
    expect(find.text('Fernzugriff einrichten'), findsOneWidget);
  });

  testWidgets('Fernzugriff einrichten: installiert Tailscale und meldet an',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'system', name: 'System (Pi)', installed: true, active: true),
      ]
      ..tailscaleUpUrl = null; // schon angemeldet → kein Browser nötig
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.text('Fernzugriff einrichten'));
    await tester.pumpAndSettle();

    expect(u.tailscaleInstallCalls, 1);
    expect(u.tailscaleUpCalls, 1);
    // Noch keine Tailnet-IP erkannt → der Nutzer muss die Anmeldung abschließen.
    expect(find.text('Jetzt prüfen'), findsOneWidget);
  });

  testWidgets('Fernzugriff meldet erst Erfolg, wenn das HANDY den Pi erreicht',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'tailscale',
            name: 'Tailscale',
            installed: true,
            active: true,
            version: '100.64.0.5'),
      ]
      ..tailscaleUpUrl = null
      ..reachableHosts = {}; // Handy erreicht das Tailnet NICHT
    final launcher = _FakeLauncher();
    await tester.pumpWidget(page(u, appLauncher: launcher));
    await tester.pumpAndSettle();
    await detect(tester);

    // Pi trägt schon eine Tailnet-IP → die Karte bietet direkt die Prüfung an.
    await tester.tap(find.text('Jetzt prüfen'));
    await tester.pumpAndSettle();

    // NICHT „App fehlt" behaupten: Die App misst Erreichbarkeit, nicht
    // Installation. Tailscale kann installiert und nur das VPN aus sein —
    // Stefans Meldung vom 01.08.2026.
    expect(find.textContaining('erreicht ihn noch nicht'), findsOneWidget);
    expect(find.textContaining('Fernzugriff steht'), findsNothing);

    // Ein Knopf deckt beide Fälle ab: installiert → Tailscale öffnet sich;
    // nicht installiert → der Launcher fällt auf den Play Store zurück.
    await tester.tap(find.text('Tailscale öffnen'));
    await tester.pumpAndSettle();
    expect(launcher.opened, ['com.tailscale.ipn']);
  });

  testWidgets('Fernzugriff steht, sobald das Handy die Tailnet-IP erreicht',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'tailscale',
            name: 'Tailscale',
            installed: true,
            active: true,
            version: '100.64.0.5'),
      ]
      ..tailscaleUpUrl = null
      ..reachableHosts = {'100.64.0.5'};
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.text('Jetzt prüfen'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Fernzugriff steht'), findsOneWidget);
  });

  // ---- Dienste deinstallieren ----

  const grafana = ServiceStatus(
      id: 'grafana',
      name: 'Grafana',
      installed: true,
      active: true,
      version: '11.0.0',
      updateKnown: true,
      webPort: 3000,
      aptPackage: 'grafana');

  Future<void> openUninstall(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(ValueKey('menu-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Deinstallieren'));
    await tester.pumpAndSettle();
  }

  testWidgets('Deinstallieren: Standard behält Konfiguration und Daten',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()..services = const [grafana];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await openUninstall(tester, 'grafana');
    expect(find.text('Grafana deinstallieren?'), findsOneWidget);
    // Die Löschwarnung erscheint erst mit dem Häkchen.
    expect(find.textContaining('nicht rückgängig'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Deinstallieren'));
    await tester.pumpAndSettle();

    expect(u.uninstalled, [('grafana', false)]);
    expect(find.byKey(const ValueKey('menu-grafana')), findsNothing);
    expect(find.textContaining('Grafana deinstalliert'), findsWidgets);
  });

  testWidgets('Deinstallieren mit Häkchen: löscht auch Daten, mit Warnung',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()..services = const [grafana];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await openUninstall(tester, 'grafana');
    await tester.tap(find.byKey(const ValueKey('uninstallPurge')));
    await tester.pumpAndSettle();
    expect(find.textContaining('nicht rückgängig'), findsOneWidget);
    expect(find.textContaining('Dashboards'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Deinstallieren'));
    await tester.pumpAndSettle();

    expect(u.uninstalled, [('grafana', true)]);
  });

  testWidgets(
      'Deinstallieren mit Häkchen: kein „bleibt"-Text mehr im Dialog '
      '(Home Assistant)', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'homeassistant',
            name: 'Home Assistant',
            installed: true,
            active: true,
            version: '2026.9.1'),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await openUninstall(tester, 'homeassistant');
    expect(find.textContaining('Konfiguration und Image bleiben'),
        findsOneWidget);
    expect(find.textContaining('Konfiguration und Daten bleiben'),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('uninstallPurge')));
    await tester.pumpAndSettle();
    expect(find.textContaining('bleiben'), findsNothing);
    expect(find.textContaining('Löscht /opt/homeassistant/config'),
        findsOneWidget);
  });

  testWidgets('Deinstallieren: Abbrechen ändert nichts', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()..services = const [grafana];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await openUninstall(tester, 'grafana');
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(u.uninstalled, isEmpty);
    expect(find.byKey(const ValueKey('menu-grafana')), findsOneWidget);
  });

  testWidgets(
      'Deinstallieren abgelehnt: der Grund steht in der Meldung, die Karte '
      'bleibt', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [grafana]
      ..uninstallError = const EvccUpdateException(UpdateErrorKind.unknown,
          'apt würde zusätzlich entfernen: foo – abgebrochen.');
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await openUninstall(tester, 'grafana');
    await tester.tap(find.widgetWithText(FilledButton, 'Deinstallieren'));
    await tester.pumpAndSettle();
    expect(find.textContaining('apt würde zusätzlich entfernen'), findsWidgets);
    expect(find.byKey(const ValueKey('menu-grafana')), findsOneWidget);
  });

  testWidgets(
      'Tailscale deinstallieren: Karte wandert in „Dienst hinzufügen", '
      'die gemerkte Tailnet-IP ist weg', (tester) async {
    useTallScreen(tester);
    final store = _FakeStore(const AppConfig(
      profiles: [
        Profile(
            name: 'S',
            host: '192.168.178.64',
            password: 'pw',
            tailscaleIp: '100.64.0.5',
            remoteAccessProven: true)
      ],
      activeIndex: 0,
      disclaimerAccepted: true,
    ));
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'tailscale',
            name: 'Tailscale',
            installed: true,
            active: true,
            version: '100.64.0.5'),
      ];
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
        store: store,
        updater: u,
        updateChecker: _noUpdateChecker,
        apiClient: EvccApiClient(
            getJson: (_) async =>
                throw const EvccApiException('kein Netz im Test')),
      ),
    ));
    await tester.pumpAndSettle();
    await detect(tester);

    await openUninstall(tester, 'tailscale');
    expect(find.textContaining('Fernzugriff über Tailscale endet'),
        findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Deinstallieren'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1)); // drain the auto-save debounce

    expect(u.uninstalled, [('tailscale', false)]);
    expect(find.byKey(const ValueKey('menu-tailscale')), findsNothing);
    expect(store.saved.active.tailscaleIp, '');
    expect(store.saved.active.remoteAccessProven, isFalse);
  });

  testWidgets('evcc als Docker-Container: kein Deinstallieren im Menü',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'evcc',
            name: 'evcc',
            installed: true,
            active: true,
            version: '0.310.0',
            detail: 'Docker · evcc'),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-evcc')));
    await tester.pumpAndSettle();
    expect(find.text('Deinstallieren'), findsNothing);
  });

  testWidgets('evcc per apt: Deinstallieren im Menü', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater(); // Standard: evcc über apt
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-evcc')));
    await tester.pumpAndSettle();
    expect(find.text('Deinstallieren'), findsOneWidget);
  });

  testWidgets('Demo-Modus: kein Deinstallieren (die Demo hätte nur Fehler)',
      (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
        store: _FakeStore(const AppConfig(
          profiles: [Profile(name: 'S')],
          activeIndex: 0,
          disclaimerAccepted: true,
        )),
        updater: FakeEvccUpdater(),
        updateChecker: _noUpdateChecker,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('demoEntry')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('menu-evcc')));
    await tester.pumpAndSettle();
    expect(find.text('Deinstallieren'), findsNothing);
  });

  // ---- Heimnetz über Tailscale freigeben (Subnet Router) ----

  ServiceStatus tsWith(SubnetRoutes routes) => ServiceStatus(
      id: 'tailscale',
      name: 'Tailscale',
      installed: true,
      active: true,
      version: '100.64.0.5',
      routes: routes);
  const lanOff = SubnetRoutes(lan: ['192.168.178.0/24'], machine: 'evcc-pi');
  const lanPending = SubnetRoutes(
      lan: ['192.168.178.0/24'],
      advertised: ['192.168.178.0/24'],
      machine: 'evcc-pi');
  const lanActive = SubnetRoutes(
      lan: ['192.168.178.0/24'],
      advertised: ['192.168.178.0/24'],
      approved: ['192.168.178.0/24'],
      machine: 'evcc-pi');

  testWidgets(
      'Heimnetz freigeben: erst bestätigen, danach Popup mit dem Schritt in '
      'der Tailscale-Konsole', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = [tsWith(lanOff)]
      ..servicesAfterShare = [tsWith(lanPending)];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-tailscale')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Heimnetz freigeben'));
    await tester.pumpAndSettle();

    // Opt-in mit Erklärung: das ganze Heimnetz wird fürs Tailnet geöffnet.
    expect(find.text('Heimnetz freigeben?'), findsOneWidget);
    expect(find.textContaining('192.168.178.0/24'), findsOneWidget);
    expect(u.shareLanCalls, 0);
    await tester.tap(find.widgetWithText(FilledButton, 'Heimnetz freigeben'));
    await tester.pumpAndSettle();

    expect(u.shareLanCalls, 1);
    // Die Bestätigung passiert außerhalb der App — genau dafür das Popup.
    expect(find.text('Noch ein Schritt: Route bestätigen'), findsOneWidget);
    expect(find.textContaining('„evcc-pi“'), findsOneWidget);
    await tester.tap(find.text('Später'));
    await tester.pumpAndSettle();
    expect(find.text('Noch ein Schritt: Route bestätigen'), findsNothing);
    expect(find.text('Heimnetz 192.168.178.0/24: Bestätigung in Tailscale offen'),
        findsOneWidget);
  });

  testWidgets('Heimnetz freigeben: Abbrechen ändert nichts', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()..services = [tsWith(lanOff)];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-tailscale')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Heimnetz freigeben'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(u.shareLanCalls, 0);
  });

  testWidgets(
      'Freigabe prüfen: bestätigt → Statuszeile, kein Popup mehr',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()..services = [tsWith(lanPending)];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-tailscale')));
    await tester.pumpAndSettle();
    // Offen: nicht erneut „freigeben", sondern prüfen oder beenden.
    expect(find.text('Heimnetz freigeben'), findsNothing);
    expect(find.text('Heimnetz-Freigabe beenden'), findsOneWidget);
    u.services = [tsWith(lanActive)]; // inzwischen in der Konsole bestätigt
    await tester.tap(find.text('Heimnetz-Freigabe prüfen'));
    await tester.pumpAndSettle();

    expect(find.text('Noch ein Schritt: Route bestätigen'), findsNothing);
    expect(find.textContaining('ist über Tailscale erreichbar'), findsWidgets);
    expect(find.text('Heimnetz 192.168.178.0/24 freigegeben'), findsOneWidget);
  });

  testWidgets('Freigabe prüfen: noch offen → das Popup erklärt den Schritt erneut',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()..services = [tsWith(lanPending)];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-tailscale')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Heimnetz-Freigabe prüfen'));
    await tester.pumpAndSettle();
    expect(find.text('Noch ein Schritt: Route bestätigen'), findsOneWidget);
  });

  testWidgets('Heimnetz-Freigabe beenden', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()..services = [tsWith(lanActive)];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-tailscale')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Heimnetz-Freigabe beenden'));
    await tester.pumpAndSettle();
    await tester
        .tap(find.widgetWithText(FilledButton, 'Heimnetz-Freigabe beenden'));
    await tester.pumpAndSettle();
    expect(u.unshareLanCalls, 1);
    expect(find.textContaining('Heimnetz-Freigabe beendet'), findsWidgets);
  });

  testWidgets('getrennt: keine Heimnetz-Aktionen (nichts Verlässliches zu sagen)',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'tailscale',
            name: 'Tailscale',
            installed: true,
            active: false,
            routes: lanActive),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-tailscale')));
    await tester.pumpAndSettle();
    expect(find.text('Heimnetz freigeben'), findsNothing);
    expect(find.text('Heimnetz-Freigabe beenden'), findsNothing);
  });

  testWidgets(
      'Fernzugriff-Helfer: nach dem ersten Erfolg optional das Heimnetz '
      'anbieten — ohne zweite Rückfrage', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = [tsWith(lanOff)]
      ..servicesAfterShare = [tsWith(lanPending)]
      ..tailscaleUpUrl = null
      ..reachableHosts = {'100.64.0.5'};
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.text('Jetzt prüfen'));
    await tester.pumpAndSettle();
    expect(find.text('Auch das Heimnetz erreichen?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Heimnetz freigeben'));
    await tester.pumpAndSettle();

    expect(find.text('Heimnetz freigeben?'), findsNothing);
    expect(u.shareLanCalls, 1);
    expect(find.text('Noch ein Schritt: Route bestätigen'), findsOneWidget);
  });

  testWidgets('Fernzugriff-Helfer: „Nicht jetzt" lässt das Heimnetz zu',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = [tsWith(lanOff)]
      ..tailscaleUpUrl = null
      ..reachableHosts = {'100.64.0.5'};
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.text('Jetzt prüfen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nicht jetzt'));
    await tester.pumpAndSettle();
    expect(u.shareLanCalls, 0);
    expect(find.textContaining('Fernzugriff steht'), findsWidgets);
  });

  testWidgets(
      'neues Heimnetz neben alter App-Route: freigeben UND beenden im Angebot',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = [
        tsWith(const SubnetRoutes(
            lan: ['192.168.1.0/24'],
            advertised: ['192.168.178.0/24'],
            approved: ['192.168.178.0/24'],
            mine: ['192.168.178.0/24']))
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    expect(find.text('Heimnetz 192.168.178.0/24 freigegeben'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('menu-tailscale')));
    await tester.pumpAndSettle();
    expect(find.text('Heimnetz freigeben'), findsOneWidget);
    expect(find.text('Heimnetz-Freigabe beenden'), findsOneWidget);
  });

  // ---- evcc über die Tailscale-Adresse / Heimnetz im Router-Standardbereich ----
  // Notiz vom 25.09.2026: freigegeben war 192.168.178.0/24, das Testgerät hing
  // in einem WLAN mit demselben Bereich — die Heimnetz-Adresse von evcc blieb
  // dort im eigenen Netz. Über die 100.x-Adresse des Pi geht es aus jedem Netz.

  const evccOnPi = ServiceStatus(
      id: 'evcc',
      name: 'evcc',
      installed: true,
      version: '0.310.0',
      active: true,
      detail: 'apt · Dienst aktiv');
  const evccViaTailscale = 'evcc über Tailscale: http://100.64.0.5:7070';
  const sameRange = 'Aus einem Netz mit demselben Adressbereich '
      '(192.168.178.0/24) ist das Heimnetz über Tailscale unter Umständen '
      'nicht erreichbar.';
  const sameRangeEvcc =
      '$sameRange evcc dort über die Tailscale-Adresse aufrufen.';
  const ownRange = SubnetRoutes(
      lan: ['10.20.30.0/24'],
      advertised: ['10.20.30.0/24'],
      approved: ['10.20.30.0/24'],
      machine: 'evcc-pi');

  testWidgets(
      'Tailscale verbunden + evcc auf dem Pi: die Karte nennt die evcc-Adresse '
      'über Tailscale', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = [evccOnPi, tsWith(const SubnetRoutes())];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    expect(find.text(evccViaTailscale), findsOneWidget);
    // Nichts freigegeben → auch nichts, wovor zu warnen wäre.
    expect(find.textContaining('demselben Adressbereich'), findsNothing);
  });

  testWidgets(
      'evcc-Adresse über Tailscale folgt Schema und Port der evcc-Oberfläche',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = [evccOnPi, tsWith(const SubnetRoutes())];
    await tester.pumpWidget(page(u,
        config: const AppConfig(
          profiles: [Profile(name: 'S', host: '192.168.178.64', password: 'pw')],
          activeIndex: 0,
          disclaimerAccepted: true,
          uiScheme: 'https',
          uiPort: '7443',
        )));
    await tester.pumpAndSettle();
    await detect(tester);

    expect(find.text('evcc über Tailscale: https://100.64.0.5:7443'),
        findsOneWidget);
  });

  testWidgets(
      'ein in den Einstellungen geänderter evcc-Port steht sofort auf der '
      'Karte — geteilt wird nie ein veralteter', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = [evccOnPi, tsWith(const SubnetRoutes())];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);
    expect(find.text(evccViaTailscale), findsOneWidget);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Einstellungen'));
    await tester.pumpAndSettle();
    final port = find.widgetWithText(TextField, 'evcc-Oberfläche: Port');
    await tester.ensureVisible(port);
    await tester.enterText(port, '7443');
    await tester.pumpAndSettle();
    Navigator.of(tester.element(port)).pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1)); // drain the auto-save debounce

    expect(find.text('evcc über Tailscale: http://100.64.0.5:7443'),
        findsOneWidget);
    expect(find.text(evccViaTailscale), findsNothing);
  });

  testWidgets('ohne evcc auf dem Pi: keine evcc-Adresse, kein Teilen-Eintrag',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = [ServiceStatus.absent('evcc', 'evcc'), tsWith(lanActive)];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    expect(find.textContaining('evcc über Tailscale'), findsNothing);
    // Der Hinweis bleibt, verweist aber auf nichts, das es hier nicht gibt.
    expect(find.text(sameRange), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('menu-tailscale')));
    await tester.pumpAndSettle();
    expect(find.text('evcc-Adresse teilen'), findsNothing);
  });

  testWidgets(
      'Tailscale getrennt: keine evcc-Adresse, kein Hinweis, kein Teilen-Eintrag',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        evccOnPi,
        // Ein angehaltener Knoten behält seine 100.x — erreichbar ist er nicht.
        ServiceStatus(
            id: 'tailscale',
            name: 'Tailscale',
            installed: true,
            active: false,
            version: '100.64.0.5',
            detail: 'Getrennt',
            routes: lanActive),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    expect(find.textContaining('evcc über Tailscale'), findsNothing);
    expect(find.textContaining('demselben Adressbereich'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('menu-tailscale')));
    await tester.pumpAndSettle();
    expect(find.text('evcc-Adresse teilen'), findsNothing);
  });

  testWidgets(
      '⋮ → „evcc-Adresse teilen" übergibt genau diese Adresse samt '
      'Voraussetzung', (tester) async {
    useTallScreen(tester);
    final shared = <String>[];
    final u = FakeEvccUpdater()..services = [evccOnPi, tsWith(lanActive)];
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
        store: _FakeStore(_ready),
        updater: u,
        updateChecker: _noUpdateChecker,
        apiClient: EvccApiClient(
            getJson: (_) async =>
                throw const EvccApiException('kein Netz im Test')),
        evccReleaseFetcher: () async => null,
        haVersionFetcher: () async => null,
        textSharer: (text) async => shared.add(text),
      ),
    ));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-tailscale')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('evcc-Adresse teilen'));
    await tester.pumpAndSettle();

    expect(shared, [
      'evcc über Tailscale: http://100.64.0.5:7070\n'
          'Voraussetzung: Das Gerät ist in Tailscale im selben Tailnet '
          'angemeldet und verbunden.'
    ]);
    // Genau eine Adresse, und zwar die der Karte — keine Heimnetz-Adresse.
    expect(RegExp(r'https?://\S+').allMatches(shared.single).map((m) => m[0]),
        ['http://100.64.0.5:7070']);
    // Teilen ist keine SSH-Aktion: nichts lief gegen den Pi.
    expect(u.shareLanCalls, 0);
  });

  for (final (state, routes) in [
    ('bestätigt', lanActive),
    ('Bestätigung offen', lanPending),
  ]) {
    testWidgets(
        'Heimnetz im Router-Standardbereich freigegeben ($state): Hinweis auf '
        'der Karte, direkt über der evcc-Adresse', (tester) async {
      useTallScreen(tester);
      final u = FakeEvccUpdater()..services = [evccOnPi, tsWith(routes)];
      await tester.pumpWidget(page(u));
      await tester.pumpAndSettle();
      await detect(tester);

      expect(find.text(sameRangeEvcc), findsOneWidget);
      expect(find.text(evccViaTailscale), findsOneWidget);
      expect(tester.getBottomLeft(find.text(sameRangeEvcc)).dy,
          tester.getTopLeft(find.text(evccViaTailscale)).dy);
    });
  }

  testWidgets('eigener Adressbereich (10.20.30.0/24) freigegeben: kein Hinweis',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()..services = [evccOnPi, tsWith(ownRange)];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    expect(find.text('Heimnetz 10.20.30.0/24 freigegeben'), findsOneWidget);
    expect(find.textContaining('demselben Adressbereich'), findsNothing);
    expect(find.text(evccViaTailscale), findsOneWidget);
  });

  testWidgets(
      '„Heimnetz freigeben?" nennt die Einschränkung, bevor freigegeben wird',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()..services = [evccOnPi, tsWith(lanOff)];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    // Noch nicht freigegeben: die Karte hat dazu nichts zu sagen.
    expect(find.textContaining('demselben Adressbereich'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('menu-tailscale')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Heimnetz freigeben'));
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    expect(find.text('Heimnetz freigeben?'), findsOneWidget);
    expect(
        find.descendant(
            of: dialog, matching: find.textContaining(sameRangeEvcc)),
        findsOneWidget);
    // Im Dialog steht die Adresse dabei — die Karte liegt dahinter.
    expect(
        find.descendant(
            of: dialog, matching: find.textContaining(evccViaTailscale)),
        findsOneWidget);
    expect(u.shareLanCalls, 0);
  });

  testWidgets(
      '„Heimnetz freigeben?" mit Hinweis auf einem kleinen Display: läuft nicht '
      'über, die Adresse bleibt erreichbar', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()..services = [evccOnPi, tsWith(lanOff)];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);
    await tester.tap(find.byKey(const ValueKey('menu-tailscale')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Heimnetz freigeben'));
    await tester.pumpAndSettle();

    // Shrink to a small phone (360x640 logical): with the note the text is
    // longer than the dialog may get — a RenderFlex overflow fails here.
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    final confirm = find.widgetWithText(FilledButton, 'Heimnetz freigeben');
    expect(tester.getRect(confirm).bottom, lessThanOrEqualTo(640));
    await tester.drag(
        find.descendant(
            of: dialog, matching: find.byType(SingleChildScrollView)),
        const Offset(0, -3000));
    await tester.pumpAndSettle();
    final body = tester.getRect(find.descendant(
        of: dialog, matching: find.textContaining(evccViaTailscale)));
    expect(body.bottom, lessThanOrEqualTo(tester.getRect(confirm).top));
  });

  testWidgets('„Heimnetz freigeben?" ohne evcc: Hinweis ohne Verweis auf evcc',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()..services = [tsWith(lanOff)];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-tailscale')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Heimnetz freigeben'));
    await tester.pumpAndSettle();

    expect(find.textContaining(sameRange), findsOneWidget);
    expect(find.textContaining('evcc dort'), findsNothing);
    expect(find.textContaining('evcc über Tailscale'), findsNothing);
  });

  testWidgets('„Heimnetz freigeben?" bei eigenem Adressbereich: ohne Hinweis',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = [
        evccOnPi,
        tsWith(const SubnetRoutes(lan: ['10.20.30.0/24'], machine: 'evcc-pi'))
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-tailscale')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Heimnetz freigeben'));
    await tester.pumpAndSettle();

    expect(find.text('Heimnetz freigeben?'), findsOneWidget);
    expect(find.textContaining('10.20.30.0/24'), findsOneWidget);
    expect(find.textContaining('demselben Adressbereich'), findsNothing);
  });

  testWidgets(
      'Fernzugriff-Helfer: auch das Angebot nennt die Einschränkung im '
      'Router-Standardbereich', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = [evccOnPi, tsWith(lanOff)]
      ..tailscaleUpUrl = null
      ..reachableHosts = {'100.64.0.5'};
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.text('Jetzt prüfen'));
    await tester.pumpAndSettle();
    expect(find.text('Auch das Heimnetz erreichen?'), findsOneWidget);
    final dialog = find.byType(AlertDialog);
    expect(
        find.descendant(
            of: dialog, matching: find.textContaining(sameRangeEvcc)),
        findsOneWidget);
    expect(
        find.descendant(
            of: dialog, matching: find.textContaining(evccViaTailscale)),
        findsOneWidget);
  });

  testWidgets(
      'Tailscale-Karte auf 360 dp: Hinweis und evcc-Adresse werden nicht '
      'abgeschnitten', (tester) async {
    tester.view.physicalSize = const Size(360, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final u = FakeEvccUpdater()..services = [evccOnPi, tsWith(lanActive)];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    final card = tester.getRect(find.ancestor(
        of: find.byKey(const ValueKey('menu-tailscale')),
        matching: find.byType(Container)).first);
    for (final line in [sameRangeEvcc, evccViaTailscale]) {
      final text = tester.widget<Text>(find.text(line));
      // Keine Zeilengrenze und keine Auslassung: die Zeile bricht um, so oft
      // sie muss — eine halbe Adresse nützt niemandem.
      expect(text.maxLines, isNull, reason: line);
      expect(text.overflow, isNull, reason: line);
      final rect = tester.getRect(find.text(line));
      expect(rect.left, greaterThanOrEqualTo(card.left), reason: line);
      expect(rect.right, lessThanOrEqualTo(card.right), reason: line);
      expect(rect.bottom, lessThanOrEqualTo(card.bottom), reason: line);
    }
    // Der Satz braucht auf dem Handy mehrere Zeilen — und bekommt sie.
    expect(tester.getSize(find.text(sameRangeEvcc)).height,
        greaterThan(tester.getSize(find.text('100.64.0.5')).height * 2));
    expect(tester.takeException(), isNull);
  });

  // ---- „Pi im WLAN suchen" nur, solange der Pi unbekannt ist ----

  testWidgets(
      'Demo-Aktionen merken sich die eingetippte IP nicht als „schon verbunden"',
      (tester) async {
    // Der Weg des Play-Prüfers: Host + Passwort eingetippt, nie verbunden,
    // dann die Demo. Eine Demo-Aktion „gelingt" gegen den eingetippten Host —
    // früher landete der danach als lanHost im Profil, und die WLAN-Suche war
    // für einen nie erreichten Pi dauerhaft weg.
    useTallScreen(tester);
    final store = _FakeStore(const AppConfig(
      profiles: [Profile(name: 'S', host: '192.168.97.1', password: 'pw')],
      activeIndex: 0,
      disclaimerAccepted: true,
    ));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
        store: store,
        updater: FakeEvccUpdater(),
        updateChecker: _noUpdateChecker,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('demoEntry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-system')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paketlisten aktualisieren'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Beenden'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1)); // drain the auto-save debounce

    expect(store.saved.active.lanHost, '');
    expect(find.widgetWithText(OutlinedButton, 'Pi im WLAN suchen'),
        findsOneWidget);
  });

  // Die Demo ist der Weg in die App für jemanden OHNE Pi — also mit leerem
  // Host-Feld. Jede Aktion muss dort gegen die Beispieldaten laufen, statt nach
  // Zugangsdaten zu fragen, die es nicht gibt.
  Widget demoPage(AppConfigStore store, {HistoryStore? history}) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('de'),
        home: UpdaterPage(
          store: store,
          updater: FakeEvccUpdater(),
          updateChecker: _noUpdateChecker,
          historyStore: history,
          // The real API must never be asked in a demo; this one would fail.
          apiClient: EvccApiClient(
              getJson: (_) async =>
                  throw const EvccApiException('kein Netz im Test')),
          evccReleaseFetcher: () async => null,
          haVersionFetcher: () async => null,
        ),
      );

  const emptyProfile = AppConfig(
    profiles: [Profile(name: 'S')],
    activeIndex: 0,
    disclaimerAccepted: true,
  );

  testWidgets(
      'Demo mit leerem Profil: Aktionen in Verwaltung, Terminal und Dateien '
      'laufen, ohne nach Host oder Passwort zu fragen', (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(demoPage(_FakeStore(emptyProfile)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('demoEntry')));
    await tester.pumpAndSettle();

    // Verwaltung: eine Karten-Aktion läuft gegen die Beispieldaten.
    await tester.tap(find.byKey(const ValueKey('menu-system')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paketlisten aktualisieren'));
    await tester.pumpAndSettle();
    expect(find.text('Bitte Host/IP eintragen.'), findsNothing);
    expect(find.text('Paketlisten aktualisiert.'), findsOneWidget);

    // evcc-Status kommt aus der Demo-API, nicht von einem (leeren) Host.
    await tester.tap(find.byKey(const ValueKey('menu-evcc')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Live-Status'));
    await tester.pumpAndSettle();
    expect(find.text('Bitte zuerst Host/IP eintragen.'), findsNothing);
    expect(find.text('Zuhause'), findsOneWidget);
    Navigator.of(tester.element(find.text('Zuhause'))).pop();
    await tester.pumpAndSettle();

    // „Oberfläche öffnen" (evcc-, Pi-hole- und Tailscale-Karte): hinter den
    // Beispielkarten steht keine Weboberfläche — auch keine Tailscale-Konsole.
    expect(find.byIcon(Icons.open_in_browser), findsNWidgets(3));
    for (final web in [
      for (var i = 0; i < 3; i++) find.byIcon(Icons.open_in_browser).at(i),
    ]) {
      await tester.tap(web);
      await tester.pumpAndSettle();
      expect(find.text('Bitte zuerst Host/IP eintragen.'), findsNothing);
      expect(find.textContaining('keine Weboberfläche'), findsOneWidget);
    }

    // Terminal.
    await tester.tap(find.byIcon(Icons.terminal_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('consoleField')), 'uptime');
    await tester.tap(find.byIcon(Icons.keyboard_return));
    await tester.pumpAndSettle();
    expect(find.text('Bitte Host/IP eintragen.'), findsNothing);
    expect(find.text('Befehl ausgeführt: uptime'), findsOneWidget);

    // Dateien: Listing und Vorschau aus den Beispieldaten.
    await tester.tap(find.byIcon(Icons.folder_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Kein Pi verbunden'), findsNothing);
    expect(find.text('evcc.yaml'), findsOneWidget);
    await tester.tap(find.text('evcc.yaml'));
    await tester.pumpAndSettle();
    expect(find.text('Datei: evcc.yaml'), findsOneWidget);
  });

  testWidgets('Demo-Konsole: ein unbekannter Befehl nennt den Demo-Modus',
      (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(demoPage(_FakeStore(emptyProfile)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('demoEntry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.terminal_outlined));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('consoleField')), 'hostname');
    await tester.tap(find.byIcon(Icons.keyboard_return));
    await tester.pumpAndSettle();

    expect(
        find.textContaining(
            'Demo-Modus: Befehle werden nicht wirklich ausgeführt.'),
        findsOneWidget);
  });

  testWidgets(
      'Demo: die Tailscale-Karte zeigt die evcc-Adresse über Tailscale; die '
      'Beispiel-Adresse lässt sich nicht als Host übernehmen', (tester) async {
    useTallScreen(tester);
    final store = _FakeStore(emptyProfile);
    await tester.pumpWidget(demoPage(store));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('demoEntry')));
    await tester.pumpAndSettle();

    expect(find.text('evcc über Tailscale: http://100.101.102.103:7070'),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('menu-tailscale')));
    await tester.pumpAndSettle();
    // Die Beispiel-Adresse führt nirgendwohin: kein Weg, sie an andere zu
    // geben.
    expect(find.text('evcc-Adresse teilen'), findsNothing);
    // Die 100.x der Beispieldaten gehört zu keinem Pi: als Host übernommen,
    // stünde sie im echten Profil (und der Tastendruck beendete die Demo).
    expect(find.textContaining('Diese IP als Host übernehmen'), findsNothing);
    // Ohne Beispiel-Backend dafür wird in der Demo kein Heimnetz angeboten.
    expect(find.text('Heimnetz freigeben'), findsNothing);
    expect(find.text('Demo-Modus – Beispieldaten, kein echter Pi.'),
        findsOneWidget);
  });

  testWidgets(
      'Demo: Beispielkarten werden nicht als „Stand von vorhin" ins Profil '
      'geschrieben; der gemerkte Stand des Profils bleibt', (tester) async {
    useTallScreen(tester);
    // Ein importiertes Profil bringt gemerkte Karten mit, ohne dass auf diesem
    // Gerät je verbunden wurde — der Demo-Einstieg ist dann noch da.
    final store = _FakeStore(AppConfig(
      profiles: [
        Profile(name: 'S', cachedServices: [grafana.toJson()])
      ],
      activeIndex: 0,
      disclaimerAccepted: true,
    ));
    await tester.pumpWidget(demoPage(store));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('menu-grafana')), findsOneWidget);

    await tester.tap(find.byKey(const Key('demoEntry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('menu-evcc')), findsOneWidget);

    // Jeder Speichervorgang während der Demo — hier: App geht in den
    // Hintergrund. Endet der Prozess danach, ist das der Stand beim Neustart.
    for (final s in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.pump();
    expect([for (final j in store.saved.active.cachedServices) j['id']],
        ['grafana']);

    // Nach der Demo steht wieder der gemerkte Stand da — keine Beispielkarten
    // und auch kein geleertes Profil.
    await tester.tap(find.text('Beenden'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('menu-evcc')), findsNothing);
    expect(find.byKey(const ValueKey('menu-grafana')), findsOneWidget);
  });

  testWidgets(
      'Demo: ein Tastendruck in den Zugangsdaten beendet die Demo samt '
      'Beispielkarten', (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(demoPage(_FakeStore(emptyProfile)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('demoEntry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('menu-evcc')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('conn-card-header')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Host / IP'), '192.168.1.50');
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1)); // drain the auto-save debounce

    expect(find.text('Demo-Modus – Beispieldaten, kein echter Pi.'),
        findsNothing);
    // Ohne Banner wären die Beispielkarten nicht mehr als solche erkennbar —
    // und ihre Aktionen gingen an das echte Backend.
    expect(find.byKey(const ValueKey('menu-evcc')), findsNothing);
    expect(find.byKey(const ValueKey('menu-system')), findsNothing);
    expect(find.textContaining('Verbindung OK'), findsNothing);
  });

  testWidgets('Demo-Aktionen landen nicht im Verlauf des echten Pi',
      (tester) async {
    useTallScreen(tester);
    final history = _RecordingHistory();
    await tester.pumpWidget(demoPage(_FakeStore(emptyProfile), history: history));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('demoEntry')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('menu-evcc')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dienst neu starten'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();

    expect(find.text('evcc-Dienst neu gestartet.'), findsOneWidget);
    expect(history.added, isEmpty);
  });

  // Gegenprobe zum Test darüber: außerhalb der Demo schreibt dieselbe Aktion
  // sehr wohl in den Verlauf.
  testWidgets('echte Aktionen landen weiter im Verlauf', (tester) async {
    useTallScreen(tester);
    final history = _RecordingHistory();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
        store: _FakeStore(_ready),
        updater: FakeEvccUpdater(),
        updateChecker: _noUpdateChecker,
        historyStore: history,
        apiClient: EvccApiClient(
            getJson: (_) async =>
                throw const EvccApiException('kein Netz im Test')),
        evccReleaseFetcher: () async => null,
        haVersionFetcher: () async => null,
      ),
    ));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-evcc')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dienst neu starten'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();

    expect(history.added, ['evcc-Dienst neu gestartet.']);
  });

  // ---- Profilwechsel: nichts geht verloren, nichts wandert mit ----

  testWidgets(
      'Profilwechsel: der gemerkte Stand des Ziel-Pi erscheint und bleibt '
      'gespeichert', (tester) async {
    useTallScreen(tester);
    final store = _FakeStore(AppConfig(
      profiles: [
        const Profile(name: 'A', host: '1.1.1.1', password: 'pw'),
        Profile(
            name: 'B',
            host: '2.2.2.2',
            password: 'pw',
            cachedServices: [grafana.toJson()]),
      ],
      activeIndex: 0,
      disclaimerAccepted: true,
    ));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
        store: store,
        updater: FakeEvccUpdater(),
        updateChecker: _noUpdateChecker,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('menu-grafana')), findsNothing);

    await tester.tap(find.byKey(const Key('profileSwitcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();

    // Shown as what it is — a remembered state …
    expect(find.byKey(const ValueKey('menu-grafana')), findsOneWidget);
    expect(find.textContaining('Stand von vorhin'), findsOneWidget);
    // … and the switch itself must not wipe it from the stored profile.
    expect([for (final j in store.saved.profiles[1].cachedServices) j['id']],
        ['grafana']);
  });

  testWidgets(
      'Erkennung ohne Ergebnis (Verbindung mittendrin weg): der gemerkte '
      'Stand bleibt auf dem Schirm und im Profil', (tester) async {
    useTallScreen(tester);
    final store = _FakeStore(AppConfig(
      profiles: [
        Profile(
            name: 'S',
            host: '192.168.178.64',
            password: 'pw',
            cachedServices: [grafana.toJson()]),
      ],
      activeIndex: 0,
      disclaimerAccepted: true,
    ));
    // What detectServices throws for a batch without its end marker.
    final u = FakeEvccUpdater()
      ..detectError = const EvccUpdateException(
          UpdateErrorKind.unknown,
          'Verbindung während der Aktion abgerissen – Ergebnis unbekannt. '
          'Details im Log.');
    await tester.pumpWidget(page(u, store: store));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('menu-grafana')), findsOneWidget);

    await detect(tester);
    expect(u.detectCalls, 1);
    expect(find.textContaining('Ergebnis unbekannt'), findsWidgets);

    // Nothing of that detection reached the cards …
    expect(find.byKey(const ValueKey('menu-grafana')), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-evcc')), findsNothing);
    expect(find.textContaining('Stand von vorhin'), findsOneWidget);
    // … nor the stored profile (any save from here on, e.g. backgrounding).
    for (final s in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.pump();
    expect([for (final j in store.saved.active.cachedServices) j['id']],
        ['grafana']);
  });

  testWidgets(
      'Docker-Karte im Restart-Loop: „inaktiv" und darunter der Grund',
      (tester) async {
    useTallScreen(tester);
    // What detection reports for a container `docker ps` lists as restarting.
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'homeassistant',
            name: 'Home Assistant',
            installed: true,
            version: 'stable',
            active: false,
            detail: 'Docker · homeassistant',
            health: '⚠ Container startet neu',
            healthWarning: true),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    expect(find.text('inaktiv'), findsOneWidget);
    expect(find.text('⚠ Container startet neu'), findsOneWidget);
    expect(find.text('stable  ·  Docker · homeassistant'), findsOneWidget);
  });

  testWidgets(
      'Profilwechsel: ein Fernzugriff-Ablauf von Pi A steht nicht bei Pi B',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'tailscale',
            name: 'Tailscale',
            installed: true,
            active: true,
            version: '100.64.0.5'),
      ]
      ..tailscaleUpUrl = null
      ..reachableHosts = {}; // dieses Handy erreicht das Tailnet nicht
    await tester.pumpWidget(page(u,
        config: const AppConfig(
          profiles: [
            Profile(name: 'A', host: '1.1.1.1', password: 'pw'),
            Profile(name: 'B', host: '2.2.2.2', password: 'pw'),
          ],
          activeIndex: 0,
          disclaimerAccepted: true,
        )));
    await tester.pumpAndSettle();
    await detect(tester);
    await tester.tap(find.text('Jetzt prüfen'));
    await tester.pumpAndSettle();
    expect(find.textContaining('erreicht ihn noch nicht'), findsOneWidget);

    await tester.tap(find.byKey(const Key('profileSwitcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    await detect(tester);

    // Auf Pi B hat dieser Ablauf nie begonnen.
    expect(find.textContaining('erreicht ihn noch nicht'), findsNothing);
  });

  testWidgets(
      'bekannter Pi: keine WLAN-Suche und kein Einsteiger-Link unter dem '
      'Verbinden-Knopf', (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(page(FakeEvccUpdater(),
        config: const AppConfig(
          profiles: [
            Profile(
                name: 'S',
                host: '192.168.178.64',
                password: 'pw',
                lanHost: '192.168.178.64')
          ],
          activeIndex: 0,
          disclaimerAccepted: true,
        )));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(OutlinedButton, 'Pi im WLAN suchen'),
        findsNothing);
    expect(find.text('Noch keinen Pi? So richtest du einen ein'), findsNothing);
  });

  testWidgets(
      'bekannter Pi, Verbindung gescheitert: die WLAN-Suche kommt zurück '
      '(die Adresse kann sich geändert haben)', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..detectError = const EvccUpdateException(
          UpdateErrorKind.connection, 'Keine Verbindung');
    await tester.pumpWidget(page(u,
        config: const AppConfig(
          profiles: [
            Profile(
                name: 'S',
                host: '192.168.178.64',
                password: 'pw',
                lanHost: '192.168.178.64')
          ],
          activeIndex: 0,
          disclaimerAccepted: true,
        )));
    await tester.pumpAndSettle();
    await detect(tester);
    expect(find.widgetWithText(OutlinedButton, 'Pi im WLAN suchen'),
        findsOneWidget);
    expect(find.text('Noch keinen Pi? So richtest du einen ein'), findsNothing);
  });

  testWidgets('Verbinden fällt auf die Tailnet-IP zurück, wenn die Heim-IP tot ist',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()..reachableHosts = {'100.64.0.5'};
    await tester.pumpWidget(page(u,
        config: const AppConfig(
          profiles: [
            Profile(
                name: 'S',
                host: '192.168.178.125',
                password: 'pw',
                lanHost: '192.168.178.125',
                tailscaleIp: '100.64.0.5')
          ],
          activeIndex: 0,
          disclaimerAccepted: true,
        )));
    await tester.pumpAndSettle();
    await detect(tester);

    // Heim zuerst (schnell, ohne VPN), dann das Tailnet …
    expect(u.probedHosts, ['192.168.178.125', '100.64.0.5']);
    // … und die eigentliche Erkennung läuft über die Adresse, die geantwortet hat.
    expect(u.detectHosts.last, '100.64.0.5');
  });

  testWidgets('nur eine bekannte Adresse: gar kein Sondieren, keine Wartezeit',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    expect(u.probedHosts, isEmpty);
  });

  // ---- Vorprobe (Heim-/Tailnet-Adresse): Host-Key, Abbruch, eingetippter Host ----

  // Host-Feld = Tailnet-IP, gemerkt sind Heim- UND Tailnet-Adresse → die
  // Vorprobe läuft, und zwar zuerst gegen die Heim-Adresse.
  const twoAddresses = AppConfig(
    profiles: [
      Profile(
          name: 'S',
          host: '100.64.0.5',
          password: 'pw',
          lanHost: '192.168.178.125',
          tailscaleIp: '100.64.0.5')
    ],
    activeIndex: 0,
    disclaimerAccepted: true,
  );

  testWidgets(
      'geänderter Host-Key in der Vorprobe: Host-Key-Leiste statt blockierter '
      'App, und „vertrauen" vergisst den Eintrag der sondierten Adresse',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..probeError = const EvccUpdateException(
          UpdateErrorKind.hostKeyChanged, 'Host-Key geändert!');
    await tester.pumpWidget(page(u, config: twoAddresses));
    await tester.pumpAndSettle();
    await detect(tester);

    // Same error path as a changed key on the connect itself …
    expect(find.textContaining('neuen Key vertrauen'), findsOneWidget);
    expect(u.detectCalls, 0,
        reason: 'kein Connect an einem geänderten Host-Key vorbei');
    // … and the UI is released: no running bar, the profile switcher reacts.
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
        tester
            .widget<InkWell>(find.byKey(const Key('profileSwitcher')))
            .onTap,
        isNotNull);

    // The key that changed belongs to the PROBED address (home first), not to
    // the one in the host field.
    u
      ..probeError = null
      ..reachableHosts = {'192.168.178.125'};
    await tester.tap(find.byIcon(Icons.verified_user_outlined));
    await tester.pumpAndSettle();
    expect(u.forgotConfig!.host, '192.168.178.125');
    expect(find.text('Verbunden'), findsOneWidget);
  });

  testWidgets(
      'Fernzugriff prüfen: geänderter Host-Key der Tailnet-Adresse → '
      '„vertrauen" vergisst DEREN Eintrag, nicht den des Host-Felds',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'tailscale',
            name: 'Tailscale',
            installed: true,
            active: true,
            version: '100.64.0.5'),
      ]
      ..tailscaleUpUrl = null;
    await tester.pumpWidget(page(u)); // Host-Feld: 192.168.178.64
    await tester.pumpAndSettle();
    await detect(tester);

    u.probeError = const EvccUpdateException(
        UpdateErrorKind.hostKeyChanged, 'Host-Key geändert!');
    await tester.tap(find.text('Jetzt prüfen'));
    await tester.pumpAndSettle();
    expect(find.textContaining('neuen Key vertrauen'), findsOneWidget);

    u
      ..probeError = null
      ..reachableHosts = {'100.64.0.5'};
    await tester.tap(find.byIcon(Icons.verified_user_outlined));
    await tester.pumpAndSettle();
    expect(u.forgotConfig!.host, '100.64.0.5');
  });

  testWidgets(
      '„Abbrechen" während der Vorprobe bricht ab — danach wird nicht doch '
      'noch verbunden', (tester) async {
    useTallScreen(tester);
    final gate = Completer<void>();
    // reachableHosts leer: wie die echte probeConnection meldet der Fake eine
    // abgebrochene Probe als „nicht erreichbar".
    final u = FakeEvccUpdater()..probeGate = gate;
    await tester.pumpWidget(page(u, config: twoAddresses));
    await tester.pumpAndSettle();

    await tester
        .tap(find.widgetWithText(OutlinedButton, 'Verbindung herstellen'));
    await tester.pump(); // running bar is up, the first probe hangs
    await tester.tap(find.widgetWithText(OutlinedButton, 'Abbrechen'));
    await tester.pump();
    expect(u.cancelCalls, 1);

    gate.complete();
    await tester.pumpAndSettle();

    expect(u.probedHosts, ['192.168.178.125'],
        reason: 'nach dem Abbruch wird auch die zweite Adresse nicht sondiert');
    expect(u.detectCalls, 0, reason: 'abgebrochen heißt: kein Connect');
    expect(find.text('Abgebrochen.'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets(
      'eingetippter Host, der keine gemerkte Adresse ist: kein Sondieren, '
      'verbunden wird genau dorthin', (tester) async {
    useTallScreen(tester);
    // Beide gemerkten Adressen würden antworten — trotzdem gilt die Eingabe.
    final u = FakeEvccUpdater()
      ..reachableHosts = {'192.168.178.125', '100.64.0.5'};
    await tester.pumpWidget(page(u,
        config: const AppConfig(
          profiles: [
            Profile(
                name: 'S',
                host: '192.168.178.200',
                password: 'pw',
                lanHost: '192.168.178.125',
                tailscaleIp: '100.64.0.5')
          ],
          activeIndex: 0,
          disclaimerAccepted: true,
        )));
    await tester.pumpAndSettle();
    await detect(tester);

    expect(u.probedHosts, isEmpty);
    expect(u.detectHosts, ['192.168.178.200']);
    expect(find.byKey(const Key('sessionConnected')), findsOneWidget);
  });

  testWidgets(
      'System-Karte → „Paketlisten aktualisieren" frischt den Index auf und erkennt neu',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'system',
            name: 'System (Pi)',
            installed: true,
            active: true,
            updateKnown: false,
            detail: 'Paketlisten 10 Tage alt — Stand unbekannt')
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);
    final detectsBefore = u.detectCalls;

    await tester.tap(find.byKey(const ValueKey('menu-system')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paketlisten aktualisieren'));
    await tester.pumpAndSettle();

    expect(u.aptRefreshCalls, 1);
    // Re-read afterwards — otherwise the stale line would sit there unchanged
    // and the refresh would look like it did nothing.
    expect(u.detectCalls, greaterThan(detectsBefore));
  });

  testWidgets('System-Karte → „Paketzustand reparieren" führt dpkg --configure aus',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'system', name: 'System (Pi)', installed: true, active: true)
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-system')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paketzustand reparieren'));
    await tester.pumpAndSettle();

    expect(u.repairPackageCalls, 1);
  });

  testWidgets(
      'zwei Bestätigungsdialoge übereinander: der zuerst bestätigte startet '
      'die Aktion, der zweite startet nichts neben ihr', (tester) async {
    useTallScreen(tester);
    final gate = Completer<void>();
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'system',
            name: 'System (Pi)',
            installed: true,
            active: true,
            updateAvailable: true,
            updateKnown: true),
      ]
      ..jobGate = gate;
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    // Two handlers past the busy check (nothing runs yet), each waiting in
    // its confirmation. Called directly: a second tap in the same frame never
    // arrives — the Navigator absorbs pointers once a route was pushed — so
    // this pins _prepare()'s own check, not a path a finger can take.
    final update = find.widgetWithText(OutlinedButton, 'Updates installieren');
    final onPressed = tester.widget<OutlinedButton>(update).onPressed!;
    onPressed();
    onPressed();
    await tester.pumpAndSettle();
    expect(find.text('System aktualisieren?'), findsNWidgets(2));

    // The upper one: the upgrade starts and stays busy on the gate.
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500)); // dialog is gone
    expect(u.systemUpgradeCalls, 1);
    expect(find.text('System aktualisieren?'), findsOneWidget);
    expect(find.text('System-Upgrade läuft …'), findsOneWidget);

    // The one underneath, confirmed while that upgrade is still running.
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('System aktualisieren?'), findsNothing);
    expect(u.systemUpgradeCalls, 1,
        reason: 'kein zweiter Lauf neben dem laufenden');
    // The running action is still the one on screen.
    expect(find.text('System-Upgrade läuft …'), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(u.systemUpgradeCalls, 1);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('System ⋮ → Umzugshelfer zieht evcc + Pi-hole aufs Ziel um',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'system', name: 'System (Pi)', installed: true, active: true),
        ServiceStatus(
            id: 'evcc',
            name: 'evcc',
            installed: true,
            version: '0.211.0',
            active: true,
            detail: 'apt · Dienst aktiv'),
        ServiceStatus(
            id: 'pihole',
            name: 'Pi-hole',
            installed: true,
            version: 'v6.0.4',
            active: true),
      ]
      ..downloadBytes = Uint8List.fromList([1, 2, 3]);
    await tester.pumpWidget(page(u,
        config: const AppConfig(
          profiles: [
            Profile(name: 'S', host: '192.168.178.64', password: 'pw'),
            Profile(name: 'Zweiter', host: '192.168.178.99', password: 'pw'),
          ],
          activeIndex: 0,
          disclaimerAccepted: true,
        )));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-system')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Auf anderen Pi umziehen'));
    await tester.pumpAndSettle();

    // Target picker lists the OTHER profile only.
    expect(find.text('Zweiter'), findsOneWidget);
    await tester.tap(find.text('Zweiter'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();

    // Fresh backups from the source, both fetched to the phone …
    expect(u.backupCalls, 1);
    expect(u.piholeBackupCalls, 1);
    expect(u.downloadedPaths, hasLength(2));
    // … uploaded to the target's expected locations and restored there.
    expect(u.uploadedTo, contains('/var/backups/evcc/x.tar.gz'));
    expect(u.uploadedTo, contains('/var/backups/pi-tool/pihole-backup-x.zip'));
    expect(u.restoredPath, '/var/backups/evcc/x.tar.gz');
    expect(u.restoredPihole,
        contains('/var/backups/pi-tool/pihole-backup-x.zip'));
    // The log marks where the work on the target begins.
    await goTerminal(tester);
    expect(find.textContaining('— Ziel-Pi „Zweiter“ (192.168.178.99) —'),
        findsOneWidget);
  });

  // ---- Umzugshelfer: Pi-hole on the target and its web password ----

  const migrationProfiles = AppConfig(
    profiles: [
      Profile(name: 'S', host: '192.168.178.64', password: 'pw'),
      Profile(name: 'Zweiter', host: '192.168.178.99', password: 'pw'),
    ],
    activeIndex: 0,
    disclaimerAccepted: true,
  );
  const migrationSystem = ServiceStatus(
      id: 'system', name: 'System (Pi)', installed: true, active: true);
  const migrationEvcc = ServiceStatus(
      id: 'evcc',
      name: 'evcc',
      installed: true,
      version: '0.211.0',
      active: true,
      detail: 'apt · Dienst aktiv');
  const migrationPihole = ServiceStatus(
      id: 'pihole',
      name: 'Pi-hole',
      installed: true,
      version: 'v6.0.4',
      active: true);

  // Connects to the source, then runs the helper against „Zweiter".
  Future<void> migrate(WidgetTester tester) async {
    await detect(tester);
    await tester.tap(find.byKey(const ValueKey('menu-system')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Auf anderen Pi umziehen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zweiter'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'Umzugshelfer, Pi-hole v5 auf der Quelle: Pi-hole wird auf dem Ziel gar '
      'nicht erst installiert, die Meldung nennt den Grund – evcc zieht um',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [migrationSystem, migrationEvcc, migrationPihole]
      // The target has evcc already, but no Pi-hole.
      ..servicesByHost = const {
        '192.168.178.99': [migrationSystem, migrationEvcc]
      }
      ..piholeBackupPath = '/var/backups/pi-tool/pihole-backup-x.tar.gz'
      ..piholeWebPassword = 'Abc234xyzKLMN567'
      ..downloadBytes = Uint8List.fromList([1, 2, 3]);
    await tester.pumpWidget(page(u, config: migrationProfiles));
    await tester.pumpAndSettle();
    await migrate(tester);

    // evcc went across as before.
    expect(u.restoredPath, '/var/backups/evcc/x.tar.gz');
    // Pi-hole: nothing was written to the target — no install (which would
    // set a password nobody gets to see), no upload, no restore.
    expect(u.piholeInstallCalls, 0);
    expect(u.uploadedTo, ['/var/backups/evcc/x.tar.gz']);
    expect(u.restoredPihole, isEmpty);
    expect(find.text('Pi-hole-Passwort'), findsNothing);
    // The banner says what did not happen and why — and no success claim.
    expect(find.textContaining('Pi-hole wurde nicht umgezogen'), findsOneWidget);
    expect(find.textContaining('Pi-hole v5'), findsOneWidget);
    expect(find.textContaining('Umzug abgeschlossen'), findsNothing);
  });

  testWidgets(
      'Umzugshelfer: Pi-hole auf dem Ziel neu installiert, das Einspielen '
      'scheitert → das dabei gesetzte Web-Passwort wird gezeigt',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [migrationSystem, migrationPihole]
      ..servicesByHost = const {
        '192.168.178.99': [migrationSystem]
      }
      ..piholeWebPassword = 'Abc234xyzKLMN567'
      ..piholeRestoreError = const EvccUpdateException(
          UpdateErrorKind.unknown, 'Pi-hole-Wiederherstellung fehlgeschlagen')
      ..downloadBytes = Uint8List.fromList([1, 2, 3]);
    await tester.pumpWidget(page(u, config: migrationProfiles));
    await tester.pumpAndSettle();
    await migrate(tester);

    expect(u.piholeInstallHosts, ['192.168.178.99']);
    expect(u.restoredPihole, isEmpty);
    // The install's password is the only way into the target's web
    // interface now — shown once, and it says which Pi it belongs to.
    expect(find.text('Pi-hole-Passwort'), findsOneWidget);
    expect(find.text('Abc234xyzKLMN567'), findsOneWidget);
    expect(find.textContaining('„Zweiter"'), findsOneWidget);
    await tester.tap(find.text('Fertig'));
    await tester.pumpAndSettle();
    // The failure itself stays on screen underneath.
    expect(find.text('Pi-hole-Wiederherstellung fehlgeschlagen'),
        findsOneWidget);
  });

  testWidgets(
      'Umzugshelfer: Pi-hole auf dem Ziel neu installiert und Backup '
      'eingespielt → kein Passwort-Dialog (der Import ersetzt das Passwort)',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [migrationSystem, migrationPihole]
      ..servicesByHost = const {
        '192.168.178.99': [migrationSystem]
      }
      ..piholeWebPassword = 'Abc234xyzKLMN567'
      ..downloadBytes = Uint8List.fromList([1, 2, 3]);
    await tester.pumpWidget(page(u, config: migrationProfiles));
    await tester.pumpAndSettle();
    await migrate(tester);

    expect(u.piholeInstallHosts, ['192.168.178.99']);
    expect(u.restoredPihole, ['/var/backups/pi-tool/pihole-backup-x.zip']);
    expect(find.textContaining('Umzug abgeschlossen'), findsOneWidget);
    expect(find.text('Pi-hole-Passwort'), findsNothing);
    expect(find.text('Abc234xyzKLMN567'), findsNothing);
  });

  testWidgets('Grafana ⋮ → „Mit evcc verdrahten" verdrahtet den Stack',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'grafana',
            name: 'Grafana',
            installed: true,
            version: '11.1.0',
            active: true,
            detail: 'apt · grafana · Dienst aktiv'),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-grafana')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mit evcc verdrahten (Dashboard)'));
    await tester.pumpAndSettle();
    // The confirm names the moving parts before anything runs.
    expect(find.textContaining('evcc.yaml'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();

    expect(u.stackWirings, 1);
  });

  testWidgets('Sicherheits-Check → „Beheben" wendet den Fix an und prüft neu',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'system', name: 'System (Pi)', installed: true, active: true)
      ]
      ..securityFindings = const [
        (
          title: 'SSH-Root-Login',
          level: SecurityLevel.warn,
          detail: 'Root darf sich per SSH anmelden.'
        ),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-system')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sicherheits-Check'));
    await tester.pumpAndSettle();

    // The warn finding carries a fix button; tap → confirm → fix runs.
    await tester.tap(find.text('Beheben'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();

    expect(u.securityFixes, [SecurityFix.rootLogin]);
    // The automatic re-check shows the finding green now.
    expect(find.text('Root-Login per SSH ist deaktiviert.'), findsOneWidget);
    expect(find.text('Beheben'), findsNothing);
  });

  testWidgets(
      'Sicherheits-Check: Pi-hole ohne Passwort → „Beheben" setzt eins und '
      'zeigt es einmalig', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'system', name: 'System (Pi)', installed: true, active: true)
      ]
      ..securityFindings = const [
        (
          title: 'Pi-hole-Weboberfläche',
          level: SecurityLevel.warn,
          detail: 'Kein Passwort gesetzt.'
        ),
      ]
      ..piholeWebPassword = 'Abc234xyzKLMN567';
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-system')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sicherheits-Check'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Beheben'));
    await tester.pumpAndSettle();
    expect(find.textContaining('keine Anmeldung'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();

    expect(u.securityFixes, [SecurityFix.piholePassword]);
    expect(find.text('Pi-hole-Passwort'), findsOneWidget);
    expect(find.text('Abc234xyzKLMN567'), findsOneWidget);
    // Ein versehentlicher Tipp daneben schließt ihn nicht.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('Pi-hole-Passwort'), findsOneWidget);
    await tester.tap(find.text('Fertig'));
    await tester.pumpAndSettle();
    // Danach prüft die App neu: der Befund ist grün.
    expect(find.text('Die Weboberfläche ist passwortgeschützt.'), findsOneWidget);
    // (Dass das Passwort nie ins Log gelangt, prüft evcc_updater_test.)
  });

  testWidgets('Pi-hole installieren: das gesetzte Passwort erscheint danach',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = [
        ServiceStatus.absent('pihole', 'Pi-hole'),
        const ServiceStatus(
            id: 'system', name: 'System (Pi)', installed: true, active: true),
      ]
      ..piholeWebPassword = 'Abc234xyzKLMN567';
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.textContaining('Dienst hinzufügen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pi-hole'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();

    expect(u.piholeInstallCalls, 1);
    expect(find.text('Abc234xyzKLMN567'), findsOneWidget);
  });

  testWidgets('Pi-hole installieren: vorhandenes Passwort → kein Dialog',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = [
        ServiceStatus.absent('pihole', 'Pi-hole'),
        const ServiceStatus(
            id: 'system', name: 'System (Pi)', installed: true, active: true),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.textContaining('Dienst hinzufügen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pi-hole'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();

    expect(u.piholeInstallCalls, 1);
    expect(find.text('Pi-hole-Passwort'), findsNothing);
  });

  testWidgets('System-Karte → Sicherheits-Check zeigt die Ampel-Befunde',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'system', name: 'System (Pi)', installed: true, active: true)
      ]
      ..securityFindings = const [
        (
          title: 'SSH-Root-Login',
          level: SecurityLevel.warn,
          detail: 'Root darf sich per SSH anmelden.'
        ),
        (
          title: 'Offene Ports',
          level: SecurityLevel.info,
          detail: 'Lauschende TCP-Ports: 22'
        ),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-system')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sicherheits-Check'));
    await tester.pumpAndSettle();

    expect(find.text('SSH-Root-Login'), findsOneWidget);
    expect(find.text('Offene Ports'), findsOneWidget);
    expect(find.textContaining('1 Warnung'), findsOneWidget);
  });

  testWidgets('console sheet: eigene Schnellbefehle anlegen und löschen',
      (tester) async {
    useTallScreen(tester);
    final store = _FakeStore(const AppConfig(
      profiles: [Profile(name: 'S', host: '192.168.178.64', password: 'pw')],
      activeIndex: 0,
      disclaimerAccepted: true,
      customCommands: ['vcgencmd measure_temp'],
    ));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('de'),
      home: UpdaterPage(
          store: store,
          updater: FakeEvccUpdater(),
          updateChecker: _noUpdateChecker),
    ));
    await tester.pumpAndSettle();
    await goTerminal(tester);

    await tester.tap(find.byIcon(Icons.history).first);
    await tester.pumpAndSettle();
    // The stored custom command is offered under „Eigene Befehle".
    expect(find.text('Eigene Befehle'), findsOneWidget);
    expect(find.text('vcgencmd measure_temp'), findsOneWidget);

    // Add a new one via the + dialog → persisted (debounced save).
    await tester.tap(find.byKey(const Key('addCustomCommand')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('customCommandField')), 'ls -la /etc');
    await tester.tap(find.widgetWithText(FilledButton, 'Speichern'));
    await tester.pumpAndSettle();
    expect(find.text('ls -la /etc'), findsOneWidget); // sheet updates in place
    await tester.pump(const Duration(seconds: 1));
    expect(store.saved.customCommands, contains('ls -la /etc'));

    // Delete the stored one via its row delete icon.
    await tester
        .tap(find.byKey(const ValueKey('delCustom-vcgencmd measure_temp')));
    await tester.pumpAndSettle();
    expect(find.text('vcgencmd measure_temp'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(store.saved.customCommands, isNot(contains('vcgencmd measure_temp')));
  });

  testWidgets(
      'Dateien tab: Textdatei-Vorschau bietet Bearbeiten → atomarer Editor; '
      'Binärdatei nicht', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..dirEntries = const [(name: 'notes.txt', isDir: false)]
      ..fileBytes = Uint8List.fromList('hallo welt\n'.codeUnits);
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await goDateien(tester);

    await tester.tap(find.text('notes.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bearbeiten'));
    await tester.pumpAndSettle();
    // The atomic config editor opens, loaded via readConfigFile (sudo-capable).
    expect(find.text(u.configText), findsOneWidget);
    // Leave the editor again (no save). Tap the AppBar back button by type —
    // tester.pageBack() matches the English 'Back' tooltip, which is now
    // localized to 'Zurück' under the pinned German test locale.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    // A binary file (NUL byte) must NOT offer editing.
    u.fileBytes = Uint8List.fromList([104, 105, 0, 1, 2]);
    await tester.tap(find.text('notes.txt'));
    await tester.pumpAndSettle();
    expect(find.text('Bearbeiten'), findsNothing);
  });

  // ---- Karten-Regel: „Aktuell" nur, wo der Primär-Knopf das Update ist ----

  // updateKnown: true ohne offenes Update = frischer apt-Index. Das ist der
  // Zustand direkt nach der Installation über die App (das Installationsskript
  // führt apt-get update aus). Auf Pi Connect und Tailscale hängt der
  // Primär-Knopf am Anmelde-/Verbindungszustand — ein deaktiviertes „Aktuell"
  // an seiner Stelle macht „Anmelden" bzw. „Trennen" unerreichbar.
  testWidgets(
      'Pi Connect, aktuell und nicht angemeldet: „Anmelden" bleibt der '
      'Primär-Knopf und startet die Anmeldung', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'piconnect',
            name: 'Raspberry Pi Connect',
            installed: true,
            active: false, // nicht angemeldet
            updateAvailable: false,
            updateKnown: true,
            aptPackage: 'rpi-connect-lite'),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    expect(find.widgetWithText(OutlinedButton, 'Aktuell'), findsNothing);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Anmelden'));
    await tester.pumpAndSettle();
    expect(u.piConnectSigninCalls, 1);
  });

  testWidgets(
      'Pi Connect, aktuell und angemeldet: „Web öffnen" bleibt bedienbar; '
      'Karten mit Update als Primär-Aktion zeigen weiter „Aktuell"',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        grafana, // updateKnown: true, kein Update offen
        ServiceStatus(
            id: 'piconnect',
            name: 'Raspberry Pi Connect',
            installed: true,
            active: true, // angemeldet
            updateAvailable: false,
            updateKnown: true,
            aptPackage: 'rpi-connect-lite'),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    final openWeb = find.widgetWithText(OutlinedButton, 'Web öffnen');
    expect(openWeb, findsOneWidget);
    expect(tester.widget<OutlinedButton>(openWeb).onPressed, isNotNull);
    // Grafana: der Primär-Knopf IST das Update → dort bleibt „Aktuell".
    expect(find.widgetWithText(OutlinedButton, 'Aktuell'), findsOneWidget);
  });

  testWidgets(
      'Tailscale, aktuell und getrennt: „Verbinden" bleibt der Primär-Knopf',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'tailscale',
            name: 'Tailscale',
            installed: true,
            active: false,
            updateAvailable: false,
            updateKnown: true,
            detail: 'Getrennt',
            aptPackage: 'tailscale'),
      ]
      ..tailscaleUpUrl = null;
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    expect(find.widgetWithText(OutlinedButton, 'Aktuell'), findsNothing);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Verbinden'));
    await tester.pumpAndSettle();
    expect(u.tailscaleUpCalls, 1);
  });

  testWidgets(
      'Tailscale, aktuell und verbunden: „Trennen" bleibt der Primär-Knopf',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [
        ServiceStatus(
            id: 'tailscale',
            name: 'Tailscale',
            installed: true,
            active: true,
            version: '100.64.0.5',
            updateAvailable: false,
            updateKnown: true,
            aptPackage: 'tailscale'),
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    expect(find.widgetWithText(OutlinedButton, 'Aktuell'), findsNothing);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Trennen'));
    await tester.pumpAndSettle();
    expect(u.tailscaleLoggedOut, isFalse); // tailscale down, kein Logout
    expect(find.text('Tailscale getrennt.'), findsOneWidget);
  });

  // ---- Fernzugriff / Tailscale: Erfolg kommt aus dem Ablauf selbst ----

  testWidgets(
      'Fernzugriff einrichten läuft auch nach einer zuvor gescheiterten Aktion '
      'bis in die Prüfung', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..backupError = const EvccUpdateException(
          UpdateErrorKind.unknown, 'Backup fehlgeschlagen')
      ..tailscaleUpUrl = null; // schon angemeldet → kein Browser nötig
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    // Irgendeine Aktion scheitert — kein Verbindungsfehler, die Sitzung bleibt.
    await tester.tap(find.widgetWithText(OutlinedButton, 'Aktualisieren'));
    await tester.pumpAndSettle();
    expect(find.text('Backup fehlgeschlagen'), findsOneWidget);

    await tester.tap(find.text('Fernzugriff einrichten'));
    await tester.pumpAndSettle();

    expect(u.tailscaleInstallCalls, 1);
    expect(u.tailscaleUpCalls, 1);
    // Der Ablauf endet nicht stumm am alten Fehler: er geht in die Prüfung
    // (noch keine Tailnet-IP → „im Browser bestätigen" mit „Jetzt prüfen").
    expect(find.text('Jetzt prüfen'), findsOneWidget);
  });

  const tailscaleDown = ServiceStatus(
      id: 'tailscale',
      name: 'Tailscale',
      installed: true,
      active: false,
      detail: 'Getrennt');

  testWidgets(
      'Tailscale „Verbinden" scheitert: keine Meldung „Tailscale verbunden." '
      'und kein Neu-Erkennen hinter dem Fehler', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [tailscaleDown]
      ..tailscaleUpError =
          const EvccUpdateException(UpdateErrorKind.sudo, 'sudo abgelehnt');
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);
    final detectsBefore = u.detectCalls;

    await tester.tap(find.widgetWithText(OutlinedButton, 'Verbinden'));
    await tester.pumpAndSettle();

    expect(find.text('sudo abgelehnt'), findsOneWidget);
    expect(find.text('Tailscale verbunden.'), findsNothing);
    expect(u.detectCalls, detectsBefore);
  });

  testWidgets(
      'Tailscale „Verbinden" gelingt: das Neu-Erkennen läuft noch als Teil '
      'der Aktion, erst danach kommt die Meldung', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = const [tailscaleDown]
      ..tailscaleUpUrl = null; // schon angemeldet
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);
    final detectsBefore = u.detectCalls;

    final gate = Completer<void>();
    u.detectGate = gate; // das Neu-Erkennen hängt
    await tester.tap(find.widgetWithText(OutlinedButton, 'Verbinden'));
    await tester.pump();
    await tester.pump();

    // Solange es läuft, ist die App belegt: Laufleiste da, Profilwechsel
    // gesperrt — sonst landeten die Karten dieses Pi im nächsten Profil.
    expect(u.detectCalls, detectsBefore + 1);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
        tester
            .widget<InkWell>(find.byKey(const Key('profileSwitcher')))
            .onTap,
        isNull);
    expect(find.text('Tailscale verbunden.'), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Tailscale verbunden.'), findsOneWidget);
  });

  // ---- Profil-Import ----

  testWidgets(
      'Profil-Import: was nur in den Feldern des aktiven Profils steht, geht '
      'nicht verloren', (tester) async {
    useTallScreen(tester);
    final envelope = (await tester.runAsync(() => encryptProfileExport(
        encodeAppConfig(const AppConfig(
          profiles: [Profile(name: 'Neu', host: '10.0.0.9', password: 'x')],
          activeIndex: 0,
        )),
        'geheim1',
        iterations: 10)))!;
    final store = _FakeStore(_ready);
    final picker = _FakeFilePicker((
      name: 'pi-tool-profile.pitool',
      bytes: Uint8List.fromList(utf8.encode(envelope)),
    ));
    await tester.pumpWidget(
        page(FakeEvccUpdater(), store: store, filePicker: picker));
    await tester.pumpAndSettle();

    // Eine Eingabe, die bisher nur in den Feldern steht.
    await tester.tap(find.byKey(const ValueKey('conn-card-header')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Host / IP'), '192.168.178.99');
    await tester.pump();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Einstellungen'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Profile importieren'));
    await tester.tap(find.text('Profile importieren'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Passphrase'), 'geheim1');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1)); // drain the auto-save debounce

    expect(store.saved.profiles.map((p) => p.name), ['S', 'Neu']);
    expect(store.saved.activeIndex, 1); // das erste importierte Profil
    expect(store.saved.profiles.first.host, '192.168.178.99');
  });

  testWidgets(
      'Profil-Import: das ntfy-Thema kommt mit — das eigene des Profils, sonst '
      'das app-weite der exportierenden App', (tester) async {
    useTallScreen(tester);
    final envelope = (await tester.runAsync(() => encryptProfileExport(
        encodeAppConfig(const AppConfig(
          profiles: [
            Profile(
                name: 'Garage',
                host: '10.0.0.9',
                password: 'x',
                alertsNtfyServer: 'https://ntfy.example.org',
                alertsNtfyTopic: 'pi-tool-aaaa2222bbbb33'),
            Profile(name: 'Keller', host: '10.0.0.10', password: 'x'),
          ],
          activeIndex: 0,
          alertsNtfyTopic: 'pi-tool-eeee6666ffff77',
        )),
        'geheim1',
        iterations: 10)))!;
    final store = _FakeStore(_ready);
    final u = FakeEvccUpdater()
      ..alertsStatus =
          (enabled: true, lastCheck: '12:00', wrapperOutdated: false);
    await tester.pumpWidget(page(u,
        store: store,
        filePicker: _FakeFilePicker((
          name: 'pi-tool-profile.pitool',
          bytes: Uint8List.fromList(utf8.encode(envelope)),
        ))));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Einstellungen'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Profile importieren'));
    await tester.tap(find.text('Profile importieren'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Passphrase'), 'geheim1');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Weiter'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1)); // drain the auto-save debounce

    final saved = store.saved.profiles;
    expect(saved.map((p) => p.name), ['S', 'Garage', 'Keller']);
    expect(saved[0].alertsNtfyTopic, ''); // the profile that was here
    expect(saved[1].alertsNtfyTopic, 'pi-tool-aaaa2222bbbb33');
    expect(saved[1].alertsNtfyServer, 'https://ntfy.example.org');
    expect(saved[2].alertsNtfyTopic, 'pi-tool-eeee6666ffff77');

    // The imported Pi (now active) shows its topic in the sheet.
    await goAutomatik(tester);
    await tester.tap(find.text('Health-Alerts'));
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'pi-tool-aaaa2222bbbb33');
  });

  // ---- Datei-Auswahl: Fehlercode der nativen Seite ----

  testWidgets(
      'Upload: lehnt die native Auswahl eine zu große Datei ab, nennt die '
      'Meldung das Limit', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()..dirEntries = const [(name: 'x', isDir: false)];
    await tester.pumpWidget(page(u,
        filePicker: _ThrowingPicker(PlatformException(
            code: 'too_large', message: 'Datei zu groß (max 8 MB).'))));
    await tester.pumpAndSettle();
    await goDateien(tester);

    await tester.tap(find.byIcon(Icons.upload_file));
    await tester.pumpAndSettle();

    expect(u.uploadedTo, isEmpty);
    expect(find.text('Datei zu groß (max 8 MB).'), findsOneWidget);
    expect(find.text('Dateiauswahl fehlgeschlagen.'), findsNothing);
  });

  testWidgets('Upload: jeder andere Fehler der Auswahl bleibt „fehlgeschlagen"',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()..dirEntries = const [(name: 'x', isDir: false)];
    await tester.pumpWidget(page(u,
        filePicker: _ThrowingPicker(
            PlatformException(code: 'read_failed', message: 'I/O'))));
    await tester.pumpAndSettle();
    await goDateien(tester);

    await tester.tap(find.byIcon(Icons.upload_file));
    await tester.pumpAndSettle();

    expect(find.text('Dateiauswahl fehlgeschlagen.'), findsOneWidget);
  });

  testWidgets(
      'Profil-Import: eine zu große Datei wird ebenfalls mit dem Limit gemeldet',
      (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(page(FakeEvccUpdater(),
        filePicker: _ThrowingPicker(PlatformException(
            code: 'too_large', message: 'Datei zu groß (max 8 MB).'))));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Einstellungen'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Profile importieren'));
    await tester.tap(find.text('Profile importieren'));
    await tester.pumpAndSettle();

    expect(find.text('Datei zu groß (max 8 MB).'), findsOneWidget);
    expect(find.text('Dateiauswahl fehlgeschlagen.'), findsNothing);
  });

  // ---- Screenshot-Sperre folgt der Zugangsdaten-Karte ----

  // FLAG_SECURE gehört an, solange Zugangsdaten auf dem Bildschirm stehen
  // können (aufgeklappte Karte, Sperrbildschirm), und sonst aus. Auch dann,
  // wenn die App die Karte von sich aus auf- oder zuklappt.
  testWidgets(
      'Screenshot-Sperre: „Diese IP als Host übernehmen" klappt die Karte auf '
      '→ gesperrt', (tester) async {
    useTallScreen(tester);
    final secure = _RecordingSecureScreen();
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
    await tester.pumpWidget(page(u, secureScreen: secure));
    await tester.pumpAndSettle();
    await detect(tester);
    expect(secure.calls.last, isFalse); // eingeklappt: Karten dürfen aufs Bild

    await tester.tap(find.byKey(const ValueKey('menu-tailscale')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Diese IP als Host übernehmen'));
    await tester.pumpAndSettle();

    expect(find.text('Host / IP'), findsOneWidget); // aufgeklappt
    expect(secure.calls.last, isTrue);
  });

  testWidgets(
      'Screenshot-Sperre: das Verbinden klappt die Karte zu → wieder erlaubt',
      (tester) async {
    useTallScreen(tester);
    final secure = _RecordingSecureScreen();
    await tester.pumpWidget(page(FakeEvccUpdater(), secureScreen: secure));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('conn-card-header')));
    await tester.pumpAndSettle();
    expect(secure.calls.last, isTrue); // von Hand aufgeklappt

    await detect(tester);

    expect(find.text('Host / IP'), findsNothing); // zugeklappt
    expect(secure.calls.last, isFalse);
  });

  testWidgets(
      'Screenshot-Sperre: Profilwechsel auf ein leeres Profil klappt auf '
      '→ gesperrt', (tester) async {
    useTallScreen(tester);
    final secure = _RecordingSecureScreen();
    await tester.pumpWidget(page(FakeEvccUpdater(),
        secureScreen: secure,
        config: const AppConfig(
          profiles: [
            Profile(name: 'A', host: '1.1.1.1', password: 'pw'),
            Profile(name: 'B'), // noch nichts eingetragen
          ],
          activeIndex: 0,
          disclaimerAccepted: true,
        )));
    await tester.pumpAndSettle();
    expect(secure.calls.last, isFalse);

    await tester.tap(find.byKey(const Key('profileSwitcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();

    expect(find.text('Host / IP'), findsOneWidget);
    expect(secure.calls.last, isTrue);
  });

  testWidgets(
      'Screenshot-Sperre: Demo-Start gibt frei, Demo-Ende sperrt wieder',
      (tester) async {
    useTallScreen(tester);
    final secure = _RecordingSecureScreen();
    await tester.pumpWidget(page(FakeEvccUpdater(),
        secureScreen: secure,
        config: const AppConfig(
          profiles: [Profile(name: 'S')], // leer → Karte aufgeklappt
          activeIndex: 0,
          disclaimerAccepted: true,
        )));
    await tester.pumpAndSettle();
    expect(secure.calls.last, isTrue);

    await tester.tap(find.byKey(const Key('demoEntry')));
    await tester.pumpAndSettle();
    expect(secure.calls.last, isFalse); // Beispielkarten sind vorzeigbar

    await tester.tap(find.text('Beenden'));
    await tester.pumpAndSettle();
    expect(secure.calls.last, isTrue);
  });

  testWidgets(
      'Screenshot-Sperre: gesperrt → an; nach dem Entsperren folgt sie wieder '
      'der (eingeklappten) Karte', (tester) async {
    useTallScreen(tester);
    final secure = _RecordingSecureScreen();
    await tester.pumpWidget(page(FakeEvccUpdater(),
        secureScreen: secure,
        authenticator: _AllowAuth(),
        config: const AppConfig(
          profiles: [Profile(name: 'S', host: '1.1.1.1', password: 'pw')],
          activeIndex: 0,
          disclaimerAccepted: true,
          lockEnabled: true,
        )));
    await tester.pumpAndSettle(); // lädt + entsperrt von allein
    expect(find.text('Entsperren'), findsNothing);
    expect(secure.calls.last, isFalse);

    // In den Hintergrund: die App sperrt.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(secure.calls.last, isTrue);

    // Zurück: entsperrt, die Karte ist weiter eingeklappt.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Entsperren'), findsNothing);
    expect(secure.calls.last, isFalse);
  });

  // ---- evcc-Update: Abbrechen während des Release-Abrufs ----

  testWidgets(
      '„Abbrechen" während „evcc-Release wird geladen …" beendet den Ablauf – '
      'danach startet kein Update', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater();
    Completer<EvccRelease?>? gate;
    await tester.pumpWidget(page(u,
        rel: () => gate?.future ?? Future<EvccRelease?>.value()));
    await tester.pumpAndSettle();
    await detect(tester);

    gate = Completer<EvccRelease?>(); // ab jetzt hängt der Abruf
    await tester.tap(find.widgetWithText(OutlinedButton, 'Aktualisieren'));
    await tester.pump();
    expect(find.text('evcc-Release wird geladen …'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Abbrechen'));
    await tester.pump();

    // Der Abruf scheitert erst jetzt (Timeout). Ohne Release-Notes gibt es
    // keinen Bestätigungsdialog — das Update liefe ohne Rückfrage los.
    gate.complete(null);
    await tester.pumpAndSettle();

    expect(u.backupCalls, 0);
    expect(u.runCalls, 0);
    expect(find.text('Abgebrochen.'), findsOneWidget);
    // … und die App ist wieder frei.
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
        tester
            .widget<InkWell>(find.byKey(const Key('profileSwitcher')))
            .onTap,
        isNotNull);
  });

  testWidgets(
      'ein früherer Abbruch bricht das nächste evcc-Update nicht ab',
      (tester) async {
    useTallScreen(tester);
    final gate = Completer<void>();
    final u = FakeEvccUpdater()..detectGate = gate;
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();

    // „Abbrechen" beim Verbinden — der Fake verbindet danach trotzdem.
    await tester
        .tap(find.widgetWithText(OutlinedButton, 'Verbindung herstellen'));
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Abbrechen'));
    await tester.pump();
    gate.complete();
    u.detectGate = null;
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Aktualisieren'));
    await tester.pumpAndSettle();
    expect(u.runCalls, 1);
  });

  // ---- Zeitüberschreitung mitten in einer Aktion ----

  testWidgets(
      'keine Ausgabe mitten in einer Aktion: die Meldung erscheint, die '
      'Sitzung bleibt – der Pi war erreichbar', (tester) async {
    useTallScreen(tester);
    const message = 'Seit 10 min keine Ausgabe – die Aktion läuft '
        'möglicherweise auf dem Pi weiter, Ergebnis unbekannt.';
    final u = FakeEvccUpdater()
      ..backupError =
          const EvccUpdateException(UpdateErrorKind.outputTimeout, message);
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Aktualisieren'));
    await tester.pumpAndSettle();

    expect(find.text(message), findsOneWidget);
    expect(find.byKey(const Key('sessionConnected')), findsOneWidget);
    expect(u.runCalls, 0, reason: 'ohne Backup kein Update');
  });

  testWidgets(
      'Pi nicht erreichbar mitten in einer Aktion: die Sitzung endet wie '
      'bisher', (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..backupError = const EvccUpdateException(UpdateErrorKind.connection,
          'Zeitüberschreitung – Pi nicht erreichbar.');
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);
    expect(find.byKey(const Key('sessionConnected')), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Aktualisieren'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sessionConnected')), findsNothing);
  });

  // ---- Config-Editor: ungespeicherte Änderungen ----

  testWidgets(
      'Config-Editor: Zurück mit ungespeicherten Änderungen fragt nach — '
      '„Weiter bearbeiten" behält sie, „Verwerfen" schließt ohne zu speichern',
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
    await tester.enterText(
        find.byType(TextField).first, 'network:\n  schema: https');
    await tester.pump();

    // System-Zurück (Geste/Taste).
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Änderungen verwerfen?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Weiter bearbeiten'));
    await tester.pumpAndSettle();

    // Noch im Editor, die Eingabe steht.
    expect(find.text('evcc.yaml'), findsOneWidget);
    expect(find.text('network:\n  schema: https'), findsOneWidget);

    // Zurück-Pfeil der App-Leiste.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Änderungen verwerfen?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Verwerfen'));
    await tester.pumpAndSettle();

    expect(find.text('evcc.yaml'), findsNothing); // Editor zu
    expect(find.text('Speichern?'), findsNothing);
    expect(u.savedConfig, isNull);
  });

  testWidgets('Config-Editor: ohne Änderung schließt Zurück ohne Rückfrage',
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
      ];
    await tester.pumpWidget(page(u));
    await tester.pumpAndSettle();
    await detect(tester);

    await tester.tap(find.byKey(const ValueKey('menu-evcc')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Konfiguration bearbeiten'));
    await tester.pumpAndSettle();
    // Getippt und wieder zurückgenommen: der Inhalt ist der geladene.
    await tester.enterText(find.byType(TextField).first, 'x');
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, u.configText);
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('Änderungen verwerfen?'), findsNothing);
    expect(find.text('evcc.yaml'), findsNothing); // Editor zu
  });

  // ---- Multi-Pi: ein Pi-Job ist kein „fehlgeschlagen" ----

  const twoPisWithUpdates = AppConfig(
    profiles: [
      Profile(name: 'A', host: '1.1.1.1', password: 'pw'),
      Profile(name: 'B', host: '2.2.2.2', password: 'pw'),
    ],
    activeIndex: 0,
    disclaimerAccepted: true,
  );
  const systemWithUpdates = [
    ServiceStatus(
        id: 'system',
        name: 'System (Pi)',
        installed: true,
        active: true,
        updateAvailable: true,
        updateKnown: true),
  ];

  Future<void> openMultiPi(WidgetTester tester) async {
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alle Pis (Überblick)'));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'Multi-Pi: reißt die Verbindung ab, läuft der Pi-Job weiter — die Zeile '
      'sagt das statt „Update fehlgeschlagen"; „Neu prüfen" räumt sie ab',
      (tester) async {
    useTallScreen(tester);
    const ref = JobRef(id: 'aaaaaaaaaaaaaaaa', kind: jobKindSystemUpgrade);
    final u = FakeEvccUpdater()
      ..services = systemWithUpdates
      ..startedJob = ref
      ..jobError = const JobException(UpdateErrorKind.jobDetached, 'x',
          ref: ref,
          jobKind: jobKindSystemUpgrade,
          reason: JobDetachReason.connectionLost);
    await tester.pumpWidget(page(u, config: twoPisWithUpdates));
    await tester.pumpAndSettle();
    await openMultiPi(tester);

    await tester.tap(find.byTooltip('Alle mit Updates aktualisieren'));
    await tester.pumpAndSettle();

    expect(u.systemUpgradeCalls, 2); // fail-soft: beide Pis kommen dran
    expect(find.text('Update fehlgeschlagen'), findsNothing);
    expect(find.textContaining('läuft auf dem Pi weiter'), findsNWidgets(2));

    // „Neu prüfen" zeigt wieder den gemessenen Stand, nicht das alte Ergebnis.
    u.jobError = null;
    await tester.tap(find.byTooltip('Neu prüfen'));
    await tester.pumpAndSettle();
    expect(find.textContaining('läuft auf dem Pi weiter'), findsNothing);
    expect(find.textContaining('Updates verfügbar'), findsNWidgets(2));
  });

  testWidgets(
      'Multi-Pi: ein belegter Pi wird als belegt gemeldet, nicht als '
      'fehlgeschlagen', (tester) async {
    // Handy-Breite: der Hinweis ist ein ganzer Satz und muss in der Zeile
    // umbrechen können, ohne das Layout zu sprengen.
    tester.view.physicalSize = const Size(360, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final u = FakeEvccUpdater()
      ..services = systemWithUpdates
      ..jobError = const JobException(UpdateErrorKind.jobBusy, 'x',
          jobKind: 'autoupdate');
    await tester.pumpWidget(page(u, config: twoPisWithUpdates));
    await tester.pumpAndSettle();
    await openMultiPi(tester);

    await tester.tap(find.byTooltip('Alle mit Updates aktualisieren'));
    await tester.pumpAndSettle();

    expect(find.text('Update fehlgeschlagen'), findsNothing);
    expect(find.textContaining('automatischen Updates'), findsNWidgets(2));
  });

  testWidgets('Multi-Pi: ein echter Fehler bleibt „Update fehlgeschlagen"',
      (tester) async {
    useTallScreen(tester);
    final u = FakeEvccUpdater()
      ..services = systemWithUpdates
      ..jobError =
          const EvccUpdateException(UpdateErrorKind.unknown, 'apt kaputt');
    await tester.pumpWidget(page(u, config: twoPisWithUpdates));
    await tester.pumpAndSettle();
    await openMultiPi(tester);

    await tester.tap(find.byTooltip('Alle mit Updates aktualisieren'));
    await tester.pumpAndSettle();

    expect(find.text('Update fehlgeschlagen'), findsNWidgets(2));
  });

  testWidgets(
      'Multi-Pi: ein Keep-Alive um den ganzen Sammellauf — vom ersten bis zum '
      'letzten Pi, nicht je Pi', (tester) async {
    useTallScreen(tester);
    final ka = _FakeKeepAlive();
    final gate = Completer<void>();
    final u = FakeEvccUpdater()
      ..services = systemWithUpdates
      ..jobGate = gate;
    await tester
        .pumpWidget(page(u, config: twoPisWithUpdates, keepAlive: ka));
    await tester.pumpAndSettle();
    await openMultiPi(tester);
    expect(ka.beginCount, 0, reason: 'das Prüfen allein braucht keinen');

    await tester.tap(find.byTooltip('Alle mit Updates aktualisieren'));
    await tester.pump();
    // The first Pi's upgrade hangs on the gate: the service is up and stays.
    expect(u.systemUpgradeCalls, 1);
    expect(ka.beginCount, 1);
    expect(ka.endCount, 0);

    gate.complete();
    await tester.pumpAndSettle();
    expect(u.systemUpgradeCalls, 2);
    expect(ka.beginCount, 1, reason: 'zwischen den Pis nicht neu gestartet');
    expect(ka.endCount, 1);
  });

  testWidgets(
      'Multi-Pi: Übersicht mitten im Sammellauf verlassen und eine andere '
      'Aktion gestartet — das Ende des Sammellaufs nimmt ihr den Keep-Alive '
      'nicht weg', (tester) async {
    useTallScreen(tester);
    final ka = _FakeKeepAlive();
    final bulkGate = Completer<void>();
    final refreshGate = Completer<void>();
    final u = FakeEvccUpdater()
      ..services = systemWithUpdates
      ..jobGate = bulkGate
      ..aptRefreshGate = refreshGate;
    await tester
        .pumpWidget(page(u, config: twoPisWithUpdates, keepAlive: ka));
    await tester.pumpAndSettle();
    await detect(tester);
    await openMultiPi(tester);
    await tester.tap(find.byTooltip('Alle mit Updates aktualisieren'));
    await tester.pump();
    expect(ka.beginCount, 1);

    // Back to the main view; the first Pi's upgrade is still under way.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-system')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paketlisten aktualisieren'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500)); // menu is gone
    expect(u.aptRefreshCalls, 1);
    expect(ka.beginCount, 2);

    // The bulk run's Pi finishes first: no further Pi is started (the page is
    // gone), and the service stays up for the action that still runs.
    bulkGate.complete();
    await tester.pump();
    await tester.pump();
    expect(u.systemUpgradeCalls, 1);
    expect(ka.endCount, 0);

    refreshGate.complete();
    await tester.pumpAndSettle();
    expect(ka.endCount, 1);
  });

  group('Pi-Jobs in der Oberfläche', () {
    const jobId = 'aaaaaaaaaaaaaaaa';
    const ref = JobRef(id: jobId, kind: jobKindSystemUpgrade);
    List<ServiceStatus> systemWith([PiJobStatus? job]) => [
          ServiceStatus(
              id: 'system',
              name: 'System (Pi)',
              installed: true,
              active: true,
              updateAvailable: true,
              updateKnown: true,
              detail: '3 Updates verfügbar',
              job: job),
        ];

    Future<void> startSystemUpgrade(WidgetTester tester) async {
      await tester.tap(find.text('Updates installieren'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Weiter'));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('läuft der Job, heißt der Knopf „Nicht mehr mitlesen"',
        (tester) async {
      useTallScreen(tester);
      final gate = Completer<void>();
      final u = FakeEvccUpdater()
        ..services = systemWith()
        ..startedJob = ref
        ..jobGate = gate;
      await tester.pumpWidget(page(u));
      await tester.pumpAndSettle();
      await detect(tester);

      await startSystemUpgrade(tester);
      expect(find.text('Nicht mehr mitlesen'), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Nicht mehr mitlesen'), findsNothing);
      expect(find.text('System aktualisiert.'), findsOneWidget);
    });

    // The test font is wider than a real one: at this width the label would
    // push the bar past its edge, as a large font does on a phone.
    testWidgets(
        'reicht der Platz nicht für „Nicht mehr mitlesen“, wird der Knopf zum '
        'Symbol mit Tooltip – ohne Überlauf', (tester) async {
      tester.view.physicalSize = const Size(360, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final gate = Completer<void>();
      final u = FakeEvccUpdater()
        ..services = systemWith()
        ..startedJob = ref
        ..jobGate = gate;
      await tester.pumpWidget(page(u, config: _readyNoOffer));
      await tester.pumpAndSettle();
      await detect(tester);

      await startSystemUpgrade(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Nicht mehr mitlesen'), findsNothing);
      await tester.tap(find.byTooltip('Nicht mehr mitlesen'));
      await tester.pump();
      expect(u.cancelCalls, 1);

      gate.complete();
      await tester.pumpAndSettle();
    });

    testWidgets(
        'Verbindung weg: gelber Hinweis statt „Abgebrochen", Job-Leiste, '
        'Mitlesen liefert das echte Ergebnis', (tester) async {
      useTallScreen(tester);
      final u = FakeEvccUpdater()
        ..services = systemWith()
        ..startedJob = ref
        ..jobError = const JobException(UpdateErrorKind.jobDetached, 'x',
            ref: ref,
            jobKind: jobKindSystemUpgrade,
            reason: JobDetachReason.connectionLost);
      await tester.pumpWidget(page(u));
      await tester.pumpAndSettle();
      await detect(tester);

      await startSystemUpgrade(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('läuft auf dem Pi weiter'), findsOneWidget);
      expect(find.text('Abgebrochen.'), findsNothing);
      expect(find.text('Mitlesen'), findsOneWidget);

      u.services = systemWith();
      await tester.tap(find.text('Mitlesen'));
      await tester.pumpAndSettle();
      expect(u.followCalls, 1);
      expect(u.followedJobId, jobId);
      expect(find.text('System aktualisiert.'), findsOneWidget);
      expect(find.text('Mitlesen'), findsNothing);
    });

    testWidgets('Pi mit laufender Automatik: Hinweis, nichts gestartet',
        (tester) async {
      useTallScreen(tester);
      final u = FakeEvccUpdater()
        ..services = systemWith()
        ..jobError = const JobException(UpdateErrorKind.jobBusy, 'x',
            jobKind: 'autoupdate');
      await tester.pumpWidget(page(u));
      await tester.pumpAndSettle();
      await detect(tester);

      await startSystemUpgrade(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('automatischen Updates'), findsOneWidget);
      expect(find.text('Mitlesen'), findsNothing);
    });

    testWidgets('Erkennung meldet einen laufenden Job → Job-Leiste',
        (tester) async {
      useTallScreen(tester);
      final u = FakeEvccUpdater()
        ..services = systemWith(PiJobStatus(
            id: jobId,
            kind: jobKindSystemUpgrade,
            state: PiJobState.running,
            start: DateTime(2026, 9, 24, 14, 2)));
      await tester.pumpWidget(page(u));
      await tester.pumpAndSettle();
      await detect(tester);

      expect(find.textContaining('Pi-Job „System-Update“ läuft'), findsOneWidget);
      expect(find.text('Mitlesen'), findsOneWidget);
    });

    testWidgets('System-Karte zeigt den letzten Job – ohne Erfolgsbehauptung',
        (tester) async {
      useTallScreen(tester);
      final u = FakeEvccUpdater()
        ..services = systemWith(PiJobStatus(
            id: jobId,
            kind: jobKindSystemUpgrade,
            state: PiJobState.done,
            rc: 100,
            start: DateTime(2026, 9, 24, 14, 2),
            end: DateTime(2026, 9, 24, 14, 40)));
      await tester.pumpWidget(page(u));
      await tester.pumpAndSettle();
      await detect(tester);

      expect(find.textContaining('mit Fehler beendet (Exit 100)'),
          findsOneWidget);
      expect(find.text('Mitlesen'), findsNothing);
    });

    testWidgets('unterbrochener Job (Neustart) → Hinweis auf die Reparatur',
        (tester) async {
      useTallScreen(tester);
      final u = FakeEvccUpdater()
        ..services = systemWith(PiJobStatus(
            id: jobId,
            kind: jobKindSystemUpgrade,
            state: PiJobState.interrupted,
            start: DateTime(2026, 9, 24, 14, 2)));
      await tester.pumpWidget(page(u));
      await tester.pumpAndSettle();
      await detect(tester);

      expect(find.textContaining('unterbrochen (Neustart oder Absturz)'),
          findsOneWidget);
    });
  });
}
