/// The rhythm-anomaly model, evaluated on the handset in pure Dart.
///
/// # Why not `tflite_flutter`
///
/// The artefact is a **scikit-learn Random Forest**, not a neural network. `ml/MODEL_HANDOFF.md`
/// section 1 is explicit: TFLite converts TensorFlow/Keras models only, so a Random Forest cannot
/// be exported to `.tflite` at all. The ML team prepared two on-device routes instead —
/// `model.onnx` via `onnxruntime`, and `model_trees.json` for "evaluasi pohon murni di Dart
/// (tanpa dependensi runtime)". This is the second: a decision tree is an `if` ladder, so a forest
/// needs no inference runtime, no native library and no new dependency.
///
/// # What it is for, and what it is not
///
/// It powers exactly one field: whether the rhythm looked irregular. PTT is unreliable in an
/// irregular rhythm — every competitor excludes arrhythmia by questionnaire, and this detects it
/// in the measurement itself. It is **not** a diagnosis and is never presented as one.
///
/// # Off by default, deliberately
///
/// The handoff's own recommendation: "Leave `rhythm_model` unset and everything works... If there
/// is any doubt on demo day, run without it. A missing flag costs nothing. A false 'irregular
/// rhythm' on a healthy volunteer in front of a judge costs a lot."
///
/// The asset is 37 MB and is **not** bundled. [RhythmForest.fromJson] takes the decoded JSON, so
/// wiring it to a real asset is a deliberate act with a build-size cost attached.
library;

import 'dart:math' as math;

import 'package:meta/meta.dart';

/// Feature order as it appears in `model_trees.json`, which is the order the forest was trained
/// on. Wrong order, wrong answer, no error — so the loader checks it rather than assuming it.
const List<String> rhythmFeatureOrder = [
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
];

/// Physiological bounds on an RR interval, seconds. From the reference's `rhythm_flag`.
const double rrMinSeconds = 0.2;
const double rrMaxSeconds = 2.5;

/// Fewer intervals than this and the features mean nothing.
const int minRrIntervals = 8;

/// The 10 HRV features, computed exactly as `_hrv_features` in `tera_ptt.py` does.
///
/// [rr] is in **seconds**; the features are in milliseconds where the names say so.
@visibleForTesting
List<double> hrvFeatures(List<double> rr) {
  final rrMs = [for (final r in rr) r * 1000.0];
  final n = rrMs.length;

  double meanOf(List<double> v) => v.reduce((a, b) => a + b) / v.length;

  final meanRr = meanOf(rrMs);
  double acc = 0;
  for (final v in rrMs) {
    acc += (v - meanRr) * (v - meanRr);
  }
  // numpy's ndarray.std() is population (ddof = 0).
  final sdnn = math.sqrt(acc / n);

  final d = <double>[for (int i = 1; i < n; i++) rrMs[i] - rrMs[i - 1]];
  double rmssd = 0.0;
  if (d.isNotEmpty) {
    double sq = 0;
    for (final v in d) {
      sq += v * v;
    }
    rmssd = math.sqrt(sq / d.length);
  }

  // Longest consecutive run of intervals above 0.6 s, in seconds.
  double run = 0;
  double longest = 0;
  for (final r in rr) {
    if (r > 0.6) {
      run += r;
      longest = math.max(longest, run);
    } else {
      run = 0;
    }
  }

  // Slope of instantaneous HR across the window, from a first-order least-squares fit.
  final instHr = [for (final r in rr) 60.0 / math.max(r, 1e-3)];
  double slope = 0.0;
  if (instHr.length >= 3) {
    final xs = [for (int i = 0; i < instHr.length; i++) i.toDouble()];
    final mx = meanOf(xs);
    final my = meanOf(instHr);
    double num = 0;
    double den = 0;
    for (int i = 0; i < xs.length; i++) {
      num += (xs[i] - mx) * (instHr[i] - my);
      den += (xs[i] - mx) * (xs[i] - mx);
    }
    slope = den == 0 ? 0.0 : num / den;
  }

  int longCount = 0;
  for (final r in rr) {
    if (r > 0.6) longCount++;
  }

  return [
    60000.0 / meanRr, // mean_hr
    meanRr, // mean_rr
    sdnn, // sdnn
    rmssd, // rmssd
    sdnn / (meanRr + 1e-8), // rr_cv
    rrMs.reduce(math.min), // min_rr
    rrMs.reduce(math.max), // max_rr
    longCount / rr.length, // pct_long
    longest, // long_brady
    slope, // hr_slope
  ];
}

