/// Orchestrates the seven measurements in BUILD_SPEC 6.1.
///
/// The order matters and is not arbitrary:
///
///  1. Characteristics and clock offsets first — cheap, and they tell the operator immediately
///     whether the handset is worth the next three minutes.
///  2. Accelerometer, 60 s, from a cold device.
///  3. Camera, 60 s, cold.
///  4. Camera, 60 s again, **immediately** — no cool-down. BUILD_SPEC 6.4: "repeat immediately
///     so the warm-device result is captured separately — thermal throttling is exactly what we
///     are looking for." Any pause between the two runs would let the device recover and hide
///     the thing being measured.
///
/// Every step is wrapped so a failure is recorded as a failure and the run continues. A handset
/// with no torch should still produce an accelerometer figure.
library;

import 'dart:async';

import 'package:tera_capture/tera_capture.dart';

import 'profile_result.dart';
import 'raw_export.dart';
import 'smoke_report.dart';

const String profilerVersion = 'tera-profiler-0.1.0';

/// How long each sustained measurement runs. BUILD_SPEC 6.1 and 6.4 both say 60 s.
const Duration measurementDuration = Duration(seconds: 60);

/// BUILD_SPEC 6.6: "repeat across three separate runs so the spread can be reported".
const int clockOffsetRuns = 3;

/// Spacing between clock readings. Long enough that they are genuinely separate observations
/// rather than three reads of the same instant.
const Duration clockOffsetSpacing = Duration(milliseconds: 400);

/// Smoke-test stage length. Long enough to prove a stream starts, delivers and stops; far too
/// short to measure a sustained rate, which is why a smoke run cannot produce a table row.
const Duration smokeDuration = Duration(seconds: 5);
const String smokeDurationLabel = '5 s';

typedef ProgressCallback = void Function(String message);

class ProfileRunner {
  ProfileRunner({TeraCapture? capture}) : _capture = capture ?? TeraCapture();

  final TeraCapture _capture;

