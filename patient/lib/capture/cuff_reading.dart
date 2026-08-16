/// Recording a cuff reading from the handset.
///
/// **This is the only way a blood-pressure number enters the system** (invariant 1), and it is the
/// half of the method that makes the rest legitimate: PTT tracks change, and change is only
/// meaningful against a baseline a validated upper-arm cuff established. Without this path the
/// calibration loop cannot be closed from the phone at all.
///
/// # Manual entry only
///
/// The patient reads the numbers off their own cuff and types them in. `source` is always
/// `manual_entry`. Seven-segment OCR from a photograph is out of scope (BUILD_SPEC 8): the backend
/// refuses `source = 'photograph'` and refuses `ocr_confidence` outright, because accepting either
/// would imply a capability that does not exist.
///
/// # Confirmation is structural, not a checkbox
///
/// `user_confirmed_at` is NOT NULL in the schema — a cuff reading that nobody confirmed is not a
/// thing the system can represent. That is enforced here by construction rather than by a flag
/// somebody sets: [ConfirmedCuffReading] cannot be built without a confirmation instant, and
/// [CuffReadingSubmitter.submit] takes only that type. There is no path from a form field to the
/// API that does not pass through a person saying yes.
///
/// The reason is that a typo in a blood pressure is not like a typo elsewhere. It becomes the
/// reference every subsequent estimate is measured against, it is append-only, and the correction
/// is a new row rather than an edit. Cheap to confirm, expensive to get wrong.
library;

import 'package:meta/meta.dart';

import '../api/api_client.dart';

/// Data-entry bounds, mirroring the backend's `PlausibilitySettings`.
///
/// **These are data-entry filters, not clinical thresholds.** A value inside the range is not
/// "normal" and a value at the edge is not an alarm; the system does not make that judgement
/// (invariant 6). They exist so an obvious slip is caught while the cuff is still in front of the
/// patient, rather than after a round trip.
const int systolicMinMmhg = 50;
const int systolicMaxMmhg = 300;
const int diastolicMinMmhg = 30;
const int diastolicMaxMmhg = 200;
const int pulseMinBpm = 25;
const int pulseMaxBpm = 250;

@immutable
class CuffReadingViolation {
  const CuffReadingViolation(this.field, this.message);

  /// Matches the backend's field names, so a client-side and a server-side rejection of the same
  /// value read identically to whoever is debugging.
  final String field;
  final String message;
}

/// What the patient typed, before anyone confirmed it.
@immutable
class DraftCuffReading {
  const DraftCuffReading({
    required this.systolicMmhg,
    required this.diastolicMmhg,
    this.pulseBpm,
    this.takenAt,
  });

  final int systolicMmhg;
  final int diastolicMmhg;
  final int? pulseBpm;

  /// When the cuff was used. Defaults to the moment of confirmation.
  final DateTime? takenAt;

  /// Mirrors `check_cuff_reading` on the backend, in the same order, with the same wording.
  List<CuffReadingViolation> validate() {
    final violations = <CuffReadingViolation>[];

    if (systolicMmhg < systolicMinMmhg || systolicMmhg > systolicMaxMmhg) {
      violations.add(
        CuffReadingViolation(
          'systolic_mmhg',
          'Top number must be between $systolicMinMmhg and $systolicMaxMmhg.',
        ),
      );
    }
    if (diastolicMmhg < diastolicMinMmhg || diastolicMmhg > diastolicMaxMmhg) {
      violations.add(
        CuffReadingViolation(
          'diastolic_mmhg',
          'Bottom number must be between $diastolicMinMmhg and $diastolicMaxMmhg.',
        ),
      );
    }
    if (systolicMmhg <= diastolicMmhg) {
      violations.add(
        const CuffReadingViolation(
          'systolic_mmhg',
          'The top number must be higher than the bottom number. They may have been swapped.',
        ),
      );
    }
    final pulse = pulseBpm;
    if (pulse != null && (pulse < pulseMinBpm || pulse > pulseMaxBpm)) {
      violations.add(
        CuffReadingViolation(
          'pulse_bpm',
          'Pulse must be between $pulseMinBpm and $pulseMaxBpm.',
        ),
      );
    }

    return violations;
  }

  /// Confirm this reading. The only way to produce a [ConfirmedCuffReading].
  ///
  /// Throws [StateError] if the draft does not validate, so an invalid reading cannot be confirmed
  /// into existence by a caller that forgot to check.
  ConfirmedCuffReading confirm({DateTime? at}) {
    final violations = validate();
    if (violations.isNotEmpty) {
      throw StateError(
        'an invalid cuff reading cannot be confirmed: ${violations.first.message}',
      );
    }
    final now = at ?? DateTime.now().toUtc();
    return ConfirmedCuffReading._(draft: this, confirmedAt: now);
  }
}

/// A reading a person has explicitly confirmed.
///
/// The private constructor is the point: this type cannot be created anywhere except
/// [DraftCuffReading.confirm], so "was this confirmed" is answered by the type system rather than
/// by reading the call site.
@immutable
class ConfirmedCuffReading {
  const ConfirmedCuffReading._({
    required this.draft,
    required this.confirmedAt,
  });

  final DraftCuffReading draft;
  final DateTime confirmedAt;

  Map<String, dynamic> toPayload(String episodeId) => {
    'episode_id': episodeId,
    'systolic_mmhg': draft.systolicMmhg,
    'diastolic_mmhg': draft.diastolicMmhg,
    if (draft.pulseBpm != null) 'pulse_bpm': draft.pulseBpm,
    // Never anything else. OCR is not implemented and the backend refuses the value.
    'source': 'manual_entry',
    'taken_at': (draft.takenAt ?? confirmedAt).toUtc().toIso8601String(),
    'user_confirmed_at': confirmedAt.toUtc().toIso8601String(),
    // Stated, not left to the server's default. Invariant 9 turns on synthetic data being
    // unmistakably labelled, and a payload that says what it is beats one that is only ever
    // false because nobody set it. `SessionSubmitter` sends it for the same reason.
    'synthetic': false,
  };
}

/// Sends a confirmed reading. Takes [ConfirmedCuffReading] and nothing else, by design.
class CuffReadingSubmitter {
  const CuffReadingSubmitter({required ApiClient api}) : _api = api;

  final ApiClient _api;

  Future<Map<String, dynamic>> submit({
    required ConfirmedCuffReading reading,
    required String episodeId,
  }) => _api.postJson('/v1/cuff-readings', reading.toPayload(episodeId));
}
