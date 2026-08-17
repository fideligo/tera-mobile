/// Design tokens, named to match `tera-web/dashboard/app/globals.css` so the two clients stay
/// visually consistent and a change to one is obviously a change to the other.
///
/// # Brand carries meaning, neutrals carry structure
///
/// The five brand colours are for components and meaning. The neutral scale does the structural
/// work. Two earlier attempts treated the brand set as a complete palette and tried to build
/// structure out of it; the second flooded every screen with Frosted Mint and read as a pastel
/// consumer app.
///
///     page          neutral50   the ground
///     panel         paper       white
///     body text     ink         Deep Space Blue
///     primary       brand       Dark Teal — app bar, primary actions
///     secondary     baltic      Baltic Blue — links, secondary emphasis
///     accent        mint        Frosted Mint — SPARING. One element, never a ground.
///     system state  plum        Wine Plum — NEVER physiological
///
/// **The hard rule: no colour may imply clinical reassurance or alarm.** There is no
/// green-for-good and no red-for-bad, and none may be added. [TeraColors.plum] is the sharpest
/// test of that rule rather than an exception to it: it marks what the *system* did — a capture
/// it could not use, a form it could not accept, an API it could not reach. A deviation is
/// physiological and is differentiated by **form only**: weight, a rule, a textual label. If plum
/// is reaching for a trend or a reading, the guardrail is firing.
///
/// # Who this app is for
///
/// The persona is a 52-year-old with hypertension, holding a phone against their sternum, often
/// in poor light. So the type is a step larger than the web client throughout, touch targets are
/// at least 48dp, and there is **no small grey text on a light ground** — supporting text is
/// [TeraColors.neutral700] at body size, never a lighter step at a smaller one.
///
/// # Measured WCAG 2.1 ratios
///
/// Computed by `tera-web/dashboard/scripts/contrast.py`, the same script as the web client, so
/// the two cannot drift apart silently. None estimated.
///
///     TEXT           on paper   on page
///       ink           13.57:1   12.76:1  AAA  body and headings
///       plum          10.66:1   10.02:1  AAA
///       neutral900    10.63:1   10.00:1  AAA
///       brand          9.56:1    9.00:1  AAA
///       baltic         5.71:1    5.37:1  AA   links, secondary
///       neutral700     5.62:1    5.29:1  AA   supporting text
///       neutral500     3.70:1    3.48:1  borders that carry meaning
///       neutral300     1.60:1    1.51:1  structural edges only
///
///     REVERSED
///       paper on brand   9.56:1  AAA  app bar, primary actions
///       paper on ink    13.57:1  AAA
///       paper on plum   10.66:1  AAA
///
///     SURFACES
///       paper panel on page   1.06:1  <- why panels always carry a border
///       mint on paper         1.08:1  <- same, for the accent
library;

import 'package:flutter/material.dart';

abstract final class TeraColors {
  // Brand. Five colours, each with one job.
  static const ink = Color(0xFF12304A);
  static const brand = Color(0xFF114B5F);
  static const baltic = Color(0xFF456990);
  static const mint = Color(0xFFE4FDE1);
  static const plum = Color(0xFF6B2737);

  // Surfaces.
  static const paper = Color(0xFFFFFFFF);
  static const page = Color(0xFFF7F8F9);

  /// Neutral scale, mixed from [ink] toward white. 900/700 are text-safe; 500 is the darkest
  /// border and clears 3:1; 400 and lighter are decoration and fills, never the only signal for
  /// a state.
  static const neutral900 = Color(0xFF254158);
  static const neutral700 = Color(0xFF546A7D);
  static const neutral500 = Color(0xFF768796);
  static const neutral400 = Color(0xFF9BA8B3);
  static const neutral300 = Color(0xFFC6CDD4);
  static const neutral200 = Color(0xFFDEE2E6);
  static const neutral100 = Color(0xFFEEF1F2);
  static const neutral50 = Color(0xFFF7F8F9);
}

