import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tera_patient/api/api_client.dart';
import 'package:tera_patient/auth/token_store.dart';
import 'package:tera_patient/capture/cuff_ocr.dart';
import 'package:tera_patient/capture/cuff_reading.dart';
import 'package:tera_patient/ui/cuff_reading_screen.dart';

/// Instant, so widget tests do not wait on the mock's one-second delay.
class _InstantOcr implements CuffOcrExtractor {
  _InstantOcr({this.systolic = mockOcrSystolic, this.diastolic = mockOcrDiastolic});

  final int systolic;
  final int diastolic;
  int calls = 0;

  @override
  Future<CuffOcrReading> extract() async {
    calls++;
    return CuffOcrReading(
      systolicMmhg: systolic,
      diastolicMmhg: diastolic,
      pulseBpm: mockOcrPulse,
      confidence: mockOcrConfidence,
      simulated: true,
    );
  }
}

int _requests = 0;

ApiClient _api() {
  _requests = 0;
  return ApiClient(
    baseUrl: 'http://test',
    tokenStore: InMemoryTokenStore()
      ..write(
        const StoredSession(
          accessToken: 'a',
          refreshToken: 'r',
          role: 'patient',
          subject: 'demo.patient@tera.invalid',
        ),
      ),
    httpClient: MockClient((_) async {
      _requests++;
      return http.Response('{}', 500);
    }),
    onSessionLost: () {},
  );
}

Future<void> pumpScreen(WidgetTester tester, CuffOcrExtractor ocr) async {
  // A phone-sized surface rather than the 800x600 default. The suggestion panel is tall, and on
  // the default viewport the two actions fall outside the ListView's lazily-built range — which
  // makes them unfindable for reasons that have nothing to do with the flow being tested.
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(home: CuffReadingScreen(api: _api(), onDone: () {}, ocr: ocr)),
  );
}

