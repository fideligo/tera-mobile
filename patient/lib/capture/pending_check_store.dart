/// Survives the capture across an activity death.
///
/// # Why this exists
///
/// Launching the camera through `image_picker` starts a separate activity, and Android is free to
/// destroy the Flutter activity behind it to reclaim memory. On a device that does so, everything
/// held in widget state — including the sixty seconds of capture the patient has just sat through
/// — is gone by the time the picker returns. `image_picker` acknowledges this directly with its
/// `retrieveLostData` API; the same hazard applies to anything the app was holding at the time.
///
/// So before the camera is opened, the parts of the check needed to submit it are written to a
/// file, and `ProcessingScreen` reads them back if it finds itself with nothing in memory.
///
/// # What is written, and what is deliberately not
///
/// **The derived intervals only. Never the waveform.** `SignalResult` carries `scg` and `ppg` —
/// the raw accelerometer and ROI series — and those are excluded here, by omission that is
/// checked in [_toJson] rather than left to habit. Invariant 2 says raw sample buffers are never
/// persisted, and "briefly, to a cache file, to survive a camera intent" is still persisted. The
/// per-beat intervals are a different thing: they are the deepest granularity the API itself
/// accepts, so writing them to the handset's own private storage for a few seconds does not cross
/// a line the submission does not already cross.
///
/// The file lives in the app's temporary directory, is deleted the moment the check is submitted,
/// and is ignored if it is older than [_maxAge] — a stale capture from a previous session must
/// never be silently attached to a new check.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../signal/signal_pipeline.dart';

/// A check interrupted mid-flow, as far as it can be restored.
class PendingCheck {
  const PendingCheck({
    required this.signal,
    required this.savedAt,
    this.checkSessionId,
    this.capturedAt,
  });

  final SignalResult signal;
  final DateTime savedAt;
  final String? checkSessionId;
  final DateTime? capturedAt;
}

class PendingCheckStore {
  const PendingCheckStore();

  static const _fileName = 'tera_pending_check.json';

  /// Older than this and the capture is not offered back.
  ///
  /// A capture is a measurement of a moment. Reattaching one from yesterday to today's check
  /// would file a reading against the wrong time, which is worse than losing it.
  static const _maxAge = Duration(minutes: 30);

  Future<File> _file() async {
    final dir = await getTemporaryDirectory();
    return File('${dir.path}/$_fileName');
  }

  Map<String, dynamic> _toJson(
    SignalResult s,
    String? checkSessionId,
    DateTime? capturedAt,
  ) => {
    'saved_at': DateTime.now().toUtc().toIso8601String(),
    'check_session_id': checkSessionId,
    'captured_at': capturedAt?.toUtc().toIso8601String(),
    // Derived values only. `scg` and `ppg` are absent on purpose — see the library docstring.
    'ptt_ms': s.pttMs,
    'n_beats_total': s.nBeatsTotal,
    'n_beats_usable': s.nBeatsUsable,
    'quality': s.quality,
    'synthetic': s.synthetic,
    'heart_rate_bpm': s.heartRateBpm,
    'ptt_median_ms': s.pttMedianMs,
  };

  /// Write the check. Never throws: failing to make a backup must not fail the capture.
  Future<void> save({
    required SignalResult signal,
    String? checkSessionId,
    DateTime? capturedAt,
  }) async {
    try {
      final file = await _file();
      await file.writeAsString(
        jsonEncode(_toJson(signal, checkSessionId, capturedAt)),
        flush: true,
      );
    } on Object {
      // Deliberately swallowed. The in-memory path is still the primary one.
    }
  }

  /// Read a check back, or null if there is none, it is unreadable, or it has aged out.
  Future<PendingCheck?> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;

      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final savedAt = DateTime.tryParse(raw['saved_at'] as String? ?? '');
      if (savedAt == null) return null;
      if (DateTime.now().toUtc().difference(savedAt.toUtc()) > _maxAge) {
        await clear();
        return null;
      }

      final ptt = (raw['ptt_ms'] as List?)?.map((v) => (v as num).toDouble()).toList();
      if (ptt == null) return null;

      return PendingCheck(
        savedAt: savedAt,
        checkSessionId: raw['check_session_id'] as String?,
        capturedAt: DateTime.tryParse(raw['captured_at'] as String? ?? ''),
        signal: SignalResult(
          accepted: true,
          pttMs: ptt,
          nBeatsTotal: (raw['n_beats_total'] as num?)?.toInt() ?? ptt.length,
          nBeatsUsable: (raw['n_beats_usable'] as num?)?.toInt() ?? ptt.length,
          quality: (raw['quality'] as Map?)?.cast<String, dynamic>() ?? const {},
          synthetic: raw['synthetic'] as bool? ?? false,
          heartRateBpm: (raw['heart_rate_bpm'] as num?)?.toDouble(),
          pttMedianMs: (raw['ptt_median_ms'] as num?)?.toDouble(),
          // Restored without the waveform, because it was never written. Nothing downstream
          // reads these: the submission sends `pttMs` and the quality figures.
          scg: const [],
          ppg: const [],
        ),
      );
    } on Object {
      return null;
    }
  }

  Future<void> clear() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } on Object {
      // Nothing to do; a stale file ages out on its own.
    }
  }
}
