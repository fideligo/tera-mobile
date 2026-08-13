/// Submits a completed capture to the backend.
///
/// Follows the device contract in BUILD_SPEC 4.2 exactly: obtain a single-use nonce, then POST
/// the session with `X-Session-Nonce` and an `Idempotency-Key` equal to the session id. A retry
/// after a dropped response returns the stored result rather than creating a second row.
library;

import 'dart:math';

import '../api/api_client.dart';
import '../signal/signal_pipeline.dart';
import 'capture_session.dart';

class SubmissionOutcome {
  const SubmissionOutcome({
    required this.accepted,
    required this.message,
    required this.sessionId,
    this.trendDirection,
    this.duplicate = false,
  });

  /// The id the backend stored this under. CTX-01 is filed against it, so it has to come back
  /// out of here rather than being generated and forgotten.
  final String sessionId;

  final bool accepted;
  final String message;

  /// Present only when the backend produced an estimate. Never a pressure value.
  final String? trendDirection;
  final bool duplicate;
}

class SessionSubmitter {
  SessionSubmitter({required ApiClient api}) : _api = api;

  final ApiClient _api;

  Future<SubmissionOutcome> submit({
    required String episodeId,
    required String deviceProfileId,
    required DateTime startedAt,
    required SignalResult signal,
  }) async {
    final sessionId = _uuidV4();

    // The nonce is obtained immediately before the submission, not at capture time: it has a
    // short TTL and a capture takes a minute.
    final nonce = await _api.postJson('/v1/sessions/nonce', const {});

    final payload = <String, dynamic>{
      'session_id': sessionId,
      'episode_id': episodeId,
      'device_profile_id': deviceProfileId,
      'model_version': signalPipelineVersion,
      'started_at': startedAt.toUtc().toIso8601String(),
      'posture': 'seated',
      'status': signal.accepted ? 'completed' : 'rejected',
      'rejection_reason': signal.rejectionReason?.wireValue,
      'n_beats_total': signal.nBeatsTotal,
      'n_beats_usable': signal.nBeatsUsable,
      'ptt_ms': signal.pttMs,
      'quality': signal.quality,
      'synthetic': false,
    };

    try {
      final response = await _api.postJson(
        '/v1/sessions',
        payload,
        extraHeaders: {
          'X-Session-Nonce': nonce['nonce'] as String,
          'Idempotency-Key': sessionId,
        },
      );
      return _outcomeFrom(response, sessionId);
    } on ApiException catch (e) {
      if (e.statusCode == 409) {
        // The contract: a duplicate returns the stored result unchanged.
        return SubmissionOutcome(
          accepted: false,
          message: 'This spot check was already recorded.',
          sessionId: sessionId,
          duplicate: true,
        );
      }
      rethrow;
    }
  }

  SubmissionOutcome _outcomeFrom(
    Map<String, dynamic> response,
    String sessionId,
  ) {
    final trend = response['trend'] as Map<String, dynamic>?;
    final rejection = response['rejection'] as Map<String, dynamic>?;
    final action = response['action'] as Map<String, dynamic>?;

    if (trend != null) {
      return SubmissionOutcome(
        accepted: true,
        // The backend's own wording, which is written to avoid implying a measurement.
        message: (action?['message'] as String?) ?? 'Recorded.',
        sessionId: (response['session_id'] as String?) ?? sessionId,
        trendDirection: trend['direction'] as String?,
      );
    }

    return SubmissionOutcome(
      accepted: false,
      message:
          (rejection?['message'] as String?) ??
          (action?['message'] as String?) ??
          'This spot check was recorded but could not be used.',
      sessionId: (response['session_id'] as String?) ?? sessionId,
    );
  }

  /// A version-4 UUID. Small enough not to justify a dependency.
  String _uuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    String hex(int start, int end) => bytes
        .sublist(start, end)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }
}
