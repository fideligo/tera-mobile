/// The record a patient can hand to a clinician.
///
/// # The one rule this document has to get right
///
/// **A cuff reading and a phone check are different kinds of claim, and the page must not let them
/// be read as one.** That is standing constraint 1, and a report is where it is easiest to lose:
/// the natural shape for "blood pressure history" is a single table with a systolic column, and
/// filling that column from both sources would put a modelled figure and a measured one under the
/// same heading for a clinician who has no way to tell them apart.
///
/// So they are two sections with different headings, different columns, and a stated explanation
/// between them. The API makes the same distinction structurally — `HistoryEntryOut` carries mmHg
/// fields only for `cuff_reading`, and a trend entry has no field that could hold a pressure — and
/// this file keeps that distinction rather than flattening it for layout.
///
/// # What else survives into the page
///
///   * **Refused checks** (invariant 3). A history that quietly omits the attempts reads as a
///     cleaner record than the one that exists, and the reason a capture failed is often the most
///     clinically interesting line on the page.
///   * **The synthetic flag** (invariant 9), against every row that carries it. Seeded and demo
///     data is labelled in the API, the UI and the database; a PDF that dropped the label would be
///     the one place fabricated data could be presented as real.
///   * **No interpretation** (invariant 6). No categories, no colour-coding by value, no "elevated",
///     no advice. The document reports what was recorded and says who to ask about it.
library;

import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../capture/phr_profile.dart';

/// One cuff measurement, as it appears on the page.
@immutable
class CuffRow {
  const CuffRow({
    required this.takenAt,
    required this.systolic,
    required this.diastolic,
    this.pulseBpm,
    this.synthetic = false,
  });

  final DateTime takenAt;
  final int systolic;
  final int diastolic;
  final int? pulseBpm;
  final bool synthetic;
}

/// One phone check. **Deliberately has no pressure field.**
@immutable
class CheckRow {
  const CheckRow({
    required this.occurredAt,
    this.direction,
    this.magnitudeSd,
    this.rejectionReason,
    this.synthetic = false,
  });

  final DateTime occurredAt;

  /// `rising`, `falling`, `stable` — a direction against the patient's own baseline, never a value.
  final String? direction;

  /// Distance from baseline in units of the patient's own standard deviation.
  final double? magnitudeSd;

  /// Set when the capture did not produce a usable measurement. Invariant 3: retained, reported.
  final String? rejectionReason;

  final bool synthetic;

  bool get refused => rejectionReason != null;
}

/// Everything the document needs, already separated by kind.
@immutable
class ReportData {
  const ReportData({
    required this.generatedAt,
    this.displayName,
    this.patientId,
    this.dateOfBirth,
    this.sex,
    this.cuffReadings = const [],
    this.checks = const [],
  });

  final DateTime generatedAt;
  final String? displayName;
  final String? patientId;
  final DateTime? dateOfBirth;
  final SexAtBirth? sex;
  final List<CuffRow> cuffReadings;
  final List<CheckRow> checks;

  /// Whole years at [generatedAt]. Null when no date of birth is recorded.
  int? get age {
    final dob = dateOfBirth;
    if (dob == null) return null;
    var years = generatedAt.year - dob.year;
    if (generatedAt.month < dob.month ||
        (generatedAt.month == dob.month && generatedAt.day < dob.day)) {
      years -= 1;
    }
    return years;
  }

  bool get isEmpty => cuffReadings.isEmpty && checks.isEmpty;

  /// True when anything on the page came from seeded or substituted data.
  bool get hasSynthetic =>
      cuffReadings.any((r) => r.synthetic) || checks.any((c) => c.synthetic);
}

