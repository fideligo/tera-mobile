/// Filing CTX-01 to the backend.
///
/// # Two routes, and which one is used depends on whether a session exists
///
/// `POST /v1/check-sessions/{id}/context` is the real home: a typed table, closed symptom codes,
/// and a backend that can tell a context record from a reported symptom without inspecting a
/// payload. It needs a `session_id`, which only exists **after** the check is submitted — CTX-01
/// is collected before capture, so the context is held in the flow's payload and filed afterwards.
///
/// **BP-only has no session to attach to.** A confirmed cuff reading is not a
/// `measurement_session`, so there is no id for that route. Rather than lose the context, it falls
/// back to `/v1/events` as a `symptom` event, which needs only an episode. The fallback is
/// recorded in `docs/decisions.md` as a gap, not a design: the two modes should file context the
/// same way once BP-only checks get a session of their own.
///
/// # It is filed even when nothing was reported
///
/// "Nothing different today" is a real input to the intervention matrix, not an absence of one. A
/// day with no context recorded and a day recorded as unremarkable are different facts, and only
/// one of them can be told apart later.
library;

import '../api/api_client.dart';
import 'current_context.dart';

class CurrentContextSubmitter {
  const CurrentContextSubmitter({required ApiClient api}) : _api = api;

  final ApiClient _api;

  /// File against a submitted session. The typed route.
  ///
  /// **Never throws and never gates the check** — the measurement is the point of the flow, and
  /// losing the context should not lose the reading.
  Future<bool> submitForSession({
    required String sessionId,
    required CurrentContext context,
  }) async {
    try {
      await _api.postJson('/v1/check-sessions/$sessionId/context', context.toJson());
      return true;
    } on Object {
      return false;
    }
  }

  /// BP-only fallback: no session exists, so the context rides on an episode-scoped event.
  Future<bool> submit({
    required String episodeId,
    required CurrentContext context,
    DateTime? occurredAt,
  }) async {
    try {
      await _api.postJson('/v1/events', {
        'episode_id': episodeId,
        'event_type': 'symptom',
        'occurred_at': (occurredAt ?? DateTime.now()).toUtc().toIso8601String(),
        'payload': context.toJson(),
        'synthetic': false,
      });
      return true;
    } on Object {
      return false;
    }
  }
}
