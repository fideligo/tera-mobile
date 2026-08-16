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

/// The clinical band, from the proposal (p. 7). **These do not move.**
///
/// 200 Hz is a floor rather than a target: the proposal's own measured figure is 10.6 ms of jitter
/// at 100 Hz against a signal carried in 10–50 ms shifts, so below it the timing error is larger
/// than the effect being measured and no downstream processing recovers that. 500 Hz is where the
/// sample interval stops being a leading error term. They match the backend's
/// `DeviceEligibilitySettings` so the two sides agree, and `threshold_crosscheck.dart` reports it
/// when they stop agreeing.
const double clinicalMinimumAccelRateHz = 200.0;
const double clinicalTargetAccelRateHz = 500.0;

/// **The gate is open for field testing, and this is the switch.**
///
/// Enforcing the clinical floor refuses a handset *before* it produces any data, so the one thing
/// it guarantees is that nothing is ever learned about the handsets being refused. There are no
/// field measurements yet to set a real baseline from, and the gate blocks the work that would
/// produce them. Until that changes, every device proceeds to capture.
///
/// What this is **not**: a decision that low-rate handsets can produce trustworthy readings. They
/// cannot, and nothing downstream pretends otherwise —
///
///   * the local signal gate still refuses a capture that cannot yield [minUsableBeats] intervals,
///     so a bad rate produces a refusal rather than a fabricated reading;
///   * the backend still grades the device profile against *its* 200 Hz band, and still marks a
///     session `sensor_rate_below_qualified` when the achieved rate misses it — retained, per
///     invariant 3, which is where the field telemetry actually accumulates;
///   * the measured rate is recorded on the handset and shown in Profile, so a patient and a
///     tester both see the figure rather than the verdict alone.
///
/// Restoring the clinical gate is one define: `--dart-define=TERA_OPEN_DEVICE_GATE=false`. It is a
/// define rather than a deleted branch because this gate has already been lost once — commit
/// 0200c30 replaced `EligibilityChecker.check()` with a stub returning a hardcoded 500 Hz, and it
/// took a git archaeology pass to notice and restore. A threshold that is configuration can be put
/// back; a threshold that was deleted has to be rediscovered.
const bool openDeviceGate = bool.fromEnvironment(
  'TERA_OPEN_DEVICE_GATE',
  defaultValue: true,
);

/// The band actually enforced. Equal to the clinical band unless [openDeviceGate] is set.
///
/// The *target* does not move even when the gate is open: a handset below it is still reported as
/// `provisional`, which already proceeds, so keeping it means the verdict still carries the honest
/// figure instead of calling every phone qualified.
const double minimumAccelRateHz = openDeviceGate
    ? 0.0
    : clinicalMinimumAccelRateHz;
const double targetAccelRateHz = clinicalTargetAccelRateHz;

/// Whether a handset with no camera light is refused.
///
/// Held to the same switch. PPG needs illumination and a torchless phone will produce nothing the
/// signal chain can use — but "produces nothing" is itself the measurement field testing is for,
/// and the local gate reports it as a refusal rather than a reading.
const bool requireTorch = !openDeviceGate;

/// How long to sample when measuring the achieved rate. Long enough for the mean to settle,
/// short enough that a patient will wait for it.
const Duration eligibilityProbeDuration = Duration(seconds: 6);

/// The accelerometer band rule on its own, so the threshold cross-check applies exactly the rule
/// the gate applies rather than a second copy of it that can drift.
///
/// The bounds default to the *enforced* band, which is what the gate uses. They are parameters so
/// the rule can be exercised against the **clinical** band whatever posture the build is in:
/// [openDeviceGate] is a compile-time constant, so without this a test of the closed-gate rule
/// would need a second build to run, and a rule that cannot be tested in the shipped build is a
/// rule that quietly stops being true.
EligibilityVerdict gradeAccelRate(
  double achievedHz, {
  double minimumHz = minimumAccelRateHz,
  double targetHz = targetAccelRateHz,
}) {
  if (achievedHz < minimumHz) return EligibilityVerdict.notQualified;
  if (achievedHz < targetHz) return EligibilityVerdict.provisional;
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

    if (requireTorch && !capabilities.hasFlash) {
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

    final graded = gradeAccelRate(achieved);

    if (graded == EligibilityVerdict.notQualified) {
      return EligibilityResult(
        verdict: EligibilityVerdict.notQualified,
        headline: 'This phone cannot be used',
        detail:
            'Its motion sensor runs at ${achieved.toStringAsFixed(0)} readings per second. '
            'Tera needs at least ${clinicalMinimumAccelRateHz.toStringAsFixed(0)}. Below that, the '
            'timing error is larger than the change being measured, so any result would be '
            'meaningless. Ask your clinic about a supported handset.',
        achievedRateHz: achieved,
        capabilities: capabilities,
      );
    }

    if (graded == EligibilityVerdict.provisional) {
      // While the gate is open the enforced floor is 0, so quoting it back ("above the minimum of
      // 0") would be meaningless. The clinical floor is what the sentence is actually about, and
      // it is the figure a tester needs to read.
      if (openDeviceGate && achieved < clinicalMinimumAccelRateHz) {
        return EligibilityResult(
          verdict: EligibilityVerdict.provisional,
          headline: 'This phone can be used, with a caveat',
          detail:
              'Its motion sensor runs at ${achieved.toStringAsFixed(0)} readings per second, '
              'below the ${clinicalMinimumAccelRateHz.toStringAsFixed(0)} Tera is designed '
              'around. Checks will run so the method can be measured on real hardware, and more '
              'of them will be set aside as unusable.',
          achievedRateHz: achieved,
          capabilities: capabilities,
        );
      }
      return EligibilityResult(
        verdict: EligibilityVerdict.provisional,
        headline: 'This phone can be used',
        detail:
            'Its motion sensor runs at ${achieved.toStringAsFixed(0)} readings per second — '
            'above the minimum of ${clinicalMinimumAccelRateHz.toStringAsFixed(0)}, below the '
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
