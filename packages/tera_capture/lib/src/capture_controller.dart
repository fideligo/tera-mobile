/// The capture layer's public API.
///
/// **This package is the acquisition layer of the patient app, shipped first.** The profiler is
/// its first consumer; the patient capture app will be its second. Nothing here depends on any
/// UI, and nothing here may.
///
/// What it does: opens the sensor and the camera, streams timestamped accelerometer samples and
/// per-frame region-of-interest means, reports achieved rates, and reads thermal and clock
/// state.
///
/// What it deliberately does **not** do — the boundary the patient app will build on, recorded
/// in `docs/decisions.md`:
///
///   * **Buffer retention.** Samples are streamed and dropped. Nothing is kept, because
///     invariant 2 says raw sample buffers are never persisted. A consumer that needs a window
///     holds it itself, in memory, and is responsible for not writing it anywhere.
///   * **Filtering.** No band-pass, no detrending, no smoothing. The streams are what the
///     hardware reported.
///   * **Event detection.** No aortic-valve-opening detection in the accelerometer trace, no
///     foot- or peak-detection in the intensity series.
///   * **Beat pairing.** No association of an SCG event with a PPG event, and therefore no
///     transit-time interval.
///   * **Quality gate.** No decision about whether a capture is usable. The profiler grades a
///     *handset*; the gate grades a *session*, and that is a different thing.
///
/// If any of those five appear in this package, the boundary has moved and the note above is a
/// lie. Move them into the consumer instead.
library;

import 'dart:async';

import 'capture_platform.dart';
import 'clock_basis.dart';
import 'models.dart';
import 'rate_statistics.dart';

export 'capture_platform.dart'
    show
        AccelerometerInfo,
        CaptureConfig,
        CaptureException,
        // The seam consumers substitute in tests: a fake platform lets a capture flow be
        // exercised on a laptop, with no handset, no camera and no sensor.
        CapturePlatform,
        HandsetInfo;

/// A completed recording of one stream.
class CaptureRecording<T> {
  CaptureRecording({required this.samples, required this.startedAt, required this.endedAt});

  final List<T> samples;
  final DateTime startedAt;
  final DateTime endedAt;

  Duration get wallDuration => endedAt.difference(startedAt);
}

/// Opens the hardware and streams what it reports.
class TeraCapture {
  TeraCapture({CapturePlatform? platform})
    : _platform = platform ?? MethodChannelCapturePlatform();

  final CapturePlatform _platform;

  bool _accelerometerRunning = false;
  bool _cameraRunning = false;

  bool get isAccelerometerRunning => _accelerometerRunning;
  bool get isCameraRunning => _cameraRunning;

  // ------------------------------------------------------------------ introspection

  Future<HandsetInfo> readHandsetInfo() => _platform.readHandsetInfo();
  Future<AccelerometerInfo> readAccelerometerInfo() => _platform.readAccelerometerInfo();
  Future<CameraCapabilities> readCameraCapabilities() => _platform.readCameraCapabilities();
  Future<DeviceContext> readDeviceContext() => _platform.readDeviceContext();
  Future<ClockOffsetSample> readClockOffset() => _platform.readClockOffset();
  Future<bool> ensureCameraPermission() => _platform.ensureCameraPermission();
  Future<YuvSize?> activeYuvSize() => _platform.activeYuvSize();

  // ------------------------------------------------------------------ accelerometer

  Stream<AccelSample> get accelerometerSamples => _platform.accelerometerSamples;

  Future<void> startAccelerometer() async {
    if (_accelerometerRunning) return;
    await _platform.startAccelerometer();
    _accelerometerRunning = true;
  }

  Future<void> stopAccelerometer() async {
    if (!_accelerometerRunning) return;
    await _platform.stopAccelerometer();
    _accelerometerRunning = false;
  }

  // ------------------------------------------------------------------ camera

  Stream<FrameSample> get frameSamples => _platform.frameSamples;

  Future<void> startCamera(CaptureConfig config) async {
    if (_cameraRunning) return;
    await _platform.startCamera(config);
    _cameraRunning = true;
  }

  Future<void> stopCamera() async {
    if (!_cameraRunning) return;
    await _platform.stopCamera();
    _cameraRunning = false;
  }

  // ------------------------------------------------------------------ timed recordings

