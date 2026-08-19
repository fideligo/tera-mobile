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

import 'package:flutter/foundation.dart';

// For the rateStatistics extensions on CaptureRecording; extension methods are only in scope
// when their defining library is imported.
import 'package:tera_capture/tera_capture.dart';

import '../capture/dsp/tera_ptt.dart';
import '../ui/capture_screen.dart';

/// Minimum intervals that must survive the gate for a session to be usable.
///
/// **12, matching the ML reference's `MIN_PAIRS` and the backend's `min_usable_beats`.** It was 30
/// on both sides, which put a second and stricter gate behind the chain's own: `qualityGate`
/// accepts at 12 paired beats — the reference's figure, validated against the vectors in
/// `test/fixtures/` — and this then refused the same capture as `insufficient_beats`. A recording
/// the signal chain had accepted was thrown away here, and the patient was asked to sit through
/// another minute.
///
/// The old rule was "half of a 60 s capture at 60 bpm". Half of a 60 bpm capture is not half of a
/// 48 bpm one, so it fell hardest on the slowest heart rates, and it was never validated against
/// anything. A trimmed mean over 12 beats *is* noisier than over 30; that cost is carried by the
/// backend's confidence score, which rates a 12-beat session low, rather than by refusing to keep
/// a record of it at all.
///
/// **This constant is duplicated in `backend/app/config.py` and nothing enforces that they
/// agree.** The comment here used to claim a "threshold cross-check at device-profile time"
/// reconciles them; there is no such check — no endpoint publishes the server's thresholds and
/// nothing compares them. Changing one without the other does not fail a test, it moves where the
/// patient is refused. Both were changed together here.
const int minUsableBeats = 12;

/// Plausible transit-time bounds, milliseconds. Mirrors the backend's `ptt_min_ms` / `ptt_max_ms`.
///
/// Applied *here* as the primary filter. The backend's identical check remains as defence in
/// depth, but it rejects the whole session rather than the interval, so relying on it would throw
/// away a good capture for one bad pair.
const double pttMinMs = 80.0;
const double pttMaxMs = 500.0;

/// Longest array the API will accept, from invariant 2's bound (`max_ptt_array_length`).
const int maxPttArrayLength = 300;

