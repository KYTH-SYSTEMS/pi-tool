/// Platform glue for the daily background update check: workmanager scheduling +
/// flutter_local_notifications. The decidable logic lives in notifications.dart
/// (unit-tested); this file is the thin, device-validated adapter.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';

import 'evcc_updater.dart';
import 'notifications.dart';
import 'profiles.dart';
import 'ssh_runner.dart';

const _taskName = 'pi-tool-update-check';
const _channelId = 'pi_tool_updates';

/// workmanager entry point — runs in a background isolate, so it must be a
/// top-level function with the vm:entry-point pragma.
@pragma('vm:entry-point')
void updateCheckDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    final store = AppConfigStore();
    final updater = EvccUpdater.real();
    final runner = UpdateCheckRunner(
      loadProfiles: () async {
        final cfg = await store.load();
        return cfg.notifyUpdates ? cfg.profiles : const <Profile>[];
      },
      detect: (p) => updater.detectServices(
        config: _configForProfile(p),
        onLog: (_) {},
        // Background stays password-free: no sudo escalation.
        allowSudoForDocker: false,
      ),
      notify: showUpdateNotification,
    );
    try {
      await runner.run();
    } catch (_) {
      // best-effort background check — never crash the worker
    }
    return true;
  });
}

/// Initialise workmanager once at startup (does not schedule anything).
Future<void> initUpdateChecks() =>
    Workmanager().initialize(updateCheckDispatcher);

/// Schedule (daily) or cancel the background update check.
Future<void> setUpdateChecksEnabled(bool enabled) async {
  if (enabled) {
    await Workmanager().registerPeriodicTask(
      _taskName,
      _taskName,
      frequency: const Duration(hours: 24),
      constraints: Constraints(networkType: NetworkType.connected),
    );
  } else {
    await Workmanager().cancelByUniqueName(_taskName);
  }
}

/// Requests the POST_NOTIFICATIONS runtime permission (Android 13+). Returns
/// whether notifications are allowed. Safe to call from the UI isolate.
Future<bool> requestNotificationPermission() async {
  final android = FlutterLocalNotificationsPlugin()
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  final granted = await android?.requestNotificationsPermission();
  return granted ?? true;
}

/// Shows the update notification (used from the background isolate).
Future<void> showUpdateNotification(NotificationContent c) async {
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(const InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
  ));
  await plugin.show(
    1001,
    c.title,
    c.body,
    NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        'Update-Hinweise',
        channelDescription:
            'Benachrichtigt, wenn auf deinem Pi Updates verfügbar sind.',
        importance: Importance.defaultImportance,
        styleInformation: BigTextStyleInformation(c.body),
      ),
    ),
  );
}

SshConfig _configForProfile(Profile p) => SshConfig(
      host: p.host,
      port: int.tryParse(p.port) ?? 22,
      username: p.username,
      password: p.password,
      privateKey: p.privateKey,
      keyPassphrase: p.keyPassphrase,
      timeout: const Duration(seconds: 15),
    );
