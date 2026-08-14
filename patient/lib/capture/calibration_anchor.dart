/// The cuff reading a pending calibration will be anchored to.
///
/// # Why this has to be stored at all
///
/// Establishing a calibration needs two things that are produced on different screens, minutes
/// apart: the id of a confirmed cuff reading (`CuffReadingScreen`) and the id of an accepted
/// session (`ProcessingScreen`, after submission). The cuff reading comes first and the camera
/// intent in between can take the activity down with it, so the id is written to disk rather than
/// carried in memory — the same reasoning as [PendingCheckStore], for the same hazard.
///
/// # It is cleared as soon as it is used
///
/// An anchor left lying around would re-calibrate every later check against the same stale
/// reading, which is worse than not calibrating: the estimate would look confident and be
/// anchored to a measurement from weeks ago. [clear] runs the moment the calibration is
/// established, and the value ages out on its own if it never is.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class CalibrationAnchorStore {
  const CalibrationAnchorStore();

  static const _fileName = 'tera_calibration_anchor.json';

  /// A cuff reading older than this is not used as an anchor. Calibration is meant to pair a
  /// cuff reading with a capture taken at about the same time; pairing across days would anchor
  /// the baseline to a pressure the patient no longer had.
  static const _maxAge = Duration(hours: 2);

  Future<File> _file() async {
    final dir = await getTemporaryDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// Never throws: failing to record the anchor costs a calibration, not the reading itself.
  Future<void> save(String cuffReadingId) async {
    try {
      final file = await _file();
      await file.writeAsString(
        jsonEncode({
          'cuff_reading_id': cuffReadingId,
          'saved_at': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true,
      );
    } on Object {
      // Deliberately swallowed. See above.
    }
  }

  /// The pending anchor, or null when there is none or it has aged out.
  Future<String?> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;

      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final savedAt = DateTime.tryParse(raw['saved_at'] as String? ?? '');
      if (savedAt == null) return null;
      if (DateTime.now().toUtc().difference(savedAt.toUtc()) > _maxAge) {
        await clear();
        return null;
      }
      return raw['cuff_reading_id'] as String?;
    } on Object {
      return null;
    }
  }

  Future<void> clear() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } on Object {
      // Nothing to do; it ages out on its own.
    }
  }
}
