/// Invariant 8 on the handset: red-flag symptoms terminate the session, locally.
///
/// The invariant's exact words are that a red flag produces "an immediate instruction to seek
/// emergency care, with no measurement offered and no estimate displayed", and that **this path
/// must not depend on network availability** — the handset shows it locally; the API call is a
/// record, not a precondition.
///
/// The backend half has existed since Phase 1: `POST /v1/events` accepts a `red_flag` event and
/// echoes an `emergency_instruction`. The handset half did not exist at all, which meant the half
/// the invariant explicitly says must work offline was the half that was missing.
///
/// # Why this file has no ApiClient
///
/// The absence is the design. [SymptomTriage.decide] is a pure function of what the patient
/// selected, and [emergencyInstruction] is a compile-time constant. There is no code path from
/// selecting a red flag to showing the instruction that can touch a socket, so "works offline"
/// is a property of the structure rather than a behaviour someone has to remember to test on a
/// plane.
///
/// Recording is separate, deliberately: [RedFlagRecorder] runs after the instruction is already
/// on screen, and cannot fail in a way the patient sees.
library;

import 'package:meta/meta.dart';

import '../api/api_client.dart';

/// The five red flags named in invariant 8.
///
/// The wire values go into the event payload. The labels are what the patient reads, written for
/// someone holding a phone in poor light who may be frightened: plain words, no clinical terms,
/// and each one describes a sensation rather than a diagnosis.
enum RedFlagSymptom {
  chestPain('chest_pain', 'Chest pain, tightness or pressure'),
  severeBreathlessness('severe_breathlessness', 'Severe shortness of breath'),
  severeHeadache('severe_headache', 'A sudden or severe headache'),
  visualDisturbance('visual_disturbance', 'A sudden change in your eyesight'),
  weaknessOrSpeechDifficulty(
    'weakness_or_speech_difficulty',
    'New weakness or numbness, or trouble speaking',
  );

  const RedFlagSymptom(this.wireValue, this.label);

  final String wireValue;
  final String label;
}

/// What the app does next.
enum TriageOutcome {
  /// Nothing reported. The spot check may go ahead.
  proceed,

  /// At least one red flag. The session ends here.
  emergency,
}

/// **The instruction, held locally.**
///
/// A verbatim copy of `ACTION_SEEK_EMERGENCY_CARE` in the backend's `app/services/language.py`.
/// It is duplicated rather than fetched because fetching it would make the one path that must
/// survive a dead network depend on that network. The backend's copy is the record of what was
/// shown; this is what is shown.
///
/// If the wording changes, change it in both places. `language.py` is the source of the words.
const String emergencyInstruction =
    'Seek emergency care now. Call your local emergency number or go to an emergency '
    'department. Do not wait for a measurement.';

/// Why the emergency screen never softens.
///
/// Invariant 6 forbids diagnosis and reassurance alike. This says what to do and stops: it does
/// not say what the symptoms might mean, does not estimate how urgent it is, and does not offer a
/// measurement as an alternative to going.
const String emergencySupportingText =
    'Tera has stopped this spot check. It does not measure blood pressure and it cannot tell you '
    'what these symptoms mean. Getting seen matters more than any reading.';

@immutable
class TriageDecision {
  const TriageDecision({required this.outcome, required this.selected});

  final TriageOutcome outcome;
  final Set<RedFlagSymptom> selected;

  bool get isEmergency => outcome == TriageOutcome.emergency;
}

abstract final class SymptomTriage {
  /// Pure. No IO, no clock, no network.
  ///
  /// Any selection at all is an emergency: there is no severity weighting and no combination that
  /// is safe to wave through. Invariant 7 — a false alarm costs a wasted trip, a false
  /// reassurance can cost much more.
  static TriageDecision decide(Set<RedFlagSymptom> selected) => TriageDecision(
    outcome: selected.isEmpty ? TriageOutcome.proceed : TriageOutcome.emergency,
    selected: selected,
  );
}

/// Records that a red flag was reported. Best effort, after the fact.
///
/// **Never throws, never blocks, and its result never changes what the patient sees.** The
/// instruction is already on screen by the time this runs. A patient in the middle of a possible
/// emergency is not going to be shown a network error, and must not be made to wait on a retry.
class RedFlagRecorder {
  const RedFlagRecorder({required ApiClient api}) : _api = api;

  final ApiClient _api;

  /// Returns whether the record reached the server. The caller may log it; nothing else.
  Future<bool> record({
    required String episodeId,
    required Set<RedFlagSymptom> symptoms,
    DateTime? occurredAt,
  }) async {
    try {
      await _api.postJson('/v1/events', {
        'episode_id': episodeId,
        'event_type': 'red_flag',
        'occurred_at': (occurredAt ?? DateTime.now().toUtc()).toUtc().toIso8601String(),
        'payload': {
          'symptoms': [for (final s in symptoms) s.wireValue],
          // What the handset showed, so the record says what the patient was actually told
          // rather than leaving it to be inferred from the event type.
          'instruction_shown': emergencyInstruction,
        },
        'synthetic': false,
      });
      return true;
    } on Object {
      // Swallowed on purpose. See the class docstring: this is a record, not a precondition.
      return false;
    }
  }
}
