/// ONB-01 and ONB-03 — the PHR onboarding forms (PM spec section 7).
///
/// ONB-02 is [SafetyOnboardingScreen] in `safety_onboarding_screen.dart`, because the safety
/// answers it collects feed the contraindication gate and belong next to it.
///
/// # Minimum viable PHR, not a health intake
///
/// Section 7 is explicit: onboarding collects only what safety and basic interpretation need, and
/// enrichment happens progressively in Profile. Three screens, and the [StepProgress] bar says so
/// — a patient should be able to see the end of this from the start of it.
///
/// # Nothing here is interpreted
///
/// Height and weight are stored and **no BMI is computed or shown**, which the spec says
/// directly ("jangan otomatis mendiagnosis berdasarkan BMI") and invariant 6 says generally.
/// A hypertension diagnosis is recorded as something the patient reported, never inferred. The
/// screen says so out loud under ONB-01's fields, because someone will otherwise expect a number.
///
/// # Local first, upload second
///
/// [_advance] writes the handset copy and moves the step **before** the upload, and the upload
/// never blocks. Onboarding has to work on a bad connection: a form that will not advance because
/// a request failed strands a patient at step one of three, with no way past it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../capture/phr_profile.dart';
import '../capture/phr_submitter.dart';
import '../routing/app_flow_state.dart';
import '../routing/app_router.dart';
import '../routing/routes.dart';
import 'form_kit.dart';
import 'tokens.dart';

/// Save locally, advance the step, then upload. In that order, for the reason in the library
/// docstring.
Future<void> advanceOnboarding(
  BuildContext context,
  TeraFlow flow,
  OnboardingStep step,
  PhrProfile profile,
  OnboardingSection section,
) async {
  await flow.completeOnboardingStep(step);
  // Fire and forget by design — `PhrSubmitter.submit` swallows and reports a bool it does not
  // need to wait for. The server copy is what survives an uninstall; the handset copy is what
  // the next screen reads.
  unawaited(PhrSubmitter(api: flow.api).submit(profile, section: section));

  if (!context.mounted) return;
  final next = flow.state.onboardingComplete ? Routes.home : flow.state.onboardingStep.route;
  Navigator.of(context).pushNamedAndRemoveUntil(next, (r) => false);
}

/// ONB-01 — About You. DOB and sex required; height and weight may be skipped.
class AboutYouScreen extends StatefulWidget {
  const AboutYouScreen({super.key, required this.flow, required this.store});

  final TeraFlow flow;
  final PhrProfileStore store;

  @override
  State<AboutYouScreen> createState() => _AboutYouScreenState();
}

class _AboutYouScreenState extends State<AboutYouScreen> {
  final _formKey = GlobalKey<FormState>();
  final _height = TextEditingController();
  final _weight = TextEditingController();

  DateTime? _dob;
  SexAtBirth? _sex;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  /// A patient who backs out and returns should not retype what they already answered.
  Future<void> _restore() async {
    final saved = await widget.store.read();
    if (!mounted) return;
    setState(() {
      _dob = saved.dateOfBirth;
      _sex = saved.sexAtBirth;
      if (saved.heightCm != null) _height.text = _trimZero(saved.heightCm!);
      if (saved.weightKg != null) _weight.text = _trimZero(saved.weightKg!);
    });
  }

