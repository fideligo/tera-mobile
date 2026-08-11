/// Clinical context the patient supplies once, and the safety rules that read it.
///
/// The B2C app has no clinic behind it. Nobody enrols the patient, nobody reviews their history,
/// and nobody notices that the method is being applied to someone it was never validated on. The
/// intake form is the only place that information can come from, so it is also the only place a
/// contraindication can be caught.
///
/// # The rules are deterministic and live in Dart
///
/// [ContextIntakeSafety.evaluate] is a pure function of the intake. No network, no clock, no
/// model. A contraindication that depended on reaching a server would fail open on a bad
/// connection, and failing open is the direction that costs something.
///
/// # Stored locally *and* on the server
///
/// The handset copy is what the gate reads, because a contraindication that needed a network call
/// would fail open on a bad connection. `POST /v1/patient-context` is the durable record: without
/// it the intake vanished on uninstall, and the server could not see a contraindication it is
/// expected to respect.
///
/// The two are not kept in lockstep. The local write happens first and always; the upload is
/// attempted after and its failure never blocks the patient — see [PatientContextSubmitter].
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:meta/meta.dart';

import '../api/api_client.dart';
import 'cuff_reading.dart';

/// Deliberately three-valued. A patient who declines to answer has given a different answer from
/// "no", and collapsing the two would record a statement they did not make.
enum PregnancyAnswer {
  yes('yes'),
  no('no'),
  preferNotToSay('prefer_not_to_say');

  const PregnancyAnswer(this.wireValue);

  final String wireValue;

  static PregnancyAnswer fromWire(String value) =>
      PregnancyAnswer.values.firstWhere((a) => a.wireValue == value, orElse: () => no);
}

@immutable
class Medication {
  const Medication({required this.name, required this.dose});

  final String name;
  final String dose;

  bool get isEmpty => name.trim().isEmpty && dose.trim().isEmpty;

  Map<String, dynamic> toJson() => {'name': name.trim(), 'dose': dose.trim()};

  static Medication fromJson(Map<String, dynamic> json) =>
      Medication(name: json['name'] as String? ?? '', dose: json['dose'] as String? ?? '');
}

/// The last blood pressure taken somewhere with a real cuff and a clinician.
@immutable
class ClinicBloodPressure {
  const ClinicBloodPressure({
    required this.systolicMmhg,
    required this.diastolicMmhg,
    required this.takenOn,
  });

  final int systolicMmhg;
  final int diastolicMmhg;
  final DateTime takenOn;

  /// Same bounds as a cuff reading, from the one place they are defined.
  List<CuffReadingViolation> validate() => DraftCuffReading(
    systolicMmhg: systolicMmhg,
    diastolicMmhg: diastolicMmhg,
  ).validate();

  Map<String, dynamic> toJson() => {
    'systolic_mmhg': systolicMmhg,
    'diastolic_mmhg': diastolicMmhg,
    'taken_on': takenOn.toUtc().toIso8601String(),
  };

  static ClinicBloodPressure fromJson(Map<String, dynamic> json) => ClinicBloodPressure(
    systolicMmhg: json['systolic_mmhg'] as int,
    diastolicMmhg: json['diastolic_mmhg'] as int,
    takenOn: DateTime.parse(json['taken_on'] as String),
  );
}

@immutable
class ContextIntake {
  const ContextIntake({
    this.lastRegimenChangeDate,
    this.medications = const [],
    required this.pregnant,
    required this.knownArrhythmia,
    this.lastClinicBp,
  });

  /// When the patient's medication last changed. Null means "not answered".
  final DateTime? lastRegimenChangeDate;

  final List<Medication> medications;
  final PregnancyAnswer pregnant;
  final bool knownArrhythmia;
  final ClinicBloodPressure? lastClinicBp;

  Map<String, dynamic> toJson() => {
    'last_regimen_change_date': lastRegimenChangeDate?.toUtc().toIso8601String(),
    'medications': [for (final m in medications) m.toJson()],
    'pregnant': pregnant.wireValue,
    'known_arrhythmia': knownArrhythmia,
    'last_clinic_bp': lastClinicBp?.toJson(),
  };

  static ContextIntake fromJson(Map<String, dynamic> json) => ContextIntake(
    lastRegimenChangeDate: json['last_regimen_change_date'] == null
        ? null
        : DateTime.parse(json['last_regimen_change_date'] as String),
    medications: [
      for (final m in (json['medications'] as List<dynamic>? ?? []))
        Medication.fromJson(m as Map<String, dynamic>),
    ],
    pregnant: PregnancyAnswer.fromWire(json['pregnant'] as String? ?? 'no'),
    knownArrhythmia: json['known_arrhythmia'] as bool? ?? false,
    lastClinicBp: json['last_clinic_bp'] == null
        ? null
        : ClinicBloodPressure.fromJson(json['last_clinic_bp'] as Map<String, dynamic>),
  );
}

