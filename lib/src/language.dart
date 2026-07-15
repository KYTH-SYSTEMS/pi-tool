import 'package:flutter/widgets.dart' show Locale;

/// Language codes the app ships translations for. English is the fallback for
/// any device language that isn't German.
const List<String> kSupportedLanguageCodes = ['en', 'de'];

/// Persisted values for [AppConfig.languageMode].
const List<String> kLanguageModes = ['system', 'de', 'en'];

/// Maps the persisted `languageMode` to a forced [Locale], or `null` for
/// "system" (let the framework resolve from the device language).
Locale? localeForLanguageMode(String mode) {
  switch (mode) {
    case 'de':
      return const Locale('de');
    case 'en':
      return const Locale('en');
    default:
      return null; // 'system' (or anything unknown) → follow the device
  }
}

/// Resolves the actual [Locale] to use given a candidate (the forced locale in
/// DE/EN mode, or the device's preferred locale in system mode): German only
/// for a German candidate, English for everything else (English fallback).
Locale resolveSystemLocale(Locale? candidate) =>
    candidate?.languageCode == 'de' ? const Locale('de') : const Locale('en');
