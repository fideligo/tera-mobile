/// Opening a check session and filing PRE-01 against it.
///
/// The session is opened at the **start** of the flow, in both modes. That is what gives PRE-01
/// and CTX-01 something to attach to: a sensor capture does not exist until capture is over, and
/// for a BP-only check it never exists at all.
library;

import '../api/api_client.dart';
import '../routing/check_session.dart';

class CheckSessionClient {
  const CheckSessionClient({required ApiClient api}) : _api = api;

  final ApiClient _api;

  /// Opens the session and returns its id.
  ///
  /// **Throws** rather than swallowing, unlike the context and PHR submitters. Everything
  /// downstream attaches to this id, so a flow that continued without one would collect PRE-01 and
  /// CTX-01 into nothing — which is the failure this whole change exists to remove. The caller
  /// decides what to show; it must not carry on silently.
  Future<String> open({required String episodeId, required CheckMode mode}) async {
    final body = await _api.postJson('/v1/check-sessions', {
      'episode_id': episodeId,
      'mode': mode == CheckMode.sensor ? 'sensor' : 'bp_only',
    });
    return body['id'] as String;
  }

  /// PRE-01's five answers.
  ///
  /// `is_ready` is deliberately not sent: the server derives it, so the handset cannot declare
  /// itself ready while reporting a confounder.
  ///
  /// Best effort. The readiness decision has already been made locally and the flow has already
  /// branched on it, so losing the upload loses a record, not a gate.
  Future<bool> submitPreconditions({
    required String checkSessionId,
    required PrecheckAnswers answers,
  }) async {
    try {
      // POST, not PATCH — this row is append-only (invariant 5), and the route inserts.
      await _api.postJson('/v1/check-sessions/$checkSessionId/preconditions', {
        'rested_5_min': answers.rested5Min,
        'recent_activity_30_min': answers.recentActivity30Min,
        'recent_caffeine_30_min': answers.recentCaffeine30Min,
        'recent_nicotine_30_min': answers.recentNicotine30Min,
        'needs_restroom': answers.needsRestroom,
      });
      return true;
    } on Object {
      return false;
    }
  }
}
