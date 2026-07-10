/// Update-notification logic: a pure summariser + a seamed check runner.
///
/// Kept plugin-free and fully unit-tested. The platform glue (an Android
/// background scheduler + a notification plugin) is **deliberately not wired**,
/// and stays that way: update-push already ships the architecturally-correct
/// way — the on-Pi health-alert systemd timer pushes "N Updates verfuegbar" via
/// ntfy (see `alerts.dart`). An Android background service would (a) duplicate
/// that, and (b) violate the "kein Android-Hintergrunddienst für Automatik"
/// invariant (the v0.20.0 crash lesson). This decidable core is kept as a
/// tested reserve for any future *foreground* use (e.g. the multi-Pi overview).
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
