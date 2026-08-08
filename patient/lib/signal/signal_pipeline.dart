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
/// **THE GATE.** A session is rejected when the signal does not support a number. The proposal
/// specifies dual-estimator agreement - time-domain peak detection against frequency-domain
/// spectral estimation - with rejection when they disagree beyond tolerance. Rejecting is the
/// correct output, not a failure of the implementation: the system declines to produce a number
/// when the signal does not support one.
///
/// **The one thing an implementation must never do is return plausible values it did not
/// derive.** Every number here flows into a patient's clinical record and into a clinician's
/// summary. A fabricated interval becomes a real trend, indistinguishable downstream from a
/// measured one.
library;

import 'package:meta/meta.dart';
// For the rateStatistics extensions on CaptureRecording; extension methods are only in scope
// when their defining library is imported.
import 'package:tera_capture/tera_capture.dart';

import '../ui/capture_screen.dart';

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

/// Stand-in until the real chain lands.
///
/// **It rejects every session, deliberately.** The alternative - returning plausible-looking
/// intervals - would let the backend compute a genuine trend from invented data and show it to
/// a patient as an estimate. That is precisely what the estimate-versus-measurement separation
/// exists to prevent, and it would be undetectable downstream.
///
/// So the flow runs end to end, the session reaches the backend, and it is recorded as a
/// rejected session with a reason naming the actual cause. Rejected sessions are already
/// designed to be visible in the timeline and the clinician summary, so nothing is hidden.
class UnimplementedSignalPipeline implements SignalPipeline {
  const UnimplementedSignalPipeline();

  @override
  Future<SignalResult> process(CaptureResult capture) async {
    final accelStats = capture.accelerometer.rateStatistics;
    final frameStats = capture.frames.rateStatistics;

    // The quality block is real: measured from the capture that just happened, and what the
    // backend's plausibility gate checks. Only the beat analysis is absent.
    final quality = <String, dynamic>{
      'accel_rate_hz': accelStats?.meanRateHz ?? 0.0,
      'camera_fps': frameStats?.meanRateHz ?? 0.0,
      'dropped_frame_pct': frameStats?.droppedPercent ?? 100.0,
      // Not derived from the signal, and not claimed to be. The gate needs the field present,
      // and a value that cannot be computed is reported at its worst rather than invented
      // favourably.
      'snr_db': 0.0,
      'motion_index': 1.0,
    };

    final offset = capture.clockBasis.camera?.clockSeparationMillis;
    if (offset != null) quality['clock_offset_ms'] = offset;

    return SignalResult(
      accepted: false,
      pttMs: const [],
      nBeatsTotal: 0,
      nBeatsUsable: 0,
      quality: quality,
      rejectionReason: SignalRejection.signalProcessingUnavailable,
    );
  }
}
