/// Data the capture layer produces.
///
/// These are *acquisition* types. Nothing here knows what a heartbeat is, and nothing here
/// should learn — see the boundary note in `docs/decisions.md`.
library;

import 'package:meta/meta.dart';

/// One accelerometer sample, timestamped in the sensor's own time base.
///
/// [timestampNanos] is the value the platform reported (`SensorEvent.timestamp`), not a value
/// taken when Dart received it. Anything measured from arrival time in a garbage-collected
/// runtime would be measuring the runtime, not the sensor.
@immutable
class AccelSample {
  const AccelSample({
    required this.timestampNanos,
    required this.x,
    required this.y,
    required this.z,
    required this.realtimeAtDeliveryNanos,
    required this.uptimeAtDeliveryNanos,
  });

  factory AccelSample.fromList(List<Object?> raw) => AccelSample(
    timestampNanos: (raw[0] as num).toInt(),
    x: (raw[1] as num).toDouble(),
    y: (raw[2] as num).toDouble(),
    z: (raw[3] as num).toDouble(),
    realtimeAtDeliveryNanos: (raw[4] as num).toInt(),
    uptimeAtDeliveryNanos: (raw[5] as num).toInt(),
  );

  final int timestampNanos;
  final double x;
  final double y;
  final double z;

  /// Both clocks, read back to back at delivery. Used to establish which base
  /// [timestampNanos] is really in — see [ClockBasisVerification].
  final int realtimeAtDeliveryNanos;
  final int uptimeAtDeliveryNanos;
}

/// One camera frame, reduced to the single number the measurement needs.
///
/// [roiMean] is the mean luminance over the region of interest. **The frame itself never
/// crosses this boundary** — invariant 2 — and there is deliberately no field here that could
/// carry one.
@immutable
class FrameSample {
  const FrameSample({
    required this.timestampNanos,
    required this.roiMean,
    required this.processingNanos,
    required this.frameNumber,
    required this.realtimeAtDeliveryNanos,
    required this.uptimeAtDeliveryNanos,
  });

  factory FrameSample.fromList(List<Object?> raw) => FrameSample(
    timestampNanos: (raw[0] as num).toInt(),
    roiMean: (raw[1] as num).toDouble(),
    processingNanos: (raw[2] as num).toInt(),
    frameNumber: (raw[3] as num).toInt(),
    realtimeAtDeliveryNanos: (raw[4] as num).toInt(),
    uptimeAtDeliveryNanos: (raw[5] as num).toInt(),
  );

  /// Hardware timestamp, in the time base [CameraCapabilities.timestampSource] *declares*.
  /// Whether it really is in that base is checked by [ClockBasisVerification].
  final int timestampNanos;
  final double roiMean;

  /// Both clocks, read back to back at delivery.
  final int realtimeAtDeliveryNanos;
  final int uptimeAtDeliveryNanos;

  /// Wall time spent computing [roiMean] for this frame. BUILD_SPEC 6.7 — the real-time budget
  /// on actual hardware.
  final int processingNanos;
  final int frameNumber;
}

/// Android `INFO_SUPPORTED_HARDWARE_LEVEL`.
enum CameraHardwareLevel { legacy, limited, full, level3, external, unknown }

/// Android `SENSOR_INFO_TIMESTAMP_SOURCE`.
///
/// `realtime` means camera timestamps share a base with `SystemClock.elapsedRealtimeNanos()`,
/// which is what the accelerometer uses. `unknown` means they do not, and the two signals have
/// to be aligned through an inferred offset — the error a transit-time measurement is most
/// sensitive to.
enum CameraTimestampSource { unknown, realtime }

@immutable
class YuvSize {
  const YuvSize({required this.width, required this.height, required this.minFrameDurationNanos});

  factory YuvSize.fromMap(Map<Object?, Object?> raw) => YuvSize(
    width: (raw['width'] as num).toInt(),
    height: (raw['height'] as num).toInt(),
    minFrameDurationNanos: (raw['min_frame_duration_nanos'] as num).toInt(),
  );

  final int width;
  final int height;

  /// `StreamConfigurationMap.getOutputMinFrameDuration` for this size. The ceiling on frame
  /// rate the hardware will admit, before anything the app does.
  final int minFrameDurationNanos;

  int get pixels => width * height;

  double get maxFps => minFrameDurationNanos > 0 ? 1e9 / minFrameDurationNanos : double.nan;

  Map<String, Object?> toJson() => {
    'width': width,
    'height': height,
    'min_frame_duration_nanos': minFrameDurationNanos,
    'max_fps': maxFps.isNaN ? null : maxFps,
  };

  @override
  String toString() => '${width}x$height';
}

/// What `CameraCharacteristics` says about this handset.
@immutable
class CameraCapabilities {
  const CameraCapabilities({
    required this.cameraId,
    required this.hardwareLevel,
    required this.hasManualSensor,
    required this.timestampSource,
    required this.yuvSizes,
    required this.hasFlash,
    required this.supportsAutoExposureLock,
    required this.supportsAutoWhiteBalanceLock,
  });

  factory CameraCapabilities.fromMap(Map<Object?, Object?> raw) => CameraCapabilities(
    cameraId: raw['camera_id'] as String,
    hardwareLevel: _hardwareLevel(raw['hardware_level'] as String?),
    hasManualSensor: raw['has_manual_sensor'] as bool,
    timestampSource: raw['timestamp_source'] == 'realtime'
        ? CameraTimestampSource.realtime
        : CameraTimestampSource.unknown,
    yuvSizes: (raw['yuv_sizes'] as List<Object?>)
        .map((e) => YuvSize.fromMap(e! as Map<Object?, Object?>))
        .toList(growable: false),
    hasFlash: raw['has_flash'] as bool,
    supportsAutoExposureLock: raw['supports_ae_lock'] as bool,
    supportsAutoWhiteBalanceLock: raw['supports_awb_lock'] as bool,
  );