void main() {
  group('the mock extractor', () {
    test('returns the documented dummy reading', () async {
      final reading = await const MockCuffOcrExtractor(delay: Duration.zero).extract();

      // Against the named constants, not copies of them. Duplicating the literals here is how
      // these tests came to disagree with the extractor they describe.
      expect(reading.systolicMmhg, mockOcrSystolic);
      expect(reading.diastolicMmhg, mockOcrDiastolic);
      expect(reading.pulseBpm, mockOcrPulse);
      expect(reading.confidence, mockOcrConfidence);
    });

    test('its JSON shape is the documented one', () {
      const reading = CuffOcrReading(
        systolicMmhg: mockOcrSystolic,
        diastolicMmhg: mockOcrDiastolic,
        pulseBpm: mockOcrPulse,
        confidence: mockOcrConfidence,
        simulated: true,
      );

      expect(reading.toJson(), {
        'sys': mockOcrSystolic,
        'dia': mockOcrDiastolic,
        'pulse': mockOcrPulse,
        'confidence': mockOcrConfidence,
      });
    });

    test('always marks itself simulated — there is no parameter to claim otherwise', () async {
      expect((await const MockCuffOcrExtractor(delay: Duration.zero).extract()).simulated, isTrue);
    });

    test('takes about a second by default, so the waiting state is visible', () {
      expect(const MockCuffOcrExtractor().delay, const Duration(seconds: 1));
    });
  });

  group('an OCR-derived reading is still a manual entry', () {
    test('source stays manual_entry and no ocr_confidence is sent', () async {
      final suggestion = await const MockCuffOcrExtractor(delay: Duration.zero).extract();

      final payload = DraftCuffReading(
        systolicMmhg: suggestion.systolicMmhg,
        diastolicMmhg: suggestion.diastolicMmhg,
        pulseBpm: suggestion.pulseBpm,
      ).confirm().toPayload('episode-1');

      // The backend refuses both of these, for the same reason this flow submits neither: nothing
      // in this build stands behind a machine reading of a display.
      expect(payload['source'], 'manual_entry');
      expect(payload.containsKey('ocr_confidence'), isFalse);
      expect(payload['systolic_mmhg'], mockOcrSystolic);
    });

    test('confirmation is still the only route to a saveable reading', () {
      // A suggestion carries no confirmation of its own; it has to pass through confirm(), which
      // is the same gate the typed path uses.
      expect(
        () => DraftCuffReading(systolicMmhg: 96, diastolicMmhg: 152).confirm(),
        throwsStateError,
      );
    });
  });

  group('the confirmation UI', () {
    // The screen was redesigned (the old "Photograph tensimeter" / "Type the numbers in" fork is
    // gone; entry starts on the form with "Scan monitor instead" beside it). These follow the new
    // labels. What they assert has not moved: nothing reaches the API without a confirmation, and
    // a scanned reading says on the confirmation screen that it was not read from the photograph.

    testWidgets('offers both routes and suggests nothing until asked', (
      tester,
    ) async {
      await pumpScreen(tester, _InstantOcr());

      expect(find.text('Scan monitor instead'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
      // No suggestion is on screen before one is requested.
      expect(find.textContaining('Simulated reading'), findsNothing);
      expect(_requests, 0);
    });

    testWidgets('a scan lands on review with both actions and no auto-save', (
      tester,
    ) async {
      await pumpScreen(tester, _InstantOcr());

      await tester.tap(find.text('Scan monitor instead'));
      await tester.pumpAndSettle();

      expect(find.text('Review your reading'), findsOneWidget);
      expect(find.text('$mockOcrSystolic'), findsWidgets);
      expect(find.text('$mockOcrDiastolic'), findsWidgets);
      expect(find.text('Edit'), findsOneWidget);

      // The strict rule: nothing reached the API on the way here.
      expect(_requests, 0);
    });

    testWidgets('says the numbers are simulated, before Confirm is reachable', (
      tester,
    ) async {
      // The regression this exists for: the redesigned review screen showed the extractor's fixed
      // numbers under "Measured / Just now" with no disclosure at all. A patient who has just
      // photographed their own monitor reads that as their reading. It is not — the image is
      // discarded unread — and confirming it files a `cuff_reading` that anchors every later
      // estimate. Invariant 9, on the clinical path.
      await pumpScreen(tester, _InstantOcr());
      await tester.tap(find.text('Scan monitor instead'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Simulated reading'), findsOneWidget);
      expect(find.textContaining('No photograph was taken'), findsOneWidget);
    });

    testWidgets('reports confidence without letting it stand in for a check', (
      tester,
    ) async {
      await pumpScreen(tester, _InstantOcr());
      await tester.tap(find.text('Scan monitor instead'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('${(mockOcrConfidence * 100).round()}%'),
        findsOneWidget,
      );
      expect(find.textContaining('Only you can do that'), findsOneWidget);
    });

    testWidgets('a typed reading carries no simulated notice', (tester) async {
      // The disclosure is about where the numbers came from, so it must not appear over a
      // patient's own typing.
      await pumpScreen(tester, _InstantOcr());

      // The form labels are siblings of the fields rather than `labelText`, so the fields are
      // addressed by position: systolic, diastolic, pulse.
      await tester.enterText(find.byType(TextFormField).at(0), '128');
      await tester.enterText(find.byType(TextFormField).at(1), '82');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Review your reading'), findsOneWidget);
      expect(find.textContaining('Simulated reading'), findsNothing);
      expect(_requests, 0);
    });

    testWidgets('Edit drops into the form with the suggestion pre-filled', (
      tester,
    ) async {
      await pumpScreen(tester, _InstantOcr());
      await tester.tap(find.text('Scan monitor instead'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(TextFormField, '$mockOcrSystolic'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(TextFormField, '$mockOcrDiastolic'),
        findsOneWidget,
      );
      expect(_requests, 0);
    });

    testWidgets('Edit without changing a digit keeps the disclosure', (
      tester,
    ) async {
      // Editing is not correcting. Passing back through the form unchanged leaves the extractor's
      // numbers exactly where they were, so the notice has to survive the round trip.
      await pumpScreen(tester, _InstantOcr());
      await tester.tap(find.text('Scan monitor instead'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Simulated reading'), findsOneWidget);
    });

    testWidgets('an implausible suggestion cannot be saved and routes to Edit', (
      tester,
    ) async {
      // Swapped numbers, which is what a misread display most often produces.
      await pumpScreen(
        tester,
        _InstantOcr(systolic: mockOcrDiastolic, diastolic: mockOcrSystolic),
      );
      await tester.tap(find.text('Scan monitor instead'));
      await tester.pumpAndSettle();

      // It never reaches review: the draft fails validation and drops back to the form.
      expect(find.text('Review your reading'), findsNothing);
      expect(find.textContaining('higher than the bottom number'), findsOneWidget);
      expect(_requests, 0);
    });

    testWidgets('an incomplete form does not reach review, let alone the API', (
      tester,
    ) async {
      await pumpScreen(tester, _InstantOcr());

      await tester.enterText(find.byType(TextFormField).at(0), '128');
      // Diastolic left empty.
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Review your reading'), findsNothing);
      expect(_requests, 0);
    });
  });
}
