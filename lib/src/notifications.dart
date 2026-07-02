/// Update-notification logic: a pure summariser + a seamed check runner.
///
/// Kept plugin-free and fully unit-tested. The platform glue (a scheduler +
/// a notification plugin) is intentionally NOT wired yet — it needs on-device
/// validation before shipping. This decidable core is ready for that.
library;

import 'profiles.dart';
import 'services/pi_service.dart';

/// A ready-to-show notification.
class NotificationContent {
  final String title;
  final String body;
  const NotificationContent({required this.title, required this.body});
}

/// Builds an update notification from per-profile detection results, or null
/// when no installed service on any Pi has a (known) pending update.
NotificationContent? summarizeUpdates(
    Map<String, List<ServiceStatus>> perProfile) {
  final lines = <String>[];
  var total = 0;
  var pis = 0;
  for (final entry in perProfile.entries) {
    final names = entry.value
        .where((s) => s.installed && s.updateAvailable)
        .map((s) => s.name)
        .toList();
    if (names.isEmpty) continue;
    pis++;
    total += names.length;
    lines.add('${entry.key}: ${names.join(', ')}');
  }
  if (total == 0) return null;
  final title = pis == 1
      ? '$total Update${total == 1 ? '' : 's'} auf deinem Pi'
      : '$total Updates auf $pis Pis';
  return NotificationContent(title: title, body: lines.join('\n'));
}

/// Runs one background update check across all profiles and notifies if
/// anything is pending. Fully seamed: production wires the real config store,
/// SSH detection and notification plugin; tests pass fakes.
class UpdateCheckRunner {
  final Future<List<Profile>> Function() loadProfiles;
  final Future<List<ServiceStatus>> Function(Profile profile) detect;
  final Future<void> Function(NotificationContent content) notify;

  const UpdateCheckRunner({
    required this.loadProfiles,
    required this.detect,
    required this.notify,
  });

  Future<void> run() async {
    final profiles = await loadProfiles();
    final perProfile = <String, List<ServiceStatus>>{};
    for (final p in profiles) {
      try {
        perProfile[p.name] = await detect(p);
      } catch (_) {
        // Unreachable / not-yet-configured Pi — skip it silently.
      }
    }
    final content = summarizeUpdates(perProfile);
    if (content != null) await notify(content);
  }
}
