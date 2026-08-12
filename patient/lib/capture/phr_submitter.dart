/// Filing the PHR to `POST /v1/profile`.
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
  static Map<String, dynamic> patchFor(PhrProfile profile, {required OnboardingSection section}) {
    switch (section) {
      case OnboardingSection.aboutYou:
        return {
          if (profile.dateOfBirth != null)
            'date_of_birth': profile.dateOfBirth!.toIso8601String().split('T').first,
          if (profile.sexAtBirth != null) 'sex_assigned_at_birth': profile.sexAtBirth!.wireValue,
          if (profile.heightCm != null) 'height_cm': profile.heightCm,
          if (profile.weightKg != null) 'weight_kg': profile.weightKg,
        };
      case OnboardingSection.healthContext:
        return {
          if (profile.hypertension != null) 'hypertension_status': profile.hypertension!.wireValue,
          if (profile.takesBpMedication != null)
            'taking_bp_medication': profile.takesBpMedication,
          'conditions': [for (final c in profile.conditions) c.wireValue],
        };
    }
  }

  /// Returns whether it reached the server. Never throws.
  Future<bool> submit(PhrProfile profile, {required OnboardingSection section}) async {
    try {
      await _api.postJson('/v1/profile', patchFor(profile, section: section));
      return true;
    } on Object {
      return false;
    }
  }
}

/// Which screen is saving. Determines which fields the patch carries.
enum OnboardingSection { aboutYou, healthContext }