/// **Superseded and deliberately left as a pointer.** The dual-estimator tolerance is not a
/// constant: it is `hrToleranceBpm` in `capture/dsp/tera_ptt.dart`, the ANSI/AAMI EC13 readout
/// tolerance, which scales with heart rate. This declaration was never read by the gate — the gate
/// used two *different* flat constants in the DSP file — so a reader tuning this one would have
/// changed nothing at all.
@Deprecated(
  'Use hrToleranceBpm(hr) from capture/dsp/tera_ptt.dart; EC13 scales with rate',
)
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
    this.axis = 'z',
    this.axesTried = const ['z'],
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

  /// Which accelerometer axis the intervals were derived from.
  ///
  /// `z`, `x` or `y`. Reported because a recording that only worked on `x` is telling us the phone
  /// was not held the way the instructions describe, and that is worth knowing before a batch of
  /// field captures is interpreted.
  final String axis;

  /// The axes the chain actually tried, in order.
  final List<String> axesTried;

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
    // The drift figure when the handset measured one, the profiler's deep-sleep separation
    // otherwise. Clamped because `SessionQuality.clock_offset_ms` is bounded +/-10,000 ms and a
    // session that fails the drift gate is precisely the one likeliest to exceed it — an
    // out-of-range value there is a 422 that discards the row, and invariant 3 says a rejected
    // session is retained. The clamp costs a resolution nobody reads at that magnitude; the
    // alternative loses the record of the failure.
    final offset =
        capture.clockBasis.observedDriftMillis ??
        capture.clockBasis.camera?.clockSeparationMillis;
    if (offset != null) {
      quality['clock_offset_ms'] = offset.clamp(-10000.0, 10000.0);
    }

    // **The clock basis is a precondition, not a correction.**
    //
    // PTT is the distance between a beat seen by the accelerometer and the same beat seen by the
    // camera, so the two streams have to be on one timeline before the subtraction means
    // anything. Neither failure can be repaired after the fact, and both produce confident
    // nonsense that looks entirely normal on every other measure — which is why this is checked
    // before analysis rather than inferred from the result.
    //
    // **What `sharedBasis` answers changed, and this comment is the reason it had to.** It used
    // to consult only the two per-stream verifications, which the patient app cannot produce: it
    // has no platform channel to read both boot clocks at delivery, so it passed neither, so this
    // returned null, so *every capture on real hardware was refused here* with `clock_unstable`.
    // The refusal was not a tolerance being exceeded; the question was unanswerable in this app.
    //
    // The handset now stamps both streams off one `Stopwatch` and measures how far they drift
    // apart across the capture, which is the part of the question that survives having one clock.
    // A fixed offset between the streams cancels out of a change in transit time; a growing one
    // does not, and `maxCrossStreamDriftMillis` is where growing stops being jitter.
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

    // **Every axis, not just Z.** The aortic-valve signature sits on the axis normal to the chest
    // wall, and which physical axis that is depends on how the patient held the phone — telling
    // someone to hold it flat does not make them hold it flat. This chain read `s.z` and nothing
    // else, so a capture where the phone sat at an angle failed with no way to ask whether another
    // axis would have worked, even though the samples were right there.
    //
    // Best = passes the gate with the tightest PTT spread. If none pass, Z's result is kept, so a
    // refusal still describes the axis the instructions asked for rather than the luckiest one.
    // Ported from `run_best_axis` in the ML team's `contract.py`, which is where the reasoning and
    // the two tests covering it live.
    final candidates = <String, List<double>>{
      'z': scg,
      'x': [for (final sample in capture.accelerometer.samples) sample.x],
      'y': [for (final sample in capture.accelerometer.samples) sample.y],
    };

    PttAnalysis? primary;
    PttAnalysis? best;
    String bestAxis = 'z';

    // **The heart rate found on *any* axis, kept even when every axis fails the PTT gate.**
    //
    // Ported from `run_best_axis`, and missing from the first port. Heart rate is a separate and
    // easier question than transit time: PTT needs both sensors, a shared clock and beats that
    // pair, while a rate needs one sensor that can count. A recording can fail the PTT gate on
    // every axis and still have counted the heartbeat cleanly on one of them, and the reference is
    // explicit that "that number is worth returning". Without this the result screen showed no
    // figure at all for a refused capture whose pulse had in fact been measured.
    double? hrFallback;

    PttAnalysis analysis;
    try {
      for (final entry in candidates.entries) {
        final result = analyseCapture(
          scg: entry.value,
          fsScg: accelStats.meanRateHz,
          ppg: ppg,
          fsPpg: frameStats.meanRateHz,
        );
        primary ??= result;
        final usable = result.gate.passed && result.summary.sd.isFinite;
        if (usable && (best == null || result.summary.sd < best.summary.sd)) {
          best = result;
          bestAxis = entry.key;
        }
        if (hrFallback == null && result.ppgHr.isFinite && result.ppgHr > 0) {
          hrFallback = result.ppgHr;
        }

        // **Task 4: every refusal states its own arithmetic.** `GateResult.detail` has always
        // carried the measured figures and the limit they missed, and nothing ever read it — so a
        // capture refused on a 0.4 bpm overshoot and one refused for having no signal at all
        // reached the patient, and the log, as the same sentence. Guessing at the cause from that
        // is what a device test should never have to do.
        if (!result.gate.passed) {
          debugPrint(
            '[Tera] gate FAILED on axis ${entry.key}: '
            '${result.gate.failure?.name ?? "unspecified"} — '
            '${result.gate.detail ?? "no detail"} '
            '[chest ${result.nScgBeats} beats, finger ${result.nPpgFeet} feet, '
            '${result.summary.n} paired of ${result.nPairedBeforeTrim}, '
            'SD ${result.summary.sd.toStringAsFixed(1)} ms trimmed from '
            '${result.sdBeforeTrimMs.toStringAsFixed(1)} ms]',
          );
        } else {
          debugPrint(
            '[Tera] gate passed on axis ${entry.key}: '
            'PTT median ${result.summary.median.toStringAsFixed(1)} ms, '
            'SD ${result.summary.sd.toStringAsFixed(1)} ms '
            '(untrimmed ${result.sdBeforeTrimMs.toStringAsFixed(1)} ms), '
            'n=${result.summary.n} of ${result.nPairedBeforeTrim}',
          );
        }

        // A capture that needed the second pass has a diastolic complex as strong as its
        // systolic one, which is a fact about how the phone sat on the sternum. Visible in the
        // log rather than absorbed silently into a median.
        if (result.scgHarmonicSuppressed || result.ppgHarmonicSuppressed) {
          debugPrint(
            '[Tera] harmonic suppression on axis ${entry.key}: '
            'chest=${result.scgHarmonicSuppressed}, finger=${result.ppgHarmonicSuppressed} '
            '(chest ${result.scgHr.toStringAsFixed(1)} bpm vs '
            'spectral ${result.scgSpectralHr.toStringAsFixed(1)} bpm)',
          );
        }
      }
      analysis = best ?? primary!;
      debugPrint(
        '[Tera] axis chosen: $bestAxis '
        '(${best == null ? "no axis passed; reporting the primary" : "best PTT spread"})',
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
    // Recorded in the quality block so it reaches the clinical record, where a run of captures
    // that only ever worked on X is a fact about how the phone is being held.
    quality['scg_axis'] = bestAxis;

    // The PPG heart rate survives even when the SCG side is too slow to pair beats against, which
    // is what makes it usable as an offline result on its own — and what lets the result screen
    // show a measured figure even for a capture this gate refuses.
    // The winning axis's figure when it has one, otherwise whichever axis did count the pulse.
    final heartRateBpm = analysis.ppgHr.isFinite && analysis.ppgHr > 0
        ? analysis.ppgHr
        : hrFallback;
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
        axis: bestAxis,
        axesTried: const ['z', 'x', 'y'],
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
        axis: bestAxis,
        axesTried: const ['z', 'x', 'y'],
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
      axis: bestAxis,
      axesTried: const ['z', 'x', 'y'],
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
