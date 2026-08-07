/// Establishes which clock a stream's timestamps are *actually* in.
///
/// The problem this exists to catch: `SENSOR_INFO_TIMESTAMP_SOURCE` is a **declaration**, and
/// `SensorEvent.timestamp` is *documented* as `elapsedRealtimeNanos`. Neither is universally
/// honoured. A handset that declares `REALTIME` but timestamps frames in the uptime base looks
/// completely normal — the frame rate is right, the jitter is right, the intervals are right —
/// and every cross-stream alignment computed from it is wrong by however long the device has
/// spent asleep since boot. Hours, typically.
///
/// So the basis is measured rather than believed. Every sample carries both clocks, read back
/// to back at delivery. A timestamp must sit a plausible pipeline latency *behind* whichever
/// clock it is expressed in, and implausibly far behind the other. That is enough to tell them
/// apart, provided the two clocks are far enough apart to be distinguishable at all.
///
/// The figure that actually matters for pulse transit time is not either stream's basis on its
/// own — it is whether the two agree. See [CrossStreamClockCheck].
library;

import 'package:meta/meta.dart';

import 'models.dart';

/// What the timestamps behave like, as opposed to what was declared.
enum ObservedClockBasis {
  /// Consistent with `SystemClock.elapsedRealtimeNanos()`.
  realtime,

  /// Consistent with `SystemClock.uptimeNanos()` — it stops during deep sleep.
  uptime,

  /// The two clocks are too close together to be told apart, so no conclusion is available.
  /// Usually means the device was booted recently and has not slept.
  indeterminate,

  /// Consistent with neither. A real and important finding: the timestamps are in some third
  /// base, and nothing can be aligned against them without knowing what it is.
  neither,
}

/// How far behind a delivery-clock reading a timestamp may plausibly sit.
///
/// A camera frame is timestamped at exposure and delivered after the pipeline has processed it;
/// a sensor sample is timestamped at the sensor and delivered after the HAL and the scheduler
/// have had their turn. Half a second covers a badly stalled device. Beyond that, the number is
/// not pipeline latency, it is a different clock.
const double maxPlausibleDeliveryLagMillis = 500.0;

/// A small negative lag is possible from clock granularity and read ordering, not from a frame
/// arriving before it was captured.
const double minPlausibleDeliveryLagMillis = -5.0;

/// Below this separation the two clocks cannot be distinguished from one another.
const double indistinguishableClockSeparationMillis = 10.0;

@immutable
class ClockBasisVerification {
  const ClockBasisVerification({
    required this.streamName,
    required this.observed,
    required this.declaredSource,
    required this.medianRealtimeLagMillis,
    required this.medianUptimeLagMillis,
    required this.clockSeparationMillis,
    required this.sampleCount,
  });

  final String streamName;
  final ObservedClockBasis observed;

  /// What the platform said, for the camera. Null for the accelerometer, which declares nothing
  /// — its base is documented rather than reported.
  final CameraTimestampSource? declaredSource;

  final double medianRealtimeLagMillis;
  final double medianUptimeLagMillis;

  /// realtime − uptime at delivery: how long the device has spent in deep sleep since boot.
  /// This is what makes the two bases distinguishable; when it is near zero they are not.
  final double clockSeparationMillis;

  final int sampleCount;

  /// Whether the camera's declaration held up.
  ///
  /// Null when there was no claim to test (the accelerometer, or a camera declaring `unknown`),
  /// or when the observation was inconclusive.
  bool? get declarationHolds {
    if (declaredSource != CameraTimestampSource.realtime) return null;
    if (observed == ObservedClockBasis.indeterminate ||
        observed == ObservedClockBasis.neither) {
      return null;
    }
    return observed == ObservedClockBasis.realtime;
  }

  /// A sentence for the log and the results view.
  String get verdict => switch ((declaredSource, observed)) {
    (CameraTimestampSource.realtime, ObservedClockBasis.realtime) =>
      'declares REALTIME and behaves like it — confirmed',
    (CameraTimestampSource.realtime, ObservedClockBasis.uptime) =>
      'DECLARES REALTIME BUT TIMESTAMPS BEHAVE LIKE UPTIME — the declaration is wrong, and '
          'any alignment against the accelerometer computed from it would be out by the '
          'deep-sleep offset (${clockSeparationMillis.toStringAsFixed(0)} ms here)',
    (CameraTimestampSource.unknown, ObservedClockBasis.uptime) =>
      'declares UNKNOWN and behaves like uptime — consistent, nothing was claimed',
    (CameraTimestampSource.unknown, ObservedClockBasis.realtime) =>
      'declares UNKNOWN but behaves like realtime — better than claimed, but not guaranteed',
    (_, ObservedClockBasis.indeterminate) =>
      'could not be determined: the two clocks differ by only '
          '${clockSeparationMillis.toStringAsFixed(1)} ms, so they cannot be told apart. '
          'Leave the handset unplugged and idle for a few minutes, then re-run',
    (_, ObservedClockBasis.neither) =>
      'timestamps match NEITHER clock — they are in some third base, and nothing can be '
          'aligned against them until it is identified',
    (null, ObservedClockBasis.realtime) => 'behaves like realtime, as documented',
    (null, ObservedClockBasis.uptime) =>
      'BEHAVES LIKE UPTIME, not the documented realtime base',
  };

