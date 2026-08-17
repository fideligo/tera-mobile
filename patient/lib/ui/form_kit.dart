/// The form vocabulary shared by auth and onboarding.
///
/// Built from the Figma frames (`Login.png`, `about you.png`, `Measurement Safety.png`,
/// `Health Context.png`). The auth frames are hi-fi and are followed closely; the onboarding
/// frames are lo-fi wireframes — text and a `next →` — so those screens borrow this vocabulary
/// rather than inventing a second one.
///
/// # The required marker is plum, not red
///
/// Every Figma frame marks required fields with a red asterisk. Red is absent from this palette
/// by design and may not be added (working root `CLAUDE.md`, standing constraint 5). The nearest
/// honest token is [TeraColors.plum], which is reserved for **system** state — and a form saying
/// "I will not accept this without an answer" is exactly that. It is never used for anything
/// physiological.
library;

import 'package:flutter/material.dart';

import 'flow_stub_screen.dart';
import 'tokens.dart';

/// A field label with the design's asterisk.
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key, this.required = false});

  final String text;
  final bool required;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: TeraSpacing.sm),
    child: Text.rich(
      TextSpan(
        text: text,
        style: const TextStyle(
          fontSize: TeraText.small,
          fontWeight: FontWeight.w600,
          color: TeraColors.ink,
        ),
        children: [
          if (required)
            const TextSpan(
              text: ' *',
              style: TextStyle(
                color: TeraColors.plum,
                fontWeight: FontWeight.w700,
              ),
            ),
        ],
      ),
    ),
  );
}

/// A question heading on an onboarding screen.
///
/// The lo-fi frames put the question in bold at body-plus size with the asterisk inline, which is
/// what this reproduces. Larger than a [FieldLabel] because on those screens the question *is* the
/// content, not a caption above a control.
class QuestionHeading extends StatelessWidget {
  const QuestionHeading(
    this.text, {
    super.key,
    this.required = false,
    this.hint,
  });

  final String text;
  final bool required;

  /// Supporting line under the question. Body size and [TeraColors.neutral700] — never a lighter
  /// step at a smaller size, per the persona note in `tokens.dart`.
  final String? hint;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text.rich(
        TextSpan(
          text: text,
          style: const TextStyle(
            fontSize: TeraText.section,
            fontWeight: FontWeight.w700,
            color: TeraColors.ink,
            height: 1.3,
          ),
          children: [
            if (required)
              const TextSpan(
                text: ' *',
                style: TextStyle(
                  color: TeraColors.plum,
                  fontWeight: FontWeight.w700,
                ),
              ),
          ],
        ),
      ),
      if (hint != null) ...[
        const SizedBox(height: TeraSpacing.xs),
        Text(
          hint!,
          style: const TextStyle(
            fontSize: TeraText.small,
            color: TeraColors.neutral700,
            height: 1.4,
          ),
        ),
      ],
    ],
  );
}

