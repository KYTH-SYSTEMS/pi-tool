/// When Pi-Tool asks Google Play for its in-app review card, and the seam to the
/// native call.
///
/// Play decides on its own whether the card appears (quota, already reviewed,
/// no Play Store on the device) and never tells the app. So all this side can
/// do is pick a moment that is fair to the user: after enough real use, right
/// after something worked, and rarely. The decision is pure + Flutter-free and
/// unit-tested; the native call sits behind [ReviewRequester] so widget tests
/// never hit a platform channel.
///
/// Deliberately no "do you like the app?" question in front of it — filtering
/// who gets to rate is exactly what Play's guidelines rule out.
library;

import 'package:flutter/services.dart';

import 'update_check.dart';

/// Successful actions before the first ask.
const int kReviewMinSuccesses = 3;

/// Time between the first successful action and the first ask — someone who
/// installed the app an hour ago has nothing to rate yet.
const Duration kReviewMinAge = Duration(days: 3);

/// Minimum gap between two asks.
const Duration kReviewCooldown = Duration(days: 120);

/// After this many asks the app never asks again.
const int kReviewMaxAsks = 3;

/// What the app remembers about the review ask (persisted in `AppConfig`).
class ReviewPromptState {
  /// Actions that ended in a history entry, i.e. actually did something.
  final int successes;
  final DateTime? firstSuccessAt;
  final DateTime? lastAskedAt;
  final int asks;

  const ReviewPromptState({
    this.successes = 0,
    this.firstSuccessAt,
    this.lastAskedAt,
    this.asks = 0,
  });

  static const initial = ReviewPromptState();

  ReviewPromptState recordSuccess(DateTime now) => ReviewPromptState(
        successes: successes + 1,
        firstSuccessAt: firstSuccessAt ?? now,
        lastAskedAt: lastAskedAt,
        asks: asks,
      );

  ReviewPromptState recordAsk(DateTime now) => ReviewPromptState(
        successes: successes,
        firstSuccessAt: firstSuccessAt,
        lastAskedAt: now,
        asks: asks + 1,
      );

  Map<String, dynamic> toJson() => {
        'successes': successes,
        'firstSuccessAt': firstSuccessAt?.toIso8601String(),
        'lastAskedAt': lastAskedAt?.toIso8601String(),
        'asks': asks,
      };

  /// Tolerant decode: anything missing or malformed counts as never recorded.
  static ReviewPromptState fromJson(Object? raw) {
    if (raw is! Map) return initial;
    int count(Object? v) => (v is int && v > 0) ? v : 0;
    DateTime? date(Object? v) => v is String ? DateTime.tryParse(v) : null;
    return ReviewPromptState(
      successes: count(raw['successes']),
      firstSuccessAt: date(raw['firstSuccessAt']),
      lastAskedAt: date(raw['lastAskedAt']),
      asks: count(raw['asks']),
    );
  }
}

/// Whether now is a fair moment to ask Play for the review card.
///
/// Only on a Play build (the card cannot appear anywhere else) and never in
/// demo mode. A clock that was set back never triggers an ask.
bool shouldRequestReview({
  required ReviewPromptState state,
  required InstallChannel channel,
  required bool demoMode,
  required DateTime now,
}) {
  if (channel != InstallChannel.play || demoMode) return false;
  if (state.asks >= kReviewMaxAsks) return false;
  if (state.successes < kReviewMinSuccesses) return false;
  final first = state.firstSuccessAt;
  if (first == null || now.difference(first) < kReviewMinAge) return false;
  final last = state.lastAskedAt;
  if (last != null && now.difference(last) < kReviewCooldown) return false;
  return true;
}

/// Asks Play to show the in-app review card.
abstract class ReviewRequester {
  /// Returns true when the request reached Play. That is NOT "the card was
  /// shown" — Play does not report that.
  Future<bool> request();
}

/// Default: a tiny native MethodChannel (no plugin) mirroring the file picker.
class ChannelReviewRequester implements ReviewRequester {
  const ChannelReviewRequester();
  static const _channel = MethodChannel('pi_tool/review');

  @override
  Future<bool> request() async {
    try {
      return await _channel.invokeMethod<bool>('requestReview') ?? false;
    } catch (_) {
      return false; // never let a rating request disturb the app
    }
  }
}
