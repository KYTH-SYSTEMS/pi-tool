import 'package:evcc_updater/src/review_prompt.dart';
import 'package:evcc_updater/src/update_check.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 10, 1, 12);

  /// A state that satisfies every rule at [t0] + [kReviewMinAge].
  ReviewPromptState ripe() {
    var s = ReviewPromptState.initial;
    for (var i = 0; i < kReviewMinSuccesses; i++) {
      s = s.recordSuccess(t0);
    }
    return s;
  }

  bool ask(
    ReviewPromptState s, {
    InstallChannel channel = InstallChannel.play,
    bool demoMode = false,
    required DateTime now,
  }) =>
      shouldRequestReview(
          state: s, channel: channel, demoMode: demoMode, now: now);

  group('recordSuccess', () {
    test('counts every success and remembers only the first date', () {
      final later = t0.add(const Duration(days: 9));
      final s = ReviewPromptState.initial.recordSuccess(t0).recordSuccess(later);
      expect(s.successes, 2);
      expect(s.firstSuccessAt, t0);
    });
  });

  group('shouldRequestReview', () {
    final due = t0.add(kReviewMinAge);

    test('asks once enough has worked over enough days', () {
      expect(ask(ripe(), now: due), isTrue);
    });

    test('never on a sideloaded build — the Play card cannot appear there', () {
      expect(ask(ripe(), channel: InstallChannel.sideload, now: due), isFalse);
    });

    test('never in demo mode — sample data is not use of the app', () {
      expect(ask(ripe(), demoMode: true, now: due), isFalse);
    });

    test('not before the minimum number of successful actions', () {
      var s = ReviewPromptState.initial;
      for (var i = 0; i < kReviewMinSuccesses - 1; i++) {
        s = s.recordSuccess(t0);
      }
      expect(ask(s, now: due), isFalse);
    });

    test('not on the day of the first success, however much worked', () {
      expect(ask(ripe(), now: t0.add(const Duration(hours: 6))), isFalse);
      expect(
          ask(ripe(),
              now: t0.add(kReviewMinAge - const Duration(minutes: 1))),
          isFalse);
    });

    test('a fresh state never asks', () {
      expect(ask(ReviewPromptState.initial, now: due), isFalse);
    });

    test('after an ask it stays quiet for the cooldown, then asks again', () {
      final asked = ripe().recordAsk(due);
      expect(ask(asked, now: due.add(const Duration(days: 1))), isFalse);
      expect(
          ask(asked, now: due.add(kReviewCooldown - const Duration(days: 1))),
          isFalse);
      expect(ask(asked, now: due.add(kReviewCooldown)), isTrue);
    });

    test('stops for good after the maximum number of asks', () {
      var s = ripe();
      var now = due;
      for (var i = 0; i < kReviewMaxAsks; i++) {
        expect(ask(s, now: now), isTrue, reason: 'ask ${i + 1}');
        s = s.recordAsk(now);
        now = now.add(kReviewCooldown);
      }
      expect(ask(s, now: now.add(const Duration(days: 3650))), isFalse);
    });

    test('a clock set back before the last ask does not trigger one', () {
      final asked = ripe().recordAsk(due.add(const Duration(days: 400)));
      expect(ask(asked, now: due), isFalse);
    });

    test('a clock set back before the first success does not trigger one', () {
      expect(ask(ripe(), now: t0.subtract(const Duration(days: 30))), isFalse);
    });
  });

  group('persistence', () {
    test('round-trips through JSON', () {
      final s = ripe().recordAsk(t0.add(const Duration(days: 5)));
      final back = ReviewPromptState.fromJson(s.toJson());
      expect(back.successes, s.successes);
      expect(back.firstSuccessAt, s.firstSuccessAt);
      expect(back.lastAskedAt, s.lastAskedAt);
      expect(back.asks, s.asks);
    });

    test('missing or malformed data falls back to the initial state', () {
      for (final raw in <Object?>[
        null,
        'x',
        42,
        <String, dynamic>{},
        <String, dynamic>{'successes': 'many', 'firstSuccessAt': 7},
        <String, dynamic>{'successes': -4, 'asks': -1},
        <String, dynamic>{'firstSuccessAt': 'not a date'},
      ]) {
        final s = ReviewPromptState.fromJson(raw);
        expect(s.successes, 0, reason: '$raw');
        expect(s.asks, 0, reason: '$raw');
        expect(s.firstSuccessAt, isNull, reason: '$raw');
        expect(s.lastAskedAt, isNull, reason: '$raw');
      }
    });
  });
}
