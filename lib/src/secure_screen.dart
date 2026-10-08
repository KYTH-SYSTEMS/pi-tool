/// Controls Android's FLAG_SECURE at runtime.
///
/// The flag blocks screenshots and screen recording and blanks the recent-apps
/// thumbnail. It used to be set app-wide, which also blocked the harmless
/// screens — a user who wanted to show Pi-Tool in a forum could not take a
/// picture of it (report 2026-08-12). That works directly against the only
/// distribution channel this app has.
///
/// So it is now scoped: on where credentials can be on screen, off elsewhere.
/// The native side still sets the flag at startup, so the app is secure BEFORE
/// Dart runs and stays secure if this seam ever fails.
library;

import 'package:flutter/services.dart';

abstract class SecureScreen {
  /// True = block screenshots, false = allow them.
  Future<void> setSecure(bool secure);
}

/// Keeps the app's last screen out of the recent-apps overview.
///
/// For the app lock: the lock engages when the app is already in the
/// background, and Android has taken the picture for the overview by then —
/// [SecureScreen] comes too late for it. With the lock switched on the picture
/// is therefore turned off for good, and screenshots stay possible.
///
/// Android offers this from version 13 (API 33). On older versions the call
/// does nothing and the overview keeps showing the last screen.
abstract class RecentsPreview {
  /// True = no picture of the app in the overview, false = the default.
  Future<void> setRecentsHidden(bool hidden);
}

/// Default: a tiny MethodChannel (no plugin), mirroring the file picker.
class ChannelSecureScreen implements SecureScreen, RecentsPreview {
  const ChannelSecureScreen();
  static const _channel = MethodChannel('pi_tool/secure');

  @override
  Future<void> setSecure(bool secure) async {
    try {
      await _channel.invokeMethod<void>('setSecure', {'secure': secure});
    } catch (_) {
      // A failure here must never take the app down. The worst case is that
      // the flag stays as it was — and it starts in the SECURE state.
    }
  }

  @override
  Future<void> setRecentsHidden(bool hidden) async {
    try {
      await _channel.invokeMethod<void>('setRecentsHidden', {'hidden': hidden});
    } catch (_) {
      // As above. The worst case is the overview picture as it was before the
      // app lock cared about it.
    }
  }
}