/// The type scale. A step larger than the web client throughout — see the persona note above.
abstract final class TeraText {
  static const display = 30.0;
  static const section = 21.0;
  static const body = 17.0;
  static const small = 15.0;
  static const micro = 12.0;
}

abstract final class TeraSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
  static const xxl = 48.0;
}

/// Corner radii, from the hi-fi designs.
///
/// The first version of this file used square corners throughout — a deliberate choice at the
/// time, made before there were designs to work from. The Figma frames for Login and the device
/// check are unambiguously rounded, so the radii are tokens now rather than an argument. Squared
/// corners survive nowhere except where a design shows them.
abstract final class TeraRadius {
  /// Inputs and small controls.
  static const field = 10.0;

  /// Primary buttons.
  static const button = 12.0;

  /// The panel a form sits on.
  static const card = 20.0;

  /// Pills, chips and progress tracks.
  static const pill = 999.0;

  static BorderRadius get fieldBorder => BorderRadius.circular(field);
  static BorderRadius get buttonBorder => BorderRadius.circular(button);
  static BorderRadius get cardBorder => BorderRadius.circular(card);
}

/// The app theme. One typeface, hierarchy by weight and size, generous whitespace, hairline
/// borders, no gradients and no heavy shadows — a health application, not a consumer one.
ThemeData buildTeraTheme() {
  return ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: TeraColors.page,
    colorScheme: ColorScheme.fromSeed(
      seedColor: TeraColors.brand,
      primary: TeraColors.brand,
      secondary: TeraColors.baltic,
      surface: TeraColors.paper,
      error: TeraColors.plum,
      brightness: Brightness.light,
    ),
    // **White, not brand.** This was a brand-filled bar, on the reasoning that the app bar is the
    // primary surface. In practice almost every screen overrode it back to paper, which is the
    // clearest signal a default is wrong — and a teal band across the top of every screen fights
    // the sterile, white-dominant feel the product is going for. Brand now earns its place on the
    // things a patient acts on: primary buttons, active states, icons.
    //
    // Ink on paper measures 13.57:1.
    appBarTheme: const AppBarTheme(
      backgroundColor: TeraColors.paper,
      foregroundColor: TeraColors.ink,
      surfaceTintColor: TeraColors.paper,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: TeraText.section,
        fontWeight: FontWeight.w700,
        color: TeraColors.ink,
      ),
      iconTheme: IconThemeData(color: TeraColors.ink),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: TeraColors.brand,
        foregroundColor: TeraColors.paper,
        shape: RoundedRectangleBorder(borderRadius: TeraRadius.buttonBorder),
        padding: const EdgeInsets.symmetric(
          horizontal: TeraSpacing.lg,
          vertical: TeraSpacing.md,
        ),
        textStyle: const TextStyle(
          fontSize: TeraText.body,
          fontWeight: FontWeight.w600,
        ),
        // 48dp minimum touch target; the persona is not a designer with a trackpad.
        minimumSize: const Size.fromHeight(52),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: TeraColors.brand,
        side: const BorderSide(color: TeraColors.brand),
        shape: RoundedRectangleBorder(borderRadius: TeraRadius.buttonBorder),
        padding: const EdgeInsets.symmetric(
          horizontal: TeraSpacing.md,
          vertical: 14,
        ),
        minimumSize: const Size.fromHeight(52),
        textStyle: const TextStyle(
          fontSize: TeraText.body,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: TeraColors.paper,
      border: OutlineInputBorder(
        borderRadius: TeraRadius.fieldBorder,
        borderSide: const BorderSide(color: TeraColors.neutral500),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: TeraRadius.fieldBorder,
        borderSide: const BorderSide(color: TeraColors.neutral500),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: TeraRadius.fieldBorder,
        borderSide: const BorderSide(color: TeraColors.brand, width: 2),
      ),
      labelStyle: const TextStyle(color: TeraColors.ink),
    ),
    dividerTheme: const DividerThemeData(
      color: TeraColors.neutral200,
      thickness: 1,
      space: 1,
    ),
    // The scale, so a widget that asks for `titleLarge` gets the product's answer rather than
    // Material's. Every screen that hand-rolled a TextStyle was doing so because this was one
    // entry long, and hand-rolled styles are how six different heading sizes ended up shipping.
    //
    // Ink for anything a patient reads as content; neutral700 for supporting text, never a
    // lighter step at a smaller size (see the persona note above).
    textTheme: const TextTheme(
      displaySmall: TextStyle(
        fontSize: TeraText.display,
        fontWeight: FontWeight.w700,
        color: TeraColors.ink,
        height: 1.2,
      ),
      headlineSmall: TextStyle(
        fontSize: TeraText.section,
        fontWeight: FontWeight.w700,
        color: TeraColors.ink,
        height: 1.3,
      ),
      titleLarge: TextStyle(
        fontSize: TeraText.section,
        fontWeight: FontWeight.w700,
        color: TeraColors.ink,
        height: 1.3,
      ),
      titleMedium: TextStyle(
        fontSize: TeraText.body,
        fontWeight: FontWeight.w600,
        color: TeraColors.ink,
        height: 1.4,
      ),
      bodyLarge: TextStyle(
        fontSize: TeraText.body,
        color: TeraColors.ink,
        height: 1.5,
      ),
      bodyMedium: TextStyle(
        fontSize: TeraText.body,
        color: TeraColors.ink,
        height: 1.5,
      ),
      bodySmall: TextStyle(
        fontSize: TeraText.small,
        color: TeraColors.neutral700,
        height: 1.45,
      ),
      labelSmall: TextStyle(
        fontSize: TeraText.micro,
        color: TeraColors.neutral700,
        height: 1.4,
      ),
    ),

    // Secondary actions. Baltic rather than brand, so a screen with two buttons reads as one
    // primary and one alternative instead of two equal choices.
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: TeraColors.baltic,
        padding: const EdgeInsets.symmetric(
          horizontal: TeraSpacing.md,
          vertical: TeraSpacing.sm,
        ),
        shape: RoundedRectangleBorder(borderRadius: TeraRadius.buttonBorder),
        textStyle: const TextStyle(
          fontSize: TeraText.body,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),

    cardTheme: CardThemeData(
      color: TeraColors.paper,
      surfaceTintColor: TeraColors.paper,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: TeraRadius.cardBorder,
        // Paper on page is 1.06:1, so a card without an edge is not a card.
        side: const BorderSide(color: TeraColors.neutral200),
      ),
    ),

    // Dialogs are where an error or a consent question is put to a patient, so they get the same
    // radius and the same ink as everything else rather than Material's defaults.
    dialogTheme: DialogThemeData(
      backgroundColor: TeraColors.paper,
      surfaceTintColor: TeraColors.paper,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: TeraRadius.cardBorder),
      titleTextStyle: const TextStyle(
        fontSize: TeraText.section,
        fontWeight: FontWeight.w700,
        color: TeraColors.ink,
      ),
      contentTextStyle: const TextStyle(
        fontSize: TeraText.body,
        color: TeraColors.ink,
        height: 1.45,
      ),
    ),

    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: TeraColors.paper,
      surfaceTintColor: TeraColors.paper,
      elevation: 0,
      showDragHandle: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(TeraRadius.card)),
      ),
    ),

    snackBarTheme: SnackBarThemeData(
      backgroundColor: TeraColors.ink,
      contentTextStyle: const TextStyle(
        fontSize: TeraText.small,
        color: TeraColors.paper,
      ),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: TeraRadius.buttonBorder),
    ),

    // Brand is the active state. There is deliberately no green here: `switch on` is a setting the
    // patient chose, not a clinical outcome, and the palette has no green-for-good to reach for.
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? TeraColors.paper
            : TeraColors.neutral500,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? TeraColors.brand
            : TeraColors.neutral200,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? TeraColors.brand
            : TeraColors.neutral300,
      ),
    ),

    chipTheme: ChipThemeData(
      backgroundColor: TeraColors.paper,
      selectedColor: TeraColors.brand,
      side: const BorderSide(color: TeraColors.neutral300),
      shape: const StadiumBorder(),
      labelStyle: const TextStyle(
        fontSize: TeraText.small,
        fontWeight: FontWeight.w600,
        color: TeraColors.ink,
      ),
      secondaryLabelStyle: const TextStyle(
        fontSize: TeraText.small,
        fontWeight: FontWeight.w600,
        color: TeraColors.paper,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: TeraSpacing.md,
        vertical: TeraSpacing.sm,
      ),
    ),

    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: TeraColors.brand,
      linearTrackColor: TeraColors.neutral200,
      circularTrackColor: TeraColors.neutral200,
    ),

    listTileTheme: const ListTileThemeData(
      iconColor: TeraColors.brand,
      textColor: TeraColors.ink,
      contentPadding: EdgeInsets.symmetric(horizontal: TeraSpacing.md),
    ),

    // Main icons, per the brand direction. Anything that needs to recede asks for neutral700.
    iconTheme: const IconThemeData(color: TeraColors.brand),
  );
}

