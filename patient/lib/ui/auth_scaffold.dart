/// The chrome shared by sign-in and sign-up.
///
/// The two screens are the same page with different fields, so they are the same widget with
/// different children. Keeping the wordmark, the panel, the error treatment and the primary
/// button in one place is what stops them drifting into two designs — which is exactly what had
/// happened: one was a form, the other was a line of placeholder text.
///
/// # Colour
///
/// Everything here goes through [TeraColors]; no component carries a raw hex (working root
/// `CLAUDE.md`, standing constraint 5). A failed sign-in or a refused sign-up is a **system**
/// state, so it gets [systemFlagDecoration] — the plum rule on a pale ground — and never a red
/// fill. Nothing on these screens is physiological, so nothing here is differentiated by hue.
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import 'form_kit.dart';
import 'tokens.dart';

/// The page: wordmark, heading, a bordered panel holding the form, and a footer link.
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
    this.footer,
  });

  final String title;
  final String subtitle;

  /// The form fields, error panel and primary action, in order.
  final List<Widget> children;

  /// The "switch to the other screen" line. Null on a screen with nowhere to switch to.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: TeraSpacing.lg,
              vertical: TeraSpacing.xl,
            ),
            child: ConstrainedBox(
              // The persona holds a phone, but a tablet or a foldable should not stretch a form
              // across a hand's width of empty page.
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _Wordmark(),
                  const SizedBox(height: TeraSpacing.xl),
                  Container(
                    // The Figma frame is a rounded card on a near-white page, lifted by a soft
                    // shadow. Card and page differ by 1.06:1, so it needs *something* to separate
                    // it — but not a shadow: a 24px-blur `BoxShadow` here segfaults the Flutter
                    // rasterizer on the x86_64 emulator (SIGSEGV in the raster thread, native, no
                    // Dart frame) the moment the keyboard animates over it. A hairline border
                    // reads almost identically, matches every other panel in the app, and cannot
                    // take the demo down.
                    decoration: BoxDecoration(
                      color: TeraColors.paper,
                      borderRadius: TeraRadius.cardBorder,
                      border: Border.all(color: TeraColors.neutral200),
                    ),
                    padding: const EdgeInsets.all(TeraSpacing.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: TeraText.section,
                            fontWeight: FontWeight.w700,
                            color: TeraColors.ink,
                          ),
                        ),
                        const SizedBox(height: TeraSpacing.xs),
                        Text(
                          subtitle,
                          style: const TextStyle(
                            fontSize: TeraText.small,
                            color: TeraColors.neutral700,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: TeraSpacing.lg),
                        ...children,
                      ],
                    ),
                  ),
                  if (footer != null) ...[
                    const SizedBox(height: TeraSpacing.lg),
                    footer!,
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) => const Column(
    children: [
      Text(
        'Tera',
        style: TextStyle(
          fontSize: TeraText.display,
          fontWeight: FontWeight.w600,
          color: TeraColors.brand,
          letterSpacing: 1.5,
        ),
      ),
      SizedBox(height: TeraSpacing.xs),
      Text(
        'Home blood-pressure monitoring',
        style: TextStyle(
          fontSize: TeraText.small,
          color: TeraColors.neutral700,
        ),
      ),
    ],
  );
}

/// A form field, sized and spaced for the persona: body-size text, a 48dp-plus target, and a
/// label that stays visible once the field has content.
/// The key on an [AuthField]'s input, by id. Tests address fields through this.
Key fieldKey(String id) => Key('tera.field.$id');

class AuthField extends StatelessWidget {
  const AuthField({
    super.key,
    required this.id,
    required this.controller,
    required this.label,
    required this.icon,
    required this.validator,
    this.hint,
    this.helper,
    this.keyboardType,
    this.obscureText = false,
    this.enabled = true,
    this.required = true,
    this.textInputAction = TextInputAction.next,
    this.autofillHints,
    this.suffix,
    this.onSubmitted,
  });

  /// A stable handle for this field, independent of the display copy.
  ///
  /// The visible label is the design's and is in Indonesian on these screens; a test that found
  /// a field by reading its label would break the next time a word changed. This is what
  /// [fieldKey] is built from.
  final String id;

  final TextEditingController controller;
  final String label;
  final IconData icon;
  final String? Function(String?) validator;

  /// Placeholder inside the field. The Figma frame uses these to show the shape of the answer
  /// ("cth: nama@email.com"), which is worth more than repeating the label inside the box.
  final String? hint;

  final String? helper;
  final TextInputType? keyboardType;
  final bool obscureText;
  final bool enabled;

  /// Drives the asterisk only. What is actually enforced is [validator].
  final bool required;

  final TextInputAction textInputAction;
  final Iterable<String>? autofillHints;

  /// Trailing control inside the field — in practice the show/hide password toggle.
  final Widget? suffix;

  final void Function(String)? onSubmitted;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // Label above the box, as the design has it, rather than Material's floating label. On a
      // filled field the floating variant collapses into the border at exactly the moment the
      // patient is typing into it, and this form is read in poor light.
      FieldLabel(label, required: required),
      TextFormField(
        key: fieldKey(id),
        controller: controller,
        enabled: enabled,
        obscureText: obscureText,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        autofillHints: autofillHints,
        autocorrect: false,
        // Nothing on an auth form should be capitalised for the user: an email must not be, and
        // a password must be exactly what was typed.
        enableSuggestions: false,
        style: const TextStyle(fontSize: TeraText.body, color: TeraColors.ink),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(
            color: TeraColors.neutral500,
            fontSize: TeraText.body,
          ),
          helperText: helper,
          helperStyle: const TextStyle(
            fontSize: TeraText.micro,
            color: TeraColors.neutral700,
          ),
          prefixIcon: Icon(icon, color: TeraColors.neutral500),
          suffixIcon: suffix,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: TeraSpacing.md,
            vertical: TeraSpacing.md,
          ),
          // The error rule matches the system-flag rule: this is the form refusing input, which
          // is a system state like any other.
          errorStyle: const TextStyle(
            fontSize: TeraText.micro,
            color: TeraColors.plum,
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: TeraRadius.fieldBorder,
            borderSide: const BorderSide(color: TeraColors.plum),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: TeraRadius.fieldBorder,
            borderSide: const BorderSide(color: TeraColors.plum, width: 2),
          ),
        ),
        validator: validator,
        onFieldSubmitted: onSubmitted,
      ),
    ],
  );
}

