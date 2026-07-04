/// KYTH brand splash: plays the short outro video once (muted, full-screen) on
/// top of the app on cold start, then fades out to reveal it. Kept out of the
/// widget tests — only the production app root wraps [KythSplashGate].
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Matches the video's own background (#0A0A0B) so there is no hard seam while
/// the first frame loads or when it fades into the (near-black) app.
const Color _kSplashBg = Color(0xFF0A0A0B);

/// True once the brand splash has finished (or was never shown). The app waits
/// for this before popping the biometric unlock prompt, so the system dialog
/// can't cover the splash video. Defaults to true, so anything that runs
/// without the splash (widget tests, hot reload) is never blocked.
final ValueNotifier<bool> splashDoneNotifier = ValueNotifier<bool>(true);

/// Wraps [child], showing the KYTH splash video over it until the clip ends (or
/// the user taps to skip, or a safety cap fires), then fades the overlay away.
/// Fail-safe: any load error reveals [child] immediately — the splash can never
/// trap the user.
class KythSplashGate extends StatefulWidget {
  const KythSplashGate({super.key, required this.child});

  final Widget child;

  @override
  State<KythSplashGate> createState() => _KythSplashGateState();
}

class _KythSplashGateState extends State<KythSplashGate> {
  VideoPlayerController? _controller;
  Timer? _cap;
  bool _fading = false; // start the fade-out
  bool _gone = false; // remove the overlay entirely

  @override
  void initState() {
    super.initState();
    splashDoneNotifier.value = false; // hold the unlock prompt until we're done
    _init();
  }

  Future<void> _init() async {
    // Hard cap: a slow/broken video must never leave the user stuck on black.
    _cap = Timer(const Duration(seconds: 4), _finish);
    try {
      final c = VideoPlayerController.asset('assets/kyth-splash.mp4');
      _controller = c;
      await c.initialize();
      await c.setVolume(0); // splash is silent
      c.addListener(_onTick);
      await c.play();
      if (mounted) setState(() {});
    } catch (_) {
      _finish(); // no video → straight to the app
    }
  }

  void _onTick() {
    final c = _controller;
    if (c == null || _fading) return;
    final v = c.value;
    if (v.isInitialized &&
        v.duration > Duration.zero &&
        v.position >= v.duration) {
      _finish();
    }
  }

  void _finish() {
    if (_fading) return;
    _cap?.cancel();
    splashDoneNotifier.value = true; // splash done → the app may now unlock
    if (!mounted) return;
    setState(() => _fading = true);
    Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _gone = true);
    });
  }

  @override
  void dispose() {
    _cap?.cancel();
    splashDoneNotifier.value = true; // never leave the unlock prompt blocked
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final ready = c != null && c.value.isInitialized;
    return Stack(
      children: [
        widget.child, // builds/loads underneath while the splash plays
        if (!_gone)
          Positioned.fill(
            child: GestureDetector(
              onTap: _finish, // tap to skip
              child: AnimatedOpacity(
                opacity: _fading ? 0 : 1,
                duration: const Duration(milliseconds: 350),
                child: ColoredBox(
                  color: _kSplashBg,
                  child: ready
                      ? FittedBox(
                          fit: BoxFit.cover,
                          clipBehavior: Clip.hardEdge,
                          child: SizedBox(
                            width: c.value.size.width,
                            height: c.value.size.height,
                            child: VideoPlayer(c),
                          ),
                        )
                      : const SizedBox.expand(),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
