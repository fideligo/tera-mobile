/// The on-device rhythm model: features against the Python, tree walking against a forest whose
/// answer can be worked out by hand.
///
/// The real artefact is 400 trees and 37 MB and is not bundled, so the two halves are pinned
/// separately. `hrv_reference.json` comes from the ML team's own `_hrv_features`; the tree
/// evaluator is checked against a forest small enough to verify by reading it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tera_patient/capture/dsp/rhythm_model.dart';

Map<String, dynamic> _hrvReference() =>
    jsonDecode(File('test/fixtures/hrv_reference.json').readAsStringSync())
        as Map<String, dynamic>;

/// A two-tree forest splitting on feature 0 (mean_hr) at 70 bpm.
///
/// Tree layout: node 0 is the split, nodes 1 and 2 are leaves.
///   left  (mean_hr <= 70) -> [0.9 normal, 0.1 abnormal]
///   right (mean_hr >  70) -> [0.2 normal, 0.8 abnormal]
Map<String, dynamic> _toyForest({double? opThreshold, List<String>? features}) => {
  'features': features ?? rhythmFeatureOrder,
  if (opThreshold != null) 'op_threshold': opThreshold,
  'n_classes': 2,
  'trees': [
    {
      'children_left': [1, -1, -1],
      'children_right': [2, -1, -1],
      'feature': [0, -2, -2],
      'threshold': [70.0, -2.0, -2.0],
      'value': [
        [0.5, 0.5],
        [0.9, 0.1],
        [0.2, 0.8],
      ],
    },
    {
      'children_left': [1, -1, -1],
      'children_right': [2, -1, -1],
      'feature': [0, -2, -2],
      'threshold': [70.0, -2.0, -2.0],
      'value': [
        [0.5, 0.5],
        [0.7, 0.3],
        [0.4, 0.6],
      ],
    },
  ],
};

List<double> _beatTimesFrom(List<double> rr) {
  final t = <double>[0.0];
  for (final r in rr) {
    t.add(t.last + r);
  }
  return t;
}

