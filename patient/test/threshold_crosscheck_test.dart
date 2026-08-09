import 'package:flutter_test/flutter_test.dart';
import 'package:tera_patient/capture/eligibility_check.dart';
import 'package:tera_patient/capture/threshold_crosscheck.dart';

/// A device-profile response with one accelerometer finding graded [verdict].
Map<String, dynamic> profileWithAccelVerdict(
  String verdict, {
  String label = accelFindingLabel,
  String threshold = '>= 500 Hz target, >= 200 Hz minimum',
}) => {
  'id': 'a-device-profile',
  'qualified_status': verdict,
  'findings': [
    {
      'measurement': 'Camera sustained frame rate',
      'measured': '30.0 fps',
      'threshold': '>= 30 fps qualified, >= 24 fps provisional',
      'verdict': 'qualified',
      'explanation': 'irrelevant to this check',
    },
    {
      'measurement': label,
      'measured': '250.0 Hz',
      'threshold': threshold,
      'verdict': verdict,
      'explanation': 'graded by the backend',
    },
  ],
};

void main() {
  group('agreement', () {
    test('the same rate graded the same way on both sides agrees', () {
      // 250 Hz: above the 200 minimum, below the 500 target -> provisional on the handset.
      final result = crossCheckThresholds(
        accelRateHz: 250,
        deviceProfile: profileWithAccelVerdict('provisional'),
      );

      expect(result.agreement, ThresholdAgreement.agreed);
      expect(result.handsetVerdict, EligibilityVerdict.provisional);
      expect(result.backendVerdict, 'provisional');
    });

    test('a qualified rate agrees when the backend also says qualified', () {
      final result = crossCheckThresholds(
        accelRateHz: 500,
        deviceProfile: profileWithAccelVerdict('qualified'),
      );

      expect(result.agreement, ThresholdAgreement.agreed);
    });
  });

  group('drift is caught', () {
    test('a backend that rebanded upward disagrees with the handset', () {
      // The venue case: someone raises the backend's minimum past 250 without rebuilding the APK.
      final result = crossCheckThresholds(
        accelRateHz: 250,
        deviceProfile: profileWithAccelVerdict(
          'not_qualified',
          threshold: '>= 800 Hz target, >= 400 Hz minimum',
        ),
      );

      expect(result.agreement, ThresholdAgreement.disagreed);
      expect(result.handsetVerdict, EligibilityVerdict.provisional);
      expect(result.backendVerdict, 'not_qualified');
    });

    test('the message carries both sides and the backend threshold prose', () {
      final result = crossCheckThresholds(
        accelRateHz: 250,
        deviceProfile: profileWithAccelVerdict(
          'not_qualified',
          threshold: '>= 800 Hz target, >= 400 Hz minimum',
        ),
      );

      // A human reading this at a venue needs the numbers, not just "mismatch".
      expect(result.summary, contains('250.0 Hz'));
      expect(result.summary, contains('provisional'));
      expect(result.summary, contains('not_qualified'));
      expect(result.summary, contains('>= 800 Hz target'));
      expect(result.backendThreshold, '>= 800 Hz target, >= 400 Hz minimum');
    });
  });

  group('"could not check" is never reported as agreement', () {
    test('a reworded finding label is notChecked, not agreed', () {
      final result = crossCheckThresholds(
        accelRateHz: 250,
        deviceProfile: profileWithAccelVerdict(
          'provisional',
          label: 'Accelerometer sample rate (achieved)',
        ),
      );

      expect(result.agreement, ThresholdAgreement.notChecked);
      expect(result.summary, contains('NOT compared'));
    });

    test('a response with no findings is notChecked', () {
      final result = crossCheckThresholds(
        accelRateHz: 250,
        deviceProfile: const {'id': 'x', 'qualified_status': 'provisional'},
      );

      expect(result.agreement, ThresholdAgreement.notChecked);
    });
  });

  group('the comparison is scoped to the accelerometer', () {
    test('an overall status graded down by another measurement does not fire', () {
      // The backend takes the worst of five measurements. A handset graded down for its camera
      // is not threshold drift, and firing here would train everyone to ignore the warning.
      final profile = profileWithAccelVerdict('qualified');
      profile['qualified_status'] = 'provisional'; // dragged down by the camera finding

      final result = crossCheckThresholds(accelRateHz: 500, deviceProfile: profile);

      expect(result.agreement, ThresholdAgreement.agreed);
    });
  });

  group('the graded rule is the gate\'s own rule', () {
    test('band boundaries are inclusive at the qualifying end', () {
      expect(gradeAccelRate(minimumAccelRateHz), EligibilityVerdict.provisional);
      expect(gradeAccelRate(targetAccelRateHz), EligibilityVerdict.qualified);
      expect(gradeAccelRate(minimumAccelRateHz - 0.1), EligibilityVerdict.notQualified);
    });
  });
}
