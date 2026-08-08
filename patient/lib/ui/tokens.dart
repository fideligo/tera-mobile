/// Design tokens, named to match `tera-web/dashboard/app/globals.css` so the two clients stay
/// visually consistent and a change to one is obviously a change to the other.
///
/// **The hard rule, carried over from BUILD_SPEC 5.1: no colour may imply clinical
/// reassurance.** There is deliberately no green and no red in this file, and none may be
/// added for a physiological value. A deviation is differentiated by *form* — weight, a rule,
/// wording — never by hue. Warning treatment is reserved for *system* states: a rejected
/// session, a stale calibration, an unqualified device.
///
/// **Surface hierarchy.** Mint is the ground, not an accent:
///
///     page          surface   mint
///     panel         paper     white, so a card reads as a card
///     primary       brand     app bar and primary actions
///     body text     ink
///     secondary     muted and its tints; borders; the system-flag rule
///
/// **The measurement that shapes all of it:** a white panel on the mint page is **1.08:1**. Mint
/// and white are near-identical in luminance, so a panel is not a panel because of its fill — it
/// is a panel because of its border. Every white surface on mint carries a visible edge, and that
/// edge must clear 3:1, which is why [TeraColors.ink500] exists.
///
/// Measured WCAG 2.1 ratios, same palette and same script as the web client:
///
///     TEXT                on paper    on mint
///       ink                13.57:1    12.56:1  AAA
///       brand               9.56:1     8.85:1  AAA
///       ink800              8.53:1     7.89:1  AAA  <- small print
///       muted               5.71:1     5.29:1  AA
///       ink700              5.29:1     4.90:1  AA
///       ink500              3.92:1     3.62:1  large text / borders only
///       ink300              1.82:1     1.69:1  decorative only
///       ink200              1.33:1     1.23:1  decorative only
///
///     REVERSED
///       paper on brand      9.56:1  AAA  <- app bar, primary actions
///       paper on ink       13.57:1  AAA
///       ink on muted100    10.89:1  AAA  <- system-flag body text
///
///     NON-TEXT (WCAG 1.4.11 wants 3:1)
///       paper panel vs mint page   1.08:1  <- why borders are mandatory
///       muted border on mint       5.29:1
///       ink500 border on mint      3.62:1  (on paper 3.92:1)
///       ink200 border on mint      1.23:1  decoration inside a panel only
library;

import 'package:flutter/material.dart';

abstract final class TeraColors {
  static const ink = Color(0xFF12304A);
  static const brand = Color(0xFF114B5F);
  static const muted = Color(0xFF456990);
  static const surface = Color(0xFFE4FDE1);

  /// White as a token rather than a literal, so "what is a panel" is answerable in one place.
  static const paper = Color(0xFFFFFFFF);

  /// Neutral ramp mixed from [ink] toward white. ink800 and ink700 are safe for text; ink500 is
  /// the panel edge and clears 3:1 on both grounds; ink300 and lighter are decoration inside a
  /// panel and must never be the only signal for a state, nor a panel edge on mint.
  static const ink800 = Color(0xFF364F65);
  static const ink700 = Color(0xFF596E80);
  static const ink500 = Color(0xFF718392);
  static const ink300 = Color(0xFFB8C1C9);
  static const ink200 = Color(0xFFDBE0E4);
  static const ink100 = Color(0xFFF1F3F4);

  /// A tint of [muted] for the system-flag fill. At 1.25:1 against paper it is a hint, not a
  /// signal — the left rule carries the meaning, because no fill this pale can.
  static const muted100 = Color(0xFFE1E7ED);
}

abstract final class TeraSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
}

/// The app theme. One typeface, hierarchy by weight and size, generous whitespace, hairline
/// borders, no gradients and no heavy shadows — a health application, not a consumer one.
ThemeData buildTeraTheme() {
  return ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: TeraColors.surface,
    colorScheme: ColorScheme.fromSeed(
      seedColor: TeraColors.brand,
      primary: TeraColors.brand,
      secondary: TeraColors.muted,
      surface: TeraColors.paper,
      brightness: Brightness.light,
    ),
    // Brand, not ink: the app bar is the primary surface and brand is the primary colour.
    // Paper on brand measures 9.56:1.
    appBarTheme: const AppBarTheme(
      backgroundColor: TeraColors.brand,
      foregroundColor: TeraColors.paper,
      elevation: 0,
      centerTitle: false,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: TeraColors.brand,
        foregroundColor: TeraColors.paper,
        shape: const RoundedRectangleBorder(),
        padding: const EdgeInsets.symmetric(horizontal: TeraSpacing.lg, vertical: TeraSpacing.md),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: TeraColors.brand,
        side: const BorderSide(color: TeraColors.brand),
        shape: const RoundedRectangleBorder(),
        padding: const EdgeInsets.symmetric(horizontal: TeraSpacing.md, vertical: 14),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: TeraColors.paper,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: TeraColors.muted),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: TeraColors.muted),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: TeraColors.brand, width: 2),
      ),
      labelStyle: TextStyle(color: TeraColors.ink),
    ),
    dividerTheme: const DividerThemeData(color: TeraColors.ink200, thickness: 1, space: 1),
  );
}

/// System-state emphasis: a rule in the secondary tone on a pale ground.
///
/// The equivalent of `.system-flag` in the web client. Used for a rejected session, an
/// unqualified device, a failed sign-in — never for a physiological value.
///
/// The rule is [TeraColors.muted] because it is the thing doing the work; the fill is a tint at
/// 1.25:1, deliberately too pale to be asked to carry meaning.
BoxDecoration systemFlagDecoration() => const BoxDecoration(
  color: TeraColors.muted100,
  border: Border(left: BorderSide(color: TeraColors.muted, width: 3)),
);

/// A white card on the mint page. The equivalent of `.panel` in the web client.
///
/// The border is not decoration: paper on mint is 1.08:1, so without an edge a panel has no
/// boundary at all. [TeraColors.ink500] clears 3:1 on both grounds; ink200 does not.
BoxDecoration panelDecoration() => BoxDecoration(
  color: TeraColors.paper,
  border: Border.all(color: TeraColors.ink500),
);
