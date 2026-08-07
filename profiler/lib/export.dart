/// Export (BUILD_SPEC 6.2): "Export as JSON and as a copy-paste-ready markdown table row, so
/// results from several phones can be pasted straight into the proposal."
library;

import 'dart:convert';
import 'dart:io';

import 'profile_result.dart';

const JsonEncoder _pretty = JsonEncoder.withIndent('  ');

String exportJson(ProfileResult result) => _pretty.convert(result.toJson());

/// The markdown row, with the header above it.
///
/// The header travels with the row so the first handset of the day produces a usable table and
/// later ones can have their header line deleted. Getting eight rows with no header, or eight
/// headers, is the sort of small friction that costs time on a measurement day.
String exportMarkdownRow(ProfileResult result) =>
    '${ProfileResult.markdownHeader}\n${result.toMarkdownRow()}';

/// Write the JSON to the app's external files directory and return the path.
///
/// External-files-dir needs no permission on any supported version, and the file survives the
/// app being closed — which matters when eight handsets are profiled in one session and the
/// results are collected afterwards over USB.
Future<String> saveResultToFile(ProfileResult result) async {
  final directory = await _exportDirectory();
  final handset = result.handset.isOk
      ? result.handset.requireValue.displayName.replaceAll(RegExp('[^A-Za-z0-9]+'), '-')
      : 'unknown-handset';
  final stamp = result.completedAt
      .toUtc()
      .toIso8601String()
      .replaceAll(RegExp('[:.]'), '-')
      .split('T')
      .join('_');

  final file = File('${directory.path}/tera-profile_${handset}_$stamp.json');
  await file.writeAsString(exportJson(result));
  return file.path;
}

/// The app-specific external directory, falling back to internal storage.
///
/// Resolved without `path_provider` — one fewer dependency for a tool that needs to be built
/// and installed on eight borrowed handsets in a hurry.
Future<Directory> _exportDirectory() async {
  const externalRoot = '/storage/emulated/0/Android/data/id.tera.tera_profiler/files';
  final external = Directory(externalRoot);
  try {
    if (await external.exists() || (await external.create(recursive: true)).existsSync()) {
      return external;
    }
  } on FileSystemException {
    // Falls through to the app's own directory below.
  }
  return Directory.systemTemp;
}
