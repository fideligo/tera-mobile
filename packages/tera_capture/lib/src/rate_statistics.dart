/// Achieved-rate statistics computed from timestamps.
///
/// BUILD_SPEC 6.1: "Do not trust the requested rate — measure it." Everything here is derived
/// from the timestamps the platform actually reported, never from what was asked for.
library;

import 'dart:math' as math;

import 'package:meta/meta.dart';

@immutable
class RateStatistics {
  const RateStatistics({
    required this.sampleCount,
    required this.meanRateHz,
    required this.meanIntervalMillis,
    required this.intervalSdMillis,
    required this.p99IntervalMillis,
    required this.medianIntervalMillis,
    required this.estimatedDroppedSamples,
    required this.spanSeconds,
  });

  final int sampleCount;

  /// Computed as `(n - 1) / span`, from first and last timestamp. Not `n / requestedDuration`,
  /// which would hide samples that never arrived.
  final double meanRateHz;
  final double meanIntervalMillis;

  /// Standard deviation of the inter-sample interval — the jitter figure. BUILD_SPEC 6.1 asks
  /// for it by name because a stable-but-slow stream is more usable than a fast erratic one.
  final double intervalSdMillis;

  /// 99th percentile inter-frame interval (BUILD_SPEC 6.4). The worst realistic stall, which a
  /// mean hides completely.
  final double p99IntervalMillis;
  final double medianIntervalMillis;

  /// How many samples appear to be missing.
  ///
  /// Estimated by counting how many median intervals each gap spans: an interval of 3x the
  /// median implies two samples did not arrive. It is an estimate and is named as one — the
  /// platform does not report drops, so there is no exact figure to have.
  final int estimatedDroppedSamples;

  final double spanSeconds;

  double get droppedPercent {
    final expected = sampleCount + estimatedDroppedSamples;
    return expected == 0 ? 0 : 100.0 * estimatedDroppedSamples / expected;
  }

  Map<String, Object?> toJson() => {
    'sample_count': sampleCount,
    'mean_rate_hz': meanRateHz,
    'mean_interval_ms': meanIntervalMillis,
    'interval_sd_ms': intervalSdMillis,
    'median_interval_ms': medianIntervalMillis,
    'p99_interval_ms': p99IntervalMillis,
    'estimated_dropped_samples': estimatedDroppedSamples,
    'dropped_percent': droppedPercent,
    'span_seconds': spanSeconds,
  };

  /// Compute statistics from monotonically increasing timestamps in nanoseconds.
  ///
  /// Returns null when there are too few samples to say anything — two timestamps give one
  /// interval and no spread, which is not a measurement. The caller reports the failure rather
  /// than receiving a fabricated zero.
  static RateStatistics? fromTimestamps(List<int> timestampsNanos) {
    if (timestampsNanos.length < 3) return null;

    final intervals = <double>[];
    for (var i = 1; i < timestampsNanos.length; i++) {
      final deltaNanos = timestampsNanos[i] - timestampsNanos[i - 1];
      // Non-monotonic timestamps mean the stream is not what it claims to be. Dropping the
      // sample is wrong (it hides the fault) so the whole run is refused instead.
      if (deltaNanos <= 0) return null;
      intervals.add(deltaNanos / 1e6);
    }

    final sorted = List<double>.from(intervals)..sort();
    final median = _percentile(sorted, 0.5);
    final mean = intervals.reduce((a, b) => a + b) / intervals.length;

    final variance =
        intervals.map((v) => math.pow(v - mean, 2).toDouble()).reduce((a, b) => a + b) /
        (intervals.length - 1);

    var dropped = 0;
    if (median > 0) {
      for (final interval in intervals) {
        final implied = (interval / median).round();
        if (implied > 1) dropped += implied - 1;
      }
    }

    final spanNanos = timestampsNanos.last - timestampsNanos.first;
    final spanSeconds = spanNanos / 1e9;

    return RateStatistics(
      sampleCount: timestampsNanos.length,
      meanRateHz: spanSeconds > 0 ? (timestampsNanos.length - 1) / spanSeconds : double.nan,
      meanIntervalMillis: mean,
      intervalSdMillis: math.sqrt(variance),
      medianIntervalMillis: median,
      p99IntervalMillis: _percentile(sorted, 0.99),
      estimatedDroppedSamples: dropped,
      spanSeconds: spanSeconds,
    );
  }

  /// Nearest-rank percentile over an already-sorted list.
  static double _percentile(List<double> sorted, double fraction) {
    if (sorted.isEmpty) return double.nan;
    final rank = (fraction * sorted.length).ceil().clamp(1, sorted.length);
    return sorted[rank - 1];
  }
}

/// Mean and 99th percentile of a set of durations, in milliseconds.
///
/// Used for per-frame region-of-interest processing time (BUILD_SPEC 6.7): the mean says
/// whether the budget is met on average, the 99th says whether it is ever blown.
@immutable
class DurationStatistics {
  const DurationStatistics({
    required this.count,
    required this.meanMillis,
    required this.p99Millis,
    required this.maxMillis,
  });

  final int count;
  final double meanMillis;
  final double p99Millis;
  final double maxMillis;

  Map<String, Object?> toJson() => {
    'count': count,
    'mean_ms': meanMillis,
    'p99_ms': p99Millis,
    'max_ms': maxMillis,
  };

  static DurationStatistics? fromNanos(List<int> durationsNanos) {
    if (durationsNanos.isEmpty) return null;

    final millis = durationsNanos.map((n) => n / 1e6).toList()..sort();
    return DurationStatistics(
      count: millis.length,
      meanMillis: millis.reduce((a, b) => a + b) / millis.length,
      p99Millis: RateStatistics._percentile(millis, 0.99),
      maxMillis: millis.last,
    );
  }
}

/// Spread of the clock offset across repeated readings (BUILD_SPEC 6.6).
///
/// "Note in the UI that what matters is stability, not the absolute value, because a constant
/// offset is absorbed by personal calibration."
@immutable
class OffsetStatistics {
  const OffsetStatistics({
    required this.count,
    required this.meanMillis,
    required this.sdMillis,
    required this.spreadMillis,
  });

  final int count;
  final double meanMillis;

  /// The figure that matters.
  final double sdMillis;

  /// max - min, which for three readings is more legible than a standard deviation.
  final double spreadMillis;

  Map<String, Object?> toJson() => {
    'count': count,
    'mean_ms': meanMillis,
    'sd_ms': sdMillis,
    'spread_ms': spreadMillis,
  };

  static OffsetStatistics? fromOffsetsMillis(List<double> offsets) {
    if (offsets.length < 2) return null;

    final mean = offsets.reduce((a, b) => a + b) / offsets.length;
    final variance =
        offsets.map((v) => math.pow(v - mean, 2).toDouble()).reduce((a, b) => a + b) /
        (offsets.length - 1);
    final sorted = List<double>.from(offsets)..sort();

    return OffsetStatistics(
      count: offsets.length,
      meanMillis: mean,
      sdMillis: math.sqrt(variance),
      spreadMillis: sorted.last - sorted.first,
    );
  }
}
