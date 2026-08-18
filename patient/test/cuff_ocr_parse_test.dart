/// Turning recognised text into a blood-pressure pair.
///
/// The recogniser itself needs a camera and a native plugin, so what is tested here is the part
/// that decides what its output *means* — which is where the interesting failures live. A misread
/// display that produces a plausible-looking pair is worse than one that produces nothing: the
/// patient is anchored to a wrong number they then confirm, and the anchor becomes a calibration.
///
/// So the rule this file mostly enforces is the refusal. `parseCuffText` returns null far more
/// readily than it guesses, and every case below that returns null is a case where guessing would
/// have been possible.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tera_patient/capture/cuff_ocr.dart';

void main() {
  group('the shapes a tensimeter actually prints', () {
    test('an explicit pair', () {
      final reading = parseCuffText('SYS 128/82 mmHg');

      expect(reading, isNotNull);
      expect(reading!.systolicMmhg, 128);
      expect(reading.diastolicMmhg, 82);
      // Stated as a pair by the display itself, which is the strongest evidence available.
      expect(reading.confidence, OcrMatch.explicitPair.confidence);
    });

    test('three stacked lines, in the order they are printed', () {
      final reading = parseCuffText('SYS\n128\nDIA\n82\nPULSE\n71');

      expect(reading!.systolicMmhg, 128);
      expect(reading.diastolicMmhg, 82);
      expect(reading.pulseBpm, 71);
    });

    test('digits with the labels lost, largest first', () {
      // What recognition returns from a display photographed at an angle.
      final reading = parseCuffText('82 71 128');

      expect(reading!.systolicMmhg, 128);
      expect(reading.diastolicMmhg, 82);
      expect(reading.confidence, OcrMatch.looseDigits.confidence);
    });

    test('a capital O read where a zero was printed', () {
      // Seven-segment zeroes come back as letter O often enough to be worth handling.
      final reading = parseCuffText('12O/8O');

      expect(reading!.systolicMmhg, 120);
      expect(reading.diastolicMmhg, 80);
    });

    test('a real reading is never marked simulated', () {
      // The flag is what separates a machine's guess at a real display from placeholder numbers.
      expect(parseCuffText('128/82')!.simulated, isFalse);
    });
  });

  group('it refuses rather than guesses', () {
    test('nothing recognisable', () {
      expect(parseCuffText(''), isNull);
      expect(parseCuffText('mmHg'), isNull);
    });

    test('a single number is not a reading', () {
      expect(parseCuffText('128'), isNull);
    });

    test('a systolic at or below its diastolic', () {
      // The signature of a misread, and what `DraftCuffReading.validate` refuses anyway — better
      // to decline than to pre-fill a form that cannot be saved.
      expect(parseCuffText('82/128'), isNull);
      expect(parseCuffText('100/100'), isNull);
    });

    test('numbers outside the plausible bounds', () {
      expect(parseCuffText('999/888'), isNull);
      // 10 and 12 are below the two-digit floor the pattern requires, and below the bounds anyway.
      expect(parseCuffText('10 12'), isNull);
    });

    test('a time on the display is not a blood pressure', () {
      // 10:45 with a date beside it. Nothing here is a plausible pair, so nothing is offered.
      expect(parseCuffText('10:45  01-02'), isNull);
    });
  });

  group('the pulse is optional and bounded', () {
    test('an implausible pulse is dropped, not carried', () {
      final reading = parseCuffText('128/82 PUL 400');

      expect(reading, isNotNull);
      expect(reading!.pulseBpm, isNull);
    });

    test('no pulse at all is fine', () {
      expect(parseCuffText('128/82')!.pulseBpm, isNull);
    });
  });

  group('the mock is still labelled as one', () {
    test('it declares itself simulated, with no way to say otherwise', () async {
      // Invariant 9: placeholder numbers shown without that label are fabricated data presented
      // as real. There is deliberately no constructor parameter for this.
      final reading = await const MockCuffOcrExtractor(delay: Duration.zero).extract();

      expect(reading.simulated, isTrue);
      expect(reading.systolicMmhg, mockOcrSystolic);
    });
  });
}
