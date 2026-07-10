/// The KYTH corporate wordmark, rendered to the brand spec (KYTH-Wortmarke.md).
///
/// The two non-negotiables are honoured: the tight **Y–T** kerning and the
/// **green glowing full-stop**. `KYTH` is set in Bricolage Grotesque ExtraBold
/// (800) with the brand's base condensation; an optional [product] word follows
/// in regular weight (400), un-condensed — the deliberate brand/product
/// contrast, e.g. `KYTH. Systems`.
///
/// Font kerning is expressed per glyph (Flutter's letterSpacing is trailing):
/// K/T carry the base −0.08em, Y the extra-tight −0.12em (closing the Y–T gap),
/// and H a small +0.04em so the dot sits just beside the H instead of over it
/// (the CSS `margin-left:0.04em`).
library;

import 'package:flutter/material.dart';

class KythWordmark extends StatelessWidget {
  const KythWordmark({
    super.key,
    this.fontSize = 14,
    this.product,
    this.color,
    this.glow = true,
    this.background,
  });

  /// Cap height driver — everything (kerning, glow, dot margin) scales off this
  /// so the mark stays proportional at any size (the spec's em-based values).
  final double fontSize;

  /// Optional product/suffix word in Title Case, e.g. 'Systems' → "KYTH. Systems".
  final String? product;

  /// Colour of the letters (not the dot). Defaults to white on a dark theme,
  /// near-black (#0A0A0B) on a light one, per the spec.
  final Color? color;

  /// Whether the dot glows. Always dropped on a light background (spec).
  final bool glow;

  /// Overrides the theme-derived brightness — pass [Brightness.dark] when the
  /// mark sits on a known-dark surface regardless of the app theme (e.g. the
  /// always-black lock screen), so the letters/glow don't key off a light theme.
  final Brightness? background;

  /// The brand dot. Aligned to the app accent (kGreen, #1FD65F) rather than the
  /// spec's #22C55E — a deliberate owner decision (2026-07) so the app, its
  /// launcher icon and this mark share one green.
  static const Color kWordmarkGreen = Color(0xFF1FD65F);

  /// Wordmark colour on a light background (spec).
  static const Color _lightInk = Color(0xFF0A0A0B);

  static const String _family = 'Bricolage Grotesque';

  @override
  Widget build(BuildContext context) {
    final dark = (background ?? Theme.of(context).brightness) == Brightness.dark;
    final ink = color ?? (dark ? Colors.white : _lightInk);
    final useGlow = glow && dark; // no glow on light backgrounds

    TextStyle letter(double spacingEm) => TextStyle(
          fontFamily: _family,
          fontSize: fontSize,
          height: 1.0,
          color: ink,
          fontVariations: const [FontVariation('wght', 800)],
          letterSpacing: spacingEm * fontSize,
        );

    final dotStyle = TextStyle(
      fontFamily: _family,
      fontSize: fontSize,
      height: 1.0,
      color: kWordmarkGreen,
      fontVariations: const [FontVariation('wght', 800)],
      shadows: useGlow
          ? [
              Shadow(
                  color: kWordmarkGreen.withValues(alpha: 0.75),
                  blurRadius: fontSize * 1.4),
              Shadow(
                  color: kWordmarkGreen.withValues(alpha: 0.35),
                  blurRadius: fontSize * 3.9),
            ]
          : null,
    );

    return Text.rich(
      TextSpan(children: [
        TextSpan(text: 'K', style: letter(-0.08)),
        TextSpan(text: 'Y', style: letter(-0.12)), // extra-tight Y–T
        TextSpan(text: 'T', style: letter(-0.08)),
        TextSpan(text: 'H', style: letter(0.04)), // +margin before the dot
        TextSpan(text: '.', style: dotStyle),
        if (product != null && product!.isNotEmpty)
          TextSpan(
            text: ' $product',
            style: TextStyle(
              fontFamily: _family,
              fontSize: fontSize,
              height: 1.0,
              color: ink,
              fontVariations: const [FontVariation('wght', 400)],
              letterSpacing: 0,
            ),
          ),
      ]),
    );
  }
}
