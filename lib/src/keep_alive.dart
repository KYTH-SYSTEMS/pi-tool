import 'dart:io' show Platform;

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Keeps the app process alive while a long SSH action runs, so an update isn't
/// killed when the user backgrounds the app. Android-only via a foreground
/// service; a no-op on other platforms (and in tests, where `Platform.isAndroid`
/// is false). Injected into the UI so tests can substitute a fake.
abstract class KeepAliveService {
  /// Begin keeping alive, showing [message] in the ongoing notification.
  /// [channelName] and [channelDescription] label its notification channel in
  /// the system settings, in the app's language.
  Future<void> begin(
    String message, {
    required String channelName,
    required String channelDescription,
  });

  /// Stop keeping alive.
  Future<void> end();
}

/// Android foreground-service implementation (flutter_foreground_task). All
/// calls are best-effort: a failed service must never break the actual SSH
/// action, and on non-Android it does nothing.
class ForegroundKeepAlive implements KeepAliveService {
  bool _initialized = false;

  // The texts of the first call stay: the plugin creates the channel once and
  // leaves an existing one as it is, so a later language has no effect anyway.
  void _ensureInit(String channelName, String channelDescription) {
    if (_initialized) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'pi_tool_action',
        channelName: channelName,
        channelDescription: channelDescription,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      // No repeat callback — the service only keeps the app alive while the
      // existing SSH action runs in the main isolate.
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
      ),
    );
    _initialized = true;
  }

  @override
  Future<void> begin(
    String message, {
    required String channelName,
    required String channelDescription,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      _ensureInit(channelName, channelDescription);
      if (await FlutterForegroundTask.checkNotificationPermission() !=
          NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(
          notificationTitle: 'Pi-Tool',
          notificationText: message,
        );
      } else {
        await FlutterForegroundTask.startService(
          serviceId: 4711,
          serviceTypes: [ForegroundServiceTypes.dataSync],
          notificationTitle: 'Pi-Tool',
          notificationText: message,
        );
      }
    } catch (_) {
      // Best-effort: keeping alive must never break the update itself.
    }
  }

  @override
  Future<void> end() async {
    if (!Platform.isAndroid) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {
      // Best-effort.
    }
  }
}
