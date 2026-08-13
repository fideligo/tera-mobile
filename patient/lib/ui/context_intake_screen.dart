/// The one-time clinical context form.
///
/// Five fields, all on one screen. The safety gate is evaluated the moment the patient saves, and
/// a pregnancy answer of yes produces a hard stop dialog that cannot be dismissed into the capture
/// flow — the only way out of it is back.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';
import '../capture/context_intake.dart';
import 'tokens.dart';

class ContextIntakeScreen extends StatefulWidget {
  const ContextIntakeScreen({
    super.key,
    required this.store,
    required this.onSaved,
    this.api,
    this.existing,
  });

  final ContextIntakeStore store;

  /// Null in a test that only exercises the form and the gate. When present, the intake is also
  /// filed to `POST /v1/patient-context`.
  final ApiClient? api;

  /// Called with the saved intake when the gate is clear. Not called when it is blocked.
  final void Function(ContextIntake intake) onSaved;

  final ContextIntake? existing;

  @override
  State<ContextIntakeScreen> createState() => _ContextIntakeScreenState();
}

class _ContextIntakeScreenState extends State<ContextIntakeScreen> {
  final _formKey = GlobalKey<FormState>();

  DateTime? _regimenChange;
  final List<({TextEditingController name, TextEditingController dose})>
  _medications = [];
  PregnancyAnswer? _pregnant;
  bool? _arrhythmia;
  final _clinicSys = TextEditingController();
  final _clinicDia = TextEditingController();
  DateTime? _clinicDate;

  String? _error;
  bool _busy = false;

