/// The triage checklist, shown before anything else in a spot check.
///
/// It comes before the eligibility probe, not after: a patient reporting chest pain should not be
/// made to sit through six seconds of sensor measurement first, and the eligibility screen can
/// end in "this phone cannot be used", which would swallow the report entirely.
///
/// Selecting any red flag routes to [EmergencyScreen] immediately, with no measurement offered.
/// The instruction is rendered from a local constant; the API record is fired afterwards and its
/// outcome changes nothing.
library;

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../capture/symptom_triage.dart';
import 'emergency_screen.dart';
import 'tokens.dart';

class SymptomTriageScreen extends StatefulWidget {
  const SymptomTriageScreen({
    super.key,
    required this.api,
    required this.onProceed,
    required this.onDone,
  });

  final ApiClient api;

  /// Nothing reported: continue into the spot check.
  final VoidCallback onProceed;

  /// The patient has finished with the emergency screen and is back at the start.
  final VoidCallback onDone;

  @override
  State<SymptomTriageScreen> createState() => _SymptomTriageScreenState();
}

class _SymptomTriageScreenState extends State<SymptomTriageScreen> {
  final Set<RedFlagSymptom> _selected = {};

  void _continue() {
    final decision = SymptomTriage.decide(_selected);

    if (decision.isEmergency) {
      // Replace rather than push: there is no going back to a measurement from here, and the
      // back button must not offer one.
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => EmergencyScreen(
            api: widget.api,
            symptoms: decision.selected,
            onDone: widget.onDone,
          ),
        ),
      );
      return;
    }

    widget.onProceed();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Before you start')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(TeraSpacing.md),
          children: [
            const Text(
              'Are you feeling any of these right now?',
              style: TextStyle(
                fontSize: TeraText.section,
                fontWeight: FontWeight.w600,
                color: TeraColors.ink,
              ),
            ),
            const SizedBox(height: TeraSpacing.sm),
            const Text(
              'Tick anything you have now. If you tick one, Tera will stop and tell you what to '
              'do instead of taking a reading.',
              style: TextStyle(color: TeraColors.ink, height: 1.5),
            ),
            const SizedBox(height: TeraSpacing.lg),

            for (final symptom in RedFlagSymptom.values)
              CheckboxListTile(
                value: _selected.contains(symptom),
                onChanged: (checked) => setState(() {
                  if (checked ?? false) {
                    _selected.add(symptom);
                  } else {
                    _selected.remove(symptom);
                  }
                }),
                title: Text(
                  symptom.label,
                  style: const TextStyle(
                    fontSize: TeraText.body,
                    color: TeraColors.ink,
                  ),
                ),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                // 48dp minimum; the persona is not a designer with a trackpad.
                visualDensity: const VisualDensity(vertical: 1),
                activeColor: TeraColors.brand,
              ),

            const SizedBox(height: TeraSpacing.lg),
            FilledButton(
              onPressed: _continue,
              child: Text(
                _selected.isEmpty ? 'None of these — continue' : 'Continue',
              ),
            ),
            const SizedBox(height: TeraSpacing.md),
            const Text(
              'Tera does not diagnose and does not replace calling for help. If something feels '
              'wrong and it is not on this list, contact your clinic.',
              style: TextStyle(
                fontSize: TeraText.small,
                height: 1.5,
                color: TeraColors.neutral700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
