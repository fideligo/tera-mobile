/// Measuring the handset well enough to register it as a device profile.
///
/// A session cannot be submitted without a `device_profile_id`, and the backend's
/// `DeviceProfileCreate` has **no optional measurements** — by design. Invariant 9: if a figure
/// could not be measured, the submission fails rather than carrying a plausible substitute.
///
/// So the patient app measures the same five things the profiler measures, from the same package,
/// rather than sending defaults for the ones the eligibility probe happens not to need. The
/// eligibility gate itself only depends on the accelerometer rate; the camera rate and the clock
/// offset spread are gathered because a device profile is not honest without them.
library;

import 'package:meta/meta.dart';
import 'package:tera_capture/tera_capture.dart';

import '../api/api_client.dart';
import 'eligibility_check.dart';

/// How long to sample the camera when measuring its sustained rate.
///
/// Shorter than the profiler's warm run: this is registration, not qualification, and the number
/// it produces is recorded as what it is — a rate measured over a few seconds on a cold camera.
const Duration cameraProbeDuration = Duration(seconds: 6);

/// Clock-offset readings, and the gap between them.
///
/// What matters is the *spread* across readings, not the absolute offset: a constant offset is
/// absorbed by personal calibration, an unstable one is not. Two readings is the minimum from
/// which any spread can be computed; five gives it somewhere to show.
const int clockOffsetRuns = 5;
const Duration clockOffsetSpacing = Duration(milliseconds: 400);

/// Everything `POST /v1/device-profiles` requires, and nothing it does not.
///
/// Every field here was measured on this handset. There is deliberately no constructor that
/// accepts a default for any of them.
@immutable
class DeviceMeasurements {
  const DeviceMeasurements({
    required this.handset,
    required this.capabilities,
    required this.accelRateHz,
    required this.cameraFps,
    required this.clockOffsetSdMs,
  });

  final HandsetInfo handset;
  final CameraCapabilities capabilities;

  /// Achieved, not requested.
  final double accelRateHz;

  /// Sustained rate from frame timestamps, over [cameraProbeDuration].
  final double cameraFps;

  /// Spread of the realtime/uptime offset across [clockOffsetRuns] readings.
  final double clockOffsetSdMs;

  /// The request body. Mirrors the profiler's payload exactly, so a handset registered from
  /// either route grades identically.
  Map<String, dynamic> toDeviceProfilePayload(String patientId) => {
    'patient_id': patientId,
    'model': handset.displayName,
    'os_version': 'Android ${handset.androidRelease}',
    'accel_rate_hz': accelRateHz,
    'camera_fps': cameraFps,
    'camera_hw_level': switch (capabilities.hardwareLevel) {
      // The only value whose Dart name and wire name differ.
      CameraHardwareLevel.level3 => 'level_3',
      final level => level.name,
    },
    'manual_sensor': capabilities.hasManualSensor,
    'timestamp_source': capabilities.timestampSource.name,
    'clock_offset_sd_ms': clockOffsetSdMs,
    // Invariant 9. This is a real handset; nothing here is seeded.
    'synthetic': false,
  };

  /// The body for `POST /v1/device/eligibility`.
  ///
  /// The same measurements as [toDeviceProfilePayload] **without `patient_id`**: that route takes
  /// the patient from the token, because it is called by the patient's own handset and a body
  /// that could name a patient would let one phone write a hardware verdict onto another account.
  Map<String, dynamic> toEligibilityPayload() {
    final payload = Map<String, dynamic>.from(toDeviceProfilePayload(''))
      ..remove('patient_id')
      ..remove('synthetic');
    return payload;
  }
}

