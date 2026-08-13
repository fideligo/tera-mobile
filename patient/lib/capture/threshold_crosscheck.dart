/// Catching the two halves of the system disagreeing about a threshold.
///
/// Several thresholds exist twice. The backend holds them as pydantic-settings, overridable from
/// the environment; the handset holds them as compile-time constants, because it has to decide
/// whether to let a patient record before it can ask anything. They agree today by hand, and
/// nothing was keeping them agreeing.
///
/// That is a live failure mode. Set a backend override at a venue — or edit one side and forget
/// the other — and the handset admits captures the backend then rejects, with no signal anywhere
/// that the two disagree.
///
/// **The check compares verdicts, not numbers.** The handset grades the handset and submits the
/// measurements; the backend grades the same measurements independently and returns its own
/// verdict. If those differ, a threshold has drifted, whatever the numbers happen to be.
///
/// Comparing verdicts rather than parsing the backend's `threshold` field is deliberate. That
/// field is prose built for a human reading a device report — `">= 500 Hz target, >= 200 Hz
/// minimum"` — and a Dart regex over it would be a second place for the halves to disagree, one
/// that fails silently the first time somebody rewords the string. A verdict is a value both sides
/// compute from the same inputs.
///
/// It compares the **accelerometer finding specifically**, not the overall `qualified_status`. The
/// backend grades five measurements and takes the worst; the handset's gate depends only on the
/// accelerometer rate. Comparing the overall verdicts would fire every time a handset was graded
/// down for its camera hardware level, which is not threshold drift and would train everyone to
/// ignore the warning.
library;

import 'dart:developer' as developer;

import 'package:meta/meta.dart';

import 'eligibility_check.dart';

/// The label the backend gives its accelerometer finding.
///
/// Prose, and therefore the one brittle join in here. When it does not match, the outcome is
/// [ThresholdAgreement.notChecked] — which is reported, not silently treated as agreement. "We
/// could not check" and "we checked and they agree" are different facts.
const String accelFindingLabel = 'Accelerometer achieved rate';

enum ThresholdAgreement {
  /// Both sides reached the same verdict on the same measurement.
  agreed,

  /// They did not. A threshold has drifted.
  disagreed,

  /// The comparison could not be made — no accelerometer finding in the response, or the handset
  /// could not grade. Not a pass.
  notChecked,
}

@immutable
class ThresholdCrossCheckResult {
  const ThresholdCrossCheckResult({
    required this.agreement,
    required this.summary,
    this.handsetVerdict,
    this.backendVerdict,
    this.backendThreshold,
  });

  final ThresholdAgreement agreement;

  /// One line, written for whoever is reading logs at a venue under time pressure.
  final String summary;

  final EligibilityVerdict? handsetVerdict;
  final String? backendVerdict;

  /// The backend's own words for the threshold it applied. Carried so a human sees the actual
  /// numbers without anyone having to parse them.
  final String? backendThreshold;
}

/// Wire values of the backend's `QualifiedStatus`.
String? _wireValue(EligibilityVerdict verdict) => switch (verdict) {
  EligibilityVerdict.qualified => 'qualified',
  EligibilityVerdict.provisional => 'provisional',
  EligibilityVerdict.notQualified => 'not_qualified',
  // The handset could not grade, so there is nothing to compare against.
  EligibilityVerdict.couldNotCheck => null,
};

/// Compare the handset's accelerometer verdict against the backend's, given a device-profile
/// response body.
ThresholdCrossCheckResult crossCheckThresholds({
  required double accelRateHz,
  required Map<String, dynamic> deviceProfile,
}) {
  final handsetVerdict = gradeAccelRate(accelRateHz);
  final expected = _wireValue(handsetVerdict);
  if (expected == null) {
    return const ThresholdCrossCheckResult(
      agreement: ThresholdAgreement.notChecked,
      summary: 'The handset had no accelerometer verdict to compare.',
    );
  }

  final findings = deviceProfile['findings'];
  if (findings is! List) {
    return ThresholdCrossCheckResult(
      agreement: ThresholdAgreement.notChecked,
      summary:
          'The device profile carried no findings, so the accelerometer thresholds could not be '
          'compared.',
      handsetVerdict: handsetVerdict,
    );
  }

  Map<String, dynamic>? accelFinding;
  for (final f in findings) {
    if (f is Map<String, dynamic> && f['measurement'] == accelFindingLabel) {
      accelFinding = f;
      break;
    }
  }

  if (accelFinding == null) {
    return ThresholdCrossCheckResult(
      agreement: ThresholdAgreement.notChecked,
      summary:
          'No finding labelled "$accelFindingLabel" in the device profile. The backend may have '
          'reworded it; the accelerometer thresholds were NOT compared.',
      handsetVerdict: handsetVerdict,
    );
  }

  final backendVerdict = accelFinding['verdict'] as String?;
  final backendThreshold = accelFinding['threshold'] as String?;

  if (backendVerdict == expected) {
    return ThresholdCrossCheckResult(
      agreement: ThresholdAgreement.agreed,
      summary:
          'Accelerometer thresholds agree: both graded '
          '${accelRateHz.toStringAsFixed(1)} Hz as $expected.',
      handsetVerdict: handsetVerdict,
      backendVerdict: backendVerdict,
      backendThreshold: backendThreshold,
    );
  }

  return ThresholdCrossCheckResult(
    agreement: ThresholdAgreement.disagreed,
    summary:
        'THRESHOLD MISMATCH. The same ${accelRateHz.toStringAsFixed(1)} Hz was graded "$expected" '
        'by this handset and "$backendVerdict" by the backend. The backend applied: '
        '${backendThreshold ?? "(no threshold reported)"}. The handset uses '
        '${targetAccelRateHz.toStringAsFixed(0)} Hz target / '
        '${minimumAccelRateHz.toStringAsFixed(0)} Hz minimum, compiled in. One side has been '
        'changed without the other.',
    handsetVerdict: handsetVerdict,
    backendVerdict: backendVerdict,
    backendThreshold: backendThreshold,
  );
}

/// Run the check and log it. Never throws, and never blocks the patient.
///
/// The backend's grading is authoritative for what gets stored, so a disagreement is a
/// configuration fault for a developer to fix, not a reason to refuse a patient their spot check.
/// Loud in the log, invisible on the screen.
ThresholdCrossCheckResult reportThresholdCrossCheck({
  required double accelRateHz,
  required Map<String, dynamic> deviceProfile,
}) {
  final result = crossCheckThresholds(
    accelRateHz: accelRateHz,
    deviceProfile: deviceProfile,
  );
  developer.log(
    result.summary,
    name: 'tera.thresholds',
    level: switch (result.agreement) {
      ThresholdAgreement.disagreed => 1000, // SEVERE
      ThresholdAgreement.notChecked => 900, // WARNING
      ThresholdAgreement.agreed => 500, // FINE
    },
  );
  return result;
}
