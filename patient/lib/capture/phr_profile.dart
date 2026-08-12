/// ONB-01 and ONB-03 — the minimum viable PHR.
///
/// The spec is explicit that onboarding is not a complete health intake: it collects only what
/// safety and basic interpretation need, and enrichment happens progressively in Profile.
///
/// # Nothing here is interpreted on the handset
///
/// Height and weight are stored, and **no BMI is computed or shown**. The spec says so directly
/// ("jangan otomatis mendiagnosis berdasarkan BMI") and invariant 6 says it generally. Likewise a
/// hypertension diagnosis is recorded as something the patient reported, never inferred.
///
/// # Stored locally, and uploaded where an endpoint exists
///
/// `/v1/patient-context` already carries the ONB-02 answers — pregnancy, rhythm, medications, the
/// last clinic reading. It has no columns for date of birth, sex, height, weight or a hypertension
/// flag, and adding them is a backend change rather than a routine one. So this half of the PHR is
/// kept on the handset and the overlap (medications) continues to go through the existing intake.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:meta/meta.dart';

/// ONB-01. Three options, matching the spec.
enum SexAtBirth {
  female('female', 'Female'),
  male('male', 'Male'),
  preferNotToSay('prefer_not_to_say', 'Prefer not to say');

  const SexAtBirth(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static SexAtBirth? fromWire(String? v) =>
      v == null ? null : SexAtBirth.values.where((s) => s.wireValue == v).firstOrNull;
}

/// ONB-03's hypertension question.
enum HypertensionStatus {
  diagnosed('diagnosed', 'Yes, diagnosed'),
  notDiagnosed('not_diagnosed', 'No'),
  notSure('not_sure', 'Not sure');

  const HypertensionStatus(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static HypertensionStatus? fromWire(String? v) =>
      v == null ? null : HypertensionStatus.values.where((s) => s.wireValue == v).firstOrNull;
}

/// ONB-03's condition list. Reported, never inferred.
enum KnownCondition {
  diabetes('diabetes', 'Diabetes'),
  kidneyDisease('kidney_disease', 'Kidney disease'),
  heartDisease('heart_disease', 'Heart disease'),
  stroke('stroke', 'Previous stroke'),
  highCholesterol('high_cholesterol', 'High cholesterol');

  const KnownCondition(this.wireValue, this.label);

  final String wireValue;
  final String label;
}

@immutable
class PhrProfile {
  const PhrProfile({
    this.displayName,
    this.postpartum,
    this.postpartumDate,
    this.rhythmAnswer,
    this.dateOfBirth,
    this.sexAtBirth,
    this.heightCm,
    this.weightKg,
    this.hypertension,
    this.takesBpMedication,
    this.conditions = const {},
  });

  /// What the patient asked to be called, collected at sign-up.
  ///
  /// **Handset only, and deliberately so.** `/v1/auth/register-patient` takes a login subject and
  /// a password and nothing else; it generates a pseudonym rather than storing a name, and its
  /// docstring says outright that deriving one from the sign-up details would put a name into the
  /// clinical record sideways. So the name greets the patient on their own phone and never
  /// travels: it lives here with the rest of the local PHR, behind the same Keystore as the
  /// tokens.
  final String? displayName;

  /// ONB-02's "recently gave birth", and the date.
  ///
  /// Handset-only. `PregnancyAnswer` on the wire is three-valued (`yes` / `no` /
  /// `prefer_not_to_say`) and has nowhere to put a fourth state, so the answer is recorded here
  /// rather than collapsed into one of the three and lost. Whether postpartum should close the
  /// contraindication gate is an open clinical question — see `docs/decisions.md`.
  final bool? postpartum;
  final DateTime? postpartumDate;

  /// ONB-02's rhythm question, as the patient answered it: `yes`, `no` or `notSure`.
  ///
  /// `known_arrhythmia` on the wire is a bool, and "not sure" is not an assertion of arrhythmia,
  /// so it travels as false. The distinction is kept here.
  final String? rhythmAnswer;

  // ONB-01. DOB and sex are required by the spec; height and weight may be skipped.
  final DateTime? dateOfBirth;
  final SexAtBirth? sexAtBirth;
  final double? heightCm;
  final double? weightKg;

  // ONB-03.
  final HypertensionStatus? hypertension;
  final bool? takesBpMedication;
  final Set<KnownCondition> conditions;

