/// What a check accumulates on its way to submission.
///
/// Kept out of [CheckSession] on purpose. That file is the state machine and is pure — no capture
/// types, no API types, testable on its own. This is the luggage: it rides alongside in
/// [CheckArgs] and is read only at the end.
library;

import 'package:meta/meta.dart';

import '../capture/current_context.dart';
import '../signal/signal_pipeline.dart';

@immutable
class CheckPayload {
  const CheckPayload({
    this.context,
    this.signal,
    this.capturedAt,
    this.cuffReadingSaved = false,
    this.submittedSessionId,
    this.checkSessionId,
    this.uncalibratedDemo = false,
    this.aiConsent,
    this.firstTimeCalibration = false,
    this.calibrationSystolic,
    this.calibrationDiastolic,
  });

  /// CTX-01. Collected on both paths, before the fork.
  final CurrentContext? context;

  /// Sensor path: the pipeline's output. Per-beat intervals and quality, never a waveform.
  final SignalResult? signal;

  /// When the capture started, for `started_at`.
  final DateTime? capturedAt;

  /// BP-only path: the cuff reading was confirmed and already filed by `CuffReadingScreen`.
  final bool cuffReadingSaved;

  /// Set once the backend has stored the sensor capture.
  final String? submittedSessionId;

  /// The check session, opened at the start of the flow in both modes. PRE-01, CTX-01 and the
  /// insight all attach to this rather than to a capture that may never exist.
  final String? checkSessionId;

  /// BPREF-01 was skipped rather than completed — the demo bypass for a patient with no cuff at
  /// hand. Nothing about the capture or the backend's own gating changes: this only tells the
  /// insight screen to show the uncalibrated warning banner up front, before whatever the
  /// deterministic engine itself decides about confidence.
  final bool uncalibratedDemo;

  /// The patient's answer to the AI-commentary question, asked once the recording is finished
  /// and the session is filed.
  ///
  /// Three-valued on purpose. `true` and `false` are decisions the patient made; **null means
  /// they were never asked**, which happens when the submission failed before the question could
  /// be put to them. Collapsing null into false would record a refusal nobody gave, and would
  /// stop [InsightScreen] from asking later when it legitimately still could.
  final bool? aiConsent;

  /// This account has no recorded history, so the check is running as a first-time calibration:
  /// the cuff reading is taken alongside the phone recording rather than being skippable.
  ///
  /// Decided from the server's own history count at the start of the flow, not from local state
  /// — see `HomeScreen._startCheck`.
  final bool firstTimeCalibration;

  /// The cuff reading entered after a first-time calibration capture, mmHg.
  ///
  /// Held here only long enough to be filed as a real `cuff_reading`. These are the **only**
  /// pressure numbers anywhere in this payload, and they came off a cuff the patient read —
  /// nothing derived from SCG or PPG may ever populate them (invariant 1).
  final int? calibrationSystolic;
  final int? calibrationDiastolic;

  CheckPayload copyWith({
    CurrentContext? context,
    SignalResult? signal,
    DateTime? capturedAt,
    bool? cuffReadingSaved,
    String? submittedSessionId,
    String? checkSessionId,
    bool? uncalibratedDemo,
    bool? aiConsent,
    bool? firstTimeCalibration,
    int? calibrationSystolic,
    int? calibrationDiastolic,
  }) => CheckPayload(
    context: context ?? this.context,
    signal: signal ?? this.signal,
    capturedAt: capturedAt ?? this.capturedAt,
    cuffReadingSaved: cuffReadingSaved ?? this.cuffReadingSaved,
    submittedSessionId: submittedSessionId ?? this.submittedSessionId,
    checkSessionId: checkSessionId ?? this.checkSessionId,
    uncalibratedDemo: uncalibratedDemo ?? this.uncalibratedDemo,
    aiConsent: aiConsent ?? this.aiConsent,
    firstTimeCalibration: firstTimeCalibration ?? this.firstTimeCalibration,
    calibrationSystolic: calibrationSystolic ?? this.calibrationSystolic,
    calibrationDiastolic: calibrationDiastolic ?? this.calibrationDiastolic,
  );
}