  /// True when this result should stop the operator and be investigated.
  bool get needsAttention =>
      declarationHolds == false ||
      observed == ObservedClockBasis.neither ||
      (declaredSource == null && observed == ObservedClockBasis.uptime);

  Map<String, Object?> toJson() => {
    'stream': streamName,
    'declared_source': declaredSource?.name,
    'observed_basis': observed.name,
    'declaration_holds': declarationHolds,
    'median_realtime_lag_ms': medianRealtimeLagMillis,
    'median_uptime_lag_ms': medianUptimeLagMillis,
    'clock_separation_ms': clockSeparationMillis,
    'sample_count': sampleCount,
    'verdict': verdict,
  };

  /// Determine the basis from a stream's samples.
  ///
  /// Returns null when there is nothing to work with. The caller reports that as a failed
  /// measurement rather than assuming the declaration was right.
  static ClockBasisVerification? analyse({
    required String streamName,
    required List<int> timestampsNanos,
    required List<int> realtimeAtDeliveryNanos,
    required List<int> uptimeAtDeliveryNanos,
    CameraTimestampSource? declaredSource,
  }) {
    final count = timestampsNanos.length;
    if (count < 3 ||
        realtimeAtDeliveryNanos.length != count ||
        uptimeAtDeliveryNanos.length != count) {
      return null;
    }

    final realtimeLags = <double>[];
    final uptimeLags = <double>[];
    final separations = <double>[];

    for (var i = 0; i < count; i++) {
      realtimeLags.add((realtimeAtDeliveryNanos[i] - timestampsNanos[i]) / 1e6);
      uptimeLags.add((uptimeAtDeliveryNanos[i] - timestampsNanos[i]) / 1e6);
      separations.add((realtimeAtDeliveryNanos[i] - uptimeAtDeliveryNanos[i]) / 1e6);
    }

    final medianRealtimeLag = _median(realtimeLags);
    final medianUptimeLag = _median(uptimeLags);
    final separation = _median(separations);

    final ObservedClockBasis observed;
    if (separation.abs() < indistinguishableClockSeparationMillis) {
      // The clocks agree with each other, so a timestamp consistent with one is consistent with
      // both. Not a failure — just not an answer.
      observed = ObservedClockBasis.indeterminate;
    } else {
      final realtimePlausible = _plausible(medianRealtimeLag);
      final uptimePlausible = _plausible(medianUptimeLag);

      observed = switch ((realtimePlausible, uptimePlausible)) {
        (true, false) => ObservedClockBasis.realtime,
        (false, true) => ObservedClockBasis.uptime,
        (true, true) => ObservedClockBasis.indeterminate,
        (false, false) => ObservedClockBasis.neither,
      };
    }

    return ClockBasisVerification(
      streamName: streamName,
      observed: observed,
      declaredSource: declaredSource,
      medianRealtimeLagMillis: medianRealtimeLag,
      medianUptimeLagMillis: medianUptimeLag,
      clockSeparationMillis: separation,
      sampleCount: count,
    );
  }

  static bool _plausible(double lagMillis) =>
      lagMillis >= minPlausibleDeliveryLagMillis && lagMillis <= maxPlausibleDeliveryLagMillis;

  static double _median(List<double> values) {
    final sorted = List<double>.from(values)..sort();
    final middle = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[middle]
        : (sorted[middle - 1] + sorted[middle]) / 2;
  }
}

/// Whether the camera and the accelerometer share a time base.
///
/// **This is the question that decides whether a pulse transit time can be measured at all.**
/// Either stream's basis matters only through this: if the two disagree, an SCG event and a PPG
/// event cannot be placed on one timeline, and every interval derived from them is out by the
/// deep-sleep offset — which is not a few milliseconds, it is however long the handset has been
/// asleep since it was last rebooted.
@immutable
class CrossStreamClockCheck {
  const CrossStreamClockCheck({required this.camera, required this.accelerometer});

  final ClockBasisVerification? camera;
  final ClockBasisVerification? accelerometer;

  /// Null when either side could not be determined.
  bool? get sharedBasis {
    final c = camera;
    final a = accelerometer;
    if (c == null || a == null) return null;
    if (!_conclusive(c.observed) || !_conclusive(a.observed)) return null;
    return c.observed == a.observed;
  }

  String get verdict {
    final shared = sharedBasis;
    if (shared == null) {
      return 'Could not be established. Until it is, treat any cross-stream timing from this '
          'handset as unverified.';
    }
    if (shared) {
      return 'Camera and accelerometer timestamps share the ${camera!.observed.name} base. '
          'They can be placed on one timeline.';
    }
    return 'CAMERA AND ACCELEROMETER ARE IN DIFFERENT TIME BASES '
        '(${camera!.observed.name} vs ${accelerometer!.observed.name}). They cannot be placed '
        'on one timeline without correcting for the '
        '${camera!.clockSeparationMillis.toStringAsFixed(0)} ms deep-sleep offset, and any '
        'transit time measured on this handset without that correction is meaningless.';
  }

  bool get needsAttention =>
      sharedBasis == false ||
      (camera?.needsAttention ?? false) ||
      (accelerometer?.needsAttention ?? false);

  Map<String, Object?> toJson() => {
    'camera': camera?.toJson(),
    'accelerometer': accelerometer?.toJson(),
    'shared_basis': sharedBasis,
    'verdict': verdict,
  };

  static bool _conclusive(ObservedClockBasis basis) =>
      basis == ObservedClockBasis.realtime || basis == ObservedClockBasis.uptime;
}
