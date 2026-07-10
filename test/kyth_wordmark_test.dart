import 'package:evcc_updater/src/kyth_wordmark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Walks an [InlineSpan] tree and returns the first [TextSpan] whose text
/// equals [needle] — used to inspect a single glyph's styling.
TextSpan? _spanFor(InlineSpan root, String needle) {
  TextSpan? hit;
  void visit(InlineSpan s) {
    if (hit != null) return;
    if (s is TextSpan) {
      if (s.text == needle) {
        hit = s;
        return;
      }
      s.children?.forEach(visit);
    }
  }

  visit(root);
  return hit;
}

RichText _richOf(WidgetTester tester) => tester.widget<RichText>(
      find.descendant(
          of: find.byType(KythWordmark), matching: find.byType(RichText)),
    );

void main() {
  Future<void> pump(WidgetTester tester, Widget w) => tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: Scaffold(body: Center(child: w)),
        ),
      );

  testWidgets('renders "KYTH. Systems" with the product suffix as plain text',
      (tester) async {
    await pump(tester, const KythWordmark(product: 'Systems'));
    // Placeholders excluded so the reading order is exactly the wordmark text.
    expect(_richOf(tester).text.toPlainText(includePlaceholders: false),
        'KYTH. Systems');
  });

  testWidgets('the full-stop is the green brand dot (aligned to the app accent)',
      (tester) async {
    await pump(tester, const KythWordmark());
    final dot = _spanFor(_richOf(tester).text, '.');
    expect(dot, isNotNull);
    expect(dot!.style!.color, const Color(0xFF1FD65F));
  });

  testWidgets('dark background: the dot carries a glow', (tester) async {
    await pump(tester, const KythWordmark());
    final dot = _spanFor(_richOf(tester).text, '.');
    expect(dot!.style!.shadows, isNotNull);
    expect(dot.style!.shadows, isNotEmpty);
  });

  testWidgets('light background: no glow, near-black letters (spec)',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: Brightness.light),
      home: const Scaffold(body: Center(child: KythWordmark(product: 'Systems'))),
    ));
    final rich = _richOf(tester);
    final dot = _spanFor(rich.text, '.');
    // Dot stays green, but the glow is dropped on light backgrounds.
    expect(dot!.style!.color, const Color(0xFF1FD65F));
    expect(dot.style!.shadows ?? const [], isEmpty);
    // Letters go near-black.
    final k = _spanFor(rich.text, 'K');
    expect(k!.style!.color, const Color(0xFF0A0A0B));
  });

  testWidgets('KYTH is ExtraBold (800); the product word is regular (400)',
      (tester) async {
    await pump(tester, const KythWordmark(product: 'Systems'));
    final rich = _richOf(tester);
    final k = _spanFor(rich.text, 'K');
    final product = _spanFor(rich.text, ' Systems');
    expect(k!.style!.fontFamily, 'Bricolage Grotesque');
    expect(k.style!.fontVariations, contains(const FontVariation('wght', 800)));
    expect(product, isNotNull);
    expect(product!.style!.fontVariations,
        contains(const FontVariation('wght', 400)));
  });

  testWidgets(
      'background override forces the dark treatment even under a light theme '
      '(fixes the always-dark lock screen)', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      // Light theme, but the mark sits on a known-dark surface.
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
            child: KythWordmark(background: Brightness.dark, product: 'Systems')),
      ),
    ));
    final rich = _richOf(tester);
    // Letters stay white (not near-black) and the dot keeps its glow.
    expect(_spanFor(rich.text, 'K')!.style!.color, Colors.white);
    expect(_spanFor(rich.text, '.')!.style!.shadows, isNotEmpty);
  });

  testWidgets('the Y–T pair is kerned tighter than the base', (tester) async {
    await pump(tester, const KythWordmark(fontSize: 20));
    final rich = _richOf(tester);
    final k = _spanFor(rich.text, 'K');
    final y = _spanFor(rich.text, 'Y');
    // Y carries the extra-tight kerning (-0.12em vs the base -0.08em).
    expect(y!.style!.letterSpacing, lessThan(k!.style!.letterSpacing!));
  });
}
