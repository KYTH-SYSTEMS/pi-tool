import 'package:evcc_updater/src/entitlement.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isFeatureLocked', () {
    test('every Pro feature is locked for a free user', () {
      for (final f in ProFeature.values) {
        expect(isFeatureLocked(f, isPro: false), isTrue, reason: '$f');
      }
    });
    test('nothing is locked for a Pro user', () {
      for (final f in ProFeature.values) {
        expect(isFeatureLocked(f, isPro: true), isFalse, reason: '$f');
      }
    });
  });

  group('isAddProfileLocked (multi-Pi)', () {
    test('free user may keep one profile but not add a second', () {
      expect(isAddProfileLocked(isPro: false, profileCount: 0), isFalse);
      expect(isAddProfileLocked(isPro: false, profileCount: 1), isTrue);
      expect(isAddProfileLocked(isPro: false, profileCount: 3), isTrue);
    });
    test('Pro user may add unlimited profiles', () {
      expect(isAddProfileLocked(isPro: true, profileCount: 5), isFalse);
    });
  });

  group('DormantEntitlement (pre-launch default)', () {
    test('keeps everyone Pro so current users lose nothing', () async {
      const e = DormantEntitlement();
      expect(await e.isPro(), isTrue);
      expect(await e.buyPro(), isTrue);
      expect(await e.restore(), isTrue);
    });
  });
}
