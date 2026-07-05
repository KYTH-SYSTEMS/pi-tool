import 'package:evcc_updater/src/whats_new.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shouldShowWhatsNew', () {
    test('shows on an actual version change', () {
      expect(
          shouldShowWhatsNew(lastSeen: '0.21.13', current: '0.21.14'), isTrue);
    });

    test('does NOT show on a fresh install (empty last-seen)', () {
      expect(shouldShowWhatsNew(lastSeen: '', current: '0.21.14'), isFalse);
    });

    test('does NOT show when the version is unchanged', () {
      expect(
          shouldShowWhatsNew(lastSeen: '0.21.14', current: '0.21.14'), isFalse);
    });

    test('does NOT show when the current version is unknown/empty', () {
      expect(shouldShowWhatsNew(lastSeen: '0.21.13', current: ''), isFalse);
    });
  });

  group('whatsNewFor', () {
    test('returns curated highlights for a known version', () {
      final notes = whatsNewFor('0.21.14');
      expect(notes, isNotNull);
      expect(notes, isNotEmpty);
      expect(notes!.any((n) => n.contains('Konsole')), isTrue);
    });

    test('null for a version without curated notes', () {
      expect(whatsNewFor('0.0.1'), isNull);
    });
  });
}