  Future<ProfileResult> run({required ProgressCallback onProgress}) async {
    final startedAt = DateTime.now();
    onProgress('Starting profile run. This takes about three and a half minutes.');
    onProgress('Do not lock the screen or switch apps — that stops the camera.');

    final handset = await _attempt('handset identity', _capture.readHandsetInfo, onProgress);
    if (handset.isOk) {
      final h = handset.requireValue;
      onProgress('Handset: ${h.displayName}, Android ${h.androidRelease} (SDK ${h.sdkInt})');
    }

    // -------------------------------------------------------------- 6.3 characteristics
    onProgress('Reading camera characteristics...');
    final capabilities = await _attempt(
      'camera characteristics',
      _capture.readCameraCapabilities,
      onProgress,
    );
    if (capabilities.isOk) {
      final c = capabilities.requireValue;
      onProgress('  hardware level: ${c.hardwareLevel.name}');
      onProgress('  MANUAL_SENSOR: ${c.hasManualSensor ? 'present' : 'absent'}');
      onProgress('  timestamp source: ${c.timestampSource.name}');
      onProgress('  smallest YUV size: ${c.smallestYuvSize ?? 'none offered'}');
      if (c.smallestYuvSize != null) {
        onProgress(
          '  min frame duration there: '
          '${(c.smallestYuvSize!.minFrameDurationNanos / 1e6).toStringAsFixed(2)} ms '
          '(ceiling ${c.smallestYuvSize!.maxFps.toStringAsFixed(1)} fps)',
        );
      }
      if (!c.hasFlash) {
        onProgress('  WARNING: no torch. The camera run will produce no usable signal.');
      }
    }

    // -------------------------------------------------------------- 6.6 clock offset
    onProgress('Reading clock offset, $clockOffsetRuns runs...');
    final offsets = <ClockOffsetSample>[];
    for (var i = 0; i < clockOffsetRuns; i++) {
      try {
        final sample = await _capture.readClockOffset();
        offsets.add(sample);
        onProgress(
          '  run ${i + 1}: offset ${sample.offsetMillis.toStringAsFixed(3)} ms'
          '${sample.uptimeHasNanosecondPrecision ? '' : ' (millisecond precision only)'}',
        );
      } on Object catch (e) {
        onProgress('  run ${i + 1}: failed — $e');
      }
      if (i < clockOffsetRuns - 1) await Future<void>.delayed(clockOffsetSpacing);
    }

    final offsetStats = OffsetStatistics.fromOffsetsMillis(
      offsets.map((o) => o.offsetMillis).toList(growable: false),
    );
    final clockOffsetStatistics = offsetStats == null
        ? Measurement<OffsetStatistics>.failed(
            'fewer than two clock readings succeeded, so no spread can be computed',
          )
        : Measurement<OffsetStatistics>.ok(offsetStats);
    if (offsetStats != null) {
      onProgress(
        '  spread ${offsetStats.spreadMillis.toStringAsFixed(3)} ms, '
        'SD ${offsetStats.sdMillis.toStringAsFixed(3)} ms '
        '(stability is what matters, not the absolute value)',
      );
    }

    // -------------------------------------------------------------- 6.1 accelerometer
    final accelerometerInfo = await _attempt(
      'accelerometer characteristics',
      _capture.readAccelerometerInfo,
      onProgress,
    );
    if (accelerometerInfo.isOk) {
      final a = accelerometerInfo.requireValue;
      onProgress('Accelerometer: ${a.name} (${a.vendor})');
      onProgress('  advertised ceiling: ${a.advertisedMaxHz.toStringAsFixed(1)} Hz');
      onProgress(
        '  HIGH_SAMPLING_RATE_SENSORS: '
        '${a.highSamplingRatePermissionGranted ? 'granted' : 'NOT granted — capped at 200 Hz'}',
      );
    }

    final accelThermalBefore = await _attempt(
      'thermal state before accelerometer run',
      _capture.readDeviceContext,
      onProgress,
    );
    _reportThermal('before accelerometer run', accelThermalBefore, onProgress);

    onProgress('Recording accelerometer for 60 s. Leave the handset still on a table.');
    Measurement<RateStatistics> accelRate;
    try {
      final recording = await _capture.recordAccelerometer(
        measurementDuration,
        onProgress: (n) => onProgress('  $n samples...'),
      );
      _accelerometerBasis = recording.clockBasis;
      // Developer builds only, and serialised here inside the scope that already holds the
      // recording — nothing is retained for longer than before.
      final rawPath = await exportAccelerometerRun(recording, label: 'sustained');
      if (rawPath != null) onProgress('  raw series written to $rawPath');
      final stats = recording.rateStatistics;
      accelRate = stats == null
          ? Measurement<RateStatistics>.failed(
              'only ${recording.samples.length} samples arrived, or their timestamps were not '
              'monotonic — too few to compute a rate',
            )
          : Measurement<RateStatistics>.ok(stats);
      if (stats != null) {
        onProgress(
          '  achieved ${stats.meanRateHz.toStringAsFixed(1)} Hz, '
          'interval SD ${stats.intervalSdMillis.toStringAsFixed(3)} ms, '
          '~${stats.estimatedDroppedSamples} dropped '
          '(${stats.droppedPercent.toStringAsFixed(1)}%)',
        );
        onProgress(
          '  above 200 Hz: ${stats.meanRateHz > 200 ? 'yes' : 'no'} '
          '— this is what was delivered, not what was requested',
        );
      }
    } on Object catch (e) {
      accelRate = Measurement<RateStatistics>.failed('$e');
      onProgress('  accelerometer run failed: $e');
    }

    final accelThermalAfter = await _attempt(
      'thermal state after accelerometer run',
      _capture.readDeviceContext,
      onProgress,
    );
    _reportThermal('after accelerometer run', accelThermalAfter, onProgress);

    // -------------------------------------------------------------- 6.4 camera, cold
    onProgress('Requesting camera permission...');
    var cameraPermitted = false;
    try {
      cameraPermitted = await _capture.ensureCameraPermission();
    } on Object catch (e) {
      onProgress('  permission request failed: $e');
    }
    if (!cameraPermitted) {
      onProgress('  camera permission denied — both camera runs will be recorded as failed');
    }

    onProgress('Camera run 1 of 2 (cold). Cover the lens with a fingertip; torch will be on.');
    final coldRun = await _cameraRun(
      label: 'cold',
      permitted: cameraPermitted,
      capabilities: capabilities,
      onProgress: onProgress,
    );

    // No pause. The second run starts on a warm device, which is the whole point.
    onProgress('Camera run 2 of 2 (warm), starting immediately — no cool-down.');
    onProgress('This is the run that shows thermal throttling. Keep the fingertip in place.');
    final warmRun = await _cameraRun(
      label: 'warm',
      permitted: cameraPermitted,
      capabilities: capabilities,
      onProgress: onProgress,
    );

    if (coldRun.rate.isOk && warmRun.rate.isOk) {
      final cold = coldRun.rate.requireValue.meanRateHz;
      final warm = warmRun.rate.requireValue.meanRateHz;
      final change = cold > 0 ? 100 * (warm - cold) / cold : double.nan;
      onProgress(
        'Sustained rate cold ${cold.toStringAsFixed(1)} fps -> '
        'warm ${warm.toStringAsFixed(1)} fps '
        '(${change.isNaN ? 'n/a' : '${change.toStringAsFixed(1)}%'})',
      );
    }

    // -------------------------------------------------------------- clock basis
    //
    // Deliberately last: it reuses the samples the two 60 s runs already produced, so it costs
    // nothing extra and has far more data than a dedicated probe would.
    onProgress('Verifying clock bases...');
    final basis = CrossStreamClockCheck(
      camera: _cameraBasis,
      accelerometer: _accelerometerBasis,
    );
    if (basis.camera != null) onProgress('  camera: ${basis.camera!.verdict}');
    if (basis.accelerometer != null) {
      onProgress('  accelerometer: ${basis.accelerometer!.verdict}');
    }
    onProgress('  ${basis.verdict}');
    if (basis.needsAttention) {
      onProgress('  *** This handset needs attention before its numbers are used. ***');
    }

    onProgress('Run complete.');

    return ProfileResult(
      startedAt: startedAt,
      completedAt: DateTime.now(),
      profilerVersion: profilerVersion,
      handset: handset,
      accelerometerInfo: accelerometerInfo,
      accelerometerRate: accelRate,
      accelerometerThermalBefore: accelThermalBefore,
      accelerometerThermalAfter: accelThermalAfter,
      cameraCapabilities: capabilities,
      coldRun: coldRun,
      warmRun: warmRun,
      clockOffsets: offsets,
      clockOffsetStatistics: clockOffsetStatistics,
      clockBasis: basis,
    );
  }

