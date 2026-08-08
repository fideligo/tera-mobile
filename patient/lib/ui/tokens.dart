/// Design tokens, named to match `tera-web/dashboard/app/globals.css` so the two clients stay
/// visually consistent and a change to one is obviously a change to the other.
///
/// **The hard rule, carried over from BUILD_SPEC 5.1: no colour may imply clinical
/// reassurance.** There is deliberately no green and no red in this file, and none may be
/// added for a physiological value. A deviation is differentiated by *form* — weight, a rule,
/// wording — never by hue. Warning treatment is reserved for *system* states: a rejected
/// session, a stale calibration, an unqualified device.
///
/// Measured WCAG contrast ratios, computed against the same palette as the web client:
///
///     ink      on white     13.57:1  AAA
///     ink      on surface   12.56:1  AAA
///     brand    on white      9.56:1  AAA
///     brand    on surface    8.85:1  AAA
///     white    on brand      9.56:1  AAA   <- primary action
///     muted    on white      5.71:1  AA
///     muted    on surface    5.29:1  AA
///     ink800   on surface    7.89:1  AAA   <- small print
///     ink300, ink200                       decorative only, never text
library;

import 'package:flutter/material.dart';

abstract final class TeraColors {
  static const ink = Color(0xFF12304A);
  static const brand = Color(0xFF114B5F);
  static const muted = Color(0xFF456990);
  static const surface = Color(0xFFE4FDE1);

  /// Neutral ramp mixed from [ink] toward white. ink800 and ink700 are safe for text;
  /// ink300 and lighter are decoration and must never be the only signal for a state.
  static const ink800 = Color(0xFF364F65);
  static const ink700 = Color(0xFF596E80);
  static const ink300 = Color(0xFFB8C1C9);
  static const ink200 = Color(0xFFDBE0E4);
  static const ink100 = Color(0xFFF1F3F4);
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
      surface: Colors.white,
      brightness: Brightness.light,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: TeraColors.ink,
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: false,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: TeraColors.brand,
        foregroundColor: Colors.white,
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
      fillColor: Colors.white,
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

/// System-state emphasis: a heavier ink rule on a pale ground.
///
/// The equivalent of `.system-flag` in the web client. Used for a rejected session, an
/// unqualified device, a failed sign-in — never for a physiological value.
BoxDecoration systemFlagDecoration() => const BoxDecoration(
  color: TeraColors.ink100,
  border: Border(left: BorderSide(color: TeraColors.ink, width: 3)),
);