// ------------------------------------------------------------------------ safety ----

enum IntakeGate {
  /// Nothing in the intake contraindicates a spot check.
  clear,

  /// Pregnancy reported. No capture, no submission, no trend.
  blockedPregnancy,
}

/// What the patient is told when the gate closes.
///
/// It names the limitation and refers on. It does not diagnose, does not estimate risk, and does
/// not reassure — invariant 6 applies here exactly as it does everywhere else.
const String pregnancyBlockTitle = 'Tera cannot be used during pregnancy';

const String pregnancyBlockMessage =
    'Method unvalidated in pregnancy. Please consult your doctor.\n\n'
    'Blood pressure in pregnancy changes for reasons this method was never tested against, and '
    'Tera cannot tell those changes apart. It will not record spot checks or produce trends '
    'while this is set.';

abstract final class ContextIntakeSafety {
  /// Pure. Same intake in, same gate out, with no IO of any kind.
  ///
  /// Only [PregnancyAnswer.yes] closes the gate. **[PregnancyAnswer.preferNotToSay] does not** —
  /// blocking on a declined answer would make declining functionally identical to saying yes, and
  /// would coerce a disclosure the patient chose not to make. It is recorded as what it is.
  ///
  /// [ContextIntake.knownArrhythmia] is recorded and shown but does not gate. It degrades beat
  /// detection rather than invalidating the method, and the signal chain's own quality gate is
  /// where a capture too irregular to use gets rejected.
  static IntakeGate evaluate(ContextIntake intake) =>
      intake.pregnant == PregnancyAnswer.yes ? IntakeGate.blockedPregnancy : IntakeGate.clear;

  /// Whether a spot check may proceed to capture and submission.
  static bool allowsTrendGeneration(ContextIntake? intake) =>
      intake == null || evaluate(intake) == IntakeGate.clear;
}

// ------------------------------------------------------------------------ storage ----

abstract class ContextIntakeStore {
  Future<ContextIntake?> read();
  Future<void> write(ContextIntake intake);
  Future<void> clear();
}

class SecureContextIntakeStore implements ContextIntakeStore {
  SecureContextIntakeStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));

  final FlutterSecureStorage _storage;

  static const _key = 'tera.context_intake';

  @override
  Future<ContextIntake?> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    try {
      return ContextIntake.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      // A stored blob that no longer parses is treated as absent rather than crashing the app on
      // launch. The patient is asked again, which is recoverable; a crash loop is not.
      return null;
    }
  }

  @override
  Future<void> write(ContextIntake intake) =>
      _storage.write(key: _key, value: jsonEncode(intake.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

class InMemoryContextIntakeStore implements ContextIntakeStore {
  ContextIntake? _intake;

  @override
  Future<ContextIntake?> read() async => _intake;

  @override
  Future<void> write(ContextIntake intake) async => _intake = intake;

  @override
  Future<void> clear() async => _intake = null;
}

// ------------------------------------------------------------------------ upload ----

/// Sends the intake to `POST /v1/patient-context`.
///
/// **Never throws, never blocks, and its result never gates the patient.** The local copy is
/// already written by the time this runs, and the safety rules read that copy. A patient on a bad
/// connection is not stopped from using the app, and a patient who reported a contraindication is
/// blocked whether or not the server heard about it.
///
/// The wire shape is flat rather than the nested `last_clinic_bp` object the form uses: the
/// backend keeps the three clinic-reading values in their own columns so a CHECK can hold them
/// together, and matching that here keeps the mapping obvious in one place instead of two.
class PatientContextSubmitter {
  const PatientContextSubmitter({required ApiClient api}) : _api = api;

  final ApiClient _api;

  static Map<String, dynamic> payload(ContextIntake intake) {
    final bp = intake.lastClinicBp;
    return {
      'last_regimen_change_date': intake.lastRegimenChangeDate?.toUtc().toIso8601String(),
      'medications': [
        for (final m in intake.medications)
          if (!m.isEmpty) {'name': m.name.trim(), 'dose': m.dose.trim()},
      ],
      'pregnant': intake.pregnant.wireValue,
      'known_arrhythmia': intake.knownArrhythmia,
      'last_clinic_systolic_mmhg': bp?.systolicMmhg,
      'last_clinic_diastolic_mmhg': bp?.diastolicMmhg,
      'last_clinic_taken_on': bp?.takenOn.toUtc().toIso8601String(),
    };
  }

  /// Returns whether the server accepted it. The caller may show it; nothing else depends on it.
  Future<bool> submit(ContextIntake intake) async {
    try {
      await _api.postJson('/v1/patient-context', payload(intake));
      return true;
    } on Object {
      // Swallowed on purpose. See the class docstring.
      return false;
    }
  }
}
