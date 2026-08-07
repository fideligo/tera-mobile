/// Tests for the rule that decides whether this tool is trustworthy.
///
/// BUILD_SPEC 6.2: "Report measured values only. If a measurement fails, say so — never
/// substitute an estimate or a plausible-looking number."
///
/// The dangerous failure is not a crash. It is a run where the camera never opened, and the
/// report shows `0.0 fps` — a number a reader will take at face value, and which would end up
/// in the proposal's device table as a measured result.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tera_capture/tera_capture.dart';
import 'package:tera_profiler/profile_result.dart';
import 'package:tera_profiler/smoke_report.dart';

ProfileResult _allFailed() {
  CameraRunResult failedRun(String label) => CameraRunResult(
    label: label,
    rate: Measurement<RateStatistics>.failed('camera did not open'),
    processing: Measurement<DurationStatistics>.failed('no frames were processed'),
    thermalBefore: Measurement<DeviceContext>.failed('thermal API unavailable'),
    thermalAfter: Measurement<DeviceContext>.failed('thermal API unavailable'),
    yuvSize: Measurement<YuvSize>.failed('camera did not open'),
  );

  return ProfileResult(
    startedAt: DateTime.utc(2026, 8, 7),
    completedAt: DateTime.utc(2026, 8, 7, 0, 4),
    profilerVersion: 'test',
    handset: Measurement<HandsetInfo>.failed('Build class unavailable'),
    accelerometerInfo: Measurement<AccelerometerInfo>.failed('no accelerometer'),
    accelerometerRate: Measurement<RateStatistics>.failed('no samples arrived'),
    accelerometerThermalBefore: Measurement<DeviceContext>.failed('unavailable'),
    accelerometerThermalAfter: Measurement<DeviceContext>.failed('unavailable'),
    cameraCapabilities: Measurement<CameraCapabilities>.failed('no rear camera'),
    coldRun: failedRun('cold'),
    warmRun: failedRun('warm'),
    clockOffsets: const [],
    clockOffsetStatistics: Measurement<OffsetStatistics>.failed('fewer than two readings'),
    clockBasis: const CrossStreamClockCheck(camera: null, accelerometer: null),
  );
}

/// Samples whose timestamps sit in [basis], delivered [lagMillis] later.
List<int> _timestampsFor({
  required ObservedClockBasis basis,
  required int count,
  required int realtimeStartNanos,
  required int uptimeStartNanos,
  required double lagMillis,
  required int intervalNanos,
}) => List<int>.generate(count, (i) {
  final base = basis == ObservedClockBasis.realtime ? realtimeStartNanos : uptimeStartNanos;
  return base + i * intervalNanos - (lagMillis * 1e6).round();
});

