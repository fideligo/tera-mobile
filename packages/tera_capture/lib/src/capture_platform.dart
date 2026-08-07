/// Platform channel bindings.
///
/// The only file in the package that knows a MethodChannel exists. Everything above it works in
/// terms of the types in `models.dart`, so a second platform (or a fake, for tests on a laptop)
/// is a matter of implementing this interface.
library;

import 'package:flutter/services.dart';

import 'models.dart';

/// Thrown when the platform side refuses or fails a call. Carries the platform's own message so
/// the operator sees what actually went wrong, not a generic failure.
class CaptureException implements Exception {
  CaptureException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => code == null ? message : '$message ($code)';
}

/// Configuration for a capture run.
class CaptureConfig {
  const CaptureConfig({
    this.roiFraction = 0.4,
    this.lockAutoExposure = true,
    this.lockAutoWhiteBalance = true,
    this.lockAutoFocus = true,
    this.torchOn = true,
    this.preferredYuvWidth,
    this.preferredYuvHeight,
  }) : assert(roiFraction > 0 && roiFraction <= 1);

  /// Side of the centred square region of interest, as a fraction of the smaller frame
  /// dimension. The fingertip covers the whole lens, so the centre is representative and a
  /// smaller region costs less time per frame.
  final double roiFraction;

  /// BUILD_SPEC 6.4 requires all three locked. Unlocked auto-exposure would adjust brightness
  /// in response to the pulse and cancel out the signal being measured.
  final bool lockAutoExposure;
  final bool lockAutoWhiteBalance;
  final bool lockAutoFocus;
  final bool torchOn;

  /// Defaults to the smallest available YUV size when null.
  final int? preferredYuvWidth;
  final int? preferredYuvHeight;

  Map<String, Object?> toMap() => {
    'roi_fraction': roiFraction,
    'lock_ae': lockAutoExposure,
    'lock_awb': lockAutoWhiteBalance,
    'lock_af': lockAutoFocus,
    'torch_on': torchOn,
    'yuv_width': preferredYuvWidth,
    'yuv_height': preferredYuvHeight,
  };
}

/// What the platform reports about the sensor it opened.
class AccelerometerInfo {
  const AccelerometerInfo({
    required this.name,
    required this.vendor,
    required this.minDelayMicros,
    required this.maxDelayMicros,
    required this.highSamplingRatePermissionGranted,
  });

  factory AccelerometerInfo.fromMap(Map<Object?, Object?> raw) => AccelerometerInfo(
    name: raw['name'] as String,
    vendor: raw['vendor'] as String,
    minDelayMicros: (raw['min_delay_micros'] as num).toInt(),
    maxDelayMicros: (raw['max_delay_micros'] as num).toInt(),
    highSamplingRatePermissionGranted: raw['high_sampling_rate_granted'] as bool,
  );

  final String name;
  final String vendor;

  /// The fastest reporting period the sensor advertises. The *advertised* ceiling — BUILD_SPEC
  /// 6.1 exists because it is often not what is delivered.
  final int minDelayMicros;
  final int maxDelayMicros;

  /// Whether `HIGH_SAMPLING_RATE_SENSORS` is held. Without it the platform caps sensors at
  /// 200 Hz on Android 12+ (BUILD_SPEC 6.2).
  final bool highSamplingRatePermissionGranted;

  double get advertisedMaxHz => minDelayMicros > 0 ? 1e6 / minDelayMicros : double.nan;

  Map<String, Object?> toJson() => {
    'name': name,
    'vendor': vendor,
    'min_delay_micros': minDelayMicros,
    'max_delay_micros': maxDelayMicros,
    'advertised_max_hz': advertisedMaxHz.isNaN ? null : advertisedMaxHz,
    'high_sampling_rate_permission_granted': highSamplingRatePermissionGranted,
  };
}

/// Handset identity, for the results table.
class HandsetInfo {
  const HandsetInfo({
    required this.manufacturer,
    required this.model,
    required this.device,
    required this.androidRelease,
    required this.sdkInt,
  });

  factory HandsetInfo.fromMap(Map<Object?, Object?> raw) => HandsetInfo(
    manufacturer: raw['manufacturer'] as String,
    model: raw['model'] as String,
    device: raw['device'] as String,
    androidRelease: raw['android_release'] as String,
    sdkInt: (raw['sdk_int'] as num).toInt(),
  );

