/// Device eligibility grading.
///
/// The band boundaries come from the proposal (page 7): minimum 200 Hz, target 500 Hz,
/// non-compliant handsets excluded at onboarding. The tests below pin the boundaries and, more
/// importantly, pin the distinction between "this device is not suitable" and "we could not
/// tell" — reporting the second as the first would condemn a handset on no evidence.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tera_capture/tera_capture.dart';
import 'package:tera_patient/capture/eligibility_check.dart';

CameraCapabilities _capabilities({bool hasFlash = true}) => CameraCapabilities.fromMap({
  'camera_id': '0',
  'hardware_level': 'full',
  'has_manual_sensor': true,
  'timestamp_source': 'realtime',
  'has_flash': hasFlash,
  'supports_ae_lock': true,
  'supports_awb_lock': true,
  'yuv_sizes': [
    {'width': 320, 'height': 240, 'min_frame_duration_nanos': 16666666},
  ],
});

/// A platform whose accelerometer delivers samples at a chosen rate.
class _FakePlatform implements CapturePlatform {
  _FakePlatform({this.rateHz = 500.0, this.hasFlash = true, this.failSensor = false});

  final double rateHz;
  final bool hasFlash;
  final bool failSensor;

  @override
  Future<CameraCapabilities> readCameraCapabilities() async =>
      _capabilities(hasFlash: hasFlash);

  @override
  Stream<AccelSample> get accelerometerSamples {
    if (failSensor) return const Stream<AccelSample>.empty();
    final intervalNanos = (1e9 / rateHz).round();
    return Stream<AccelSample>.fromIterable(
      List.generate(
        400,
        (i) => AccelSample(
          timestampNanos: i * intervalNanos,
          x: 0,
          y: 0,
          z: 9.8,
          realtimeAtDeliveryNanos: i * intervalNanos + 1000,
          uptimeAtDeliveryNanos: i * intervalNanos + 1000,
        ),
      ),
    );
  }

  @override
  Future<void> startAccelerometer() async {}
  @override
  Future<void> stopAccelerometer() async {}
  @override
  Stream<FrameSample> get frameSamples => const Stream<FrameSample>.empty();
  @override
  Future<void> startCamera(CaptureConfig config) async {}
  @override
  Future<void> stopCamera() async {}
  @override
  Future<YuvSize?> activeYuvSize() async => null;
  @override
  Future<bool> ensureCameraPermission() async => true;
  @override
  Future<HandsetInfo> readHandsetInfo() async => HandsetInfo.fromMap({
    'manufacturer': 'Test',
    'model': 'Handset',
    'device': 'test',
    'android_release': '14',
    'sdk_int': 34,
  });
  @override
  Future<AccelerometerInfo> readAccelerometerInfo() async => AccelerometerInfo.fromMap({
    'name': 'test',
    'vendor': 'test',
    'min_delay_micros': 2000,
    'max_delay_micros': 200000,
    'high_sampling_rate_granted': true,
  });
  @override
  Future<DeviceContext> readDeviceContext() async => DeviceContext.fromMap({
    'thermal_status': 'none',
    'battery_percent': 80,
    'is_charging': false,
    'captured_at_millis': 0,
  });
  @override
  Future<ClockOffsetSample> readClockOffset() async => ClockOffsetSample.fromMap({
    'realtime_nanos': 1000,
    'uptime_nanos': 1000,
    'uptime_nanosecond_precision': true,
  });
}

EligibilityChecker _checker(_FakePlatform platform) =>
    EligibilityChecker(capture: TeraCapture(platform: platform));

