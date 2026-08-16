/// Editing the health record — `POST /v1/profile`.
///
/// # Only what changed is sent
///
/// The endpoint is a partial update: "only fields present in the request are touched. An absent
/// field means unchanged, not clear." So this builds its body from the fields the patient actually
/// altered. Sending the whole form back would work, but it would also rewrite five rows to their
/// own values every time somebody fixed a typo in one, and every one of those writes lands in the
/// audit log as a profile update.
///
/// # Types are settled here, not at the server
///
/// `PhrProfilePatch` is strict: `height_cm` and `weight_kg` are floats bounded 50–250 and 10–400,
/// `date_of_birth` is a `date` and must not be in the future, and the two enums accept three wire
/// values each. A text field hands you a `String` — `'seventy'`, `'70kg'`, `'1,72'` — and posting
/// one produces a 422 whose body is a Pydantic error list, which is not something to show a
/// patient. Every value is parsed and range-checked before the request is built, so the request is
/// either valid or never made.
///
/// The bounds are named once, in `PhrProfile`, and mirror the server's. They are sanity bounds and
/// not clinical ones: they catch a slipped decimal point, and a value inside them is not a
/// judgement about anybody.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';
import '../capture/phr_profile.dart';
import 'tokens.dart';

/// A calendar date on the wire, as `PhrProfilePatch.date_of_birth` expects it.
///
/// **`date`, not `datetime`.** `DateTime.toIso8601String()` produces `1990-04-17T00:00:00.000`,
/// which is an instant and not a date, and posting one is a 422 whose body is a Pydantic error
/// list — not something to put in front of a patient. It is also the kind of bug that survives
/// review because the string looks right at a glance.
///
/// A top-level function so it can be tested without driving a date picker.
String isoDateOnly(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

class ProfileEditSheet extends StatefulWidget {
  const ProfileEditSheet({super.key, required this.api, this.current});

  final ApiClient api;

  /// The profile as the server last returned it, or null when there is none yet.
  final Map<String, dynamic>? current;

  @override
  State<ProfileEditSheet> createState() => _ProfileEditSheetState();
}

class _ProfileEditSheetState extends State<ProfileEditSheet> {
  final _formKey = GlobalKey<FormState>();
  final _height = TextEditingController();
  final _weight = TextEditingController();

  DateTime? _dob;
  SexAtBirth? _sex;
  HypertensionStatus? _hypertension;
  bool? _takingMedication;

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final current = widget.current;
    if (current == null) return;

    final dob = current['date_of_birth'] as String?;
    _dob = dob == null ? null : DateTime.tryParse(dob);
    _sex = SexAtBirth.fromWire(current['sex_assigned_at_birth'] as String?);
    _hypertension = HypertensionStatus.fromWire(
      current['hypertension_status'] as String?,
    );
    _takingMedication = current['taking_bp_medication'] as bool?;

    final height = (current['height_cm'] as num?)?.toDouble();
    final weight = (current['weight_kg'] as num?)?.toDouble();
    if (height != null) _height.text = _plain(height);
    if (weight != null) _weight.text = _plain(weight);
  }

  @override
  void dispose() {
    _height.dispose();
    _weight.dispose();
    super.dispose();
  }

  static String _plain(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toString();

  // ---------------------------------------------------------------- validation

  /// A measurement field, or null when it is valid.
  ///
  /// Empty is allowed and means "leave it alone" — height and weight are optional in the schema
  /// and skippable in onboarding, so an empty box is not an error.
  String? _validateMeasure(
    String? raw, {
    required String name,
    required double min,
    required double max,
    required String unit,
  }) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty) return null;

    final value = double.tryParse(text);
    if (value == null) return 'Enter $name as a number, in $unit.';
    if (value < min || value > max) {
      return '$name should be between ${_plain(min)} and ${_plain(max)} $unit.';
    }
    return null;
  }

  // -------------------------------------------------------------------- saving

  /// The changed fields, typed as the schema expects them.
  ///
  /// Returns an empty map when nothing moved, which the caller treats as "close, do not post".
  Map<String, dynamic> _changes() {
    final current = widget.current ?? const <String, dynamic>{};
    final body = <String, dynamic>{};

    final dob = _dob;
    final dobWire = dob == null ? null : isoDateOnly(dob);
    if (dobWire != null && dobWire != current['date_of_birth']) {
      body['date_of_birth'] = dobWire;
    }

    if (_sex != null && _sex!.wireValue != current['sex_assigned_at_birth']) {
      body['sex_assigned_at_birth'] = _sex!.wireValue;
    }

    if (_hypertension != null &&
        _hypertension!.wireValue != current['hypertension_status']) {
      body['hypertension_status'] = _hypertension!.wireValue;
    }

    if (_takingMedication != null &&
        _takingMedication != current['taking_bp_medication']) {
      body['taking_bp_medication'] = _takingMedication;
    }

    // Parsed, never passed through as text. `double.tryParse` has already been run by the
    // validator; this repeats it because the value that goes on the wire has to be the parsed
    // number and not the string the patient typed.
    final height = double.tryParse(_height.text.trim());
    if (height != null && height != (current['height_cm'] as num?)?.toDouble()) {
      body['height_cm'] = height;
    }
    final weight = double.tryParse(_weight.text.trim());
    if (weight != null && weight != (current['weight_kg'] as num?)?.toDouble()) {
      body['weight_kg'] = weight;
    }

    return body;
  }

  Future<void> _save() async {
    setState(() => _error = null);
    if (!(_formKey.currentState?.validate() ?? false)) return;

    // A birth date in the future is a typo, not a person — and the server rejects it, so it is
    // caught here rather than turned into a 422.
    final dob = _dob;
    if (dob != null && !PhrProfile.dobIsPlausible(dob)) {
      setState(() => _error = 'That date of birth is in the future.');
      return;
    }

    final body = _changes();
    if (body.isEmpty) {
      Navigator.of(context).pop(false);
      return;
    }

    setState(() => _busy = true);
    try {
      await widget.api.postJson('/v1/profile', body);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not save your details. $e';
      });
    }
  }

  // --------------------------------------------------------------------- build

  Future<void> _pickDob() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dob ?? DateTime(now.year - 40),
      firstDate: DateTime(now.year - 120),
      // Today, never later. The picker cannot offer an impossible date in the first place.
      lastDate: now,
    );
    if (picked != null && mounted) setState(() => _dob = picked);
  }

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: insets),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(TeraSpacing.lg),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Your health record',
                  style: TextStyle(
                    fontSize: TeraText.section,
                    fontWeight: FontWeight.w700,
                    color: TeraColors.ink,
                  ),
                ),
                const SizedBox(height: TeraSpacing.sm),
                const Text(
                  'Only what you change is sent. Leave anything blank to keep it as it is.',
                  style: TextStyle(
                    color: TeraColors.neutral700,
                    fontSize: TeraText.small,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: TeraSpacing.lg),

                _label('Date of birth'),
                OutlinedButton(
                  onPressed: _busy ? null : _pickDob,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: TeraColors.ink,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(
                      horizontal: TeraSpacing.md,
                      vertical: TeraSpacing.md,
                    ),
                  ),
                  child: Text(
                    _dob == null
                        ? 'Choose a date'
                        : '${_dob!.day.toString().padLeft(2, '0')}/'
                              '${_dob!.month.toString().padLeft(2, '0')}/${_dob!.year}',
                  ),
                ),
                const SizedBox(height: TeraSpacing.md),

                _label('Sex assigned at birth'),
                _choices<SexAtBirth>(
                  values: SexAtBirth.values,
                  selected: _sex,
                  labelOf: (v) => v.label,
                  onSelected: (v) => setState(() => _sex = v),
                ),
                const SizedBox(height: TeraSpacing.md),

                _label('Height'),
                _measureField(
                  controller: _height,
                  unit: 'cm',
                  min: PhrProfile.minHeightCm,
                  max: PhrProfile.maxHeightCm,
                  name: 'Height',
                ),
                const SizedBox(height: TeraSpacing.md),

                _label('Weight'),
                _measureField(
                  controller: _weight,
                  unit: 'kg',
                  min: PhrProfile.minWeightKg,
                  max: PhrProfile.maxWeightKg,
                  name: 'Weight',
                ),
                const SizedBox(height: TeraSpacing.md),

                _label('Have you been diagnosed with high blood pressure?'),
                _choices<HypertensionStatus>(
                  values: HypertensionStatus.values,
                  selected: _hypertension,
                  labelOf: (v) => v.label,
                  onSelected: (v) => setState(() => _hypertension = v),
                ),
                const SizedBox(height: TeraSpacing.md),

                _label('Are you taking blood pressure medication?'),
                _choices<bool>(
                  values: const [true, false],
                  selected: _takingMedication,
                  labelOf: (v) => v ? 'Yes' : 'No',
                  onSelected: (v) => setState(() => _takingMedication = v),
                ),

                if (_error != null) ...[
                  const SizedBox(height: TeraSpacing.md),
                  Container(
                    padding: const EdgeInsets.all(TeraSpacing.md),
                    decoration: systemFlagDecoration(),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: TeraColors.ink, height: 1.4),
                    ),
                  ),
                ],

                const SizedBox(height: TeraSpacing.lg),
                FilledButton(
                  onPressed: _busy ? null : _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: TeraColors.ink,
                    foregroundColor: TeraColors.paper,
                    padding: const EdgeInsets.symmetric(vertical: TeraSpacing.md),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(TeraRadius.button),
                    ),
                  ),
                  child: Text(
                    _busy ? 'Saving...' : 'Save',
                    style: const TextStyle(
                      fontSize: TeraText.body,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: TeraSpacing.sm),
                TextButton(
                  onPressed: _busy ? null : () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: TeraSpacing.sm),
    child: Text(
      text,
      style: const TextStyle(
        color: TeraColors.ink,
        fontSize: TeraText.small,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _measureField({
    required TextEditingController controller,
    required String unit,
    required double min,
    required double max,
    required String name,
  }) => TextFormField(
    controller: controller,
    enabled: !_busy,
    // Numeric keyboard *and* an input filter. The keyboard is a hint the platform is free to
    // ignore — a hardware keyboard, a paste, or a locale that offers a comma all get past it —
    // so the filter is what actually keeps a non-number out of the field.
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
    decoration: InputDecoration(
      suffixText: unit,
      border: const OutlineInputBorder(),
      hintText: 'Optional',
    ),
    validator: (v) => _validateMeasure(v, name: name, min: min, max: max, unit: unit),
  );

  Widget _choices<T>({
    required List<T> values,
    required T? selected,
    required String Function(T) labelOf,
    required ValueChanged<T> onSelected,
  }) => Wrap(
    spacing: TeraSpacing.sm,
    runSpacing: TeraSpacing.sm,
    children: [
      for (final value in values)
        ChoiceChip(
          label: Text(labelOf(value)),
          selected: selected == value,
          onSelected: _busy ? null : (_) => onSelected(value),
          selectedColor: TeraColors.brand,
          backgroundColor: TeraColors.paper,
          labelStyle: TextStyle(
            color: selected == value ? TeraColors.paper : TeraColors.ink,
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(TeraRadius.pill),
            side: const BorderSide(color: TeraColors.neutral300),
          ),
        ),
    ],
  );
}