/// Show/hide for a password field.
///
/// Not a flourish: the persona is typing a twelve-character password on a phone keyboard, often
/// in poor light, and a field with no way to check what was typed is how three sign-in attempts
/// fail in a row over one wrong character.
class PasswordVisibilityToggle extends StatelessWidget {
  const PasswordVisibilityToggle({
    super.key,
    required this.visible,
    required this.onPressed,
  });

  final bool visible;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onPressed,
    tooltip: visible ? 'Hide password' : 'Show password',
    icon: Icon(
      visible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
      color: TeraColors.neutral500,
    ),
  );
}

/// What the system did, in the treatment reserved for it: a plum rule on a pale ground.
class AuthErrorPanel extends StatelessWidget {
  const AuthErrorPanel({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    decoration: systemFlagDecoration(),
    padding: const EdgeInsets.all(TeraSpacing.md),
    child: Text(
      message,
      style: const TextStyle(
        fontSize: TeraText.small,
        color: TeraColors.ink,
        height: 1.4,
      ),
    ),
  );
}

/// The one decisive action on the page.
///
/// [TeraColors.ink] — Deep Space Blue — rather than the theme's brand teal. It is the palette's
/// darkest surface and paper on ink measures 13.57:1, the highest ratio in the set. It replaces a
/// raw `0xFF001F3F` that had been inlined on the sign-in screen: a navy that was not a token, and
/// therefore not in the palette.
///
/// While busy it stays solid and holds a spinner rather than greying out. A washed-out button
/// under a spinner reads as a screen that has broken, which is the opposite of the message.
class AuthSubmitButton extends StatelessWidget {
  const AuthSubmitButton({
    super.key,
    required this.label,
    required this.busy,
    required this.onPressed,
  });

  final String label;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => FilledButton(
    onPressed: busy ? null : onPressed,
    style: FilledButton.styleFrom(
      backgroundColor: TeraColors.ink,
      foregroundColor: TeraColors.paper,
      disabledBackgroundColor: TeraColors.neutral700,
      disabledForegroundColor: TeraColors.paper,
    ),
    child: busy
        ? const SizedBox(
            height: 22,
            width: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: TeraColors.paper,
            ),
          )
        : Text(label),
  );
}

/// The line that switches to the other auth screen.
class AuthSwitchLink extends StatelessWidget {
  const AuthSwitchLink({
    super.key,
    required this.prompt,
    required this.action,
    required this.onPressed,
  });

  final String prompt;
  final String action;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Text(
        prompt,
        style: const TextStyle(
          fontSize: TeraText.small,
          color: TeraColors.neutral700,
        ),
      ),
      TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: TeraColors.baltic,
          textStyle: const TextStyle(
            fontSize: TeraText.small,
            fontWeight: FontWeight.w600,
          ),
          // A link is still a touch target, and the persona is not aiming carefully.
          minimumSize: const Size(48, 48),
        ),
        child: Text(action),
      ),
    ],
  );
}

/// Show a failure in both channels: the panel, which stays while the patient fixes it, and a
/// snack bar, which is what actually catches the eye.
///
/// Ink rather than plum for the snack bar fill. Plum is the palette's system-state colour and a
/// rejected request qualifies, but a full-bleed plum bar across the bottom of the screen is an
/// alarm, and the palette rule exists to keep alarms out of a health app that is not entitled to
/// raise one.
void showAuthError(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(
            fontSize: TeraText.small,
            color: TeraColors.paper,
          ),
        ),
        backgroundColor: TeraColors.ink,
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(),
        duration: const Duration(seconds: 5),
      ),
    );
}

/// Validators shared by the two screens, so the rules cannot disagree between them.
abstract final class AuthValidators {
  /// Permissive on purpose. The backend accepts any subject of three characters or more, so this
  /// only catches the typo — a missing `@`, a missing dot, a stray space — and does not attempt
  /// to adjudicate which addresses are real.
  static final _email = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  static String? email(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return 'Enter your email address.';
    if (!_email.hasMatch(v))
      return 'Enter a valid email address, for example nama@email.com.';
    return null;
  }

  static String? name(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return 'Enter your name.';
    return null;
  }

  /// Present, and not empty. Deliberately **not** the sign-up rules: an account created before a
  /// rule changed still has to be able to sign in.
  static String? existingPassword(String? value) =>
      (value == null || value.isEmpty) ? 'Enter your password.' : null;

  /// The backend's own bounds, checked here so they are a field error rather than a 422.
  ///
  /// The upper bound is in bytes because bcrypt's is: a password of 72 accented characters is
  /// well over the limit and would be refused by the server with a message about bytes, which is
  /// not a sentence to show a patient.
  static String? newPassword(String? value) {
    final v = value ?? '';
    if (v.isEmpty) return 'Choose a password.';
    if (v.length < minPasswordLength) {
      return 'Use at least $minPasswordLength characters.';
    }
    if (utf8.encode(v).length > maxPasswordBytes) {
      return 'That password is too long. Use something shorter.';
    }
    return null;
  }
}