void main() {
  test('at or above the target rate is qualified', () async {
    final result = await _checker(_FakePlatform(rateHz: 500.0)).check();

    expect(result.verdict, EligibilityVerdict.qualified);
    expect(result.canProceed, isTrue);
    expect(result.detail, contains('500'));
  });

  test('between the minimum and the target is provisional, and says why', () async {
    // The demo handset sits here. PROVISIONAL must read as a deliberate, explained state.
    final result = await _checker(_FakePlatform(rateHz: 250.0)).check();

    expect(result.verdict, EligibilityVerdict.provisional);
    expect(result.canProceed, isTrue, reason: 'provisional must not block the flow');
    expect(result.detail, contains('above the minimum'));
    expect(result.detail, contains('200'));
    expect(result.detail, contains('500'));
  });

  group('the clinical rule, whatever posture the build is in', () {
    // `openDeviceGate` is a compile-time constant, so the enforced band cannot be flipped inside a
    // test. The rule is therefore exercised against the clinical band directly — it has to stay
    // true and stay tested while the gate is open, because it is what the gate goes back to.
    test('below the clinical floor is not qualified', () {
      expect(
        gradeAccelRate(100.0, minimumHz: clinicalMinimumAccelRateHz),
        EligibilityVerdict.notQualified,
      );
    });

    test('the clinical boundary is inclusive at both ends', () {
      expect(
        gradeAccelRate(
          clinicalMinimumAccelRateHz,
          minimumHz: clinicalMinimumAccelRateHz,
        ),
        EligibilityVerdict.provisional,
      );
      expect(
        gradeAccelRate(
          clinicalMinimumAccelRateHz - 0.1,
          minimumHz: clinicalMinimumAccelRateHz,
        ),
        EligibilityVerdict.notQualified,
      );
      expect(
        gradeAccelRate(
          clinicalTargetAccelRateHz,
          minimumHz: clinicalMinimumAccelRateHz,
        ),
        EligibilityVerdict.qualified,
      );
    });

    test('the clinical thresholds are the proposal figures, unmoved', () {
      // Page 7: minimum 200 Hz, target 500 Hz. The enforced band is allowed to differ; these are
      // not, and a change here is a change to what the method claims about itself.
      expect(clinicalMinimumAccelRateHz, 200.0);
      expect(clinicalTargetAccelRateHz, 500.0);
    });
  });

  group('the gate is open for field testing', () {
    test('a handset below the clinical floor proceeds, and is told why', () async {
      // The point of the posture: a phone that would have been refused now produces data. It is
      // not called qualified, and the caveat names the figure a tester needs.
      final result = await _checker(_FakePlatform(rateHz: 100.0)).check();

      expect(result.verdict, EligibilityVerdict.provisional);
      expect(result.canProceed, isTrue);
      expect(result.achievedRateHz, 100.0);
      expect(result.detail, contains('100'));
      expect(result.detail, contains('200'));
      expect(result.detail, contains('set aside as unusable'));
    });

    test('no torch no longer blocks, and the rate is still measured', () async {
      final result = await _checker(
        _FakePlatform(rateHz: 1000.0, hasFlash: false),
      ).check();

      expect(result.canProceed, isTrue);
      expect(result.achievedRateHz, 1000.0);
    });

    test('the enforced floor is open, and the switch is named', () {
      // Reading the posture back, so flipping it is a visible change to this file rather than a
      // silent one somewhere else.
      expect(openDeviceGate, isTrue);
      expect(minimumAccelRateHz, 0.0);
      expect(requireTorch, isFalse);
      // The target does not move with the posture: a phone below it is still provisional, so the
      // verdict keeps carrying the honest figure instead of calling every handset qualified.
      expect(targetAccelRateHz, clinicalTargetAccelRateHz);
    });
  });

  test('a failed probe is "could not check", not "not suitable"', () async {
    // Condemning a handset on no evidence is a different error from measuring it and
    // finding it wanting.
    final result = await _checker(_FakePlatform(failSensor: true)).check();

    expect(result.verdict, EligibilityVerdict.couldNotCheck);
    expect(result.canProceed, isFalse);
    expect(result.headline, contains('Could not check'));
  });


}