/// System state: a Wine Plum rule on a pale ground.
///
/// The equivalent of `.system-flag` in the web client. A rejected session, an unqualified
/// handset, a failed sign-in, an unreachable API — things the **system** did.
///
/// **Never for a physiological value.** A deviation uses [attentionDecoration] instead, which has
/// no hue at all. This is the one place the temptation to reach for an alarm colour is strongest.
///
/// The rule carries the meaning; the fill is a tint deliberately too pale to be asked to.
BoxDecoration systemFlagDecoration() => const BoxDecoration(
  color: TeraColors.neutral100,
  border: Border(left: BorderSide(color: TeraColors.plum, width: 3)),
);

/// A white card on the page ground. The equivalent of `.panel` in the web client.
///
/// The border is not decoration: paper on page is 1.06:1, so without an edge there is no card.
/// It is *structural* rather than semantic — nothing about a record's state depends on seeing it
/// — so neutral300 is right and the 3:1 rule does not apply to it.
BoxDecoration panelDecoration() => BoxDecoration(
  color: TeraColors.paper,
  border: Border.all(color: TeraColors.neutral300),
);

/// Needs the patient's eye, but describes the patient rather than the system.
///
/// The counterpart to [systemFlagDecoration]. No hue: weight and an ink rule carry it. Using plum
/// here would make the interface state a clinical judgement it is not entitled to make.
BoxDecoration attentionDecoration() => const BoxDecoration(
  color: TeraColors.neutral100,
  border: Border(left: BorderSide(color: TeraColors.ink, width: 3)),
);

/// The one sparing use of Frosted Mint: a single highlighted element, never a ground.
///
/// Bordered because mint on paper is 1.08:1 and does not separate on its own.
BoxDecoration accentDecoration() => BoxDecoration(
  color: TeraColors.mint,
  border: Border.all(color: TeraColors.neutral300),
);

/// Something the **system** completed: a reading saved, a profile updated, a report built.
///
/// Mint, and bordered for the same 1.08:1 reason as [accentDecoration].
///
/// **Never a physiological verdict.** This is the exact place the green-for-good instinct bites: a
/// "your reading is fine" panel in a soft green is a clinical reassurance rendered as a colour, and
/// the hard rule at the top of this file forbids it. A saved cuff reading is a *system* success and
/// may use this. A stable trend is not, and uses form — weight and a rule — instead.
BoxDecoration confirmationDecoration() => BoxDecoration(
  color: TeraColors.mint,
  border: Border.all(color: TeraColors.neutral300),
  borderRadius: TeraRadius.cardBorder,
);