/// A tappable answer row: radio or checkbox, label, whole row is the target.
///
/// `RadioListTile` and `CheckboxListTile` were the obvious choice and are not used, for one
/// reason: their default 40dp visual density and inset leave a 48dp row that *looks* like a 32dp
/// one, and the persona is tapping this in poor light. This is a plain [InkWell] over a bordered
/// container with an explicit 56dp minimum, which also lets the selected state be a border and a
/// tint rather than a coloured control alone.
class AnswerOption extends StatelessWidget {
  const AnswerOption({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.multi = false,
    this.enabled = true,
    this.detail,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Checkbox glyph instead of a radio dot. Purely the affordance — a multi-select row behaves
  /// the same way.
  final bool multi;

  final bool enabled;

  /// Second line, for options that need a word of qualification.
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final border = selected ? TeraColors.brand : TeraColors.neutral300;

    return Padding(
      padding: const EdgeInsets.only(bottom: TeraSpacing.sm),
      child: Material(
        color: selected ? TeraColors.mint : TeraColors.paper,
        borderRadius: TeraRadius.fieldBorder,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: TeraRadius.fieldBorder,
          child: Container(
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsets.symmetric(
              horizontal: TeraSpacing.md,
              vertical: TeraSpacing.sm + 2,
            ),
            decoration: BoxDecoration(
              borderRadius: TeraRadius.fieldBorder,
              border: Border.all(color: border, width: selected ? 2 : 1),
            ),
            child: Row(
              children: [
                _Glyph(selected: selected, multi: multi, enabled: enabled),
                const SizedBox(width: TeraSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: TeraText.body,
                          height: 1.3,
                          color: enabled
                              ? TeraColors.ink
                              : TeraColors.neutral500,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                      if (detail != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          detail!,
                          style: const TextStyle(
                            fontSize: TeraText.small,
                            color: TeraColors.neutral700,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Glyph extends StatelessWidget {
  const _Glyph({
    required this.selected,
    required this.multi,
    required this.enabled,
  });

  final bool selected;
  final bool multi;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colour = !enabled
        ? TeraColors.neutral400
        : (selected ? TeraColors.brand : TeraColors.neutral500);

    return SizedBox(
      width: 24,
      height: 24,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: multi ? BoxShape.rectangle : BoxShape.circle,
          borderRadius: multi ? BorderRadius.circular(6) : null,
          border: Border.all(color: colour, width: 2),
          color: selected ? colour : Colors.transparent,
        ),
        child: selected
            ? const Icon(Icons.check, size: 16, color: TeraColors.paper)
            : const SizedBox.shrink(),
      ),
    );
  }
}

/// The bottom action bar on an onboarding step: `next →`, and an optional back.
///
/// Pinned rather than scrolled with the form. On a long question list a button that scrolls out
/// of reach is a button people hunt for.
class StepActions extends StatelessWidget {
  const StepActions({
    super.key,
    required this.onNext,
    this.nextLabel = 'Next',
    this.busy = false,
    this.onBack,
    this.note,
  });

  final VoidCallback? onNext;
  final String nextLabel;
  final bool busy;
  final VoidCallback? onBack;

  /// A line above the button — used by ONB-01 to state that no BMI is computed.
  final String? note;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(
      TeraSpacing.lg,
      TeraSpacing.md,
      TeraSpacing.lg,
      TeraSpacing.lg,
    ),
    decoration: const BoxDecoration(
      color: TeraColors.paper,
      border: Border(top: BorderSide(color: TeraColors.neutral200)),
    ),
    child: SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (note != null) ...[
            Text(
              note!,
              style: const TextStyle(
                fontSize: TeraText.small,
                color: TeraColors.neutral700,
                height: 1.4,
              ),
            ),
            const SizedBox(height: TeraSpacing.md),
          ],
          FilledButton(
            onPressed: busy ? null : onNext,
            style: FilledButton.styleFrom(
              backgroundColor: TeraColors.ink,
              foregroundColor: TeraColors.paper,
              disabledBackgroundColor: TeraColors.neutral300,
              disabledForegroundColor: TeraColors.neutral700,
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
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(nextLabel),
                      const SizedBox(width: TeraSpacing.sm),
                      const Icon(Icons.arrow_forward, size: 20),
                    ],
                  ),
          ),
          if (onBack != null) ...[
            const SizedBox(height: TeraSpacing.sm),
            TextButton(
              onPressed: busy ? null : onBack,
              style: TextButton.styleFrom(
                foregroundColor: TeraColors.baltic,
                minimumSize: const Size.fromHeight(48),
              ),
              child: const Text('Back'),
            ),
          ],
        ],
      ),
    ),
  );
}

/// Progress through a numbered sequence of steps.
///
/// Section 7 is three screens and the patient should be able to see that it is three, not an
/// unbounded queue of health questions. Filled segments rather than a bar with a percentage: the
/// count is the reassuring part.
class StepProgress extends StatelessWidget {
  const StepProgress({super.key, required this.step, required this.total});

  /// 1-based.
  final int step;
  final int total;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Step $step of $total',
    child: Row(
      children: [
        for (var i = 1; i <= total; i++) ...[
          Expanded(
            child: Container(
              height: 6,
              decoration: BoxDecoration(
                color: i <= step ? TeraColors.brand : TeraColors.neutral200,
                borderRadius: BorderRadius.circular(TeraRadius.pill),
              ),
            ),
          ),
          if (i < total) const SizedBox(width: TeraSpacing.sm),
        ],
      ],
    ),
  );
}

/// The scaffold every onboarding step sits in: progress, title, scrolling body, pinned actions.
class OnboardingStepScaffold extends StatelessWidget {
  const OnboardingStepScaffold({
    super.key,
    required this.specId,
    required this.step,
    required this.title,
    required this.children,
    required this.actions,
    this.subtitle,
  });

  /// Traceability, carried as a [Key] rather than shown.
  ///
  /// It used to be the app-bar title, which meant a patient partway through onboarding read
  /// "ONB-01" above their own date of birth. `app_router_test.dart` finds the screen through
  /// [screenKey] now, so the identifier still tells one route from another without being copy.
  final String specId;

  final int step;
  final String title;
  final String? subtitle;
  final List<Widget> children;
  final Widget actions;

  static const totalSteps = 3;

  @override
  Widget build(BuildContext context) => Scaffold(
    key: screenKey(specId),
    backgroundColor: TeraColors.page,
    // The step counter, not the section id. It is the one thing a person partway through a
    // three-screen setup actually wants from a title bar.
    appBar: AppBar(title: Text('Step $step of $totalSteps')),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            TeraSpacing.lg,
            TeraSpacing.lg,
            TeraSpacing.lg,
            0,
          ),
          child: StepProgress(step: step, total: totalSteps),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(TeraSpacing.lg),
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: TeraText.display,
                  fontWeight: FontWeight.w700,
                  color: TeraColors.ink,
                  height: 1.2,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: TeraSpacing.sm),
                Text(
                  subtitle!,
                  style: const TextStyle(
                    fontSize: TeraText.body,
                    color: TeraColors.neutral700,
                    height: 1.45,
                  ),
                ),
              ],
              const SizedBox(height: TeraSpacing.xl),
              ...children,
              const SizedBox(height: TeraSpacing.xl),
            ],
          ),
        ),
        actions,
      ],
    ),
  );
}

/// The form's own refusal, in the system-state treatment.
class FormErrorPanel extends StatelessWidget {
  const FormErrorPanel({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    decoration: systemFlagDecoration(),
    padding: const EdgeInsets.all(TeraSpacing.md),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.error_outline, size: 20, color: TeraColors.plum),
        const SizedBox(width: TeraSpacing.sm),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(
              fontSize: TeraText.small,
              color: TeraColors.ink,
              height: 1.4,
            ),
          ),
        ),
      ],
    ),
  );
}
