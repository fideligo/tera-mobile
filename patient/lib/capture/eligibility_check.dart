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
      verdict == EligibilityVerdict.qualified || verdict == EligibilityVerdict.provisional;
}

class EligibilityChecker {
  EligibilityChecker({TeraCapture? capture}) : _capture = capture ?? TeraCapture();

  final TeraCapture _capture;

  /// Measure the handset and grade it.
  ///
  /// Returns [EligibilityVerdict.couldNotCheck] rather than [EligibilityVerdict.notQualified]
  /// when the probe fails: "this device is not suitable" and "we could not tell" are different
  /// statements, and reporting the second as the first would condemn a handset on no evidence.
  Future<EligibilityResult> check() async {
    CameraCapabilities? capabilities;
    try {
      capabilities = await _capture.readCameraCapabilities();
    } on Object catch (e) {
      return EligibilityResult(
        verdict: EligibilityVerdict.couldNotCheck,
        headline: 'Could not check this phone',
        detail: 'The camera did not report its capabilities. $e',
      );
    }

    if (!capabilities.hasFlash) {
      return EligibilityResult(
        verdict: EligibilityVerdict.notQualified,
        headline: 'This phone cannot be used',
        detail:
            'A spot check needs the camera light, and this phone does not have one. Ask your '
            'clinic about a supported handset.',
        capabilities: capabilities,
      );
    }

    final double achieved;
    try {
      final recording = await _capture.recordAccelerometer(eligibilityProbeDuration);
      final stats = recording.rateStatistics;
      if (stats == null) {
        return EligibilityResult(
          verdict: EligibilityVerdict.couldNotCheck,
          headline: 'Could not check this phone',
          detail:
              'The motion sensor did not send enough readings to measure its speed. Close '
              'other apps and try again.',
          capabilities: capabilities,
        );
      }
      achieved = stats.meanRateHz;
    } on Object catch (e) {
      return EligibilityResult(
        verdict: EligibilityVerdict.couldNotCheck,
        headline: 'Could not check this phone',
        detail: 'The motion sensor could not be read. $e',
        capabilities: capabilities,
      );
    }

    if (achieved < minimumAccelRateHz) {
      return EligibilityResult(
        verdict: EligibilityVerdict.notQualified,
        headline: 'This phone cannot be used',
        detail:
            'Its motion sensor runs at ${achieved.toStringAsFixed(0)} readings per second. '
            'Tera needs at least ${minimumAccelRateHz.toStringAsFixed(0)}. Below that, the '
            'timing error is larger than the change being measured, so any result would be '
            'meaningless. Ask your clinic about a supported handset.',
        achievedRateHz: achieved,
        capabilities: capabilities,
      );
    }

    if (achieved < targetAccelRateHz) {
      return EligibilityResult(
        verdict: EligibilityVerdict.provisional,
        headline: 'This phone can be used',
        detail:
            'Its motion sensor runs at ${achieved.toStringAsFixed(0)} readings per second — '
            'above the minimum of ${minimumAccelRateHz.toStringAsFixed(0)}, below the '
            '${targetAccelRateHz.toStringAsFixed(0)} Tera works best with. Spot checks will '
            'work, and more of them may be set aside as unusable.',
        achievedRateHz: achieved,
        capabilities: capabilities,
      );
    }

    return EligibilityResult(
      verdict: EligibilityVerdict.qualified,
      headline: 'This phone is a good fit',
      detail:
          'Its motion sensor runs at ${achieved.toStringAsFixed(0)} readings per second, at or '
          'above the ${targetAccelRateHz.toStringAsFixed(0)} Tera works best with.',
      achievedRateHz: achieved,
      capabilities: capabilities,
    );
  }
}