  final String manufacturer;
  final String model;
  final String device;
  final String androidRelease;
  final int sdkInt;

  String get displayName => '$manufacturer $model';

  Map<String, Object?> toJson() => {
    'manufacturer': manufacturer,
    'model': model,
    'device': device,
    'android_release': androidRelease,
    'sdk_int': sdkInt,
  };
}

/// The platform boundary.
abstract class CapturePlatform {
  Future<HandsetInfo> readHandsetInfo();
  Future<AccelerometerInfo> readAccelerometerInfo();
  Future<CameraCapabilities> readCameraCapabilities();
  Future<DeviceContext> readDeviceContext();
  Future<ClockOffsetSample> readClockOffset();

  Future<bool> ensureCameraPermission();

  Future<void> startAccelerometer();
  Future<void> stopAccelerometer();
  Stream<AccelSample> get accelerometerSamples;

  Future<void> startCamera(CaptureConfig config);
  Future<void> stopCamera();
  Stream<FrameSample> get frameSamples;

  /// The YUV size the platform actually opened, which may not be the one requested.
  Future<YuvSize?> activeYuvSize();
}

/// MethodChannel implementation.
class MethodChannelCapturePlatform implements CapturePlatform {
  static const MethodChannel _methods = MethodChannel('id.tera.capture/methods');
  static const EventChannel _accelEvents = EventChannel('id.tera.capture/accelerometer');
  static const EventChannel _frameEvents = EventChannel('id.tera.capture/frames');

  Stream<AccelSample>? _accelStream;
  Stream<FrameSample>? _frameStream;

  Future<T> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      final result = await _methods.invokeMethod<T>(method, args);
      if (result == null) {
        throw CaptureException('$method returned nothing');
      }
      return result;
    } on PlatformException catch (e) {
      throw CaptureException(e.message ?? 'platform call failed', code: e.code);
    } on MissingPluginException {
      throw CaptureException(
        '$method is not implemented on this platform. The profiler is Android only.',
      );
    }
  }

  @override
  Future<HandsetInfo> readHandsetInfo() async =>
      HandsetInfo.fromMap(await _invoke<Map<Object?, Object?>>('readHandsetInfo'));

  @override
  Future<AccelerometerInfo> readAccelerometerInfo() async =>
      AccelerometerInfo.fromMap(await _invoke<Map<Object?, Object?>>('readAccelerometerInfo'));

  @override
  Future<CameraCapabilities> readCameraCapabilities() async =>
      CameraCapabilities.fromMap(await _invoke<Map<Object?, Object?>>('readCameraCapabilities'));

  @override
  Future<DeviceContext> readDeviceContext() async =>
      DeviceContext.fromMap(await _invoke<Map<Object?, Object?>>('readDeviceContext'));

  @override
  Future<ClockOffsetSample> readClockOffset() async =>
      ClockOffsetSample.fromMap(await _invoke<Map<Object?, Object?>>('readClockOffset'));

  @override
  Future<bool> ensureCameraPermission() => _invoke<bool>('ensureCameraPermission');

  @override
  Future<void> startAccelerometer() => _invoke<bool>('startAccelerometer');

  @override
  Future<void> stopAccelerometer() => _invoke<bool>('stopAccelerometer');

  @override
  Stream<AccelSample> get accelerometerSamples =>
      _accelStream ??= _accelEvents
          .receiveBroadcastStream()
          .map((raw) => AccelSample.fromList(raw as List<Object?>));

  @override
  Future<void> startCamera(CaptureConfig config) => _invoke<bool>('startCamera', config.toMap());

  @override
  Future<void> stopCamera() => _invoke<bool>('stopCamera');

  @override
  Stream<FrameSample> get frameSamples =>
      _frameStream ??= _frameEvents
          .receiveBroadcastStream()
          .map((raw) => FrameSample.fromList(raw as List<Object?>));

  @override
  Future<YuvSize?> activeYuvSize() async {
    final raw = await _methods.invokeMethod<Map<Object?, Object?>>('activeYuvSize');
    return raw == null ? null : YuvSize.fromMap(raw);
  }
}
