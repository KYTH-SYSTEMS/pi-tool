import 'package:evcc_updater/src/early_adopter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveFirstSeenVersionCode', () {
    test('a genuine fresh install records the current build', () {
      expect(
        resolveFirstSeenVersionCode(
            stored: null, wasUsedBefore: false, currentVersionCode: 112),
        112,
      );
    });

    test('an existing user gets the pre-marker sentinel (grandfathered)', () {
      expect(
        resolveFirstSeenVersionCode(
            stored: null, wasUsedBefore: true, currentVersionCode: 112),
        kPreMarkerFirstSeen,
      );
    });

    test('never overwrites a stored value (idempotent)', () {
      expect(
        resolveFirstSeenVersionCode(
            stored: 100, wasUsedBefore: false, currentVersionCode: 112),
        100,
      );
      expect(
        resolveFirstSeenVersionCode(
            stored: 0, wasUsedBefore: true, currentVersionCode: 112),
        0,
      );
    });
  });

  group('isGrandfathered (paywall @ 130)', () {
    const paywall = 130;
    test('null → not grandfathered', () {
      expect(isGrandfathered(null, paywallVersionCode: paywall), isFalse);
    });
    test('pre-marker sentinel 0 → grandfathered', () {
      expect(isGrandfathered(0, paywallVersionCode: paywall), isTrue);
    });
    test('a build before the paywall → grandfathered', () {
      expect(isGrandfathered(129, paywallVersionCode: paywall), isTrue);
    });
    test('the paywall build itself → not grandfathered', () {
      expect(isGrandfathered(130, paywallVersionCode: paywall), isFalse);
    });
    test('a later build → not grandfathered', () {
      expect(isGrandfathered(131, paywallVersionCode: paywall), isFalse);
    });
  });
}