/// Turn `GET /v1/history` into the two typed lists the report renders.
///
/// Pure, and separated from the layout so the mapping can be tested without producing a document.
/// The previous export read `session['date']`, `session['subtitle']` and `session['title']` —
/// three keys `HistoryEntryOut` has never had — so every row printed "Unknown Date" and
/// "No details". A silent mapping error in a document a clinician might act on is worth a test.
ReportData buildReportData({
  required List<dynamic> entries,
  required DateTime generatedAt,
  String? displayName,
  String? patientId,
  DateTime? dateOfBirth,
  SexAtBirth? sex,
}) {
  final cuff = <CuffRow>[];
  final checks = <CheckRow>[];

  for (final raw in entries) {
    if (raw is! Map) continue;
    final entry = raw.cast<String, dynamic>();

    final occurredAt = DateTime.tryParse(entry['occurred_at'] as String? ?? '');
    if (occurredAt == null) continue;
    final synthetic = entry['synthetic'] as bool? ?? false;

    switch (entry['entry_type'] as String?) {
      case 'cuff_reading':
        final systolic = (entry['systolic_mmhg'] as num?)?.toInt();
        final diastolic = (entry['diastolic_mmhg'] as num?)?.toInt();
        // A cuff row without both numbers is not a reading. Dropping it beats printing a blank
        // cell that reads as a measurement of nothing.
        if (systolic == null || diastolic == null) continue;
        cuff.add(
          CuffRow(
            takenAt: occurredAt.toLocal(),
            systolic: systolic,
            diastolic: diastolic,
            pulseBpm: (entry['pulse_bpm'] as num?)?.toInt(),
            synthetic: synthetic,
          ),
        );
      case 'trend':
        checks.add(
          CheckRow(
            occurredAt: occurredAt.toLocal(),
            direction: entry['direction'] as String?,
            magnitudeSd: (entry['magnitude_sd'] as num?)?.toDouble(),
            synthetic: synthetic,
          ),
        );
      case 'rejected':
        checks.add(
          CheckRow(
            occurredAt: occurredAt.toLocal(),
            rejectionReason: entry['rejection_reason'] as String? ?? 'unknown',
            synthetic: synthetic,
          ),
        );
      // `check` entries are the session envelope; the trend or rejection under them is what
      // carries the outcome, so listing both would double every row.
      default:
        continue;
    }
  }

  cuff.sort((a, b) => b.takenAt.compareTo(a.takenAt));
  checks.sort((a, b) => b.occurredAt.compareTo(a.occurredAt));

  return ReportData(
    generatedAt: generatedAt,
    displayName: displayName,
    patientId: patientId,
    dateOfBirth: dateOfBirth,
    sex: sex,
    cuffReadings: cuff,
    checks: checks,
  );
}

String _date(DateTime at) =>
    '${at.day.toString().padLeft(2, '0')}/${at.month.toString().padLeft(2, '0')}/${at.year}';

String _dateTime(DateTime at) =>
    '${_date(at)} ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';

/// Reason codes as a clinician would want them read. The wire values are the API's enum.
String describeRejection(String code) => switch (code) {
  'poor_signal_quality' => 'Signal not clear enough',
  'insufficient_beats' => 'Too few usable beats',
  'excessive_motion' => 'Too much movement',
  'posture_unstable' => 'Posture not stable',
  'torch_unavailable' => 'Camera light unavailable',
  'sensor_rate_below_qualified' => 'Motion sensor below the required rate',
  'clock_unstable' => 'Sensor timestamps not usable',
  'user_aborted' => 'Stopped by the patient',
  'signal_processing_unavailable' => 'Analysis could not run',
  _ => code.replaceAll('_', ' '),
};

String describeDirection(String? code) => switch (code) {
  'rising' => 'Higher than baseline',
  'falling' => 'Lower than baseline',
  'stable' => 'In line with baseline',
  null => 'Not determined',
  _ => code.replaceAll('_', ' '),
};

/// Composes the document. Nothing here touches the network or the filesystem.
class PdfExportService {
  const PdfExportService();

  static const _ink = PdfColor.fromInt(0xFF12304A);
  static const _muted = PdfColor.fromInt(0xFF546A7D);
  static const _rule = PdfColor.fromInt(0xFFC6CDD4);