  static String _trimZero(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  @override
  void dispose() {
    _height.dispose();
    _weight.dispose();
    super.dispose();
  }

  Future<void> _pickDob() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dob ?? DateTime(now.year - 40),
      firstDate: DateTime(now.year - 120),
      // A birth date cannot be in the future; the picker enforces what the validator also checks.
      lastDate: now,
      helpText: 'Date of birth',
    );
    if (picked != null) setState(() => _dob = picked);
  }

  String? _validateHeight(String? raw) {
    final text = (raw ?? '').trim();
    if (text.isEmpty) return null; // optional
    final value = double.tryParse(text);
    if (value == null) return 'Enter a number, for example 168.';
    if (!PhrProfile.heightIsPlausible(value)) {
      return 'Height should be between ${PhrProfile.minHeightCm.toStringAsFixed(0)} and '
          '${PhrProfile.maxHeightCm.toStringAsFixed(0)} cm.';
    }
    return null;
  }

  String? _validateWeight(String? raw) {
    final text = (raw ?? '').trim();
    if (text.isEmpty) return null; // optional
    final value = double.tryParse(text);
    if (value == null) return 'Enter a number, for example 72.';
    if (!PhrProfile.weightIsPlausible(value)) {
      return 'Weight should be between ${PhrProfile.minWeightKg.toStringAsFixed(0)} and '
          '${PhrProfile.maxWeightKg.toStringAsFixed(0)} kg.';
    }
    return null;
  }

  Future<void> _next() async {
    if (_busy) return;
    setState(() => _error = null);

    // The two required answers are controls rather than fields, so the Form validator does not
    // see them. Checked here, and named individually — "complete the form" is not an instruction.
    if (_dob == null || _sex == null) {
      setState(
        () => _error = _dob == null && _sex == null
            ? 'Add your date of birth and sex assigned at birth to continue.'
            : _dob == null
            ? 'Add your date of birth to continue.'
            : 'Add your sex assigned at birth to continue.',
      );
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (!PhrProfile.dobIsPlausible(_dob!)) {
      setState(() => _error = 'Date of birth cannot be in the future.');
      return;
    }

    setState(() => _busy = true);
    FocusScope.of(context).unfocus();

    final existing = await widget.store.read();
    final saved = existing.copyWith(
      dateOfBirth: _dob,
      sexAtBirth: _sex,
      heightCm: double.tryParse(_height.text.trim()),
      weightKg: double.tryParse(_weight.text.trim()),
    );
    await widget.store.write(saved);

    if (!mounted) return;
    await advanceOnboarding(
      context,
      widget.flow,
      OnboardingStep.aboutYou,
      saved,
      OnboardingSection.aboutYou,
    );
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;

    return Form(
      key: _formKey,
      child: OnboardingStepScaffold(
        specId: 'ONB-01',
        step: 1,
        title: 'About you',
        subtitle: 'Two answers Tera needs, and two it can use if you have them.',
        actions: StepActions(
          onNext: _next,
          busy: _busy,
          // Stated because the spec forbids deriving one, and someone will otherwise expect it.
          note: 'Tera does not calculate a BMI or judge these numbers.',
        ),
        children: [
          const QuestionHeading('What is your date of birth?', required: true),
          const SizedBox(height: TeraSpacing.md),
          _DateField(value: _dob, onTap: _pickDob),
          const SizedBox(height: TeraSpacing.xl),

          const QuestionHeading('What is your sex assigned at birth?', required: true),
          const SizedBox(height: TeraSpacing.md),
          for (final option in SexAtBirth.values)
            AnswerOption(
              label: option.label,
              selected: _sex == option,
              enabled: !_busy,
              onTap: () => setState(() => _sex = option),
            ),
          const SizedBox(height: TeraSpacing.xl),

          const QuestionHeading(
            'What is your height?',
            hint: 'Optional. You can add it later in Profile.',
          ),
          const SizedBox(height: TeraSpacing.md),
          _MeasurementField(
            controller: _height,
            hint: '168',
            unit: 'cm',
            enabled: !_busy,
            validator: _validateHeight,
          ),
          const SizedBox(height: TeraSpacing.xl),

          const QuestionHeading(
            'What is your current weight?',
            hint: 'Optional. You can add it later in Profile.',
          ),
          const SizedBox(height: TeraSpacing.md),
          _MeasurementField(
            controller: _weight,
            hint: '72',
            unit: 'kg',
            enabled: !_busy,
            validator: _validateWeight,
          ),

          if (error != null) ...[
            const SizedBox(height: TeraSpacing.lg),
            FormErrorPanel(message: error),
          ],
        ],
      ),
    );
  }
}

/// A tappable date row. A free-text date field is a validation problem nobody needs.
class _DateField extends StatelessWidget {
  const _DateField({required this.value, required this.onTap});

