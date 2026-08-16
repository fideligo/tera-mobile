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
    // Optional, and deliberately so. These are the raw sample series, carried only for the
    // compile-time-gated developer CSV export (`TERA_DEBUG_CAPTURE`); nothing on the clinical path
    // reads them and invariant 2 forbids them leaving the handset. Making them *required* pushed
    // that debug-only concern into every construction site — which silently broke
    // `signal_pipeline_test.dart` and `flow_data_test.dart` at compile time, and those two files
    // are the ones that assert this pipeline never fabricates an interval. The gate went missing
    // behind a test suite that could not run.
    this.scg = const [],
    this.ppg = const [],
    this.rejectionReason,
    this.synthetic = false,
    this.heartRateBpm,
    this.pttMedianMs,
  }) : assert(
         accepted || rejectionReason != null,
         'a rejected session must carry a reason',
       );

  /// True when [pttMs] does not come from this capture.
  ///
  /// **[TeraSignalPipeline] can no longer set this.** It marked the demo fallback that
  /// substituted a plausible PTT array whenever the chain came up short; that fallback is gone,
  /// and a capture the gate cannot stand behind is now rejected rather than filled in. The field
  /// stays because the backend carries a `synthetic` boolean on every clinical table (invariant
  /// 9) and seeded data still travels through this type, but on the capture path it is always
  /// false: there is nothing left to substitute.
  final bool synthetic;

  /// Heart rate derived on this handset from the PPG (camera) signal, beats per minute.
  ///
  /// Kept separate from everything the backend computes, because it is the one clinically
  /// meaningful figure this app can stand behind **without a server**: a 30 fps camera resolves a
  /// 0.8-2 Hz pulse comfortably. Null when the chain could not derive it.
  ///
  /// It is a heart rate and nothing more. It is not a blood pressure, and no trend can be built
  /// from it — a trend needs the patient's cuff baseline, which lives server-side.
  final double? heartRateBpm;

  /// Median pulse transit time from this capture, milliseconds. Null when not derivable.
  ///
  /// Only trustworthy when the accelerometer actually ran fast enough; `quality['accel_rate_hz']`
  /// is what says whether it did.
  final double? pttMedianMs;

  final bool accepted;

  /// One interval per usable beat, milliseconds. Empty when rejected.
  final List<double> pttMs;
  final int nBeatsTotal;
  final int nBeatsUsable;
  final Map<String, dynamic> quality;
  final SignalRejection? rejectionReason;
  
  final List<double> scg;
  final List<double> ppg;
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

    final scg = [for (final s in capture.accelerometer.samples) s.z];
    final ppg = [for (final f in capture.frames.samples) f.roiMean];

    // **A rate that could not be measured is a refusal, not a default.**
    //
    // These were `?? 50.0` and `?? 30.0`. `RateStatistics.fromTimestamps` returns null for exactly
    // two reasons — fewer than three samples, or non-monotonic timestamps — and its own comment
    // says of the second that "dropping the sample is wrong (it hides the fault) so the whole run
    // is refused instead". Substituting a rate there did precisely what it warns against, and the
    // fabricated figure then fed the backend's `sensor_rate_below_qualified` gate and the
    // eligibility cross-check as though it had been observed. 50 Hz is also a quarter of the
    // 200 Hz floor, so the substitute described a handset that could not be used anyway.
    if (accelStats == null || frameStats == null) {
      return SignalResult(
        accepted: false,
        // Both null branches are about the timestamps themselves rather than the signal carried
        // on them: too few to form an interval, or an interval that ran backwards.
        rejectionReason: SignalRejection.clockUnstable,
        pttMs: const [],
        nBeatsTotal: 0,
        nBeatsUsable: 0,
        quality: const {},
        scg: scg,
        ppg: ppg,
      );
    }

    // Every key the API requires, present from here on. `QualityMetrics` in
    // `app/schemas/session.py` makes all five mandatory with bounds and sets `extra="forbid"`, so
    // a missing key and a stray key are both a 422. `snr_db` and `motion_index` start at their
    // worst and are replaced once there is an analysis to derive them from — a rejection carries
    // no evidence of quality, and should not read as though it did.
    final quality = <String, dynamic>{
      'accel_rate_hz': accelStats.meanRateHz,
      'camera_fps': frameStats.meanRateHz,
      'dropped_frame_pct': frameStats.droppedPercent,
      'snr_db': 0.0,
      'motion_index': 1.0,
    };
    final offset = capture.clockBasis.camera?.clockSeparationMillis;
    if (offset != null) quality['clock_offset_ms'] = offset;

    // **The clock basis is a precondition, not a correction.**
    //
    // PTT is the distance between a beat seen by the accelerometer and the same beat seen by the
    // camera, so the two streams have to be on one timeline before the subtraction means
    // anything. `sharedBasis` is true only when both were verified and agree; false means they
    // are on different bases and every interval is offset by however long the handset has slept
    // since boot, and null means it could not be established at all. Neither of the latter two
    // can be repaired after the fact, and both produce confident nonsense that looks entirely
    // normal on every other measure — which is exactly why this is checked before analysis rather
    // than inferred from the result.
    if (capture.clockBasis.sharedBasis != true) {
      return SignalResult(
        accepted: false,
        rejectionReason: SignalRejection.clockUnstable,
        pttMs: const [],
        nBeatsTotal: 0,
        nBeatsUsable: 0,
        quality: quality,
        scg: scg,
        ppg: ppg,
      );
    }

    PttAnalysis analysis;
    try {
      analysis = analyseCapture(
        scg: scg,
        fsScg: accelStats.meanRateHz,
        ppg: ppg,
        fsPpg: frameStats.meanRateHz,
      );
    } on Object {
      // A fault in the chain, not a verdict about the signal. `signalProcessingUnavailable` keeps
      // the two distinguishable, which is the whole reason that value exists.
      return SignalResult(
        accepted: false,
        rejectionReason: SignalRejection.signalProcessingUnavailable,
        pttMs: const [],
        nBeatsTotal: 0,
        nBeatsUsable: 0,
        quality: quality,
        scg: scg,
        ppg: ppg,
      );
    }

    // Derived, not asserted. `snr_db` and `motion_index` were the constants 25.0 and 0.1 — two
    // figures that travelled into the clinical record and into the backend's own gate describing
    // a capture nobody had looked at. Both helpers below have existed unused since the chain
    // landed.
    quality['snr_db'] = _snrDb(analysis);
    quality['motion_index'] = _motionIndex(analysis);

    // The PPG heart rate survives even when the SCG side is too slow to pair beats against, which
    // is what makes it usable as an offline result on its own — and what lets the result screen
    // show a measured figure even for a capture this gate refuses.
    final heartRateBpm = analysis.ppgHr.isFinite && analysis.ppgHr > 0
        ? analysis.ppgHr
        : null;
    final pttMedianMs =
        analysis.summary.median.isFinite && analysis.summary.median > 0
        ? analysis.summary.median
        : null;

    final usable = [
      for (final v in analysis.pttMs)
        if (v >= pttMinMs && v <= pttMaxMs) v,
    ];

    // **The gate, restored.**
    //
    // This branch used to substitute `List.generate(40, (i) => 240.0 + (i % 5))` whenever the
    // chain could not derive enough intervals, mark the session `synthetic`, and submit it
    // `accepted`. Invariant 9 does permit labelled synthetic data — but the substitution ran on
    // the *clinical* path, so the backend anchored a calibration to those numbers and computed
    // mmHg estimates from them, and this file's own header forbids exactly that: "the one thing
    // an implementation must never do is return plausible values it did not derive."
    //
    // Rejecting is the correct output, not a failure of the implementation. The caller shows the
    // retry, and nothing is submitted.
    if (!analysis.gate.passed) {
      return SignalResult(
        accepted: false,
        rejectionReason: _reasonFor(analysis.gate.failure),
        pttMs: const [],
        nBeatsTotal: analysis.nScgBeats,
        nBeatsUsable: 0,
        quality: quality,
        scg: scg,
        ppg: ppg,
        heartRateBpm: heartRateBpm,
        pttMedianMs: pttMedianMs,
      );
    }
    if (usable.length < minUsableBeats) {
      return SignalResult(
        accepted: false,
        rejectionReason: SignalRejection.insufficientBeats,
        pttMs: const [],
        nBeatsTotal: analysis.nScgBeats,
        nBeatsUsable: 0,
        quality: quality,
        scg: scg,
        ppg: ppg,
        heartRateBpm: heartRateBpm,
        pttMedianMs: pttMedianMs,
      );
    }

    final bounded = usable.length > maxPttArrayLength
        ? usable.sublist(usable.length - maxPttArrayLength)
        : usable;

    return SignalResult(
      accepted: true,
      pttMs: bounded,
      nBeatsTotal: analysis.nScgBeats,
      nBeatsUsable: bounded.length,
      quality: quality,
      scg: scg,
      ppg: ppg,
      rejectionReason: null,
      heartRateBpm: heartRateBpm,
      pttMedianMs: pttMedianMs,
    );
  }

  /// Every gate failure maps onto a reason the backend already knows, and each names something
  /// the *device* could not do. None describes the patient.
  static SignalRejection _reasonFor(GateFailure? failure) => switch (failure) {
    GateFailure.insufficientBeats => SignalRejection.insufficientBeats,
    GateFailure.lowPairYield => SignalRejection.insufficientBeats,
    GateFailure.chestBeatDetectionUnreliable =>
      SignalRejection.poorSignalQuality,
    GateFailure.fingerBeatDetectionUnreliable =>
      SignalRejection.poorSignalQuality,
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
    final db = 20.0 * (math.log(med / sd) / math.ln10);
    // Clamped to the range `QualityMetrics.snr_db` accepts. An unusually tight run can compute
    // past 100 dB, and the API answers that with a 422 that costs the whole session — a ratio
    // beyond this range says "as good as this measure can report", not something worth losing a
    // capture over.
    return db.isFinite ? db.clamp(-100.0, 100.0) : 0.0;
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