/// RR intervals in seconds from beat times, filtered to the physiological band.
@visibleForTesting
List<double> rrIntervalsFrom(List<double> beatTimes) => [
  for (int i = 1; i < beatTimes.length; i++)
    if (beatTimes[i] - beatTimes[i - 1] > rrMinSeconds &&
        beatTimes[i] - beatTimes[i - 1] < rrMaxSeconds)
      beatTimes[i] - beatTimes[i - 1],
];

@immutable
class _Tree {
  const _Tree({
    required this.childrenLeft,
    required this.childrenRight,
    required this.feature,
    required this.threshold,
    required this.value,
  });

  final List<int> childrenLeft;
  final List<int> childrenRight;

  /// `-2` marks a leaf, which is scikit-learn's `TREE_UNDEFINED`.
  final List<int> feature;
  final List<double> threshold;

  /// Class proportions per node, `[normal, abnormal]`.
  final List<List<double>> value;

  /// Probability of the abnormal class for one feature vector.
  double probability(List<double> x) {
    int node = 0;
    // scikit-learn's rule is `x <= threshold` goes left. Getting this backwards produces a
    // confident answer from the wrong half of every split.
    while (feature[node] != -2) {
      node = x[feature[node]] <= threshold[node]
          ? childrenLeft[node]
          : childrenRight[node];
    }
    final v = value[node];
    final total = v.reduce((a, b) => a + b);
    return total <= 0 ? 0.0 : v[1] / total;
  }

  static _Tree fromJson(Map<String, dynamic> json) => _Tree(
    childrenLeft: (json['children_left'] as List)
        .map((v) => (v as num).toInt())
        .toList(),
    childrenRight: (json['children_right'] as List)
        .map((v) => (v as num).toInt())
        .toList(),
    feature: (json['feature'] as List).map((v) => (v as num).toInt()).toList(),
    threshold: (json['threshold'] as List)
        .map((v) => (v as num).toDouble())
        .toList(),
    value: (json['value'] as List)
        .map((row) => (row as List).map((v) => (v as num).toDouble()).toList())
        .toList(),
  );
}

@immutable
class RhythmVerdict {
  const RhythmVerdict({required this.irregular, required this.probability});

  final bool irregular;
  final double probability;
}

/// A Random Forest, evaluated by walking each tree and averaging.
class RhythmForest {
  RhythmForest._({
    required List<_Tree> trees,
    required this.opThreshold,
    required this.featureOrder,
    required this.opThresholdIsFallback,
  }) : _trees = trees;

  final List<_Tree> _trees;

  /// The operating point the model was tuned at. `model_trees.json` ships about 0.10 — nothing
  /// like 0.5, so substituting a default silently would change the model's behaviour entirely.
  final double opThreshold;

  final List<String> featureOrder;
  final bool opThresholdIsFallback;

  int get treeCount => _trees.length;

  /// Build from a decoded `model_trees.json`.
  ///
  /// Throws [FormatException] on a feature order this build does not compute. A silent mismatch
  /// would give a confident answer from the wrong columns.
  factory RhythmForest.fromJson(
    Map<String, dynamic> json, {
    double fallbackThreshold = 0.5,
  }) {
    final features = (json['features'] as List?)
        ?.map((v) => v.toString())
        .toList();
    if (features == null || features.length != rhythmFeatureOrder.length) {
      throw FormatException(
        'model_trees.json declares ${features?.length} features, this build computes '
        '${rhythmFeatureOrder.length}',
      );
    }
    for (int i = 0; i < features.length; i++) {
      if (features[i] != rhythmFeatureOrder[i]) {
        throw FormatException(
          'feature $i is "${features[i]}" in the model and "${rhythmFeatureOrder[i]}" here; '
          'the order is part of the contract',
        );
      }
    }

    final rawThreshold = json['op_threshold'];
    return RhythmForest._(
      trees: (json['trees'] as List)
          .map((t) => _Tree.fromJson(t as Map<String, dynamic>))
          .toList(),
      opThreshold: rawThreshold == null
          ? fallbackThreshold
          : (rawThreshold as num).toDouble(),
      opThresholdIsFallback: rawThreshold == null,
      featureOrder: features,
    );
  }

  /// The verdict for a set of beat times, or null when there is not enough to judge.
  ///
  /// Null is a real answer here, not a failure: it means the question was not asked, and the
  /// caller reports nothing rather than reporting "regular".
  RhythmVerdict? assess(List<double> beatTimes) {
    final rr = rrIntervalsFrom(beatTimes);
    if (rr.length < minRrIntervals) return null;

    final x = hrvFeatures(rr);
    double total = 0;
    for (final tree in _trees) {
      total += tree.probability(x);
    }
    final p = total / _trees.length;
    return RhythmVerdict(irregular: p >= opThreshold, probability: p);
  }
}