  /// Set by the accelerometer and cold-camera runs, consumed by the basis check at the end.
  ClockBasisVerification? _accelerometerBasis;
  ClockBasisVerification? _cameraBasis;

  /// A short run that exercises every code path and reports pass/fail per stage.
  ///
  /// For the half hour spent debugging HAL behaviour on the first handset. Returns a
  /// [SmokeReport], which has no route to a markdown row or to the upload — five seconds is not
  /// a sustained-rate measurement, and the way to keep these numbers out of the device table is
  /// for the table-building code to be unable to accept them.
  Future<SmokeReport> runSmoke({required ProgressCallback onProgress}) async {
    final stages = <StageOutcome>[];

    onProgress('SMOKE TEST — $smokeDurationLabel per stage.');
    onProgress('Exercises every path. Produces no publishable numbers.');

    Future<void> stage(String name, Future<String> Function() body) async {
      onProgress('$name...');
      try {
        final detail = await body();
        stages.add(StageOutcome.pass(name, detail));
        onProgress('  PASS  $detail');
      } on Object catch (e) {
        stages.add(StageOutcome.fail(name, '$e'));
        onProgress('  FAIL  $e');
      }
    }

    await stage('Handset identity', () async {
      final info = await _capture.readHandsetInfo();
      return '${info.displayName}, Android ${info.androidRelease} (SDK ${info.sdkInt})';
    });

    await stage('Accelerometer characteristics', () async {
      final info = await _capture.readAccelerometerInfo();
      return '${info.name}, advertised ${info.advertisedMaxHz.toStringAsFixed(0)} Hz, '
          'HIGH_SAMPLING_RATE_SENSORS '
          '${info.highSamplingRatePermissionGranted ? 'granted' : 'NOT granted'}';
    });

    await stage('Camera characteristics', () async {
      final c = await _capture.readCameraCapabilities();
      return '${c.hardwareLevel.name}, MANUAL_SENSOR '
          '${c.hasManualSensor ? 'present' : 'absent'}, timestamp source '
          '${c.timestampSource.name}, smallest YUV ${c.smallestYuvSize ?? 'none'}, '
          'torch ${c.hasFlash ? 'available' : 'ABSENT'}';
    });

    await stage('Thermal and battery', () async {
      final context = await _capture.readDeviceContext();
      return 'thermal ${context.thermalStatus.name}, '
          'battery ${context.batteryPercent ?? 'unreported'}'
          '${context.batteryPercent == null ? '' : '%'}';
    });

    await stage('Clock offset read', () async {
      final sample = await _capture.readClockOffset();
      return 'offset ${sample.offsetMillis.toStringAsFixed(3)} ms, '
          '${sample.uptimeHasNanosecondPrecision ? 'nanosecond' : 'millisecond'} precision';
    });

    ClockBasisVerification? accelBasis;
    await stage('Accelerometer capture', () async {
      final recording = await _capture.recordAccelerometer(smokeDuration);
      accelBasis = recording.clockBasis;
      final stats = recording.rateStatistics;
      if (stats == null) {
        throw StateError(
          'only ${recording.samples.length} samples arrived in $smokeDurationLabel',
        );
      }
      return '${recording.samples.length} samples, '
          '~${stats.meanRateHz.toStringAsFixed(0)} Hz (indicative only)';
    });

    var cameraPermitted = false;
    await stage('Camera permission', () async {
      cameraPermitted = await _capture.ensureCameraPermission();
      if (!cameraPermitted) throw StateError('denied');
      return 'granted';
    });

    ClockBasisVerification? cameraBasis;
    CameraTimestampSource? declared;
    try {
      declared = (await _capture.readCameraCapabilities()).timestampSource;
    } on Object {
      declared = null;
    }

    await stage('Camera capture, torch and ROI', () async {
      if (!cameraPermitted) throw StateError('skipped — permission not granted');
      final recording = await _capture.recordCamera(smokeDuration, config: const CaptureConfig());
      cameraBasis = recording.clockBasis(declared);
      final stats = recording.rateStatistics;
      final processing = recording.processingStatistics;
      if (stats == null) {
        throw StateError(
          'only ${recording.samples.length} frames arrived in $smokeDurationLabel',
        );
      }
      final size = await _capture.activeYuvSize();
      return '${recording.samples.length} frames at ${size ?? 'unreported size'}, '
          '~${stats.meanRateHz.toStringAsFixed(0)} fps (indicative), '
          'ROI mean ${processing == null ? 'n/a' : '${processing.meanMillis.toStringAsFixed(2)} ms'}';
    });

    await stage('Clock basis agreement', () async {
      final check = CrossStreamClockCheck(camera: cameraBasis, accelerometer: accelBasis);
      if (check.sharedBasis == null) {
        throw StateError(check.verdict);
      }
      if (check.sharedBasis == false) {
        throw StateError(check.verdict);
      }
      return check.verdict;
    });

    final report = SmokeReport(stages: stages, ranAt: DateTime.now());
    onProgress('');
    onProgress(report.summary);
    return report;
  }

