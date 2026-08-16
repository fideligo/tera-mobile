/// INS-01 — what the result screen is allowed to show, and what it must never hide.
///
/// Two properties are under test here and they pull in opposite directions, which is why they are
/// in one file:
///
///   * **The measured figures are always on screen.** A patient who has just held still for a
///     minute must see what the capture produced, whether or not the server answered, whether or
///     not the AI paragraph was consented to, and whether or not a calibration exists. The screen
///     used to replace all of it with the words "No result".
///   * **A number nobody measured is never shown.** Where the server returns a null estimate — no
///     calibration, an anchor past `max_calibration_age_days`, drift outside the linear range —
///     the screen explains and offers the cuff reading that fixes it. It does not fill the slot.
///     Invariant 1, and the reason `pressure_estimate.estimate()` returns `None` rather than a
///     plausible figure.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tera_patient/api/api_client.dart';
import 'package:tera_patient/auth/token_store.dart';
import 'package:tera_patient/signal/signal_pipeline.dart';
import 'package:tera_patient/ui/insight_screen.dart';

/// The paths the screen asked for, in order, so a declined consent can be proved by absence.
late List<String> requested;

ApiClient _api(Map<String, dynamic> Function(Uri) respond, {int status = 200}) {
  final store = InMemoryTokenStore();
  store.write(
    const StoredSession(
      accessToken: 'a',
      refreshToken: 'r',
      role: 'patient',
      subject: 's',
    ),
  );
  return ApiClient(
    baseUrl: 'http://test',
    tokenStore: store,
    httpClient: MockClient((request) async {
      requested.add('${request.url.path}?${request.url.query}');
      return http.Response(
        jsonEncode(respond(request.url)),
        status,
        headers: {'content-type': 'application/json'},
      );
    }),
    onSessionLost: () {},
  );
}

/// A capture this handset really analysed. 72 bpm is the figure the screen must always show.
const _measured = SignalResult(
  accepted: true,
  pttMs: [240, 241, 242],
  nBeatsTotal: 3,
  nBeatsUsable: 3,
  quality: {'accel_rate_hz': 200.0, 'camera_fps': 30.0},
  heartRateBpm: 72.0,
);

Map<String, dynamic> _insight({
  int? estSys,
  int? estDia,
  int? refSys,
  int? refDia,
  int? ageDays,
  String? aiCommentary,
}) => {
  'session_id': 'sess',
  'synthetic': false,
  'hero': 'Your reading is in line with your baseline',
  'next_best_step': 'Keep to your usual routine.',
  'estimated_systolic': estSys,
  'estimated_diastolic': estDia,
  'estimate_confidence': estSys == null ? null : 0.9,
  'estimate_calibration_age_days': ageDays,
  'reference_systolic': refSys,
  'reference_diastolic': refDia,
  'ai_commentary': aiCommentary,
};

Future<void> _pump(
  WidgetTester tester,
  ApiClient api, {
  bool? aiConsent,
  SignalResult? local = _measured,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: InsightScreen(
        api: api,
        sessionId: 'sess',
        aiConsent: aiConsent,
        localSignal: local,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => requested = []);

  group('the measured figures are never hidden', () {
    testWidgets('heart rate is on screen with the estimate', (tester) async {
      await _pump(
        tester,
        _api((_) => _insight(estSys: 128, estDia: 82, refSys: 130, refDia: 84)),
        aiConsent: false,
      );

      expect(find.text('72'), findsOneWidget);
      expect(find.text('beats per minute'), findsOneWidget);
      expect(find.text('128 / 82'), findsOneWidget);
    });

    testWidgets('heart rate survives the server being unreachable', (
      tester,
    ) async {
      // The capture happened on this handset and produced this number. Nothing about an
      // unreachable server makes it less true, and blanking the screen taught the patient their
      // minute was wasted.
      await _pump(tester, _api((_) => {'detail': 'nope'}, status: 500));

      expect(find.text('72'), findsOneWidget);
    });

    testWidgets('the words "No result" appear on no path', (tester) async {
      for (final response in [
        _insight(estSys: 128, estDia: 82, refSys: 130, refDia: 84),
        _insight(),
        <String, dynamic>{'session_id': 'sess'},
      ]) {
        await _pump(tester, _api((_) => response), aiConsent: false);
        expect(find.textContaining('No result'), findsNothing);
      }
    });
  });

  group('an estimate the model could not stand behind is not invented', () {
    testWidgets('a null estimate explains itself and offers the cuff', (
      tester,
    ) async {
      await _pump(
        tester,
        _api((_) => _insight(refSys: 130, refDia: 84, ageDays: 41)),
        aiConsent: false,
      );

      expect(find.text('No estimated reading for this check'), findsOneWidget);
      expect(find.textContaining('41 days old'), findsOneWidget);
      expect(find.text('Take a cuff reading'), findsOneWidget);
      // The whole point: no numerals in the value slot.
      expect(find.textContaining('mmHg, estimated from this check'), findsNothing);
    });

    testWidgets('an uncalibrated patient is told what to do first', (
      tester,
    ) async {
      await _pump(tester, _api((_) => _insight()), aiConsent: false);

      expect(find.textContaining('upper-arm cuff'), findsOneWidget);
      expect(find.text('Take a cuff reading'), findsOneWidget);
    });

    testWidgets('an estimate is never in a cuff reading\'s visual language', (
      tester,
    ) async {
      await _pump(
        tester,
        _api((_) => _insight(estSys: 128, estDia: 82, refSys: 130, refDia: 84)),
        aiConsent: false,
      );

      // Standing constraint 1: the estimate carries its own label, always.
      expect(find.text('ESTIMATED — NOT A CUFF READING'), findsOneWidget);
    });
  });

  group('the AI paragraph is gated on consent and on nothing else', () {
    testWidgets('declining never calls the LLM and shows no AI block', (
      tester,
    ) async {
      await _pump(
        tester,
        _api((_) => _insight(estSys: 128, estDia: 82, aiCommentary: 'leaked')),
        aiConsent: false,
      );

      expect(
        requested.every((r) => !r.contains('ai_consent=true')),
        isTrue,
        reason: 'a refusal must not reach the third-party call: $requested',
      );
      // The deterministic result is all of it, and all of it is still there.
      expect(find.text('128 / 82'), findsOneWidget);
      expect(find.text('72'), findsOneWidget);
    });

    testWidgets('consenting asks for the paragraph and renders it', (
      tester,
    ) async {
      await _pump(
        tester,
        _api(
          (uri) => _insight(
            estSys: 128,
            estDia: 82,
            aiCommentary: uri.query.contains('ai_consent=true')
                ? 'A steady week of readings.'
                : null,
          ),
        ),
        aiConsent: true,
      );

      expect(requested.any((r) => r.contains('ai_consent=true')), isTrue);
      expect(find.text('A steady week of readings.'), findsOneWidget);
      expect(find.textContaining('AI-GENERATED'), findsOneWidget);
      // And the core figures are not displaced by it.
      expect(find.text('128 / 82'), findsOneWidget);
      expect(find.text('72'), findsOneWidget);
    });

    testWidgets('a consented call that returns nothing leaves the rest intact', (
      tester,
    ) async {
      await _pump(
        tester,
        _api((_) => _insight(estSys: 128, estDia: 82)),
        aiConsent: true,
      );

      expect(find.textContaining('AI-GENERATED'), findsNothing);
      expect(find.text('128 / 82'), findsOneWidget);
      expect(find.text('72'), findsOneWidget);
    });
  });
}
