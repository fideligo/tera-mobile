/// CTX-01 — what is different about today.
///
/// The spec calls this "current context" and is explicit that it is **not** the pre-check. The
/// pre-check asks whether the measurement will be comparable; this asks what was going on around
/// it, and feeds the intervention matrix rather than the quality gate.
///
/// # Invariant 6 applies here as everywhere
///
/// These fields are *reported*, never interpreted on the handset. "Feeling unwell" does not
/// downgrade a result, and a missed medication dose does not produce advice. The deterministic
/// rule engine on the server decides what, if anything, any of it means.
///
/// # A symptom here is not a red flag
///
/// Red flags terminate the session before capture, locally and offline — that is
/// `symptom_triage.dart` and invariant 8. By the time this screen is reached those have already
/// been asked and answered "none". The symptoms here are the milder, contextual ones, and a
/// patient who develops a red flag mid-flow uses the triage path, not this list.
library;

import 'package:meta/meta.dart';

/// The spec's medication question: "Did you take your blood pressure medication as usual today?"
///
/// Four-valued because "not applicable" and "not sure" are different from yes and from no, and
/// collapsing them would record a statement the patient did not make.
enum MedicationStatusToday {
  asUsual('as_usual', 'Yes, as usual'),
  missedOrLate('missed_or_late', 'No, missed or late'),
  notApplicable('not_applicable', 'I do not take BP medication'),
  notSure('not_sure', 'Not sure');

  const MedicationStatusToday(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static MedicationStatusToday fromWire(String? v) => MedicationStatusToday
      .values
      .firstWhere((m) => m.wireValue == v, orElse: () => notSure);
}

/// The milder, contextual symptoms. Deliberately **not** the invariant 8 red-flag list.
enum ContextSymptom {
  headache('headache', 'Headache'),
  dizziness('dizziness', 'Dizziness or light-headedness'),
  palpitations('palpitations', 'Palpitations'),
  fatigue('fatigue', 'Unusual tiredness'),
  swelling('swelling', 'Swollen ankles or feet');

  const ContextSymptom(this.wireValue, this.label);

  final String wireValue;
  final String label;
}

@immutable
class CurrentContext {
  const CurrentContext({
    this.sleepLessThanUsual = false,
    this.stressHigherThanUsual = false,
    this.feelingUnwell = false,
    this.symptoms = const {},
    this.medicationStatusToday = MedicationStatusToday.notSure,
  });

  final bool sleepLessThanUsual;
  final bool stressHigherThanUsual;
  final bool feelingUnwell;
  final Set<ContextSymptom> symptoms;
  final MedicationStatusToday medicationStatusToday;

  /// True when nothing was reported. The spec's UX rule is that an unremarkable day should be one
  /// tap, so this is the state the screen opens in.
  bool get isUnremarkable =>
      !sleepLessThanUsual &&
      !stressHigherThanUsual &&
      !feelingUnwell &&
      symptoms.isEmpty &&
      medicationStatusToday == MedicationStatusToday.notSure;

  Map<String, dynamic> toJson() => {
    'sleep_less_than_usual': sleepLessThanUsual,
    'stress_higher_than_usual': stressHigherThanUsual,
    'feeling_unwell': feelingUnwell,
    'symptoms': [for (final s in symptoms) s.wireValue],
    'medication_status_today': medicationStatusToday.wireValue,
  };

  static CurrentContext fromJson(Map<String, dynamic> json) => CurrentContext(
    sleepLessThanUsual: json['sleep_less_than_usual'] as bool? ?? false,
    stressHigherThanUsual: json['stress_higher_than_usual'] as bool? ?? false,
    feelingUnwell: json['feeling_unwell'] as bool? ?? false,
    symptoms: {
      for (final v in (json['symptoms'] as List<dynamic>? ?? []))
        ...ContextSymptom.values.where((s) => s.wireValue == v),
    },
    medicationStatusToday: MedicationStatusToday.fromWire(
      json['medication_status_today'] as String?,
    ),
  );
}
