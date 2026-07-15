import 'package:evcc_updater/src/language.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('localeForLanguageMode', () {
    test('system (or unknown) → null, follow the device', () {
      expect(localeForLanguageMode('system'), isNull);
      expect(localeForLanguageMode('whatever'), isNull);
    });
    test('de/en → the forced locale', () {
      expect(localeForLanguageMode('de'), const Locale('de'));
      expect(localeForLanguageMode('en'), const Locale('en'));
    });
  });

  group('resolveSystemLocale (English fallback)', () {
    test('German candidate → German', () {
      expect(resolveSystemLocale(const Locale('de')), const Locale('de'));
      expect(resolveSystemLocale(const Locale('de', 'AT')), const Locale('de'));
    });
    test('anything else (incl. null) → English', () {
      expect(resolveSystemLocale(const Locale('en')), const Locale('en'));
      expect(resolveSystemLocale(const Locale('fr')), const Locale('en'));
      expect(resolveSystemLocale(null), const Locale('en'));
    });
  });
}
