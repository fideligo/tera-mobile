/// ONB-01 and ONB-03. Bare-bones forms, real persistence.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../capture/phr_profile.dart';
import '../routing/app_flow_state.dart';
import '../routing/app_router.dart';
import '../routing/routes.dart';

Future<void> _advance(BuildContext context, TeraFlow flow, OnboardingStep step) async {
  await flow.completeOnboardingStep(step);
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
  DateTime? _dob;
  SexAtBirth? _sex;
  final _height = TextEditingController();
  final _weight = TextEditingController();
  String? _error;

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
    );
    if (picked != null) setState(() => _dob = picked);
  }

  Future<void> _next() async {
    setState(() => _error = null);

    if (_dob == null || _sex == null) {
      setState(() => _error = 'Date of birth and sex are needed to continue.');
      return;
    }
    if (!PhrProfile.dobIsPlausible(_dob!)) {
      setState(() => _error = 'Date of birth cannot be in the future.');
      return;
    }

    double? height;
    if (_height.text.trim().isNotEmpty) {
      height = double.tryParse(_height.text.trim());
      if (height == null || !PhrProfile.heightIsPlausible(height)) {
        setState(() => _error = 'Height should be between 50 and 250 cm.');
        return;
      }
    }

    double? weight;
    if (_weight.text.trim().isNotEmpty) {
      weight = double.tryParse(_weight.text.trim());
      if (weight == null || !PhrProfile.weightIsPlausible(weight)) {
        setState(() => _error = 'Weight should be between 10 and 400 kg.');
        return;
      }
    }

    final existing = await widget.store.read();
    await widget.store.write(
      existing.copyWith(
        dateOfBirth: _dob,
        sexAtBirth: _sex,
        heightCm: height,
        weightKg: weight,
      ),
    );

    if (!mounted) return;
    await _advance(context, widget.flow, OnboardingStep.aboutYou);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ONB-01')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('About you'),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: _pickDob,
            child: Text(
              _dob == null
                  ? 'Date of birth'
                  : 'Born ${_dob!.day}/${_dob!.month}/${_dob!.year}',
            ),
          ),
          const SizedBox(height: 8),
          const Text('Sex assigned at birth'),
          DropdownButton<SexAtBirth>(
            value: _sex,
            isExpanded: true,
            hint: const Text('Select'),
            onChanged: (v) => setState(() => _sex = v),
            items: [
              for (final s in SexAtBirth.values)
                DropdownMenuItem(value: s, child: Text(s.label)),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _height,
            decoration: const InputDecoration(labelText: 'Height in cm (optional)'),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          ),
          TextField(
            controller: _weight,
            decoration: const InputDecoration(labelText: 'Weight in kg (optional)'),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          ),
          if (_error != null) ...[const SizedBox(height: 8), Text(_error!)],
          const SizedBox(height: 16),
          ElevatedButton(onPressed: _next, child: const Text('Next')),
          const SizedBox(height: 8),
          // Stated because the spec forbids deriving one, and someone will otherwise expect it.
          const Text('Tera does not calculate a BMI or judge these numbers.'),
        ],
      ),
    );
  }
}

/// ONB-03 — Health Context.
class HealthContextScreen extends StatefulWidget {
  const HealthContextScreen({super.key, required this.flow, required this.store});

  final TeraFlow flow;
  final PhrProfileStore store;

  @override
  State<HealthContextScreen> createState() => _HealthContextScreenState();
}

class _HealthContextScreenState extends State<HealthContextScreen> {
  HypertensionStatus? _hypertension;
  bool? _medication;
  final Set<KnownCondition> _conditions = {};
  String? _error;

  Future<void> _next() async {
    setState(() => _error = null);

    if (_hypertension == null || _medication == null) {
      setState(() => _error = 'Answer both questions before continuing.');
      return;
    }

    final existing = await widget.store.read();
    await widget.store.write(
      existing.copyWith(
        hypertension: _hypertension,
        takesBpMedication: _medication,
        conditions: _conditions,
      ),
    );

    if (!mounted) return;
    await _advance(context, widget.flow, OnboardingStep.healthContext);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ONB-03')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Ever diagnosed with high blood pressure?'),
          DropdownButton<HypertensionStatus>(
            value: _hypertension,
            isExpanded: true,
            hint: const Text('Select'),
            onChanged: (v) => setState(() => _hypertension = v),
            items: [
              for (final s in HypertensionStatus.values)
                DropdownMenuItem(value: s, child: Text(s.label)),
            ],
          ),
          const SizedBox(height: 8),
          const Text('Do you take blood pressure medication?'),
          DropdownButton<bool>(
            value: _medication,
            isExpanded: true,
            hint: const Text('Select'),
            onChanged: (v) => setState(() => _medication = v),
            items: const [
              DropdownMenuItem(value: true, child: Text('Yes')),
              DropdownMenuItem(value: false, child: Text('No')),
            ],
          ),
          const SizedBox(height: 8),
          const Text('Any of these conditions?'),
          for (final condition in KnownCondition.values)
            CheckboxListTile(
              value: _conditions.contains(condition),
              onChanged: (v) => setState(() {
                if (v ?? false) {
                  _conditions.add(condition);
                } else {
                  _conditions.remove(condition);
                }
              }),
              title: Text(condition.label),
            ),
          if (_error != null) ...[const SizedBox(height: 8), Text(_error!)],
          const SizedBox(height: 16),
          ElevatedButton(onPressed: _next, child: const Text('Next')),
        ],
      ),
    );
  }
}
