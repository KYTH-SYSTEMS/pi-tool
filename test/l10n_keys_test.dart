import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Both ARB files must define the same messages: a key missing in German
/// silently falls back to English in the German UI.
void main() {
  Set<String> keys(String path) {
    final m = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    return m.keys.where((k) => !k.startsWith('@')).toSet();
  }

  test('app_de.arb and app_en.arb have the same keys', () {
    final en = keys('lib/l10n/app_en.arb');
    final de = keys('lib/l10n/app_de.arb');
    expect(de.difference(en), isEmpty, reason: 'nur in app_de.arb');
    expect(en.difference(de), isEmpty, reason: 'nur in app_en.arb');
  });

  // German quotes are „…“. An ASCII " after „ renders as a straight mark next
  // to a typographic one.
  test('app_de.arb: every „ is closed by “, not by an ASCII quote', () {
    final de = jsonDecode(File('lib/l10n/app_de.arb').readAsStringSync())
        as Map<String, dynamic>;
    final wrong = <String>{};
    for (final key in keys('lib/l10n/app_de.arb')) {
      final text = de[key] as String;
      for (var open = text.indexOf('„');
          open >= 0;
          open = text.indexOf('„', open + 1)) {
        final close = text.indexOf(RegExp('[“"]'), open + 1);
        if (close < 0 || text[close] != '“') wrong.add(key);
      }
    }
    expect(wrong, isEmpty);
  });
}
