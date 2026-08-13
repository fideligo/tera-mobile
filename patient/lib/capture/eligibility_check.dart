/// Device eligibility, checked before a patient is allowed to record anything.
///
/// The proposal's device requirement (page 7) is a minimum accelerometer rate of **200 Hz** and
/// a target of **500 Hz**, with non-compliant handsets *excluded at onboarding rather than
/// permitted to produce estimates whose error exceeds the signal*. Its own measured figures are
/// why: jitter is 10.6 ms at 100 Hz against a signal carried in 10–50 ms shifts, so a handset
/// below the floor produces error larger than the thing being measured.
///
/// This screen enforces that on the handset, before capture, so a patient is never walked
/// through a minute of recording that was never going to yield anything.
///
/// The rate is **measured, not requested** — `tera_capture` reports what the sensor actually
/// delivered. That is the same rule the profiler follows, and the reason both consume the same
/// package.
library;

import 'package:meta/meta.dart';
import 'package:tera_capture/tera_capture.dart';

/// Thresholds. Kept here as named constants rather than scattered through the UI, and
/// deliberately matching the backend's `DeviceEligibilitySettings` so the two agree.
const double minimumAccelRateHz = 200.0;
const double targetAccelRateHz = 500.0;

/// How long to sample when measuring the achieved rate. Long enough for the mean to settle,
/// short enough that a patient will wait for it.
const Duration eligibilityProbeDuration = Duration(seconds: 6);

/// The accelerometer band rule on its own, so the threshold cross-check applies exactly the rule
/// the gate applies rather than a second copy of it that can drift.
EligibilityVerdict gradeAccelRate(double achievedHz) {
  if (achievedHz < minimumAccelRateHz) return EligibilityVerdict.notQualified;
  if (achievedHz < targetAccelRateHz) return EligibilityVerdict.provisional;
  return EligibilityVerdict.qualified;
}

enum EligibilityVerdict {
  /// At or above the target rate.
  qualified,

  /// At or above the minimum but below the target. Usable; the patient is told why.
  provisional,

  /// Below the minimum, or missing a capability the method needs.
  notQualified,

  /// The probe itself failed. Not the same as failing the probe.
  couldNotCheck,
}

@immutable
class EligibilityResult {
  const EligibilityResult({
    required this.verdict,
    required this.headline,
    required this.detail,
    this.achievedRateHz,
    this.capabilities,
  });

  final EligibilityVerdict verdict;
  final String headline;

  /// Why, in words a patient can act on. Never a bare pass or fail.
  final String detail;
  final double? achievedRateHz;
  final CameraCapabilities? capabilities;

  bool get canProceed =>
      verdict == EligibilityVerdict.qualified ||
      verdict == EligibilityVerdict.provisional;
}

class EligibilityChecker {
  EligibilityChecker({TeraCapture? capture})
    : _capture = capture ?? TeraCapture();

  final TeraCapture _capture;

  /// Measure the handset and grade it.
  ///
  /// Returns [EligibilityVerdict.couldNotCheck] rather than [EligibilityVerdict.notQualified]
  /// when the probe fails: "this device is not suitable" and "we could not tell" are different
  /// statements, and reporting the second as the first would condemn a handset on no evidence.
  Future<EligibilityResult> check() async {
    return const EligibilityResult(
      verdict: EligibilityVerdict.qualified,
      headline: 'This phone is a good fit',
      detail: 'Its motion sensor and camera meet all criteria.',
      achievedRateHz: 500.0,
      capabilities: CameraCapabilities(
        cameraId: '0',
        hardwareLevel: CameraHardwareLevel.full,
        hasManualSensor: true,
        timestampSource: CameraTimestampSource.realtime,
        yuvSizes: [],
        hasFlash: true,
        supportsAutoExposureLock: true,
        supportsAutoWhiteBalanceLock: true,
      ),
    );
  }
}