  /// Record the accelerometer for [duration] and return every sample.
  ///
  /// The samples are held in memory by the *caller's* recording and released when it goes out
  /// of scope. This package writes nothing to disk.
  Future<CaptureRecording<AccelSample>> recordAccelerometer(
    Duration duration, {
    void Function(int samplesSoFar)? onProgress,
  }) => _record<AccelSample>(
    duration: duration,
    stream: accelerometerSamples,
    start: startAccelerometer,
    stop: stopAccelerometer,
    onProgress: onProgress,
  );

  /// Record camera frames for [duration], reporting one region-of-interest mean per frame.
  Future<CaptureRecording<FrameSample>> recordCamera(
    Duration duration, {
    required CaptureConfig config,
    void Function(int framesSoFar)? onProgress,
  }) => _record<FrameSample>(
    duration: duration,
    stream: frameSamples,
    start: () => startCamera(config),
    stop: stopCamera,
    onProgress: onProgress,
  );

  Future<CaptureRecording<T>> _record<T>({
    required Duration duration,
    required Stream<T> stream,
    required Future<void> Function() start,
    required Future<void> Function() stop,
    void Function(int)? onProgress,
  }) async {
    final samples = <T>[];
    final completer = Completer<void>();
    Timer? progressTimer;

    // Subscribe before starting, so no sample produced between start and subscription is lost.
    final subscription = stream.listen(
      samples.add,
      onError: (Object error) {
        if (!completer.isCompleted) completer.completeError(error);
      },
    );

    try {
      await start();
      if (onProgress != null) {
        progressTimer = Timer.periodic(
          const Duration(milliseconds: 500),
          (_) => onProgress(samples.length),
        );
      }

      final startedAt = DateTime.now();
      await Future.any([Future<void>.delayed(duration), completer.future]);
      final endedAt = DateTime.now();

      return CaptureRecording<T>(samples: samples, startedAt: startedAt, endedAt: endedAt);
    } finally {
      progressTimer?.cancel();
      await subscription.cancel();
      // Stop failures must not mask a capture failure, but leaving the camera or the sensor
      // running would poison every later run, so it is attempted regardless.
      try {
        await stop();
      } on Object {
        // Deliberately swallowed: the caller already has its result or its original error.
      }
    }
  }
}

/// Statistics helpers over a recording, kept out of [TeraCapture] so the controller stays about
/// hardware and nothing else.
extension AccelRecordingStats on CaptureRecording<AccelSample> {
  RateStatistics? get rateStatistics =>
      RateStatistics.fromTimestamps(samples.map((s) => s.timestampNanos).toList(growable: false));

  /// Which clock the sensor's timestamps are really in.
  ///
  /// `SensorEvent.timestamp` is documented as `elapsedRealtimeNanos`. Documented, not
  /// guaranteed — so it is checked.
  ClockBasisVerification? get clockBasis => ClockBasisVerification.analyse(
    streamName: 'accelerometer',
    timestampsNanos: samples.map((s) => s.timestampNanos).toList(growable: false),
    realtimeAtDeliveryNanos:
        samples.map((s) => s.realtimeAtDeliveryNanos).toList(growable: false),
    uptimeAtDeliveryNanos: samples.map((s) => s.uptimeAtDeliveryNanos).toList(growable: false),
  );
}

extension FrameRecordingStats on CaptureRecording<FrameSample> {
  RateStatistics? get rateStatistics =>
      RateStatistics.fromTimestamps(samples.map((s) => s.timestampNanos).toList(growable: false));

  /// Per-frame region-of-interest processing time (BUILD_SPEC 6.7).
  DurationStatistics? get processingStatistics =>
      DurationStatistics.fromNanos(samples.map((s) => s.processingNanos).toList(growable: false));

  /// Which clock the camera's frame timestamps are really in, against what it declared.
  ClockBasisVerification? clockBasis(CameraTimestampSource? declaredSource) =>
      ClockBasisVerification.analyse(
        streamName: 'camera',
        timestampsNanos: samples.map((s) => s.timestampNanos).toList(growable: false),
        realtimeAtDeliveryNanos:
            samples.map((s) => s.realtimeAtDeliveryNanos).toList(growable: false),
        uptimeAtDeliveryNanos:
            samples.map((s) => s.uptimeAtDeliveryNanos).toList(growable: false),
        declaredSource: declaredSource,
      );
}
