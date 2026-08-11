/// The signal-processing contract.
///
/// This is the seam between acquisition, which exists, and the signal chain, which does not yet.
/// `packages/tera_capture` deliberately stops short of beat detection, beat pairing and PTT
/// derivation; this interface is where they arrive.
///
/// The contract is written out in full in `docs/decisions.md` so it can be implemented without
/// reading this file.
///
/// **INPUT** - one capture session:
///   * `accelerometer`: samples timestamped in the sensor's own base, nanoseconds
///   * `frames`: one region-of-interest mean per camera frame, timestamped, nanoseconds
///   * `clockBasis`: the verified time-base relationship between the two streams
///
/// **OUTPUT** - [SignalResult], matching the session payload contract in BUILD_SPEC 4.2:
///   * `pttMs`: one derived interval per usable beat, **milliseconds**, plausible range 80-400
///   * `nBeatsTotal` / `nBeatsUsable`: detected, and surviving the gate
///   * `quality`: `accel_rate_hz`, `camera_fps`, `dropped_frame_pct`, `snr_db`,
///     `motion_index` (0 still, 1 unusable), optional `clock_offset_ms`
///   * `accepted`: the gate decision. When false, `rejectionReason` must be set.
///
/// **PTT IS AO-TO-FOOT.** From the SCG aortic-valve-opening peak to the PPG foot of the same
/// cardiac cycle, the foot located by the intersecting-tangent method. The full detection rule is
/// in `docs/decisions.md`; do not re-derive it here, and do not change it without changing that
/// document first.
///
/// **THE GATE.** A session is rejected when the signal does not support a number. The proposal
/// specifies dual-estimator agreement - time-domain peak detection against frequency-domain
/// spectral estimation - with rejection when they disagree beyond tolerance. Rejecting is the
/// correct output, not a failure of the implementation: the system declines to produce a number
/// when the signal does not support one.
///
/// Intervals outside [pttMinMs]-[pttMaxMs] are dropped here and excluded from `nBeatsUsable`,
/// rather than passed upward: the backend's identical gate rejects the *whole session* on one bad
/// interval, so losing a pair beats losing the capture. Below [minUsableBeats] survivors, reject
/// with `insufficientBeats`.
///
/// **This method does not throw for signal reasons.** Bad signal is a return value, not an
/// exception. A throw means a fault, and the caller records the session as rejected with
/// `signalProcessingUnavailable`.
///
/// **The one thing an implementation must never do is return plausible values it did not
/// derive.** Every number here flows into a patient's clinical record and into a clinician's
/// summary. A fabricated interval becomes a real trend, indistinguishable downstream from a
/// measured one.
library;

import 'dart:math' as math;

import 'package:meta/meta.dart';
// For the rateStatistics extensions on CaptureRecording; extension methods are only in scope
// when their defining library is imported.
import 'package:tera_capture/tera_capture.dart';

import '../capture/dsp/tera_ptt.dart';
import '../ui/capture_screen.dart';

/// Minimum intervals that must survive the gate for a session to be usable.
///
/// Mirrors the backend's `min_usable_beats`. It is duplicated because the handset decides before
/// it can ask anything, and reconciled by the threshold cross-check at device-profile time rather
/// than by hoping the two stay in step.
const int minUsableBeats = 30;

/// Plausible transit-time bounds, milliseconds. Mirrors the backend's `ptt_min_ms` / `ptt_max_ms`.
///
/// Applied *here* as the primary filter. The backend's identical check remains as defence in
/// depth, but it rejects the whole session rather than the interval, so relying on it would throw
/// away a good capture for one bad pair.
const double pttMinMs = 80.0;
const double pttMaxMs = 400.0;

/// Longest array the API will accept, from invariant 2's bound (`max_ptt_array_length`).
const int maxPttArrayLength = 300;

/// How far the time-domain and frequency-domain heart-rate estimates may disagree, in bpm, before
/// the session is rejected as `poorSignalQuality`.
///
/// An engineering choice pending validation, in the same register as the backend's
/// `min_usable_beats`: there are no real captures to set it from yet. Record the validated figure
/// in `docs/decisions.md` once there are.
const double dualEstimatorToleranceBpm = 5.0;

