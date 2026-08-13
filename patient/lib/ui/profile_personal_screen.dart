/// PROF-01 — Personal Details, the editable half of the PHR (PM spec section 28).
///
/// ONB-01 collects date of birth, sex, height and weight once, at onboarding, and never again —
/// there was nowhere in Profile to come back and fix a typo or update a weight. This screen is
/// that place: the same fields, the same plausibility rules, reading and writing the same
/// [PhrProfileStore] and the same [PhrSubmitter] onboarding already uses, so there is exactly one
/// definition of "the profile" rather than a second one that could drift from it.
///
/// # Why this data matters beyond the form
///
/// `POST /v1/profile` is also what `read_insight`'s EMR context reads from when a patient
/// consents to the AI paragraph on [InsightScreen] — age, sex, height, weight and self-reported
/// conditions, never a name and never a date of birth (age only). A profile left blank here is a
/// paragraph with less to work from, not a broken one: the server treats an absent field as
/// nothing to add, not an error.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../capture/phr_profile.dart';
import '../capture/phr_submitter.dart';
import '../routing/app_router.dart';
import 'form_kit.dart';
import 'tokens.dart';

class ProfilePersonalScreen extends StatefulWidget {
  const ProfilePersonalScreen({super.key, required this.flow, required this.store});

  final TeraFlow flow;
  final PhrProfileStore store;

  @override
  State<ProfilePersonalScreen> createState() => _ProfilePersonalScreenState();
}

class _ProfilePersonalScreenState extends State<ProfilePersonalScreen> {
  final _formKey = GlobalKey<FormState>();
  final _height = TextEditingController();
  final _weight = TextEditingController();

  DateTime? _dob;
  SexAtBirth? _sex;
  PhrProfile _existing = const PhrProfile();
  bool _loading = true;
  bool _busy = false;
  String? _error;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final saved = await widget.store.read();
    if (!mounted) return;
    setState(() {
      _existing = saved;
      _dob = saved.dateOfBirth;
      _sex = saved.sexAtBirth;
      if (saved.heightCm != null) _height.text = _trimZero(saved.heightCm!);
      if (saved.weightKg != null) _weight.text = _trimZero(saved.weightKg!);
      _loading = false;
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
      lastDate: now,
      helpText: 'Date of birth',
    );
    if (picked != null) setState(() => _dob = picked);
  }

  String? _validateHeight(String? raw) {
    final text = (raw ?? '').trim();
    if (text.isEmpty) return null;
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
    if (text.isEmpty) return null;
    final value = double.tryParse(text);
    if (value == null) return 'Enter a number, for example 72.';
    if (!PhrProfile.weightIsPlausible(value)) {
      return 'Weight should be between ${PhrProfile.minWeightKg.toStringAsFixed(0)} and '
          '${PhrProfile.maxWeightKg.toStringAsFixed(0)} kg.';
    }
    return null;
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _error = null;
      _saved = false;
    });

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

    final updated = _existing.copyWith(
      dateOfBirth: _dob,
      sexAtBirth: _sex,
      heightCm: double.tryParse(_height.text.trim()),
      weightKg: double.tryParse(_weight.text.trim()),
    );
    await widget.store.write(updated);
    final reached = await PhrSubmitter(api: widget.flow.api).submit(updated);

    if (!mounted) return;
    setState(() {
      _existing = updated;
      _busy = false;
      _saved = reached;
      _error = reached ? null : 'Saved on this phone, but could not reach the server. It will '
          'sync the next time you save with a connection.';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        appBar: null,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final error = _error;

    return Scaffold(
      backgroundColor: TeraColors.page,
      appBar: AppBar(title: const Text('Personal details')),
      body: Form(
        key: _formKey,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(TeraSpacing.lg),
                children: [
                  const Text(
                    'What Tera knows about you',
                    style: TextStyle(
                      fontSize: TeraText.display,
                      fontWeight: FontWeight.w700,
                      color: TeraColors.ink,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: TeraSpacing.sm),
                  const Text(
                    'Used to put your checks in context, and — only if you consent on a '
                    'result screen — to help write the optional AI paragraph. Tera does not '
                    'calculate a BMI or judge these numbers.',
                    style: TextStyle(fontSize: TeraText.body, color: TeraColors.neutral700, height: 1.45),
                  ),
                  const SizedBox(height: TeraSpacing.xl),

                  const QuestionHeading('What is your date of birth?', required: true),
                  const SizedBox(height: TeraSpacing.md),
                  _DateField(value: _dob, onTap: _busy ? () {} : _pickDob),
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

                  const QuestionHeading('What is your height?', hint: 'Optional.'),
                  const SizedBox(height: TeraSpacing.md),
                  _MeasurementField(
                    controller: _height,
                    hint: '168',
                    unit: 'cm',
                    enabled: !_busy,
                    validator: _validateHeight,
                  ),
                  const SizedBox(height: TeraSpacing.xl),

                  const QuestionHeading('What is your current weight?', hint: 'Optional.'),
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
                  if (_saved) ...[
                    const SizedBox(height: TeraSpacing.lg),
                    Container(
                      padding: const EdgeInsets.all(TeraSpacing.md),
                      decoration: accentDecoration(),
                      child: const Row(
                        children: [
                          Icon(Icons.check_circle_outline, color: TeraColors.ink, size: 20),
                          SizedBox(width: TeraSpacing.sm),
                          Expanded(
                            child: Text(
                              'Saved.',
                              style: TextStyle(color: TeraColors.ink, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            StepActions(onNext: _save, nextLabel: 'Save', busy: _busy),
          ],
        ),
      ),
    );
  }
}

/// A tappable date row, matching ONB-01's [_DateField] — duplicated rather than shared because
/// the onboarding one is a private class in `onboarding_screens.dart` and this screen has no
/// other reason to import that file.
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

/// A numeric field with its unit shown rather than described, matching ONB-01's own.
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
