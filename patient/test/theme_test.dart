/// The palette, enforced rather than described.
///
/// `tokens.dart` has always opened with two rules — "all colour goes through tokens, no raw hex in
/// components" and "no green-for-good and no red-for-bad" — and until now nothing checked either.
/// Both had drifted: twenty raw hex values in the insight screen alone, a mint-and-emerald card
/// around the AI paragraph, Material red on the sign-in errors, a green scanner line sweeping the
/// cuff camera, and a green/plum status badge in History that turned "the capture worked" into a
/// pair of clinical verdicts.
///
/// A rule in a doc comment is a rule until someone is in a hurry. These are the same rules as a
/// build failure.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tera_patient/ui/tokens.dart';

/// Every `.dart` file under `lib/`, with the ones allowed to name raw colour excluded.
///
///   * `tokens.dart` is where the palette is *defined*; hex is the point.
///   * `pdf_export_service.dart` composes a PDF, whose `PdfColor` is a different type in a
///     different colour space and cannot take a Flutter `Color`. It mirrors the same values.
List<File> _componentSources() {
  const exempt = {'tokens.dart', 'pdf_export_service.dart'};
  return Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .where((f) => !exempt.contains(f.uri.pathSegments.last))
      .toList();
}

void main() {
  group('the brand palette is the one the product asked for', () {
    test('the five colours have not moved', () {
      // Changing one of these changes the product's identity, so it should be a deliberate edit to
      // a test and not a quiet edit to a constant.
      expect(TeraColors.ink, const Color(0xFF12304A), reason: 'Dark Navy');
      expect(TeraColors.brand, const Color(0xFF114B5F), reason: 'Deep Teal');
      expect(TeraColors.baltic, const Color(0xFF456990), reason: 'Muted Blue');
      expect(TeraColors.mint, const Color(0xFFE4FDE1), reason: 'Light Mint');
      expect(TeraColors.plum, const Color(0xFF6B2737), reason: 'system state only');
    });

    test('the surfaces are white, and the ground is near-white', () {
      // The product is meant to read as sterile and predominantly white. `page` is a hair off
      // white so a `paper` card has something to sit on — at 1.06:1 that is why panels carry a
      // border rather than relying on the fill.
      expect(TeraColors.paper, const Color(0xFFFFFFFF));
      expect(TeraColors.page.computeLuminance(), greaterThan(0.93));
    });
  });

  group('no colour may imply a clinical verdict', () {
    test('no component names red or green', () {
      // The rule `tokens.dart` leads with. Red and green are how an interface says "bad" and
      // "good", and this app is not entitled to say either — a deviation is differentiated by
      // form: weight, a rule, a textual label.
      final offenders = <String>[];
      final pattern = RegExp(
        r'Colors\.(red|green|greenAccent|lightGreen|redAccent|deepOrange)\b',
      );
      for (final file in _componentSources()) {
        final lines = file.readAsStringSync().split('\n');
        for (var i = 0; i < lines.length; i++) {
          if (pattern.hasMatch(lines[i])) {
            offenders.add('${file.path}:${i + 1}');
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'red and green are not in this palette. A system failure uses TeraColors.plum; a '
            'physiological state uses form, never hue. Found at: $offenders',
      );
    });

    test('plum is the only hue reserved for state, and it is system state', () {
      // Asserted as a property of the decoration helpers rather than of every call site: the
      // helpers are what a screen is supposed to reach for, and `attentionDecoration` existing
      // *without* a hue is the whole argument.
      expect(systemFlagDecoration().border, isNotNull);
      final attention = attentionDecoration().border as Border;
      expect(
        attention.left.color,
        TeraColors.ink,
        reason: 'a patient-facing attention state must not borrow the system colour',
      );
    });
  });

  test('components do not name raw colour', () {
    // "All colour goes through tokens — no raw hex in components", from the working root's
    // CLAUDE.md. Raw hex is how six near-identical greys and three different navies ended up in
    // one app, none of them the brand's.
    final offenders = <String>[];
    final pattern = RegExp(r'0x[Ff][Ff][0-9A-Fa-f]{6}');
    for (final file in _componentSources()) {
      final lines = file.readAsStringSync().split('\n');
      for (var i = 0; i < lines.length; i++) {
        // A hex value inside a comment is documentation, not a colour being used.
        final code = lines[i].split('//').first;
        if (pattern.hasMatch(code)) offenders.add('${file.path}:${i + 1}');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'use a TeraColors token instead of a literal. Found at: $offenders',
    );
  });

  group('the theme carries the brand so screens do not have to', () {
    final theme = buildTeraTheme();

    test('the app bar is white, not brand', () {
      // The bar was brand-filled and almost every screen overrode it back to paper, which is the
      // clearest evidence a default is wrong. Teal earns its place on things a patient acts on.
      expect(theme.appBarTheme.backgroundColor, TeraColors.paper);
      expect(theme.appBarTheme.foregroundColor, TeraColors.ink);
      expect(theme.appBarTheme.elevation, 0);
    });

    test('primary actions are brand, secondary are baltic', () {
      final filled = theme.filledButtonTheme.style!;
      expect(
        filled.backgroundColor!.resolve({}),
        TeraColors.brand,
        reason: 'Deep Teal is the CTA colour',
      );

      final text = theme.textButtonTheme.style!;
      expect(
        text.foregroundColor!.resolve({}),
        TeraColors.baltic,
        reason: 'Muted Blue is the secondary colour',
      );
    });

    test('buttons share one radius', () {
      // Standardised so two buttons on one screen cannot disagree about how round they are.
      for (final style in [
        theme.filledButtonTheme.style!,
        theme.outlinedButtonTheme.style!,
        theme.textButtonTheme.style!,
      ]) {
        final shape = style.shape!.resolve({}) as RoundedRectangleBorder;
        expect(shape.borderRadius, TeraRadius.buttonBorder);
      }
    });

    test('touch targets clear 48dp', () {
      // The persona is a 52-year-old holding a phone against their sternum, often in poor light.
      for (final style in [
        theme.filledButtonTheme.style!,
        theme.outlinedButtonTheme.style!,
      ]) {
        expect(style.minimumSize!.resolve({})!.height, greaterThanOrEqualTo(48));
      }
    });

    test('active states are brand, and the switch is not green', () {
      final track = theme.switchTheme.trackColor!.resolve({WidgetState.selected});
      expect(track, TeraColors.brand);
    });

    test('progress indicators are brand', () {
      expect(theme.progressIndicatorTheme.color, TeraColors.brand);
    });
  });
}