  final DateTime? value;
  final VoidCallback onTap;

  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  @override
  Widget build(BuildContext context) {
    final chosen = value != null;

    return Material(
      color: TeraColors.paper,
      borderRadius: TeraRadius.fieldBorder,
      child: InkWell(
        onTap: onTap,
        borderRadius: TeraRadius.fieldBorder,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: TeraSpacing.md),
          decoration: BoxDecoration(
            borderRadius: TeraRadius.fieldBorder,
            border: Border.all(
              color: chosen ? TeraColors.brand : TeraColors.neutral500,
              width: chosen ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.calendar_today_outlined, color: TeraColors.neutral500, size: 22),
              const SizedBox(width: TeraSpacing.md),
              Expanded(
                child: Text(
                  chosen
                      ? '${value!.day} ${_months[value!.month - 1]} ${value!.year}'
                      : 'Choose your date of birth',
                  style: TextStyle(
                    fontSize: TeraText.body,
                    color: chosen ? TeraColors.ink : TeraColors.neutral500,
                  ),
                ),
              ),
              const Icon(Icons.expand_more, color: TeraColors.neutral500),
            ],
          ),
        ),
      ),
    );
  }
}

/// A numeric field with its unit shown rather than described.
class _MeasurementField extends StatelessWidget {
  const _MeasurementField({
    required this.controller,
    required this.hint,
    required this.unit,
    required this.validator,
    this.enabled = true,
  });