  Future<Uint8List> build(ReportData data) async {
    final doc = pw.Document();

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(36),
        header: (context) => context.pageNumber == 1
            ? pw.SizedBox()
            : pw.Container(
                alignment: pw.Alignment.centerRight,
                margin: const pw.EdgeInsets.only(bottom: 12),
                child: pw.Text(
                  'Tera blood pressure record',
                  style: const pw.TextStyle(fontSize: 9, color: _muted),
                ),
              ),
        footer: (context) => pw.Container(
          margin: const pw.EdgeInsets.only(top: 12),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                'Generated on the patient\'s own phone. Not a diagnosis.',
                style: const pw.TextStyle(fontSize: 8, color: _muted),
              ),
              pw.Text(
                'Page ${context.pageNumber} of ${context.pagesCount}',
                style: const pw.TextStyle(fontSize: 8, color: _muted),
              ),
            ],
          ),
        ),
        build: (context) => [
          _title(data),
          pw.SizedBox(height: 16),
          _patientBlock(data),
          pw.SizedBox(height: 16),
          _howToRead(),
          if (data.hasSynthetic) ...[pw.SizedBox(height: 12), _syntheticNotice()],
          pw.SizedBox(height: 20),
          _cuffSection(data),
          pw.SizedBox(height: 20),
          _checkSection(data),
        ],
      ),
    );

    return doc.save();
  }

  pw.Widget _title(ReportData data) => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(
        'Blood pressure record',
        style: pw.TextStyle(
          fontSize: 22,
          fontWeight: pw.FontWeight.bold,
          color: _ink,
        ),
      ),
      pw.SizedBox(height: 2),
      pw.Text(
        'Tera · generated ${_dateTime(data.generatedAt)}',
        style: const pw.TextStyle(fontSize: 10, color: _muted),
      ),
    ],
  );

  pw.Widget _patientBlock(ReportData data) {
    final rows = <List<String>>[
      if (data.displayName != null && data.displayName!.trim().isNotEmpty)
        ['Name', data.displayName!.trim()],
      if (data.age != null) ['Age', '${data.age} years'],
      if (data.dateOfBirth != null) ['Date of birth', _date(data.dateOfBirth!)],
      if (data.sex != null) ['Sex assigned at birth', data.sex!.label],
      if (data.patientId != null) ['Record id', data.patientId!],
    ];
    if (rows.isEmpty) {
      return pw.Text(
        'No patient details are recorded.',
        style: const pw.TextStyle(fontSize: 10, color: _muted),
      );
    }

    return pw.Container(
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(border: pw.Border.all(color: _rule)),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          for (final row in rows)
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 2),
              child: pw.Row(
                children: [
                  pw.SizedBox(
                    width: 130,
                    child: pw.Text(
                      row[0],
                      style: const pw.TextStyle(fontSize: 10, color: _muted),
                    ),
                  ),
                  pw.Text(
                    row[1],
                    style: pw.TextStyle(
                      fontSize: 10,
                      color: _ink,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          pw.SizedBox(height: 6),
          pw.Text(
            'Tera does not store a name. Any name above was entered on this phone by the patient.',
            style: const pw.TextStyle(fontSize: 8, color: _muted),
          ),
        ],
      ),
    );
  }

  /// The explanation that keeps the two sections from being read as one.
  pw.Widget _howToRead() => pw.Container(
    padding: const pw.EdgeInsets.all(10),
    decoration: pw.BoxDecoration(border: pw.Border.all(color: _rule)),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          'How to read this record',
          style: pw.TextStyle(
            fontSize: 11,
            fontWeight: pw.FontWeight.bold,
            color: _ink,
          ),
        ),
        pw.SizedBox(height: 4),
        pw.Text(
          'Cuff readings are measurements, taken with a validated upper-arm cuff and confirmed by '
          'the patient. They are the only blood-pressure values in this document.',
          style: const pw.TextStyle(fontSize: 9, color: _ink),
        ),
        pw.SizedBox(height: 3),
        pw.Text(
          'Phone checks are not blood-pressure measurements. Each one reports a direction against '
          'the patient\'s own cuff baseline, in units of their own variability. They carry no '
          'mmHg value and are not interchangeable with the readings above.',
          style: const pw.TextStyle(fontSize: 9, color: _ink),
        ),
        pw.SizedBox(height: 3),
        pw.Text(
          'Tera does not diagnose and does not advise on medication. Nothing in this document is a '
          'clinical judgement.',
          style: const pw.TextStyle(fontSize: 9, color: _ink),
        ),
      ],
    ),
  );

  pw.Widget _syntheticNotice() => pw.Container(
    padding: const pw.EdgeInsets.all(8),
    decoration: pw.BoxDecoration(border: pw.Border.all(color: _ink, width: 1.5)),
    child: pw.Text(
      'THIS RECORD CONTAINS DEMONSTRATION DATA. Rows marked "demo" were generated for testing '
      'and are not measurements of this patient.',
      style: pw.TextStyle(
        fontSize: 9,
        fontWeight: pw.FontWeight.bold,
        color: _ink,
      ),
    ),
  );

  pw.Widget _sectionTitle(String text, String subtitle) => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(
        text,
        style: pw.TextStyle(
          fontSize: 13,
          fontWeight: pw.FontWeight.bold,
          color: _ink,
        ),
      ),
      pw.SizedBox(height: 2),
      pw.Text(subtitle, style: const pw.TextStyle(fontSize: 9, color: _muted)),
      pw.SizedBox(height: 8),
    ],
  );

  pw.Widget _cuffSection(ReportData data) => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      _sectionTitle(
        'Cuff readings',
        'Measured with an upper-arm cuff and confirmed by the patient.',
      ),
      if (data.cuffReadings.isEmpty)
        pw.Text(
          'No cuff readings recorded in this period.',
          style: const pw.TextStyle(fontSize: 10, color: _muted),
        )
      else
        pw.TableHelper.fromTextArray(
          headers: ['Date', 'Systolic', 'Diastolic', 'Pulse', 'Source'],
          cellStyle: const pw.TextStyle(fontSize: 9),
          headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
          headerDecoration: const pw.BoxDecoration(
            color: PdfColor.fromInt(0xFFEEF1F2),
          ),
          cellAlignment: pw.Alignment.centerLeft,
          border: pw.TableBorder.all(color: _rule, width: 0.5),
          data: [
            for (final row in data.cuffReadings)
              [
                _dateTime(row.takenAt),
                '${row.systolic} mmHg',
                '${row.diastolic} mmHg',
                row.pulseBpm == null ? '—' : '${row.pulseBpm} bpm',
                row.synthetic ? 'Cuff (demo)' : 'Cuff',
              ],
          ],
        ),
    ],
  );

  pw.Widget _checkSection(ReportData data) => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      _sectionTitle(
        'Phone checks',
        'Direction against the patient\'s own baseline. No mmHg value is produced by a phone check.',
      ),
      if (data.checks.isEmpty)
        pw.Text(
          'No phone checks recorded in this period.',
          style: const pw.TextStyle(fontSize: 10, color: _muted),
        )
      else
        pw.TableHelper.fromTextArray(
          headers: ['Date', 'Result', 'Distance from baseline'],
          cellStyle: const pw.TextStyle(fontSize: 9),
          headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
          headerDecoration: const pw.BoxDecoration(
            color: PdfColor.fromInt(0xFFEEF1F2),
          ),
          cellAlignment: pw.Alignment.centerLeft,
          border: pw.TableBorder.all(color: _rule, width: 0.5),
          data: [
            for (final row in data.checks)
              [
                _dateTime(row.occurredAt),
                row.refused
                    ? 'Not usable — ${describeRejection(row.rejectionReason!)}'
                    : describeDirection(row.direction) +
                          (row.synthetic ? ' (demo)' : ''),
                row.refused || row.magnitudeSd == null
                    ? '—'
                    : '${row.magnitudeSd!.toStringAsFixed(1)} SD',
              ],
          ],
        ),
    ],
  );
}