  bool get aboutYouComplete => dateOfBirth != null && sexAtBirth != null;
  bool get healthContextComplete => hypertension != null && takesBpMedication != null;

  /// Sanity bounds, not clinical ones. They exist to catch a slipped decimal point, and a value
  /// inside them is not a judgement about anybody.
  static const double minHeightCm = 50;
  static const double maxHeightCm = 250;
  static const double minWeightKg = 10;
  static const double maxWeightKg = 400;

  static bool heightIsPlausible(double v) => v >= minHeightCm && v <= maxHeightCm;
  static bool weightIsPlausible(double v) => v >= minWeightKg && v <= maxWeightKg;

  /// A birth date in the future is a typo, not a person.
  static bool dobIsPlausible(DateTime dob, {DateTime? now}) =>
      !dob.isAfter(now ?? DateTime.now());

  PhrProfile copyWith({
    String? displayName,
    bool? postpartum,
    DateTime? postpartumDate,
    String? rhythmAnswer,
    DateTime? dateOfBirth,
    SexAtBirth? sexAtBirth,
    double? heightCm,
    double? weightKg,
    HypertensionStatus? hypertension,
    bool? takesBpMedication,
    Set<KnownCondition>? conditions,
  }) => PhrProfile(
    displayName: displayName ?? this.displayName,
    postpartum: postpartum ?? this.postpartum,
    postpartumDate: postpartumDate ?? this.postpartumDate,
    rhythmAnswer: rhythmAnswer ?? this.rhythmAnswer,
    dateOfBirth: dateOfBirth ?? this.dateOfBirth,
    sexAtBirth: sexAtBirth ?? this.sexAtBirth,
    heightCm: heightCm ?? this.heightCm,
    weightKg: weightKg ?? this.weightKg,
    hypertension: hypertension ?? this.hypertension,
    takesBpMedication: takesBpMedication ?? this.takesBpMedication,
    conditions: conditions ?? this.conditions,
  );

  Map<String, dynamic> toJson() => {
    'display_name': displayName,
    'postpartum': postpartum,
    'postpartum_date': postpartumDate?.toUtc().toIso8601String(),
    'rhythm_answer': rhythmAnswer,
    'date_of_birth': dateOfBirth?.toUtc().toIso8601String(),
    'sex_at_birth': sexAtBirth?.wireValue,
    'height_cm': heightCm,
    'weight_kg': weightKg,
    'hypertension': hypertension?.wireValue,
    'takes_bp_medication': takesBpMedication,
    'conditions': [for (final c in conditions) c.wireValue],
  };

  static PhrProfile fromJson(Map<String, dynamic> json) => PhrProfile(
    displayName: json['display_name'] as String?,
    postpartum: json['postpartum'] as bool?,
    postpartumDate: json['postpartum_date'] == null
        ? null
        : DateTime.parse(json['postpartum_date'] as String),
    rhythmAnswer: json['rhythm_answer'] as String?,
    dateOfBirth: json['date_of_birth'] == null
        ? null
        : DateTime.parse(json['date_of_birth'] as String),
    sexAtBirth: SexAtBirth.fromWire(json['sex_at_birth'] as String?),
    heightCm: (json['height_cm'] as num?)?.toDouble(),
    weightKg: (json['weight_kg'] as num?)?.toDouble(),
    hypertension: HypertensionStatus.fromWire(json['hypertension'] as String?),
    takesBpMedication: json['takes_bp_medication'] as bool?,
    conditions: {
      for (final v in (json['conditions'] as List<dynamic>? ?? []))
        ...KnownCondition.values.where((c) => c.wireValue == v),
    },
  );
}

abstract class PhrProfileStore {
  Future<PhrProfile> read();
  Future<void> write(PhrProfile profile);
}

class SecurePhrProfileStore implements PhrProfileStore {
  SecurePhrProfileStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));

  final FlutterSecureStorage _storage;

  static const _key = 'tera.phr_profile';

  @override
  Future<PhrProfile> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return const PhrProfile();
    try {
      return PhrProfile.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return const PhrProfile();
    }
  }

  @override
  Future<void> write(PhrProfile profile) =>
      _storage.write(key: _key, value: jsonEncode(profile.toJson()));
}

class InMemoryPhrProfileStore implements PhrProfileStore {
  PhrProfile _profile = const PhrProfile();

  @override
  Future<PhrProfile> read() async => _profile;

  @override
  Future<void> write(PhrProfile profile) async => _profile = profile;
}