void main() {
  group('HRV features match the ML team implementation', () {
    test('every case, every feature', () {
      final reference = _hrvReference();

      reference.forEach((name, data) {
        final rr = (data['rr'] as List).map((v) => (v as num).toDouble()).toList();
        final want = (data['features'] as List).map((v) => (v as num).toDouble()).toList();
        final got = hrvFeatures(rr);

        expect(got.length, rhythmFeatureOrder.length, reason: name);
        for (int i = 0; i < want.length; i++) {
          expect(
            got[i],
            closeTo(want[i], 1e-6),
            reason: '$name: ${rhythmFeatureOrder[i]}',
          );
        }
      });
    });

    test('a perfectly regular rhythm has zero dispersion', () {
      final f = hrvFeatures(List<double>.filled(20, 0.8333));

      expect(f[2], closeTo(0.0, 1e-9), reason: 'sdnn');
      expect(f[3], closeTo(0.0, 1e-9), reason: 'rmssd');
      expect(f[4], closeTo(0.0, 1e-9), reason: 'rr_cv');
    });

    test('an irregular rhythm has visibly larger dispersion than a regular one', () {
      final reference = _hrvReference();
      final regular = hrvFeatures(
        (reference['regular_72bpm']['rr'] as List).map((v) => (v as num).toDouble()).toList(),
      );
      final irregular = hrvFeatures(
        (reference['irregular']['rr'] as List).map((v) => (v as num).toDouble()).toList(),
      );

      expect(irregular[2], greaterThan(regular[2]), reason: 'sdnn');
      expect(irregular[3], greaterThan(regular[3]), reason: 'rmssd');
    });
  });

  group('RR extraction', () {
    test('intervals outside the physiological band are dropped', () {
      // 0.1 s is faster than any heart; 3.0 s is a gap, not a beat.
      final times = [0.0, 0.1, 0.9, 1.7, 4.7, 5.5];
      final rr = rrIntervalsFrom(times);

      expect(rr, everyElement(greaterThan(rrMinSeconds)));
      expect(rr, everyElement(lessThan(rrMaxSeconds)));
      expect(rr.length, 3);
    });

    test('too few intervals is answered with null, not a guess', () {
      final forest = RhythmForest.fromJson(_toyForest(opThreshold: 0.5));

      // Null means the question was not asked. Reporting "regular" here would be an answer the
      // data does not support.
      expect(forest.assess([0.0, 0.83, 1.66]), isNull);
    });
  });

  group('forest evaluation', () {
    test('a split sends low values left and high values right', () {
      final forest = RhythmForest.fromJson(_toyForest(opThreshold: 0.5));

      // Bradycardic: mean_hr about 59.8, so <= 70 goes left -> (0.1 + 0.3) / 2 = 0.2
      final slow = forest.assess(_beatTimesFrom(List<double>.filled(12, 1.0)));
      expect(slow, isNotNull);
      expect(slow!.probability, closeTo(0.2, 1e-9));
      expect(slow.irregular, isFalse);

      // Tachycardic: mean_hr about 100, so > 70 goes right -> (0.8 + 0.6) / 2 = 0.7
      final fast = forest.assess(_beatTimesFrom(List<double>.filled(12, 0.6)));
      expect(fast, isNotNull);
      expect(fast!.probability, closeTo(0.7, 1e-9));
      expect(fast.irregular, isTrue);
    });

    test('the operating point decides the verdict, not a hardcoded half', () {
      final times = _beatTimesFrom(List<double>.filled(12, 0.6)); // probability 0.7

      expect(RhythmForest.fromJson(_toyForest(opThreshold: 0.10)).assess(times)!.irregular, isTrue);
      expect(RhythmForest.fromJson(_toyForest(opThreshold: 0.90)).assess(times)!.irregular, isFalse);
    });

    test('the real artefact ships about 0.10, so a 0.5 default would be a different model', () {
      // model_trees.json carries op_threshold 0.10023..., and the difference is not cosmetic:
      // it is the sensitivity-0.90 operating point the model was validated at.
      final tuned = RhythmForest.fromJson(_toyForest(opThreshold: 0.10024));
      final defaulted = RhythmForest.fromJson(_toyForest());

      expect(tuned.opThreshold, closeTo(0.10024, 1e-9));
      expect(tuned.opThresholdIsFallback, isFalse);
      expect(defaulted.opThreshold, 0.5);
      expect(defaulted.opThresholdIsFallback, isTrue);
    });

    test('probabilities are averaged across trees', () {
      final forest = RhythmForest.fromJson(_toyForest(opThreshold: 0.5));

      expect(forest.treeCount, 2);
    });
  });

  group('the feature contract is enforced, not assumed', () {
    test('a reordered feature list is refused', () {
      final swapped = List<String>.from(rhythmFeatureOrder);
      swapped[0] = rhythmFeatureOrder[1];
      swapped[1] = rhythmFeatureOrder[0];

      // Wrong order gives a confident answer from the wrong columns, with no error anywhere.
      expect(
        () => RhythmForest.fromJson(_toyForest(features: swapped)),
        throwsA(isA<FormatException>()),
      );
    });

    test('a different feature count is refused', () {
      expect(
        () => RhythmForest.fromJson(_toyForest(features: const ['mean_hr', 'mean_rr'])),
        throwsA(isA<FormatException>()),
      );
    });

    test('the order is the one the shipped model declares', () {
      // Read straight out of model_trees.json's "features" key.
      expect(rhythmFeatureOrder, const [
        'mean_hr',
        'mean_rr',
        'sdnn',
        'rmssd',
        'rr_cv',
        'min_rr',
        'max_rr',
        'pct_long',
        'long_brady',
        'hr_slope',
      ]);
    });
  });
}
