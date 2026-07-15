import 'package:evcc_updater/src/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Proves the generated AppLocalizations resolves per locale end-to-end.
void main() {
  Future<AppLocalizations> l10nFor(WidgetTester tester, Locale locale) async {
    late AppLocalizations l10n;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      home: Builder(builder: (c) {
        l10n = c.l10n;
        return const SizedBox();
      }),
    ));
    return l10n;
  }

  testWidgets('German locale → German strings', (tester) async {
    final l10n = await l10nFor(tester, const Locale('de'));
    expect(l10n.settingsLanguageTitle, 'Sprache');
  });

  testWidgets('English locale → English strings', (tester) async {
    final l10n = await l10nFor(tester, const Locale('en'));
    expect(l10n.settingsLanguageTitle, 'Language');
  });
}
