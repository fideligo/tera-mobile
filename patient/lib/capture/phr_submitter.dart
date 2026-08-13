/// Filing the PHR to `POST /v1/profile`.
///
/// **POST, not PATCH.** A second, B2C implementation of this route also exists on the backend
/// (`app/api/v1/profile.py`, PATCH-only) with none of this one's validation — no plausibility
/// bounds, no closed condition-code list — and it was what this file called until this note was
/// written. `postJson` is the tested, invariant-covered route; see docs/decisions.md.
///
/// The handset keeps its own copy in [SecurePhrProfileStore] and writes it first: onboarding must
/// work on a bad connection, and a form that refuses to advance because a request failed is a form
/// that strands a patient at step one of three.
///
/// The server copy is what survives an uninstall and what the rule engine can read. Both are
/// written; neither blocks.
library;

import '../api/api_client.dart';
import 'phr_profile.dart';

class PhrSubmitter {
  const PhrSubmitter({required ApiClient api}) : _api = api;

  final ApiClient _api;

  /// Only the fields a screen actually collected.
  ///
  /// The endpoint treats an absent field as "unchanged", so sending the whole profile from a
  /// screen that collected half of it would push nulls over the half it did not touch.
  /// Submits the entire gathered profile from ONB-01, 02, 03.
  static Map<String, dynamic> patchFor(PhrProfile profile) {
    return {
      if (profile.dateOfBirth != null)
        'date_of_birth': profile.dateOfBirth!.toIso8601String().split('T').first,
      if (profile.sexAtBirth != null) 'sex_assigned_at_birth': profile.sexAtBirth!.wireValue,
      if (profile.heightCm != null) 'height_cm': profile.heightCm,
      if (profile.weightKg != null) 'weight_kg': profile.weightKg,
      if (profile.hypertension != null) 'hypertension_status': profile.hypertension!.wireValue,
      if (profile.takesBpMedication != null)
        'taking_bp_medication': profile.takesBpMedication,
      'conditions': [for (final c in profile.conditions) c.wireValue],
      // postpartum / postpartumDate / rhythmAnswer are deliberately never sent: the tested
      // schema on `/v1/profile` is `extra="forbid"`, and these three have nowhere to go on the
      // wire — see PhrProfile's own docstring for why they stay handset-only. Including them
      // here used to 422 every onboarding submission that carried a value for any of the three.
    };
  }

  /// Returns whether it reached the server. Never throws.
  Future<bool> submit(PhrProfile profile) async {
    try {
      await _api.postJson('/v1/profile', patchFor(profile));
      return true;
    } on Object {
      return false;
    }
  }
}
