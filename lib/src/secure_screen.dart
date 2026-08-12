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

/// Default: a tiny MethodChannel (no plugin), mirroring the file picker.
class ChannelSecureScreen implements SecureScreen {
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
}