void main() {
  group('a failed measurement never becomes a number', () {
    test('the markdown row says "not measured", never 0', () {
      final row = _allFailed().toMarkdownRow();

      expect(row, contains('not measured'));
      // No digit may appear in any cell of a wholly failed run.
      expect(
        RegExp(r'\d').hasMatch(row),
        isFalse,
        reason: 'a run in which nothing was measured produced a numeral: $row',
      );
      expect(row, isNot(contains('0.0')));
      expect(row, isNot(contains('null')));
    });

    test('the JSON marks each failure explicitly rather than omitting it', () {
      final json = _allFailed().toJson();
      final accelerometer = json['accelerometer']! as Map<String, Object?>;
      final rate = accelerometer['achieved_rate']! as Map<String, Object?>;

      expect(rate['measured'], isFalse);
      expect(rate['failure_reason'], 'no samples arrived');
      // Deliberately absent: a null `value` would read as "measured, and it was nothing".
      expect(rate.containsKey('value'), isFalse);
    });

    test('upload is refused, with a reason, when a required field is missing', () {
      final result = _allFailed();

      expect(result.toDeviceProfilePayload('patient-1'), isNull);
      expect(result.uploadBlockedReason, isNotNull);
      expect(result.uploadBlockedReason, contains('could not be measured'));
    });

    test('reading a failed measurement throws rather than yielding a default', () {
      final failed = Measurement<double>.failed('sensor absent');

      expect(failed.isOk, isFalse);
      expect(() => failed.requireValue, throwsStateError);
      expect(failed.describe((v) => '$v'), 'not measured — sensor absent');
    });
  });

  group('statistics refuse to invent a result', () {
    test('fewer than three timestamps yields null, not a zero rate', () {
      expect(RateStatistics.fromTimestamps([]), isNull);
      expect(RateStatistics.fromTimestamps([1000]), isNull);
      expect(RateStatistics.fromTimestamps([1000, 2000]), isNull);
    });

    test('non-monotonic timestamps fail the whole run rather than being skipped', () {
      // Dropping the bad sample would hide a stream that is not what it claims to be.
      expect(
        RateStatistics.fromTimestamps([0, 10000000, 5000000, 20000000]),
        isNull,
      );
    });

    test('a clean 100 Hz stream measures as 100 Hz', () {
      final timestamps = List<int>.generate(100, (i) => i * 10000000); // 10 ms apart
      final stats = RateStatistics.fromTimestamps(timestamps)!;

      expect(stats.meanRateHz, closeTo(100.0, 0.001));
      expect(stats.meanIntervalMillis, closeTo(10.0, 0.001));
      expect(stats.intervalSdMillis, closeTo(0.0, 0.001));
      expect(stats.estimatedDroppedSamples, 0);
    });

    test('a gap is counted as dropped samples', () {
      // 10 ms apart, with one 30 ms gap: two samples did not arrive.
      final timestamps = <int>[0, 10000000, 20000000, 50000000, 60000000, 70000000];
      final stats = RateStatistics.fromTimestamps(timestamps)!;

      expect(stats.estimatedDroppedSamples, 2);
      expect(stats.droppedPercent, closeTo(100 * 2 / 8, 0.01));
    });

    test('clock offset spread needs at least two readings', () {
      expect(OffsetStatistics.fromOffsetsMillis([]), isNull);
      expect(OffsetStatistics.fromOffsetsMillis([1.5]), isNull);

      final stats = OffsetStatistics.fromOffsetsMillis([1.0, 1.5, 2.0])!;
      expect(stats.meanMillis, closeTo(1.5, 0.001));
      expect(stats.spreadMillis, closeTo(1.0, 0.001));
    });
  });

  group('camera capability parsing', () {
    test('the smallest YUV size is chosen, whatever order the platform reported them', () {
      final capabilities = CameraCapabilities.fromMap({
        'camera_id': '0',
        'hardware_level': 'full',
        'has_manual_sensor': true,
        'timestamp_source': 'realtime',
        'has_flash': true,
        'supports_ae_lock': true,
        'supports_awb_lock': true,
        'yuv_sizes': [
          {'width': 320, 'height': 240, 'min_frame_duration_nanos': 16666666},
          {'width': 1920, 'height': 1080, 'min_frame_duration_nanos': 33333333},
        ],
      });

      expect(capabilities.smallestYuvSize!.width, 320);
      expect(capabilities.smallestYuvSize!.maxFps, closeTo(60.0, 0.1));
      expect(capabilities.hardwareLevel, CameraHardwareLevel.full);
      expect(capabilities.timestampSource, CameraTimestampSource.realtime);
    });

    test('an unrecognised hardware level is unknown, not a guess', () {
      final capabilities = CameraCapabilities.fromMap({
        'camera_id': '0',
        'hardware_level': 'something_new',
        'has_manual_sensor': false,
        'timestamp_source': 'anything_else',
        'has_flash': false,
        'supports_ae_lock': false,
        'supports_awb_lock': false,
        'yuv_sizes': <Object?>[],
      });

      expect(capabilities.hardwareLevel, CameraHardwareLevel.unknown);
      expect(capabilities.timestampSource, CameraTimestampSource.unknown);
      expect(capabilities.smallestYuvSize, isNull);
    });
  });

  group('clock basis is verified, not assumed', () {
    // A device up for two hours that slept for one: realtime is an hour ahead of uptime.
    const realtimeStart = 7200 * 1000000000;
    const uptimeStart = 3600 * 1000000000;
    const separationMillis = 3600 * 1000.0;
    const interval = 16666666; // ~60 fps
    const count = 200;

    List<int> deliveryRealtime() =>
        List<int>.generate(count, (i) => realtimeStart + i * interval);
    List<int> deliveryUptime() => List<int>.generate(count, (i) => uptimeStart + i * interval);

    test('a truthful REALTIME declaration is confirmed', () {
      final verification = ClockBasisVerification.analyse(
        streamName: 'camera',
        timestampsNanos: _timestampsFor(
          basis: ObservedClockBasis.realtime,
          count: count,
          realtimeStartNanos: realtimeStart,
          uptimeStartNanos: uptimeStart,
          lagMillis: 20,
          intervalNanos: interval,
        ),
        realtimeAtDeliveryNanos: deliveryRealtime(),
        uptimeAtDeliveryNanos: deliveryUptime(),
        declaredSource: CameraTimestampSource.realtime,
      )!;

      expect(verification.observed, ObservedClockBasis.realtime);
      expect(verification.declarationHolds, isTrue);
      expect(verification.needsAttention, isFalse);
      expect(verification.medianRealtimeLagMillis, closeTo(20, 0.1));
    });

    test('a device that declares REALTIME but timestamps in uptime is caught', () {
      // The case that would otherwise pass every other check and silently invalidate every
      // cross-stream figure collected from the handset.
      final verification = ClockBasisVerification.analyse(
        streamName: 'camera',
        timestampsNanos: _timestampsFor(
          basis: ObservedClockBasis.uptime,
          count: count,
          realtimeStartNanos: realtimeStart,
          uptimeStartNanos: uptimeStart,
          lagMillis: 20,
          intervalNanos: interval,
        ),
        realtimeAtDeliveryNanos: deliveryRealtime(),
        uptimeAtDeliveryNanos: deliveryUptime(),
        declaredSource: CameraTimestampSource.realtime,
      )!;

      expect(verification.observed, ObservedClockBasis.uptime);
      expect(verification.declarationHolds, isFalse);
      expect(verification.needsAttention, isTrue);
      expect(verification.verdict, contains('DECLARES REALTIME'));
      expect(verification.clockSeparationMillis, closeTo(separationMillis, 1));
    });

    test('clocks too close together give indeterminate, not a guess', () {
      // A freshly booted device: realtime and uptime agree, so nothing can be distinguished.
      const start = 60 * 1000000000;
      final delivery = List<int>.generate(count, (i) => start + i * interval);

      final verification = ClockBasisVerification.analyse(
        streamName: 'camera',
        timestampsNanos: List<int>.generate(count, (i) => start + i * interval - 20000000),
        realtimeAtDeliveryNanos: delivery,
        uptimeAtDeliveryNanos: delivery,
        declaredSource: CameraTimestampSource.realtime,
      )!;

      expect(verification.observed, ObservedClockBasis.indeterminate);
      expect(verification.declarationHolds, isNull, reason: 'no conclusion is not a pass');
      expect(verification.verdict, contains('could not be determined'));
    });

    test('timestamps in a third base are reported as matching neither', () {
      final verification = ClockBasisVerification.analyse(
        streamName: 'camera',
        // Twenty minutes adrift of both clocks.
        timestampsNanos: List<int>.generate(count, (i) => 1200 * 1000000000 + i * interval),
        realtimeAtDeliveryNanos: deliveryRealtime(),
        uptimeAtDeliveryNanos: deliveryUptime(),
        declaredSource: CameraTimestampSource.realtime,
      )!;

      expect(verification.observed, ObservedClockBasis.neither);
      expect(verification.needsAttention, isTrue);
      expect(verification.verdict, contains('NEITHER'));
    });

    test('too few samples yields null rather than a conclusion', () {
      expect(
        ClockBasisVerification.analyse(
          streamName: 'camera',
          timestampsNanos: [1, 2],
          realtimeAtDeliveryNanos: [1, 2],
          uptimeAtDeliveryNanos: [1, 2],
        ),
        isNull,
      );
    });

    test('streams in different bases are flagged as unable to share a timeline', () {
      ClockBasisVerification forBasis(String name, ObservedClockBasis basis) =>
          ClockBasisVerification.analyse(
            streamName: name,
            timestampsNanos: _timestampsFor(
              basis: basis,
              count: count,
              realtimeStartNanos: realtimeStart,
              uptimeStartNanos: uptimeStart,
              lagMillis: 15,
              intervalNanos: interval,
            ),
            realtimeAtDeliveryNanos: deliveryRealtime(),
            uptimeAtDeliveryNanos: deliveryUptime(),
          )!;

      final disagreeing = CrossStreamClockCheck(
        camera: forBasis('camera', ObservedClockBasis.uptime),
        accelerometer: forBasis('accelerometer', ObservedClockBasis.realtime),
      );
      expect(disagreeing.sharedBasis, isFalse);
      expect(disagreeing.needsAttention, isTrue);
      expect(disagreeing.verdict, contains('DIFFERENT TIME BASES'));

      final agreeing = CrossStreamClockCheck(
        camera: forBasis('camera', ObservedClockBasis.realtime),
        accelerometer: forBasis('accelerometer', ObservedClockBasis.realtime),
      );
      expect(agreeing.sharedBasis, isTrue);
      expect(agreeing.verdict, contains('share the realtime base'));
    });

    test('an unverified basis is null, and the markdown row says so', () {
      const unknown = CrossStreamClockCheck(camera: null, accelerometer: null);
      expect(unknown.sharedBasis, isNull);
      expect(unknown.verdict, contains('Could not be established'));

      expect(_allFailed().toMarkdownRow(), contains('not verified'));
    });
  });

  group('smoke reports cannot become measurement data', () {
    test('a SmokeReport has no route to a markdown row or an upload', () {
      // A structural property rather than a runtime one: SmokeReport exposes neither
      // toMarkdownRow nor toDeviceProfilePayload, and nothing converts one to a ProfileResult.
      // Five seconds is not a sustained-rate measurement, so the guarantee is that the
      // table-building code cannot accept smoke output at all. Recorded here so the intent
      // survives someone later being tempted to add a converter.
      final smoke = SmokeReport(
        stages: const [
          StageOutcome.pass('Camera capture', '300 frames, ~60 fps (indicative)'),
        ],
        ranAt: DateTime.utc(2026, 8, 7),
      );

      expect(smoke.toPlainText(), contains('NOT MEASUREMENT DATA'));
      expect(smoke.toPlainText(), contains('must not go into the device eligibility table'));
      expect(smoke.allPassed, isTrue);
    });

    test('failures are named in the summary', () {
      final smoke = SmokeReport(
        stages: const [
          StageOutcome.pass('Handset identity', 'Pixel 7'),
          StageOutcome.fail('Camera capture, torch and ROI', 'camera did not open'),
        ],
        ranAt: DateTime.utc(2026, 8, 7),
      );

      expect(smoke.allPassed, isFalse);
      expect(smoke.summary, contains('Camera capture, torch and ROI'));
      expect(smoke.failures, hasLength(1));
    });
  });

  group('clock offset', () {
    test('offset is realtime minus uptime, and precision is reported', () {
      final sample = ClockOffsetSample.fromMap({
        'realtime_nanos': 5000000000,
        'uptime_nanos': 4000000000,
        'uptime_nanosecond_precision': false,
      });

      expect(sample.offsetMillis, closeTo(1000.0, 0.001));
      expect(sample.uptimeHasNanosecondPrecision, isFalse);
    });
  });
}
