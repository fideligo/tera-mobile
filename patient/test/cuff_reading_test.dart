import 'package:flutter_test/flutter_test.dart';
import 'package:tera_patient/capture/cuff_reading.dart';

DraftCuffReading draft({int systolic = 128, int diastolic = 82, int? pulse}) =>
    DraftCuffReading(systolicMmhg: systolic, diastolicMmhg: diastolic, pulseBpm: pulse);

void main() {
  group('nothing persists without an explicit confirmation', () {
    test('a confirmed reading can only be produced by confirming a draft', () {
      final confirmed = draft().confirm();
      expect(confirmed.confirmedAt, isNotNull);
      expect(confirmed.draft.systolicMmhg, 128);
    });

    test('user_confirmed_at is the confirmation instant, and is always present', () {
      final at = DateTime.utc(2026, 8, 13, 16, 55);
      final payload = draft().confirm(at: at).toPayload('episode-1');

      expect(payload['user_confirmed_at'], at.toIso8601String());
    });

    test('taken_at defaults to the confirmation instant when none was given', () {
      final at = DateTime.utc(2026, 8, 13, 16, 55);
      final payload = draft().confirm(at: at).toPayload('episode-1');

      expect(payload['taken_at'], at.toIso8601String());
    });

    test('a taken_at supplied by the patient is preserved', () {
      final taken = DateTime.utc(2026, 8, 13, 8, 0);
      final confirmedAt = DateTime.utc(2026, 8, 13, 16, 55);
      final payload = DraftCuffReading(
        systolicMmhg: 128,
        diastolicMmhg: 82,
        takenAt: taken,
      ).confirm(at: confirmedAt).toPayload('episode-1');

      expect(payload['taken_at'], taken.toIso8601String());
      expect(payload['user_confirmed_at'], confirmedAt.toIso8601String());
    });

    test('an invalid draft cannot be confirmed into existence', () {
      // Swapped numbers: the commonest data-entry slip, and one that would otherwise become a
      // permanent reference row.
      expect(() => draft(systolic: 80, diastolic: 120).confirm(), throwsStateError);
    });
  });

  group('the payload says only what is true', () {
    test('source is always manual_entry, because OCR does not exist', () {
      expect(draft().confirm().toPayload('e')['source'], 'manual_entry');
    });

    test('no ocr_confidence is ever sent', () {
      expect(draft().confirm().toPayload('e').containsKey('ocr_confidence'), isFalse);
    });

    test('synthetic is false — a patient typed this off a real cuff', () {
      expect(draft().confirm().toPayload('e')['synthetic'], false);
    });

    test('pulse is omitted rather than sent as a zero when not given', () {
      expect(draft().confirm().toPayload('e').containsKey('pulse_bpm'), isFalse);
    });

    test('pulse is included when given', () {
      expect(draft(pulse: 74).confirm().toPayload('e')['pulse_bpm'], 74);
    });

    test('timestamps are UTC, so a phone in WIB does not file a reading eight hours out', () {
      final local = DateTime(2026, 8, 13, 16, 55);
      final payload = draft().confirm(at: local).toPayload('e');

      expect(payload['user_confirmed_at'], endsWith('Z'));
      expect(payload['user_confirmed_at'], local.toUtc().toIso8601String());
    });
  });

  group('data-entry bounds mirror the backend', () {
    test('a plausible reading has no violations', () {
      expect(draft(systolic: 128, diastolic: 82, pulse: 74).validate(), isEmpty);
    });

    test('systolic below the floor is caught', () {
      final v = draft(systolic: systolicMinMmhg - 1, diastolic: 40).validate();
      expect(v.map((x) => x.field), contains('systolic_mmhg'));
    });

    test('systolic above the ceiling is caught', () {
      final v = draft(systolic: systolicMaxMmhg + 1).validate();
      expect(v.map((x) => x.field), contains('systolic_mmhg'));
    });

    test('diastolic outside its range is caught', () {
      expect(
        draft(systolic: 250, diastolic: diastolicMaxMmhg + 1).validate().map((x) => x.field),
        contains('diastolic_mmhg'),
      );
      expect(
        draft(systolic: 60, diastolic: diastolicMinMmhg - 1).validate().map((x) => x.field),
        contains('diastolic_mmhg'),
      );
    });

    test('systolic equal to diastolic is refused, not just below', () {
      expect(draft(systolic: 100, diastolic: 100).validate(), isNotEmpty);
    });

    test('the swapped-numbers message names the likely cause', () {
      final v = draft(systolic: 80, diastolic: 120).validate();
      expect(v.first.message, contains('swapped'));
    });

    test('pulse outside its range is caught, and only when supplied', () {
      expect(draft(pulse: pulseMaxBpm + 1).validate(), isNotEmpty);
      expect(draft(pulse: pulseMinBpm - 1).validate(), isNotEmpty);
      expect(draft().validate(), isEmpty);
    });

    test('the bounds are the backend values', () {
      // If the backend rebands these, this test fails and names the file to change.
      expect(systolicMinMmhg, 50);
      expect(systolicMaxMmhg, 300);
      expect(diastolicMinMmhg, 30);
      expect(diastolicMaxMmhg, 200);
      expect(pulseMinBpm, 25);
      expect(pulseMaxBpm, 250);
    });

    test('bounds are inclusive at both ends', () {
      expect(draft(systolic: systolicMaxMmhg, diastolic: diastolicMaxMmhg).validate(), isEmpty);
      expect(draft(systolic: 51, diastolic: diastolicMinMmhg).validate(), isEmpty);
    });
  });
}