/// Why a session was not usable. Values match the backend's `rejection_reason` enum.
enum SignalRejection {
  poorSignalQuality('poor_signal_quality'),
  insufficientBeats('insufficient_beats'),
  excessiveMotion('excessive_motion'),
  postureUnstable('posture_unstable'),
  torchUnavailable('torch_unavailable'),
  sensorRateBelowQualified('sensor_rate_below_qualified'),
  clockUnstable('clock_unstable'),
  userAborted('user_aborted'),

  /// **Not a signal-quality outcome.** The signal chain is not implemented in this build.
  ///
  /// Deliberately distinct so a judge, a teammate or a clinician can tell "the signal was bad"
  /// from "this part of the system does not exist yet". Collapsing the two would make an
  /// unfinished component look like a working one that happened to reject.
  signalProcessingUnavailable('signal_processing_unavailable');

  const SignalRejection(this.wireValue);

  final String wireValue;
}

@immutable
class SignalResult {
  const SignalResult({
    required this.accepted,
    required this.pttMs,
    required this.nBeatsTotal,
    required this.nBeatsUsable,
    required this.quality,
    this.rejectionReason,
  }) : assert(accepted || rejectionReason != null, 'a rejected session must carry a reason');

  final bool accepted;

  /// One interval per usable beat, milliseconds. Empty when rejected.
  final List<double> pttMs;
  final int nBeatsTotal;
  final int nBeatsUsable;
  final Map<String, dynamic> quality;
  final SignalRejection? rejectionReason;
}

abstract class SignalPipeline {
  /// Reduce a capture to per-beat intervals and a gate decision.
  Future<SignalResult> process(CaptureResult capture);
}

/// The real chain, running on the handset.
///
/// Ported from the ML team's `tera_ptt.py`; the DSP lives in `capture/dsp/`. It runs here rather
/// than on a server because invariant 2 says raw waveform never leaves the phone, and that is a
/// regulatory claim in the pitch rather than a preference. Only the derived intervals and the
/// quality figures are submitted.
///
/// `capture/dsp/tera_ptt.dart` is checked against the Python line by line in
/// `test/ptt_reference_test.dart` — beat times to the microsecond, every paired interval, and
/// every gate verdict.
class TeraSignalPipeline implements SignalPipeline {
  const TeraSignalPipeline();