/// Raised when the handset could not be measured. Carries a reason a patient can act on.
class DeviceMeasurementFailure implements Exception {
  const DeviceMeasurementFailure(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// Gathers the measurements a device profile needs.
///
/// Takes the accelerometer rate and camera capabilities the eligibility probe already
/// established, so the patient is not made to repeat a six-second measurement that just ran.
class DeviceMeasurer {
  DeviceMeasurer({TeraCapture? capture}) : _capture = capture ?? TeraCapture();

  final TeraCapture _capture;

  Future<DeviceMeasurements> measure({
    required CameraCapabilities capabilities,
    required double accelRateHz,
    double? cameraFpsOverride,
  }) async {
    final HandsetInfo handset;
    try {
      handset = await _capture.readHandsetInfo();
    } on Object catch (e) {
      throw DeviceMeasurementFailure('The phone did not report its model. $e');
    }

    // Supplied when the caller has already measured the camera during a real capture, which is
    // a better figure than a fresh probe: it is the rate the method actually ran at, on the same
    // code path, for a full session rather than a few seconds. Registering the advertised
    // ceiling instead is what made completed sessions fail the achieved-rate gate.
    if (cameraFpsOverride != null && cameraFpsOverride > 0) {
      final fastOffsets = <double>[];
      for (var i = 0; i < clockOffsetRuns; i++) {
        fastOffsets.add((await _capture.readClockOffset()).offsetMillis);
        if (i < clockOffsetRuns - 1) await Future<void>.delayed(clockOffsetSpacing);
      }
      final fastStats = OffsetStatistics.fromOffsetsMillis(fastOffsets);
      return DeviceMeasurements(
        handset: handset,
        capabilities: capabilities,
        accelRateHz: accelRateHz,
        cameraFps: cameraFpsOverride,
        clockOffsetSdMs: fastStats?.sdMillis ?? 0.0,
      );
    }

    final double cameraFps;
    try {
      // The same configuration a real capture uses. A rate measured with auto-exposure running
      // is not the rate the method will see, so measuring under different settings would
      // register a figure the handset never actually delivers during a spot check.
      final recording = await _capture.recordCamera(
        cameraProbeDuration,
        config: const CaptureConfig(),
      );
      final stats = recording.rateStatistics;
      if (stats == null) {
        throw const DeviceMeasurementFailure(
          'The camera did not deliver enough frames to measure its speed.',
        );
      }
      cameraFps = stats.meanRateHz;
    } on DeviceMeasurementFailure {
      rethrow;
    } on Object catch (e) {
      throw DeviceMeasurementFailure('The camera could not be measured. $e');
    }

    final offsets = <double>[];
    for (var i = 0; i < clockOffsetRuns; i++) {
      try {
        offsets.add((await _capture.readClockOffset()).offsetMillis);
      } on Object {
        // One failed reading is survivable; too few to compute a spread is not, and that is
        // caught below rather than papered over with a default.
      }
      if (i < clockOffsetRuns - 1) {
        await Future<void>.delayed(clockOffsetSpacing);
      }
    }

    final offsetStats = OffsetStatistics.fromOffsetsMillis(offsets);
    if (offsetStats == null) {
      throw const DeviceMeasurementFailure(
        'The phone’s two clocks could not be compared often enough to tell whether they '
        'stay in step.',
      );
    }

    return DeviceMeasurements(
      handset: handset,
      capabilities: capabilities,
      accelRateHz: accelRateHz,
      cameraFps: cameraFps,
      clockOffsetSdMs: offsetStats.sdMillis,
    );
  }
}

/// Files DEV-01's verdict with the backend (`POST /v1/device/eligibility`).
///
/// Separate from [DeviceMeasurer], which does the measuring, and from the session-context
/// resolver, which registers a full device profile when a capture is submitted. This one exists
/// so the *eligibility answer* survives a reinstall: section 6 runs the check once, before
/// onboarding, and `GET /v1/device/current` is what stops the next install making the patient
/// sit through it again.
///
/// **It never throws and never blocks.** The verdict is already on the handset by the time this
/// runs and that copy is what the flow reads. A patient setting the app up on a train must still
/// reach onboarding.
class DeviceEligibilityReporter {
  DeviceEligibilityReporter({required ApiClient api, DeviceMeasurer? measurer})
    : _api = api,
      _measurer = measurer ?? DeviceMeasurer();

  final ApiClient _api;
  final DeviceMeasurer _measurer;

  /// Returns whether the verdict reached the server.
  ///
  /// The gate measures the accelerometer and reads the camera's capabilities; the route also
  /// wants a sustained frame rate and a clock-offset spread, so [DeviceMeasurer] completes the
  /// set — reusing the accelerometer figure the gate just measured rather than making the patient
  /// sit through it twice.
  ///
  /// A probe that could not read the camera has nothing honest to file and files nothing.
  /// Inventing zeroes would post a benchmark nobody measured, which invariant 9 names directly.
  Future<bool> submit(EligibilityResult result) async {
    final capabilities = result.capabilities;
    final accelRateHz = result.achievedRateHz;
    if (capabilities == null || accelRateHz == null) return false;

    try {
      final measurements = await _measurer.measure(
        capabilities: capabilities,
        accelRateHz: accelRateHz,
      );
      await _api.postJson(
        '/v1/device/eligibility',
        measurements.toEligibilityPayload(),
      );
      return true;
    } on Object {
      return false;
    }
  }
}
