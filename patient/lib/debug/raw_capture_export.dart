/// Writing a capture's raw series to CSV, for developing the signal chain against real data.
///
/// # This is a documented exception to invariant 2, not a repeal of it
///
/// The clinical path still never persists or transmits a waveform: the API accepts one derived
/// interval per beat and nothing deeper, and nothing in this file touches that path. What this
/// adds is a developer's ability to keep the raw accelerometer and ROI series from *their own*
/// capture long enough to build the signal chain against it, because that chain cannot be written
/// against summary statistics.
///
/// The terms, which are not negotiable and are printed in the UI at the point of use:
///
///   * **Own or teammate data only. Never a patient.**
///   * **Purely local.** Nothing here uploads. There is no network call in this file, and the
///     export is not reachable from [SessionSubmitter] or anything it calls.
///   * **Delete after analysis.** The files sit in app-specific external storage and are removed
///     when the app is uninstalled, but that is a backstop, not the plan.
///
/// # Why a compile-time flag rather than a runtime toggle
///
/// [kDebugCaptureEnabled] comes from `--dart-define`, so in a build that did not pass it the guard
/// is a compile-time constant `false`, the tree-shaker removes the export path, and no sequence of
/// taps can reach it. A runtime switch would leave the capability present in every build, one
/// mis-set boolean away from writing a patient's raw waveform to disk. The difference matters more
/// than the convenience does.
///
/// Enable with:
///
/// ```
/// flutter run --dart-define=TERA_DEBUG_CAPTURE=true
/// ```
library;

import 'dart:io';

import 'package:tera_capture/tera_capture.dart';

import '../ui/capture_screen.dart';

/// Whether this build contains the raw export at all.
///
/// Deliberately `const`: a build without `--dart-define=TERA_DEBUG_CAPTURE=true` cannot reach the
/// code below, rather than merely declining to run it.
const bool kDebugCaptureEnabled = bool.fromEnvironment('TERA_DEBUG_CAPTURE');

/// The wording shown wherever the export is offered. Kept here so it cannot drift from the terms.
const String debugCaptureNotice =
    'Developer build. This writes the raw signals from this recording to files on this phone. '
    'Use it on your own or a teammate’s phone only, never a patient’s, and delete the '
    'files after analysis. Nothing is uploaded.';

class DebugExportResult {
  const DebugExportResult({required this.accelPath, required this.framesPath});

  final String accelPath;
  final String framesPath;
}

/// Write the two series beside each other and return where they landed.
///
/// Throws [StateError] if called from a build without the flag. That is unreachable by
/// construction, and the throw is there so a future caller that forgets the guard fails loudly
/// rather than silently exporting.
Future<DebugExportResult> exportRawCapture(CaptureResult capture) async {
  if (!kDebugCaptureEnabled) {
    throw StateError(
      'Raw export is not present in this build. Rebuild with '
      '--dart-define=TERA_DEBUG_CAPTURE=true.',
    );
  }

  final directory = await _exportDirectory();
  // One stamp for both files, so the pair is obviously a pair.
  final stamp = capture.startedAt
      .toUtc()
      .toIso8601String()
      .replaceAll(RegExp('[:.]'), '-')
      .split('T')
      .join('_');

  final accel = File('${directory.path}/tera-raw_${stamp}_accel.csv');
  final frames = File('${directory.path}/tera-raw_${stamp}_frames.csv');

  await accel.writeAsString(accelerometerCsv(capture.accelerometer));
  await frames.writeAsString(framesCsv(capture.frames));

  return DebugExportResult(accelPath: accel.path, framesPath: frames.path);
}

/// App-specific external storage, falling back to the system temp directory.
///
/// Resolved directly rather than through `path_provider`: this is a developer-only path and one
/// fewer dependency in the patient app is worth more than the abstraction. App-specific external
/// storage needs no permission, and the files go when the app is uninstalled.
Future<Directory> _exportDirectory() async {
  // Must match applicationId in android/app/build.gradle.kts exactly. It is 'id.tera.tera_patient',
  // not 'id.tera.patient' — a mismatch does not fail loudly, it silently falls through to the
  // temp directory below, and the files are then somewhere nobody thinks to look.
  const externalRoot = '/storage/emulated/0/Android/data/id.tera.tera_patient/files';
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
