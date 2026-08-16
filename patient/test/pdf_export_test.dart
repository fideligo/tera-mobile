/// The clinician-facing report.
///
/// Most of this file is about one property: **a cuff reading and a phone check must never end up
/// in the same column.** A single "systolic" column filled from both sources would put a modelled
/// figure and a measured one under one heading for a reader who has no way to tell them apart, and
/// a printed page is the worst place to discover that — it leaves the app, and it may be acted on
/// by someone who never saw the screen it came from.
///
/// The mapping is tested at all because the export it replaced read three keys the API has never
/// carried (`date`, `subtitle`, `title`), so every row of every report printed "Unknown Date" and
/// "No details" without anything failing.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tera_patient/capture/phr_profile.dart';
import 'package:tera_patient/export/pdf_export_service.dart';

Map<String, dynamic> _cuff({
  String at = '2026-08-10T09:15:00Z',
  int? systolic = 128,
  int? diastolic = 82,
  int? pulse = 71,
  bool synthetic = false,
}) => {
  'id': 'c-1',
  'entry_type': 'cuff_reading',
  'occurred_at': at,
  'systolic_mmhg': systolic,
  'diastolic_mmhg': diastolic,
  'pulse_bpm': pulse,
  'unit': 'mmHg',
  'badge': 'Cuff reading',
  'synthetic': synthetic,
};

Map<String, dynamic> _trend({
  String at = '2026-08-11T08:00:00Z',
  String direction = 'stable',
  double magnitude = 0.4,
  bool synthetic = false,
}) => {
  'id': 't-1',
  'entry_type': 'trend',
  'occurred_at': at,
  'direction': direction,
  'magnitude_sd': magnitude,
  'deviation_state': 'within_band',
  'synthetic': synthetic,
};

Map<String, dynamic> _rejected({
  String at = '2026-08-12T08:00:00Z',
  String reason = 'excessive_motion',
}) => {
  'id': 'r-1',
  'entry_type': 'rejected',
  'occurred_at': at,
  'rejection_reason': reason,
  'synthetic': false,
};

final _now = DateTime(2026, 8, 17, 10, 30);

void main() {
  group('the two kinds of record stay separate', () {
    test('mmHg lands only on cuff rows', () {
      final data = buildReportData(
        entries: [_cuff(), _trend(), _rejected()],
        generatedAt: _now,
      );

      expect(data.cuffReadings, hasLength(1));
      expect(data.cuffReadings.single.systolic, 128);
      expect(data.cuffReadings.single.diastolic, 82);
      expect(data.cuffReadings.single.pulseBpm, 71);

      // `CheckRow` has no field that could hold a pressure. This asserts the count; the type
      // asserts the rest, which is the stronger guarantee.
      expect(data.checks, hasLength(2));
    });

    test('a trend carries a direction and a distance, never a value', () {
      final data = buildReportData(entries: [_trend()], generatedAt: _now);
      final check = data.checks.single;

      expect(check.direction, 'stable');
      expect(check.magnitudeSd, 0.4);
      expect(check.refused, isFalse);
    });
  });

  group('what must not be dropped', () {
    test('a refused capture is kept, with its reason', () {
      // Invariant 3. A history that omits the attempts reads as a cleaner record than the one
      // that exists, and the reason is often the most useful line on the page.
      final data = buildReportData(
        entries: [_rejected(reason: 'sensor_rate_below_qualified')],
        generatedAt: _now,
      );

      expect(data.checks.single.refused, isTrue);
      expect(
        describeRejection(data.checks.single.rejectionReason!),
        'Motion sensor below the required rate',
      );
    });

    test('the synthetic flag survives into the report', () {
      // Invariant 9. A PDF that dropped the label would be the one place demo data could be
      // presented as real.
      final data = buildReportData(
        entries: [_cuff(synthetic: true), _trend()],
        generatedAt: _now,
      );

      expect(data.cuffReadings.single.synthetic, isTrue);
      expect(data.hasSynthetic, isTrue);
    });

    test('an all-real record raises no demonstration notice', () {
      final data = buildReportData(
        entries: [_cuff(), _trend()],
        generatedAt: _now,
      );

      expect(data.hasSynthetic, isFalse);
    });
  });

  group('the mapping matches the API it reads', () {
    test('entries the schema does not fill are skipped, not half-rendered', () {
      final data = buildReportData(
        entries: [
          _cuff(systolic: null),
          {'entry_type': 'cuff_reading', 'occurred_at': 'not-a-date'},
          {'entry_type': 'check', 'occurred_at': '2026-08-10T09:00:00Z'},
          'not a map',
        ],
        generatedAt: _now,
      );

      // A cuff row missing a number is not a reading, an unparseable date places nothing, and a
      // `check` envelope is already represented by the trend or rejection under it.
      expect(data.cuffReadings, isEmpty);
      expect(data.checks, isEmpty);
      expect(data.isEmpty, isTrue);
    });

    test('rows are newest first, within each kind', () {
      final data = buildReportData(
        entries: [
          _cuff(at: '2026-08-01T09:00:00Z'),
          _cuff(at: '2026-08-14T09:00:00Z'),
          _trend(at: '2026-08-02T09:00:00Z'),
          _trend(at: '2026-08-13T09:00:00Z'),
        ],
        generatedAt: _now,
      );

      expect(data.cuffReadings.first.takenAt.day, 14);
      expect(data.checks.first.occurredAt.day, 13);
    });
  });

  group('the patient block', () {
    test('age is whole years at the moment of generating', () {
      final data = buildReportData(
        entries: const [],
        generatedAt: DateTime(2026, 8, 17),
        dateOfBirth: DateTime(1990, 8, 18),
        sex: SexAtBirth.female,
      );

      // A birthday one day away is not yet a year.
      expect(data.age, 35);
    });

    test('no date of birth means no age, not a zero', () {
      final data = buildReportData(entries: const [], generatedAt: _now);
      expect(data.age, isNull);
    });
  });

  group('the document builds', () {
    test('a full record produces a PDF', () async {
      final data = buildReportData(
        entries: [_cuff(), _trend(), _rejected()],
        generatedAt: _now,
        displayName: 'Rafi',
        patientId: 'p-1',
        dateOfBirth: DateTime(1990, 4, 17),
        sex: SexAtBirth.male,
      );

      final bytes = await const PdfExportService().build(data);

      expect(bytes, isNotEmpty);
      // The PDF magic number, so this asserts a document rather than any non-empty buffer.
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    });

    test('an empty record still produces a document', () async {
      // Someone with no history who exports anyway gets a page saying so, not a crash and not a
      // zero-byte file they will try to send to a clinician.
      final data = buildReportData(entries: const [], generatedAt: _now);
      final bytes = await const PdfExportService().build(data);

      expect(bytes, isNotEmpty);
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    });
  });
}
