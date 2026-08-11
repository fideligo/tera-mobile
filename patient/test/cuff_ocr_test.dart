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

      expect(reading.systolicMmhg, 152);
      expect(reading.diastolicMmhg, 96);
      expect(reading.pulseBpm, 74);
      expect(reading.confidence, 0.88);
    });

    test('its JSON shape is the documented one', () {
      const reading = CuffOcrReading(
        systolicMmhg: 152,
        diastolicMmhg: 96,
        pulseBpm: 74,
        confidence: 0.88,
        simulated: true,
      );

      expect(reading.toJson(), {'sys': 152, 'dia': 96, 'pulse': 74, 'confidence': 0.88});
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
      expect(payload['systolic_mmhg'], 152);
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
    testWidgets('offers photograph and typing, and starts on neither', (tester) async {
      await pumpScreen(tester, _InstantOcr());

      expect(find.text('Photograph tensimeter'), findsOneWidget);
      expect(find.text('Type the numbers in'), findsOneWidget);
      expect(find.textContaining('We read'), findsNothing);
    });

    testWidgets('shows what was read, with both actions and no auto-save', (tester) async {
      await pumpScreen(tester, _InstantOcr());

      await tester.tap(find.text('Photograph tensimeter'));
      await tester.pumpAndSettle();

      expect(find.text('We read'), findsOneWidget);
      expect(find.text('152 / 96'), findsOneWidget);
      expect(find.text('Correct, save'), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget);

      // The strict rule: nothing reached the API on the way here.
      expect(_requests, 0);
    });

    testWidgets('says the numbers are simulated', (tester) async {
      await pumpScreen(tester, _InstantOcr());
      await tester.tap(find.text('Photograph tensimeter'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Simulated reading'), findsOneWidget);
      expect(find.textContaining('No photograph was taken'), findsOneWidget);
    });

    testWidgets('reports confidence without letting it stand in for a check', (tester) async {
      await pumpScreen(tester, _InstantOcr());
      await tester.tap(find.text('Photograph tensimeter'));
      await tester.pumpAndSettle();

      expect(find.textContaining('88%'), findsOneWidget);
      expect(find.textContaining('only you can do that'), findsOneWidget);
    });

    testWidgets('Edit drops into the form with the suggestion pre-filled', (tester) async {
      await pumpScreen(tester, _InstantOcr());
      await tester.tap(find.text('Photograph tensimeter'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      expect(find.text('Type in your cuff reading'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '152'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '96'), findsOneWidget);
      expect(_requests, 0);
    });

    testWidgets('an implausible suggestion cannot be saved and routes to Edit', (tester) async {
      // Swapped numbers, which is what a misread display most often produces.
      await pumpScreen(tester, _InstantOcr(systolic: 96, diastolic: 152));
      await tester.tap(find.text('Photograph tensimeter'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Correct, save'));
      await tester.pumpAndSettle();

      expect(find.text('Type in your cuff reading'), findsOneWidget);
      expect(find.textContaining('higher than the bottom number'), findsOneWidget);
      expect(_requests, 0);
    });

    testWidgets('the typed route still goes through its own confirm step', (tester) async {
      await pumpScreen(tester, _InstantOcr());

      await tester.tap(find.text('Type the numbers in'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextFormField, 'Top number (systolic), mmHg'), '');
      expect(find.text('Review'), findsOneWidget);
      expect(_requests, 0);
    });
  });
}
