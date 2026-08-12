/// Filing CTX-01 to the backend.
///
/// # Why `/v1/events` and not a new endpoint
///
/// `POST /v1/sessions` sets `extra="forbid"`, so a `context` field cannot ride along without a
/// schema change — and that schema is the one invariant 2 is expressed in, which is not a place to
/// add a free-form object casually. `/v1/events` already exists for exactly this shape: an episode,
/// a time, and a bounded free-form payload, with the bound (32 keys) there to stop it becoming a
/// data channel. Five keys fit comfortably inside it.
///
/// The event type is `symptom`. It is the only contextual type the enum offers — `medication` is
/// for a dose event and `red_flag` terminates a session — and the payload carries the medication
/// answer as one of its fields rather than as a second event.
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

  /// Returns whether it reached the server. **Never throws and never gates the check** — the
  /// measurement is the point of the flow, and losing the context should not lose the reading.
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
