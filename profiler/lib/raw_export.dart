/// Raw series export, for offline signal and ML work.
///
/// The profiler already records sixty seconds of accelerometer and sixty seconds of camera on a
/// real handset. Those recordings are exactly what the signal chain needs to be developed
/// against, and today they are reduced to statistics and discarded.
///
/// This writes them out — **in a developer build only**, and **without changing what the profiler
/// retains**. Each recording is serialised at the point it completes, inside the same scope that
/// already holds it, and is still dropped immediately afterwards. Nothing is buffered for longer
/// than before.
///
/// # The terms
///
///   * **Own or teammate handsets only. Never a patient's.**
///   * **Purely local.** There is no network path from here. The profiler's upload sends a device
///     profile — model, rates, hardware level, clock spread — and never a sample.
///   * **Delete after analysis.**
///
/// The clinical no-waveform rule (invariant 2) is untouched: it is a property of the API, which
/// accepts one derived interval per beat and nothing deeper. This is a documented exception for
/// development data, not a repeal.
///
/// Enable with `--dart-define=TERA_DEBUG_CAPTURE=true`. It is a compile-time constant, so a build
/// without it does not contain this path at all rather than merely declining to take it.
library;

import 'dart:io';

import 'package:tera_capture/tera_capture.dart';

const bool kRawExportEnabled = bool.fromEnvironment('TERA_DEBUG_CAPTURE');

/// Write an accelerometer recording, returning the path, or null if this build has no export.
Future<String?> exportAccelerometerRun(
  CaptureRecording<AccelSample> recording, {
  required String label,
}) => _write('$label-accel', () => accelerometerCsv(recording));

/// Write a camera recording, returning the path, or null if this build has no export.
Future<String?> exportCameraRun(
  CaptureRecording<FrameSample> recording, {
  required String label,
}) => _write('$label-frames', () => framesCsv(recording));

Future<String?> _write(String label, String Function() serialise) async {
  if (!kRawExportEnabled) return null;

  try {
    final directory = await _exportDirectory();
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp('[:.]'), '-')
        .split('T')
        .join('_');
    final file = File('${directory.path}/tera-raw_${stamp}_$label.csv');
    await file.writeAsString(serialise());
    return file.path;
  } on Object {
    // A failed export must never fail the profiling run. The run is the point; this is a bonus,
    // and losing it silently is better than losing sixty seconds of measurement on eight
    // borrowed handsets.
    return null;
  }
}

Future<Directory> _exportDirectory() async {
  const externalRoot = '/storage/emulated/0/Android/data/id.tera.tera_profiler/files';
  final external = Directory(externalRoot);
  try {
    if (await external.exists() || (await external.create(recursive: true)).existsSync()) {
      return external;
    }
  } on FileSystemException {
    // Falls through to the temp directory below.
  }
  return Directory.systemTemp;
}