  /// Whether the last save reached the server. Null before a save, or when no client was given.
  bool? _uploaded;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing != null) {
      _regimenChange = existing.lastRegimenChangeDate;
      _pregnant = existing.pregnant;
      _arrhythmia = existing.knownArrhythmia;
      final bp = existing.lastClinicBp;
      if (bp != null) {
        _clinicSys.text = '${bp.systolicMmhg}';
        _clinicDia.text = '${bp.diastolicMmhg}';
        _clinicDate = bp.takenOn;
      }
      for (final m in existing.medications) {
        _medications.add((
          name: TextEditingController(text: m.name),
          dose: TextEditingController(text: m.dose),
        ));
      }
    }
    if (_medications.isEmpty) _addMedicationRow();
  }

  @override
  void dispose() {
    for (final row in _medications) {
      row.name.dispose();
      row.dose.dispose();
    }
    _clinicSys.dispose();
    _clinicDia.dispose();
    super.dispose();
  }

  void _addMedicationRow() => _medications.add((
    name: TextEditingController(),
    dose: TextEditingController(),
  ));

  Future<void> _pickDate({
    required DateTime? current,
    required ValueChanged<DateTime> onPicked,
  }) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? now,
      // No future dates: neither a regimen change nor a clinic reading can have happened later
      // than today, and a mistyped year is a common slip.
      firstDate: DateTime(now.year - 10),
      lastDate: now,
    );
    if (picked != null) onPicked(picked);
  }

  ContextIntake? _collect() {
    setState(() => _error = null);

    if (!(_formKey.currentState?.validate() ?? false)) return null;

    if (_pregnant == null) {
      setState(() => _error = 'Answer the pregnancy question before saving.');
      return null;
    }
    if (_arrhythmia == null) {
      setState(
        () => _error = 'Answer the irregular-heartbeat question before saving.',
      );
      return null;
    }

    ClinicBloodPressure? clinicBp;
    final sys = int.tryParse(_clinicSys.text.trim());
    final dia = int.tryParse(_clinicDia.text.trim());
    if (sys != null && dia != null) {
      if (_clinicDate == null) {
        setState(() => _error = 'Add the date of the clinic reading.');
        return null;
      }
      clinicBp = ClinicBloodPressure(
        systolicMmhg: sys,
        diastolicMmhg: dia,
        takenOn: _clinicDate!,
      );
      final violations = clinicBp.validate();
      if (violations.isNotEmpty) {
        setState(() => _error = violations.first.message);
        return null;
      }
    } else if (sys != null || dia != null) {
      setState(
        () =>
            _error = 'Enter both numbers from the clinic reading, or neither.',
      );
      return null;
    }

    return ContextIntake(
      lastRegimenChangeDate: _regimenChange,
      medications: [
        for (final row in _medications)
          if (row.name.text.trim().isNotEmpty ||
              row.dose.text.trim().isNotEmpty)
            Medication(name: row.name.text, dose: row.dose.text),
      ],
      pregnant: _pregnant!,
      knownArrhythmia: _arrhythmia!,
      lastClinicBp: clinicBp,
    );
  }

  Future<void> _save() async {
    final intake = _collect();
    if (intake == null) return;

    setState(() => _busy = true);

    // Local first, and unconditionally. The safety gate reads this copy, so it must land whether
    // or not there is a network — a contraindication that needed a server would fail open.
    await widget.store.write(intake);

    // Then the durable record. Its failure is reported and never blocks: the patient is already
    // gated correctly by the line above.
    final api = widget.api;
    final uploaded = api == null
        ? null
        : await PatientContextSubmitter(api: api).submit(intake);

    if (!mounted) return;
    setState(() {
      _busy = false;
      _uploaded = uploaded;
    });

    if (ContextIntakeSafety.evaluate(intake) == IntakeGate.blockedPregnancy) {
      await _showHardStop();
      return;
    }

    if (!mounted) return;
    widget.onSaved(intake);
  }

  /// Not dismissible, and its only action returns to the previous screen. There is no path from
  /// this dialog into a capture.
  Future<void> _showHardStop() => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      shape: const RoundedRectangleBorder(),
      backgroundColor: TeraColors.paper,
      title: const Text(
        pregnancyBlockTitle,
        style: TextStyle(
          fontSize: TeraText.section,
          fontWeight: FontWeight.w600,
          color: TeraColors.ink,
        ),
      ),
      content: const Text(
        pregnancyBlockMessage,
        style: TextStyle(color: TeraColors.ink, height: 1.5),
      ),
      actions: [
        FilledButton(
          onPressed: () {
            Navigator.of(dialogContext).pop();
            Navigator.of(context).pop();
          },
          child: const Text('I understand'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About you')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(TeraSpacing.md),
            children: [
              const Text(
                'A few things Tera needs to know',
                style: TextStyle(
                  fontSize: TeraText.section,
                  fontWeight: FontWeight.w600,
                  color: TeraColors.ink,
                ),
              ),
              const SizedBox(height: TeraSpacing.sm),
              const Text(
                'Asked once, kept on this phone, and used to decide whether Tera is suitable for '
                'you. You can change these answers at any time.',
                style: TextStyle(color: TeraColors.ink, height: 1.5),
              ),
              const SizedBox(height: TeraSpacing.lg),

              _sectionLabel('When did your medication last change?'),
              _dateField(
                value: _regimenChange,
                hint: 'Not answered',
                onPick: () => _pickDate(
                  current: _regimenChange,
                  onPicked: (d) => setState(() => _regimenChange = d),
                ),
              ),
              const SizedBox(height: TeraSpacing.lg),

              _sectionLabel('What blood-pressure medication are you taking?'),
              for (var i = 0; i < _medications.length; i++) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextFormField(
                        controller: _medications[i].name,
                        decoration: const InputDecoration(labelText: 'Name'),
                        textInputAction: TextInputAction.next,
                      ),
                    ),
                    const SizedBox(width: TeraSpacing.sm),
                    Expanded(
                      flex: 2,
                      child: TextFormField(
                        controller: _medications[i].dose,
                        decoration: const InputDecoration(labelText: 'Dose'),
                        textInputAction: TextInputAction.next,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: TeraSpacing.sm),
              ],
              OutlinedButton(
                onPressed: () => setState(_addMedicationRow),
                child: const Text('Add another medicine'),
              ),
              const SizedBox(height: TeraSpacing.lg),

              _sectionLabel('Are you pregnant?'),
              RadioGroup<PregnancyAnswer>(
                groupValue: _pregnant,
                onChanged: (v) => setState(() => _pregnant = v),
                child: Column(
                  children: [
                    for (final answer in PregnancyAnswer.values)
                      RadioListTile<PregnancyAnswer>(
                        value: answer,
                        title: Text(
                          switch (answer) {
                            PregnancyAnswer.yes => 'Yes',
                            PregnancyAnswer.no => 'No',
                            PregnancyAnswer.preferNotToSay =>
                              'Prefer not to say',
                          },
                          style: const TextStyle(
                            fontSize: TeraText.body,
                            color: TeraColors.ink,
                          ),
                        ),
                        contentPadding: EdgeInsets.zero,
                        activeColor: TeraColors.brand,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: TeraSpacing.lg),

              _sectionLabel(
                'Have you been told you have an irregular heartbeat?',
              ),
              RadioGroup<bool>(
                groupValue: _arrhythmia,
                onChanged: (v) => setState(() => _arrhythmia = v),
                child: Column(
                  children: [
                    for (final yes in [true, false])
                      RadioListTile<bool>(
                        value: yes,
                        title: Text(
                          yes ? 'Yes' : 'No',
                          style: const TextStyle(
                            fontSize: TeraText.body,
                            color: TeraColors.ink,
                          ),
                        ),
                        contentPadding: EdgeInsets.zero,
                        activeColor: TeraColors.brand,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: TeraSpacing.lg),

              _sectionLabel('Your last blood pressure taken at a clinic'),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _clinicSys,
                      decoration: const InputDecoration(
                        labelText: 'Top (systolic)',
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                  ),
                  const SizedBox(width: TeraSpacing.sm),
                  Expanded(
                    child: TextFormField(
                      controller: _clinicDia,
                      decoration: const InputDecoration(
                        labelText: 'Bottom (diastolic)',
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: TeraSpacing.sm),
              _dateField(
                value: _clinicDate,
                hint: 'Date of that reading',
                onPick: () => _pickDate(
                  current: _clinicDate,
                  onPicked: (d) => setState(() => _clinicDate = d),
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: TeraSpacing.md),
                Container(
                  decoration: systemFlagDecoration(),
                  padding: const EdgeInsets.all(TeraSpacing.md),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: TeraColors.ink, height: 1.4),
                  ),
                ),
              ],

              const SizedBox(height: TeraSpacing.lg),
              FilledButton(
                onPressed: _busy ? null : _save,
                child: Text(_busy ? 'Saving…' : 'Save'),
              ),
              const SizedBox(height: TeraSpacing.md),
              Text(
                switch (_uploaded) {
                  // Stated, not apologised for. The answers are saved and the gate is applied
                  // either way; only the durable copy is missing.
                  false =>
                    'Saved on this phone. It could not reach your Tera account just now and will '
                        'need saving again when you are back online.',
                  true => 'Saved to this phone and to your Tera account.',
                  null => 'Saved on this phone and to your Tera account.',
                },
                style: const TextStyle(
                  fontSize: TeraText.small,
                  height: 1.5,
                  color: TeraColors.neutral700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: TeraSpacing.sm),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: TeraText.body,
        fontWeight: FontWeight.w600,
        color: TeraColors.ink,
      ),
    ),
  );

  Widget _dateField({
    required DateTime? value,
    required String hint,
    required VoidCallback onPick,
  }) => OutlinedButton(
    onPressed: onPick,
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        value == null ? hint : '${value.day}/${value.month}/${value.year}',
        style: TextStyle(
          fontSize: TeraText.body,
          color: value == null ? TeraColors.neutral700 : TeraColors.ink,
        ),
      ),
    ),
  );
}
