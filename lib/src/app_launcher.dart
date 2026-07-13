/// Launches another installed app (e.g. Tailscale) so the user can bring up the
/// phone-side VPN. Android forbids one app from toggling another's VPN, so the
/// best we can do is open the app; a fallback URL (Play Store) covers "not
/// installed". Behind a seam so widget tests don't hit a platform channel.
library;

import 'package:flutter/services.dart';

abstract class AppLauncher {
  /// Opens the app with [package]. Falls back to [fallbackUrl] (e.g. the Play
  /// Store page) if it isn't installed. Returns true iff the app itself opened.
  Future<bool> openApp(String package, {required String fallbackUrl});
}

/// Default: a tiny native MethodChannel (no plugin) mirroring the file picker.
class ChannelAppLauncher implements AppLauncher {
  const ChannelAppLauncher();
  static const _channel = MethodChannel('pi_tool/launcher');

  @override
  Future<bool> openApp(String package, {required String fallbackUrl}) async {
    try {
      final ok = await _channel.invokeMethod<bool>(
          'openApp', {'package': package, 'fallbackUrl': fallbackUrl});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}