  final TextEditingController controller;
  final String hint;
  final String unit;
  final String? Function(String?) validator;
  final bool enabled;

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: controller,
    enabled: enabled,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
    style: const TextStyle(fontSize: TeraText.body, color: TeraColors.ink),
    decoration: InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: TeraColors.neutral500),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: TeraSpacing.md,
        vertical: TeraSpacing.md,
      ),
      suffixIcon: Padding(
        padding: const EdgeInsets.only(right: TeraSpacing.md),
        child: Text(
          unit,
          textAlign: TextAlign.right,
          style: const TextStyle(
            fontSize: TeraText.body,
            color: TeraColors.neutral700,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      suffixIconConstraints: const BoxConstraints(minWidth: 56),
      errorStyle: const TextStyle(fontSize: TeraText.micro, color: TeraColors.plum),
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
  );
}

// =========================================================================== ONB-03

/// ONB-03 — Health Context. Two required questions and a multi-select.
class HealthContextScreen extends StatefulWidget {
  const HealthContextScreen({super.key, required this.flow, required this.store});

  final TeraFlow flow;
  final PhrProfileStore store;

  @override
  State<HealthContextScreen> createState() => _HealthContextScreenState();
}

class _HealthContextScreenState extends State<HealthContextScreen> {
  HypertensionStatus? _hypertension;
  MedicationAnswer? _medication;
  final Set<KnownCondition> _conditions = {};

  /// The two exclusive rows from the spec, held separately: neither is a `KnownCondition`,
  /// because "none of these" is not a condition and storing it as one would put a non-diagnosis
  /// into a diagnosis list.
  bool _noConditions = false;
  bool _conditionsNotSure = false;

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final saved = await widget.store.read();
    if (!mounted) return;
    setState(() {
      _hypertension = saved.hypertension;
      _medication = MedicationAnswer.fromStored(saved.takesBpMedication);
      _conditions.addAll(saved.conditions);
    });
  }

  /// Section 7's two rules, in one place.
  ///
  /// "None of these" clears the list, and "Not sure" is mutually exclusive with everything —
  /// otherwise the record says both "I have diabetes" and "I do not know what I have", which is
  /// not an answer anybody can read later.
  void _toggleCondition(KnownCondition condition) => setState(() {
    _noConditions = false;
    _conditionsNotSure = false;
    if (!_conditions.remove(condition)) _conditions.add(condition);
  });

  void _selectNone() => setState(() {
    _conditions.clear();
    _conditionsNotSure = false;
    _noConditions = !_noConditions;
  });

  void _selectNotSure() => setState(() {
    _conditions.clear();
    _noConditions = false;
    _conditionsNotSure = !_conditionsNotSure;
  });

  Future<void> _finish() async {
    if (_busy) return;
    setState(() => _error = null);

    if (_hypertension == null || _medication == null) {
      setState(() => _error = 'Answer both questions above to continue.');
      return;
    }
    // Invariant 7 in miniature: an unanswered condition list is ambiguous, and "no conditions"
    // is a clinically different statement from "not answered". The patient has to say which.
    if (_conditions.isEmpty && !_noConditions && !_conditionsNotSure) {
      setState(
        () => _error =
            'Choose any conditions that apply, or pick "None of these" or "Not sure".',
      );
      return;
    }

    setState(() => _busy = true);

    final existing = await widget.store.read();
    final saved = existing.copyWith(
      hypertension: _hypertension,
      takesBpMedication: _medication!.stored,
      conditions: _conditions,
    );
    await widget.store.write(saved);

    if (!mounted) return;
    await advanceOnboarding(
      context,
      widget.flow,
      OnboardingStep.healthContext,
      saved,
      OnboardingSection.healthContext,
    );
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;

    return OnboardingStepScaffold(
      specId: 'ONB-03',
      step: 3,
      title: 'Health context',
      subtitle:
          'Recorded as what you have told us. Tera does not diagnose and does not advise on '
          'medication.',
      actions: StepActions(onNext: _finish, nextLabel: 'Finish', busy: _busy),
      children: [
        const QuestionHeading(
          'Have you ever been diagnosed with high blood pressure or hypertension?',
          required: true,
        ),
        const SizedBox(height: TeraSpacing.md),
        for (final option in HypertensionStatus.values)
          AnswerOption(
            label: option.label,
            selected: _hypertension == option,
            enabled: !_busy,
            onTap: () => setState(() => _hypertension = option),
          ),
        const SizedBox(height: TeraSpacing.xl),

        const QuestionHeading(
          'Are you currently taking medication for high blood pressure?',
          required: true,
        ),
        const SizedBox(height: TeraSpacing.md),
        for (final option in MedicationAnswer.values)
          AnswerOption(
            label: option.label,
            selected: _medication == option,
            enabled: !_busy,
            onTap: () => setState(() => _medication = option),
          ),
        const SizedBox(height: TeraSpacing.xl),

        const QuestionHeading(
          'Have you been diagnosed with any of these conditions?',
          required: true,
          hint: 'Choose as many as apply.',
        ),
        const SizedBox(height: TeraSpacing.md),
        for (final condition in KnownCondition.values)
          AnswerOption(
            label: condition.label,
            multi: true,
            selected: _conditions.contains(condition),
            // Deliberately *not* disabled while an exclusive row is selected. Ticking a condition
            // clears "None of these" and "Not sure" — see [_toggleCondition] — which is what
            // mutual exclusion should feel like. Greying the list out instead makes the patient
            // hunt for the row they have to untick first.
            enabled: !_busy,
            onTap: () => _toggleCondition(condition),
          ),
        const SizedBox(height: TeraSpacing.sm),
        AnswerOption(
          label: 'None of these',
          multi: true,
          selected: _noConditions,
          enabled: !_busy,
          onTap: _selectNone,
        ),
        AnswerOption(
          label: 'Not sure',
          multi: true,
          selected: _conditionsNotSure,
          enabled: !_busy,
          onTap: _selectNotSure,
        ),

        if (error != null) ...[
          const SizedBox(height: TeraSpacing.lg),
          FormErrorPanel(message: error),
        ],
      ],
    );
  }
}

/// ONB-03's medication question, three-valued as the spec writes it.
///
/// The stored field is a nullable bool, because that is what `/v1/profile` accepts. "Not sure" is
/// therefore stored as *unanswered* rather than as false: recording it as "no" would assert
/// something the patient explicitly declined to assert.
enum MedicationAnswer {
  yes('Yes', true),
  no('No', false),
  notSure('Not sure', null);

  const MedicationAnswer(this.label, this.stored);

  final String label;
  final bool? stored;

  static MedicationAnswer? fromStored(bool? value) => switch (value) {
    true => yes,
    false => no,
    null => null,
  };
}
