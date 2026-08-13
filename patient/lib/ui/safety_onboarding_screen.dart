/// ONB-02 — Measurement Safety (PM spec section 7, frame `Measurement Safety.png`).
///
/// Two questions, one of them conditional. It is the smallest screen in onboarding and the only
/// one whose answers change what the app will do.
///
/// # This screen feeds the contraindication gate
///
/// Pregnancy closes [ContextIntakeSafety]'s gate: no capture, no submission, no trend, and the
/// hard stop is shown locally without waiting for a network round trip. That is why ONB-02 writes
/// to [ContextIntakeStore] rather than to the PHR profile — the gate reads the intake, and a
/// safety answer that lived somewhere the gate does not look would be a safety answer that does
/// nothing.
///
/// # Two spec answers the wire does not have yet, and how they are handled
///
/// Section 7 lists four options for the first question. `PregnancyAnswer` has three: the wire
/// enum, shared with the backend, is `yes` / `no` / `prefer_not_to_say`.
///
/// * **"Recently gave birth"** is recorded as its own answer on the handset, with the date, and
///   sent as `no`. It is deliberately **not** sent as `yes`: the gate's block message says the
///   method is unvalidated *in pregnancy*, which is not a true statement about someone postpartum,
///   and widening a clinical gate is not a change this screen is entitled to make on its own.
///   Whether postpartum should block is a clinical question for the team — recorded in
///   `docs/decisions.md` as open. What this screen guarantees is that the answer is not lost.
/// * **"Not sure"** on the rhythm question is recorded on the handset and sent as
///   `known_arrhythmia: false`. Arrhythmia does not gate anything — it degrades beat detection,
///   and the signal chain's own quality gate rejects a capture too irregular to use — so nothing
///   downstream changes. Sending `true` would assert a diagnosis the patient did not report.
///
/// Both are one backend enum widening away from being sent faithfully. Neither loses data today.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../capture/context_intake.dart';
import '../capture/phr_profile.dart';
import '../routing/app_flow_state.dart';
import '../routing/app_router.dart';
import 'form_kit.dart';
import 'tokens.dart';

/// The first question, as section 7 writes it.
enum BodyStateAnswer {
  pregnant('Pregnant', PregnancyAnswer.yes),
  recentlyGaveBirth('Recently gave birth', PregnancyAnswer.no),
  neither('Neither', PregnancyAnswer.no),
  preferNotToSay('Prefer not to say', PregnancyAnswer.preferNotToSay);

  const BodyStateAnswer(this.label, this.wire);

  final String label;

  /// What goes to `/v1/patient-context`. See the library docstring for why
  /// [recentlyGaveBirth] maps to `no`.
  final PregnancyAnswer wire;
}

/// The rhythm question, three-valued as the spec writes it.
enum RhythmAnswer {
  yes('Yes', true),
  no('No', false),
  notSure('Not sure', false);

  const RhythmAnswer(this.label, this.wire);

  final String label;

  /// `known_arrhythmia`. "Not sure" is not an assertion of arrhythmia, so it sends false.
  final bool wire;
}

class SafetyOnboardingScreen extends StatefulWidget {
  const SafetyOnboardingScreen({
    super.key,
    required this.flow,
    ContextIntakeStore? intakeStore,
    PhrProfileStore? profileStore,
  }) : _intakeStore = intakeStore,
       _profileStore = profileStore;

  final TeraFlow flow;
  final ContextIntakeStore? _intakeStore;
  final PhrProfileStore? _profileStore;

  @override
  State<SafetyOnboardingScreen> createState() => _SafetyOnboardingScreenState();
}

class _SafetyOnboardingScreenState extends State<SafetyOnboardingScreen> {
  late final ContextIntakeStore _intakeStore =
      widget._intakeStore ?? SecureContextIntakeStore();
  late final PhrProfileStore _profileStore =
      widget._profileStore ?? SecurePhrProfileStore();

  BodyStateAnswer? _bodyState;
  RhythmAnswer? _rhythm;
  DateTime? _birthDate;

  bool _busy = false;
  String? _error;