  final String cameraId;
  final CameraHardwareLevel hardwareLevel;

  /// Whether `REQUEST_AVAILABLE_CAPABILITIES` contains `MANUAL_SENSOR`. Without it, exposure
  /// and gain can drift mid-capture and add brightness changes that did not come from the pulse.
  final bool hasManualSensor;
  final CameraTimestampSource timestampSource;

  /// Every YUV_420_888 output size, ascending by pixel count.
  final List<YuvSize> yuvSizes;
  final bool hasFlash;
  final bool supportsAutoExposureLock;
  final bool supportsAutoWhiteBalanceLock;

  /// The smallest YUV size the measurement can use.
  ///
  /// Smallest, because the region of interest is a fingertip pressed against the lens: there is
  /// no detail to resolve, and every extra pixel is processing time inside the frame budget.
  YuvSize? get smallestYuvSize => yuvSizes.isEmpty ? null : yuvSizes.first;

  static CameraHardwareLevel _hardwareLevel(String? raw) => switch (raw) {
    'legacy' => CameraHardwareLevel.legacy,
    'limited' => CameraHardwareLevel.limited,
    'full' => CameraHardwareLevel.full,
    'level_3' => CameraHardwareLevel.level3,
    'external' => CameraHardwareLevel.external,
    _ => CameraHardwareLevel.unknown,
  };

  Map<String, Object?> toJson() => {
    'camera_id': cameraId,
    'hardware_level': hardwareLevel.name,
    'has_manual_sensor': hasManualSensor,
    'timestamp_source': timestampSource.name,
    'has_flash': hasFlash,
    'supports_ae_lock': supportsAutoExposureLock,
    'supports_awb_lock': supportsAutoWhiteBalanceLock,
    'yuv_sizes': yuvSizes.map((s) => s.toJson()).toList(),
    'smallest_yuv_size': smallestYuvSize?.toJson(),
  };
}

/// Android `PowerManager` thermal status.
enum ThermalStatus { none, light, moderate, severe, critical, emergency, shutdown, unsupported }

/// Thermal and battery state at a moment in time (BUILD_SPEC 6.5).
@immutable
class DeviceContext {
  const DeviceContext({
    required this.thermalStatus,
    required this.batteryPercent,
    required this.isCharging,
    required this.capturedAtMillis,
  });

  factory DeviceContext.fromMap(Map<Object?, Object?> raw) => DeviceContext(
    thermalStatus: _thermal(raw['thermal_status'] as String?),
    batteryPercent: (raw['battery_percent'] as num?)?.toInt(),
    isCharging: raw['is_charging'] as bool?,
    capturedAtMillis: (raw['captured_at_millis'] as num).toInt(),
  );

  final ThermalStatus thermalStatus;

  /// Null when the platform did not report it. Not zero.
  final int? batteryPercent;
  final bool? isCharging;
  final int capturedAtMillis;

  static ThermalStatus _thermal(String? raw) => switch (raw) {
    'none' => ThermalStatus.none,
    'light' => ThermalStatus.light,
    'moderate' => ThermalStatus.moderate,
    'severe' => ThermalStatus.severe,
    'critical' => ThermalStatus.critical,
    'emergency' => ThermalStatus.emergency,
    'shutdown' => ThermalStatus.shutdown,
    _ => ThermalStatus.unsupported,
  };

  Map<String, Object?> toJson() => {
    'thermal_status': thermalStatus.name,
    'battery_percent': batteryPercent,
    'is_charging': isCharging,
    'captured_at_millis': capturedAtMillis,
  };
}

/// One reading of the two clocks, taken back to back (BUILD_SPEC 6.6).
@immutable
class ClockOffsetSample {
  const ClockOffsetSample({
    required this.realtimeNanos,
    required this.uptimeNanos,
    required this.uptimeHasNanosecondPrecision,
  });

  factory ClockOffsetSample.fromMap(Map<Object?, Object?> raw) => ClockOffsetSample(
    realtimeNanos: (raw['realtime_nanos'] as num).toInt(),
    uptimeNanos: (raw['uptime_nanos'] as num).toInt(),
    uptimeHasNanosecondPrecision: raw['uptime_nanosecond_precision'] as bool,
  );

  /// `SystemClock.elapsedRealtimeNanos()` — the camera's base when timestamp source is REALTIME.
  final int realtimeNanos;

  /// `SystemClock.uptimeNanos()` where available, otherwise `uptimeMillis()` scaled up.
  final int uptimeNanos;

  /// False when the platform only offered millisecond resolution, which bounds how finely the
  /// offset can be resolved. Reported rather than hidden.
  final bool uptimeHasNanosecondPrecision;

  /// Time the device spent in deep sleep. The absolute value does not matter — a constant
  /// offset is absorbed by personal calibration. Its *spread* across runs does.
  int get offsetNanos => realtimeNanos - uptimeNanos;

  double get offsetMillis => offsetNanos / 1e6;

  Map<String, Object?> toJson() => {
    'realtime_nanos': realtimeNanos,
    'uptime_nanos': uptimeNanos,
    'offset_nanos': offsetNanos,
    'uptime_nanosecond_precision': uptimeHasNanosecondPrecision,
  };
}