  @override
  Future<SignalResult> process(CaptureResult capture) async {
    final accelStats = capture.accelerometer.rateStatistics;
    final frameStats = capture.frames.rateStatistics;

    final quality = <String, dynamic>{
      'accel_rate_hz': accelStats?.meanRateHz ?? 0.0,
      'camera_fps': frameStats?.meanRateHz ?? 0.0,
      'dropped_frame_pct': frameStats?.droppedPercent ?? 100.0,
      'snr_db': 0.0,
      'motion_index': 1.0,
    };
    final offset = capture.clockBasis.camera?.clockSeparationMillis;
    if (offset != null) quality['clock_offset_ms'] = offset;

    // The clock check comes first and is a rejection rule, not a correction rule. Two streams on
    // different bases are offset by however long the handset has slept since boot; pairing them
    // produces a confident nonsense figure that looks normal on every other measure.
    final sharedBasis = capture.clockBasis.sharedBasis;
    if (sharedBasis != true) {
      return SignalResult(
        accepted: false,
        pttMs: const [],
        nBeatsTotal: 0,
        nBeatsUsable: 0,
        quality: quality,
        rejectionReason: SignalRejection.clockUnstable,
      );
    }

    final accelRate = accelStats?.meanRateHz ?? 0.0;
    final cameraRate = frameStats?.meanRateHz ?? 0.0;
    if (accelRate <= 0 || cameraRate <= 0) {
      return SignalResult(
        accepted: false,
        pttMs: const [],
        nBeatsTotal: 0,
        nBeatsUsable: 0,
        quality: quality,
        rejectionReason: SignalRejection.sensorRateBelowQualified,
      );
    }

    // **The chest-normal axis, not the magnitude.** Gravity is about 9.81 m/s2 and the cardiac
    // signature is about 0.02, so a magnitude is dominated by gravity and reduces to "the
    // projection onto whichever way gravity happens to point" — which also destroys the sign
    // that separates valve opening from closing. The ML handoff calls this out as its second
    // blocker; `docs/decisions.md` records the reversal of the earlier magnitude decision.
    final scg = [for (final s in capture.accelerometer.samples) s.z];
    final ppg = [for (final f in capture.frames.samples) f.roiMean];

    final PttAnalysis analysis;
    try {
      analysis = analyseCapture(scg: scg, fsScg: accelRate, ppg: ppg, fsPpg: cameraRate);
    } on Object {
      // The contract in docs/decisions.md: process() does not throw for signal reasons, so a
      // throw here is a fault in the chain rather than a bad capture. The session is still
      // recorded, with a reason that does not blame the signal.
      return SignalResult(
        accepted: false,
        pttMs: const [],
        nBeatsTotal: 0,
        nBeatsUsable: 0,
        quality: quality,
        rejectionReason: SignalRejection.signalProcessingUnavailable,
      );
    }

    quality['snr_db'] = _snrDb(analysis);
    quality['motion_index'] = _motionIndex(analysis);

    if (!analysis.gate.passed) {
      return SignalResult(
        accepted: false,
        pttMs: const [],
        nBeatsTotal: analysis.nScgBeats,
        nBeatsUsable: 0,
        quality: quality,
        rejectionReason: _reasonFor(analysis.gate.failure),
      );
    }

    // Drop anything outside the plausible band before it reaches the backend. Its identical gate
    // rejects the *whole session* on one bad interval, so relying on it would throw away a good
    // capture for one bad pair. Defence in depth stays; it is no longer the primary filter.
    final usable = [
      for (final v in analysis.pttMs)
        if (v >= pttMinMs && v <= pttMaxMs) v,
    ];

    if (usable.length < minUsableBeats) {
      return SignalResult(
        accepted: false,
        pttMs: const [],
        nBeatsTotal: analysis.nScgBeats,
        nBeatsUsable: 0,
        quality: quality,
        rejectionReason: SignalRejection.insufficientBeats,
      );
    }

    // Invariant 2's array bound. Keeping the most recent intervals rather than truncating from
    // the front: the end of a capture is the part the patient was most settled for.
    final bounded = usable.length > maxPttArrayLength
        ? usable.sublist(usable.length - maxPttArrayLength)
        : usable;

    return SignalResult(
      accepted: true,
      pttMs: bounded,
      nBeatsTotal: analysis.nScgBeats,
      nBeatsUsable: bounded.length,
      quality: quality,
    );
  }

  /// Every gate failure maps onto a reason the backend already knows, and each names something
  /// the *device* could not do. None describes the patient.
  static SignalRejection _reasonFor(GateFailure? failure) => switch (failure) {
    GateFailure.insufficientBeats => SignalRejection.insufficientBeats,
    GateFailure.lowPairYield => SignalRejection.insufficientBeats,
    GateFailure.chestBeatDetectionUnreliable => SignalRejection.poorSignalQuality,
    GateFailure.fingerBeatDetectionUnreliable => SignalRejection.poorSignalQuality,
    // Chest and finger disagreeing about the heart rate means they are not seeing the same
    // heartbeats, which on a handset is almost always movement between the two.
    GateFailure.sensorsDisagree => SignalRejection.excessiveMotion,
    GateFailure.pttTooVariable => SignalRejection.excessiveMotion,
    null => SignalRejection.poorSignalQuality,
  };

  /// A signal-quality figure derived from the beat analysis, in dB.
  ///
  /// Defined here rather than left at its worst, now that there is a chain to define it against:
  /// the ratio of the median transit time to its own dispersion, which is what "how well resolved
  /// is this measurement" means for PTT. Not a spectral SNR, and labelled as a heuristic in
  /// `docs/decisions.md` rather than presented as a validated figure.
  static double _snrDb(PttAnalysis analysis) {
    final sd = analysis.summary.sd;
    final med = analysis.summary.median;
    if (!sd.isFinite || !med.isFinite || sd <= 0) return 0.0;
    return 20.0 * (math.log(med / sd) / math.ln10);
  }

  /// 0 still, 1 unusable, from the fraction of detected beats that failed to pair.
  ///
  /// Unpaired beats are what motion actually produces: the chest sees a beat and the finger does
  /// not, or the two drift apart. Also a heuristic, also labelled as one.
  static double _motionIndex(PttAnalysis analysis) {
    if (analysis.nScgBeats == 0) return 1.0;
    return (1.0 - analysis.summary.pairYield).clamp(0.0, 1.0);
  }
}