  bool get _needsBirthDate => _bodyState == BodyStateAnswer.recentlyGaveBirth;

  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthDate ?? now,
      // A year back covers "recently" generously; a delivery date cannot be in the future.
      firstDate: DateTime(now.year - 2),
      lastDate: now,
      helpText: 'When did you give birth?',
    );
    if (picked != null) setState(() => _birthDate = picked);
  }

  Future<void> _next() async {
    if (_busy) return;
    setState(() => _error = null);

    if (_bodyState == null || _rhythm == null) {
      setState(() => _error = 'Answer both questions to continue.');
      return;
    }
    if (_needsBirthDate && _birthDate == null) {
      setState(
        () => _error =
            'Add the date you gave birth, or choose a different answer.',
      );
      return;
    }

    setState(() => _busy = true);

    // The intake the gate reads. Merged onto whatever is stored rather than replacing it: the
    // medication list and last clinic reading are collected elsewhere and must not be erased by
    // an answer to a different question.
    final existing = await _intakeStore.read();
    final intake = ContextIntake(
      lastRegimenChangeDate: existing?.lastRegimenChangeDate,
      medications: existing?.medications ?? const [],
      pregnant: _bodyState!.wire,
      knownArrhythmia: _rhythm!.wire,
      lastClinicBp: existing?.lastClinicBp,
    );
    await _intakeStore.write(intake);

    // The two answers the wire cannot carry faithfully, kept on the handset so they are not lost.
    final profile = await _profileStore.read();
    await _profileStore.write(
      profile.copyWith(
        postpartum: _needsBirthDate,
        postpartumDate: _birthDate,
        rhythmAnswer: _rhythm!.name,
      ),
    );

    if (!mounted) return;

    // Pregnancy closes the gate. The patient continues through onboarding either way — the block
    // is on producing a trend, not on having an account — but they are told now rather than
    // discovering it at the moment they try to take a reading.
    if (ContextIntakeSafety.evaluate(intake) == IntakeGate.blockedPregnancy) {
      await _showPregnancyNotice();
      if (!mounted) return;
    }

    await widget.flow.completeOnboardingStep(OnboardingStep.safety);
    // Filed to `/v1/patient-context`, and never blocking — same discipline as the other two
    // onboarding steps. The gate has already been evaluated locally and offline.
    unawaited(PatientContextSubmitter(api: widget.flow.api).submit(intake));

    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil(
      widget.flow.state.onboardingStep.route,
      (r) => false,
    );
  }

  /// The hard stop, stated once and in the wording the gate defines.
  ///
  /// It names the limitation and refers on. It does not diagnose, does not estimate risk and does
  /// not reassure — invariant 6 applies here exactly as everywhere else.
  Future<void> _showPregnancyNotice() => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: TeraRadius.cardBorder),
      backgroundColor: TeraColors.paper,
      title: const Text(
        pregnancyBlockTitle,
        style: TextStyle(
          fontSize: TeraText.section,
          fontWeight: FontWeight.w700,
          color: TeraColors.ink,
        ),
      ),
      content: const Text(
        pregnancyBlockMessage,
        style: TextStyle(
          fontSize: TeraText.small,
          color: TeraColors.ink,
          height: 1.45,
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          style: FilledButton.styleFrom(
            backgroundColor: TeraColors.ink,
            foregroundColor: TeraColors.paper,
          ),
          child: const Text('I understand'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final error = _error;

    return OnboardingStepScaffold(
      specId: 'ONB-02',
      step: 2,
      title: 'Measurement safety',
      subtitle:
          'Two questions that change whether Tera can read a trend for you.',
      actions: StepActions(onNext: _next, busy: _busy),
      children: [
        const QuestionHeading(
          'Which best describes you right now?',
          required: true,
        ),
        const SizedBox(height: TeraSpacing.md),
        for (final option in BodyStateAnswer.values)
          AnswerOption(
            label: option.label,
            selected: _bodyState == option,
            enabled: !_busy,
            detail: option == BodyStateAnswer.pregnant
                // Said before the answer is given, not after. A hard stop that appears only once
                // someone has committed to an answer reads as a punishment for answering.
                ? 'Tera cannot produce trends during pregnancy.'
                : null,
            onTap: () => setState(() {
              _bodyState = option;
              if (option != BodyStateAnswer.recentlyGaveBirth)
                _birthDate = null;
            }),
          ),

        if (_needsBirthDate) ...[
          const SizedBox(height: TeraSpacing.lg),
          const QuestionHeading('When did you give birth?', required: true),
          const SizedBox(height: TeraSpacing.md),
          _DateRow(
            value: _birthDate,
            placeholder: 'Choose the date',
            onTap: _busy ? null : _pickBirthDate,
          ),
        ],

        const SizedBox(height: TeraSpacing.xl),
        const QuestionHeading(
          'Have you ever been diagnosed with atrial fibrillation (AFib) or another heart '
          'rhythm disorder?',
          required: true,
          hint:
              'An irregular rhythm makes the signal harder to read. Tera records the answer '
              'and does not act on it.',
        ),
        const SizedBox(height: TeraSpacing.md),
        for (final option in RhythmAnswer.values)
          AnswerOption(
            label: option.label,
            selected: _rhythm == option,
            enabled: !_busy,
            onTap: () => setState(() => _rhythm = option),
          ),

        if (error != null) ...[
          const SizedBox(height: TeraSpacing.lg),
          FormErrorPanel(message: error),
        ],
      ],
    );
  }
}

class _DateRow extends StatelessWidget {
  const _DateRow({
    required this.value,
    required this.placeholder,
    required this.onTap,
  });

  final DateTime? value;
  final String placeholder;
  final VoidCallback? onTap;

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
              const Icon(
                Icons.calendar_today_outlined,
                color: TeraColors.neutral500,
                size: 22,
              ),
              const SizedBox(width: TeraSpacing.md),
              Expanded(
                child: Text(
                  chosen
                      ? '${value!.day}/${value!.month}/${value!.year}'
                      : placeholder,
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
