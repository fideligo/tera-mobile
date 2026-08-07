/// Tera capture — the acquisition layer.
///
/// Opens the accelerometer and the rear camera, and streams what they actually report:
/// timestamped accelerometer samples, and one region-of-interest mean per camera frame.
///
/// Two consumers are planned. The **device profiler** (Phase 3) uses it to measure whether a
/// handset can run Tera at all. The **patient capture app** will use it to record spot checks.
/// Nothing in this package depends on either, and nothing in it may.
///
/// Invariant 2 is a property of this package's interface: camera frames and accelerometer
/// buffers do not cross its boundary. A frame becomes one number before it reaches Dart, and
/// there is no type here that could carry an image or a sample buffer outward.
///
/// See `CaptureController`'s documentation for the five things this package deliberately does
/// not do — the boundary the patient app will build on.
library;

export 'src/capture_controller.dart';
export 'src/clock_basis.dart';
export 'src/measurement.dart';
export 'src/models.dart';
export 'src/rate_statistics.dart';