  Future<CameraRunResult> _cameraRun({
    required String label,
    required bool permitted,
    required Measurement<CameraCapabilities> capabilities,
    required ProgressCallback onProgress,
  }) async {
    final before = await _attempt(
      'thermal state before $label camera run',
      _capture.readDeviceContext,
      onProgress,
    );
    _reportThermal('before $label camera run', before, onProgress);

    if (!permitted) {
      return CameraRunResult(
        label: label,
        rate: Measurement<RateStatistics>.failed('camera permission was not granted'),
        processing: Measurement<DurationStatistics>.failed(
          'camera permission was not granted',
        ),
        thermalBefore: before,
        thermalAfter: await _attempt(
          'thermal state after $label camera run',
          _capture.readDeviceContext,
          onProgress,
        ),
        yuvSize: Measurement<YuvSize>.failed('camera permission was not granted'),
      );
    }

    // The smallest YUV size, per BUILD_SPEC 6.4. A fingertip against the lens has no detail to
    // resolve, and every extra pixel is time inside the per-frame budget.
    final preferred = capabilities.isOk ? capabilities.requireValue.smallestYuvSize : null;
    final config = CaptureConfig(
      preferredYuvWidth: preferred?.width,
      preferredYuvHeight: preferred?.height,
    );

    Measurement<RateStatistics> rate;
    Measurement<DurationStatistics> processing;
    Measurement<YuvSize> yuvSize;

    try {
      final recording = await _capture.recordCamera(
        measurementDuration,
        config: config,
        onProgress: (n) => onProgress('  $n frames...'),
      );

      // The cold run establishes the basis; the warm run would give the same answer, and
      // overwriting it with a run that may have thermally degraded adds nothing.
      _cameraBasis ??= recording.clockBasis(
        capabilities.isOk ? capabilities.requireValue.timestampSource : null,
      );

      final rawPath = await exportCameraRun(recording, label: label);
      if (rawPath != null) onProgress('  raw series written to $rawPath');

      final stats = recording.rateStatistics;
      rate = stats == null
          ? Measurement<RateStatistics>.failed(
              'only ${recording.samples.length} frames arrived, or their timestamps were not '
              'monotonic — too few to compute a frame rate',
            )
          : Measurement<RateStatistics>.ok(stats);

      final processingStats = recording.processingStatistics;
      processing = processingStats == null
          ? Measurement<DurationStatistics>.failed('no frames were processed')
          : Measurement<DurationStatistics>.ok(processingStats);

      final active = await _capture.activeYuvSize();
      yuvSize = active == null
          ? Measurement<YuvSize>.failed('the platform did not report the size it opened')
          : Measurement<YuvSize>.ok(active);

      if (stats != null) {
        onProgress(
          '  achieved ${stats.meanRateHz.toStringAsFixed(1)} fps, '
          '~${stats.estimatedDroppedSamples} dropped '
          '(${stats.droppedPercent.toStringAsFixed(1)}%), '
          'p99 interval ${stats.p99IntervalMillis.toStringAsFixed(1)} ms',
        );
      }
      if (processingStats != null) {
        onProgress(
          '  ROI processing: mean ${processingStats.meanMillis.toStringAsFixed(2)} ms, '
          'p99 ${processingStats.p99Millis.toStringAsFixed(2)} ms',
        );
      }
    } on Object catch (e) {
      rate = Measurement<RateStatistics>.failed('$e');
      processing = Measurement<DurationStatistics>.failed('$e');
      yuvSize = Measurement<YuvSize>.failed('$e');
      onProgress('  $label camera run failed: $e');
    }

    final after = await _attempt(
      'thermal state after $label camera run',
      _capture.readDeviceContext,
      onProgress,
    );
    _reportThermal('after $label camera run', after, onProgress);

    return CameraRunResult(
      label: label,
      rate: rate,
      processing: processing,
      thermalBefore: before,
      thermalAfter: after,
      yuvSize: yuvSize,
    );
  }

  void _reportThermal(
    String when,
    Measurement<DeviceContext> context,
    ProgressCallback onProgress,
  ) {
    if (!context.isOk) return;
    final c = context.requireValue;
    onProgress(
      '  thermal $when: ${c.thermalStatus.name}'
      '${c.batteryPercent != null ? ', battery ${c.batteryPercent}%' : ''}'
      '${c.isCharging == true ? ' (charging)' : ''}',
    );
  }

  /// Run [action], returning a failed [Measurement] rather than throwing.
  Future<Measurement<T>> _attempt<T>(
    String what,
    Future<T> Function() action,
    ProgressCallback onProgress,
  ) async {
    try {
      return Measurement<T>.ok(await action());
    } on Object catch (e) {
      onProgress('  could not read $what: $e');
      return Measurement<T>.failed('$e');
    }
  }
}
