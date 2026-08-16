/// The data the flow collects and submits: CTX-01, the PHR, and the payload that reaches
/// ProcessingScreen.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tera_patient/api/api_client.dart';
import 'package:tera_patient/auth/auth_controller.dart';
import 'package:tera_patient/auth/token_store.dart';
import 'package:tera_patient/capture/current_context.dart';
import 'package:tera_patient/capture/check_session_client.dart';
import 'package:tera_patient/capture/current_context_submitter.dart';
import 'package:tera_capture/tera_capture.dart';
import 'package:tera_patient/capture/device_measurement.dart';
import 'package:tera_patient/capture/phr_profile.dart';
import 'package:tera_patient/routing/app_flow_state.dart';
import 'package:tera_patient/routing/app_router.dart';
import 'package:tera_patient/routing/check_payload.dart';
import 'package:tera_patient/routing/check_session.dart';
import 'package:tera_patient/routing/routes.dart';
import 'package:tera_patient/signal/signal_pipeline.dart';
import 'package:tera_patient/ui/flow_screens.dart';
import 'package:tera_patient/ui/onboarding_screens.dart';

ApiClient _api(MockClient client) => ApiClient(
  baseUrl: 'http://test',
  tokenStore: InMemoryTokenStore()
    ..write(
      const StoredSession(
        accessToken: 'a',
        refreshToken: 'r',
        role: 'patient',
        subject: 'someone@example.invalid',
      ),
    ),
  httpClient: client,
  onSessionLost: () {},
);

TeraFlow _flow(MockClient client, [AppFlowState state = const AppFlowState()]) {
  final api = _api(client);
  return TeraFlow(
    auth: AuthController(api: api),
    api: api,
    store: InMemoryAppFlowStore(state),
  );
}

const _accepted = SignalResult(
  accepted: true,
  pttMs: [210, 212, 209],
  nBeatsTotal: 40,
  nBeatsUsable: 3,
  quality: {'accel_rate_hz': 200.0, 'camera_fps': 30.0},
);

Future<void> _pumpProcessing(
  WidgetTester tester,
  MockClient client, {
  CheckMode mode = CheckMode.sensor,
  SignalResult? signal,
  bool settle = true,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final flow = _flow(client);
  await tester.pumpWidget(
    MaterialApp(
      onGenerateRoute: TeraRouter(flow).onGenerateRoute,
      home: ProcessingScreen(
        flow: flow,
        session: CheckSession(mode: mode, state: CheckState.processing),
        payload: CheckPayload(signal: signal, capturedAt: DateTime.utc(2026, 8, 12)),
        // No camera in a test. Everything downstream of this - resolve, submit, error handling -
        // is the real path.
        measurements: () async => const DeviceMeasurements(
          handset: HandsetInfo(
            manufacturer: 'Test',
            model: 'Rig',
            device: 'rig',
            androidRelease: '15',
            sdkInt: 35,
          ),
          capabilities: CameraCapabilities(
            cameraId: '0',
            hardwareLevel: CameraHardwareLevel.full,
            hasManualSensor: true,
            timestampSource: CameraTimestampSource.realtime,
            yuvSizes: [],
            hasFlash: true,
            supportsAutoExposureLock: true,
            supportsAutoWhiteBalanceLock: true,
          ),
          accelRateHz: 200,
          cameraFps: 30,
          clockOffsetSdMs: 0.4,
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
    return;
  }
  // Bounded instead. A run that advances all the way to the insight lands on a
  // `CircularProgressIndicator`, and an indeterminate progress animation schedules frames
  // forever — `pumpAndSettle` times out on it no matter what the code under test did.
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  _checkSessionTests();
  group('CTX-01 data', () {
    test('every field the intervention matrix needs round-trips', () {
      const original = CurrentContext(
        sleepLessThanUsual: true,
        stressHigherThanUsual: true,
        feelingUnwell: true,
        symptoms: {ContextSymptom.headache, ContextSymptom.dizziness},
        medicationStatusToday: MedicationStatusToday.missedOrLate,
      );

      final restored = CurrentContext.fromJson(original.toJson());

      expect(restored.sleepLessThanUsual, isTrue);
      expect(restored.stressHigherThanUsual, isTrue);
      expect(restored.feelingUnwell, isTrue);
      expect(restored.symptoms, {ContextSymptom.headache, ContextSymptom.dizziness});
      expect(restored.medicationStatusToday, MedicationStatusToday.missedOrLate);
    });

    test('the wire keys are the ones the spec names', () {
      final json = const CurrentContext().toJson();

      expect(json.keys, containsAll(<String>[
        'sleep_less_than_usual',
        'stress_higher_than_usual',
        'feeling_unwell',
        'symptoms',
        'medication_status_today',
      ]));
    });

    test('an unremarkable day is the default state', () {
      expect(const CurrentContext().isUnremarkable, isTrue);
      expect(
        const CurrentContext(feelingUnwell: true).isUnremarkable,
        isFalse,
      );
    });

    test('the contextual symptoms are not the invariant 8 red-flag list', () {
      // Red flags terminate the session before capture, offline. Anything in this list would be
      // a red flag arriving too late to act on.
      final wire = ContextSymptom.values.map((s) => s.wireValue).toSet();

      for (final redFlag in [
        'chest_pain',
        'severe_breathlessness',
        'severe_headache',
        'visual_disturbance',
        'weakness_or_speech_difficulty',
      ]) {
        expect(wire, isNot(contains(redFlag)));
      }
    });

    test('medication status keeps four distinct answers', () {
      // "Not applicable" and "not sure" are different from each other and from no.
      expect(MedicationStatusToday.values.length, 4);
      for (final s in MedicationStatusToday.values) {
        expect(MedicationStatusToday.fromWire(s.wireValue), s);
      }
    });
  });

  group('CTX-01 submission', () {
    test('the session route is used when a session exists', () async {
      String? path;
      await CurrentContextSubmitter(
        api: _api(
          MockClient((request) async {
            path = request.url.path;
            return http.Response(jsonEncode({'id': 'x'}), 201);
          }),
        ),
      ).submitForSession(sessionId: 'sess-1', context: const CurrentContext(feelingUnwell: true));

      // The typed table, not an event: the backend can tell a context record from a reported
      // symptom without inspecting a payload.
      //
      // `submitForSession` returns void now rather than a bool, so the observable claim is the
      // route it called — which is the part that matters here.
      expect(path, '/v1/check-sessions/sess-1/context');
    });

    test('the session route failure never throws', () async {
      // The whole point of the submitter: a failed context upload loses a record, never the
      // check. Returning normally *is* the assertion.
      await expectLater(
        CurrentContextSubmitter(
          api: _api(MockClient((_) async => http.Response('nope', 500))),
        ).submitForSession(sessionId: 's', context: const CurrentContext()),
        completes,
      );
    });

    test('BP-only falls back to an episode-scoped event', () async {
      Map<String, dynamic>? body;
      final ok = await CurrentContextSubmitter(
        api: _api(
          MockClient((request) async {
            body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(jsonEncode({'id': 'x'}), 201);
          }),
        ),
      ).submit(
        episodeId: 'episode-1',
        context: const CurrentContext(feelingUnwell: true),
        occurredAt: DateTime.utc(2026, 8, 12, 9),
      );

      expect(ok, isTrue);
      expect(body!['event_type'], 'symptom');
      expect(body!['episode_id'], 'episode-1');
      expect(body!['occurred_at'], '2026-08-12T09:00:00.000Z');
      expect((body!['payload'] as Map)['feeling_unwell'], true);
    });

    test('the payload stays well inside the endpoint key bound', () {
      // /v1/events refuses more than 32 keys, so the column cannot become a data channel.
      expect(const CurrentContext().toJson().length, lessThan(32));
    });

    test('a failure never throws and never blocks the check', () async {
      final ok = await CurrentContextSubmitter(
        api: _api(MockClient((_) async => http.Response('nope', 500))),
      ).submit(episodeId: 'e', context: const CurrentContext());

      expect(ok, isFalse);
    });
  });

  group('the payload reaches processing', () {
    testWidgets('a sensor session with a signal attempts a submission', (tester) async {
      final paths = <String>[];
      await _pumpProcessing(
        tester,
        MockClient((request) async {
          paths.add(request.url.path);
          return http.Response(jsonEncode({'patient_id': 'p'}), 200);
        }),
        signal: _accepted,
      );

      // It gets as far as resolving the session context, which is the first API call on the
      // submission path. Previously nothing was called at all.
      expect(paths, isNotEmpty);
      expect(paths.first, '/v1/auth/me');
    });

    testWidgets('a BP-only session submits nothing and moves on', (tester) async {
      final paths = <String>[];
      await _pumpProcessing(
        tester,
        MockClient((request) async {
          paths.add(request.url.path);
          return http.Response('{}', 200);
        }),
        mode: CheckMode.bpOnly,
        settle: false,
      );

      // The cuff reading was already filed by CuffReadingScreen; there is no capture to submit.
      //
      // Asserted against the submission endpoint rather than against "no request at all": a
      // BP-only check still owns a check session, so `ProcessingScreen` may reopen one it was not
      // handed, and its context is filed against it exactly as a sensor check's is. Neither is a
      // measurement.
      expect(paths, isNot(contains('/v1/sessions')));
      expect(paths.where((p) => p.contains('device-profiles')), isEmpty);
    });

    testWidgets('a 403 is shown as the contraindication, with no retry offered', (tester) async {
      await _pumpProcessing(
        tester,
        MockClient(
          (_) async => http.Response(
            jsonEncode({'detail': 'Method unvalidated in pregnancy. Please consult your doctor.'}),
            403,
          ),
        ),
        signal: _accepted,
      );

      expect(find.text('Tera cannot produce a trend'), findsOneWidget);
      expect(find.textContaining('Method unvalidated in pregnancy'), findsOneWidget);
      // Retrying will not help: the gate is doing its job.
      expect(find.text('Try again'), findsNothing);
      expect(find.text('Back to home'), findsOneWidget);
    });

    testWidgets('a network failure offers a retry rather than crashing', (tester) async {
      await _pumpProcessing(
        tester,
        MockClient((_) async => throw http.ClientException('offline')),
        signal: _accepted,
      );

      expect(find.text('Could not send'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('a 500 offers a retry', (tester) async {
      await _pumpProcessing(
        tester,
        MockClient((_) async => http.Response('boom', 500)),
        signal: _accepted,
      );

      expect(find.text('Could not send'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  });

  group('the PHR', () {
    test('every ONB-01 and ONB-03 field round-trips', () {
      final original = PhrProfile(
        dateOfBirth: DateTime.utc(1974, 3, 2),
        sexAtBirth: SexAtBirth.female,
        heightCm: 162,
        weightKg: 71.5,
        hypertension: HypertensionStatus.diagnosed,
        takesBpMedication: true,
        conditions: const {KnownCondition.diabetes, KnownCondition.highCholesterol},
      );

      final restored = PhrProfile.fromJson(original.toJson());

      expect(restored.dateOfBirth, DateTime.utc(1974, 3, 2));
      expect(restored.sexAtBirth, SexAtBirth.female);
      expect(restored.heightCm, 162);
      expect(restored.weightKg, 71.5);
      expect(restored.hypertension, HypertensionStatus.diagnosed);
      expect(restored.takesBpMedication, isTrue);
      expect(restored.conditions.length, 2);
    });

    test('a future date of birth is refused', () {
      final now = DateTime.utc(2026, 8, 12);
      expect(PhrProfile.dobIsPlausible(DateTime.utc(2027), now: now), isFalse);
      expect(PhrProfile.dobIsPlausible(DateTime.utc(1974), now: now), isTrue);
    });

    test('height and weight bounds catch a slipped decimal point', () {
      expect(PhrProfile.heightIsPlausible(1620), isFalse);
      expect(PhrProfile.heightIsPlausible(162), isTrue);
      expect(PhrProfile.weightIsPlausible(715), isFalse);
      expect(PhrProfile.weightIsPlausible(71.5), isTrue);
    });

    test('completeness is per-screen', () {
      const aboutOnly = PhrProfile(
        dateOfBirth: null,
        sexAtBirth: SexAtBirth.male,
      );
      expect(aboutOnly.aboutYouComplete, isFalse);

      final done = PhrProfile(dateOfBirth: DateTime.utc(1980), sexAtBirth: SexAtBirth.male);
      expect(done.aboutYouComplete, isTrue);
      expect(done.healthContextComplete, isFalse);
    });

    test('nothing derives a BMI', () {
      // The spec forbids it and invariant 6 forbids the class of thing. Height and weight are
      // stored and never combined.
      final json = PhrProfile(heightCm: 162, weightKg: 71.5).toJson();

      expect(json.keys, isNot(contains('bmi')));
      expect(json.keys.where((k) => k.contains('bmi')), isEmpty);
    });

    test('the store round-trips', () async {
      final store = InMemoryPhrProfileStore();
      expect((await store.read()).aboutYouComplete, isFalse);

      await store.write(
        PhrProfile(dateOfBirth: DateTime.utc(1980), sexAtBirth: SexAtBirth.female),
      );

      expect((await store.read()).sexAtBirth, SexAtBirth.female);
    });
  });

  group('the onboarding forms persist and advance', () {
    testWidgets('ONB-01 refuses to continue without the required fields', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final store = InMemoryPhrProfileStore();
      final flow = _flow(MockClient((_) async => http.Response('{}', 200)));
      await tester.pumpWidget(
        MaterialApp(
          onGenerateRoute: TeraRouter(flow).onGenerateRoute,
          home: AboutYouScreen(flow: flow, store: store),
        ),
      );

      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      // Both required answers are missing, so the refusal names both rather than saying
      // "complete the form".
      expect(find.textContaining('date of birth and sex assigned at birth'), findsOneWidget);
      expect((await store.read()).aboutYouComplete, isFalse);
      // The step is not advanced by a refused form.
      expect(flow.state.onboardingStep, OnboardingStep.aboutYou);
    });

    testWidgets('ONB-03 saves and advances onboarding to complete', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final store = InMemoryPhrProfileStore();
      final flow = _flow(
        MockClient((_) async => http.Response('{}', 200)),
        const AppFlowState(
          deviceEligibility: DeviceEligibility.eligible,
          onboardingStep: OnboardingStep.healthContext,
        ),
      );
      await flow.load();

      await tester.pumpWidget(
        MaterialApp(
          onGenerateRoute: TeraRouter(flow).onGenerateRoute,
          home: HealthContextScreen(flow: flow, store: store),
        ),
      );

      await tester.tap(find.text('Yes, diagnosed'));
      await tester.pumpAndSettle();

      // The medication question's "Yes". `.first` because ONB-03's condition list is below it
      // and the finder must not reach past the question being answered.
      await tester.tap(find.text('Yes').first);
      await tester.pumpAndSettle();

      // Section 7: an unanswered condition list is ambiguous, so one of the two exclusive rows
      // has to be chosen before the form will submit.
      await tester.scrollUntilVisible(find.text('None of these'), 200);
      await tester.tap(find.text('None of these'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Finish'));
      await tester.pumpAndSettle();

      final saved = await store.read();
      expect(saved.hypertension, HypertensionStatus.diagnosed);
      expect(saved.takesBpMedication, isTrue);
      expect(flow.state.onboardingComplete, isTrue);
      expect(flow.state.resumeRoute, Routes.home);
    });
  });
}


/// PRE-01 and the check session, which is what gives both modes somewhere to file to.
void _checkSessionTests() {
  group('the check session', () {
    test('is opened for a sensor check', () async {
      Map<String, dynamic>? body;
      final id = await CheckSessionClient(
        api: _api(
          MockClient((request) async {
            body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(jsonEncode({'id': 'cs-1'}), 201);
          }),
        ),
      ).open(episodeId: 'ep-1', mode: CheckMode.sensor);

      expect(id, 'cs-1');
      expect(body!['mode'], 'sensor');
      expect(body!['episode_id'], 'ep-1');
    });

    test('is opened for a BP-only check too', () async {
      Map<String, dynamic>? body;
      await CheckSessionClient(
        api: _api(
          MockClient((request) async {
            body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(jsonEncode({'id': 'cs-2'}), 201);
          }),
        ),
      ).open(episodeId: 'ep-1', mode: CheckMode.bpOnly);

      // The whole point: a BP-only check has a session, so PRE-01 and CTX-01 have somewhere to go.
      expect(body!['mode'], 'bp_only');
    });

    test('a failure to open throws rather than continuing silently', () async {
      // Everything downstream attaches to this id. A flow that carried on without one would
      // collect PRE-01 and CTX-01 into nothing.
      expect(
        () => CheckSessionClient(
          api: _api(MockClient((_) async => http.Response('nope', 403))),
        ).open(episodeId: 'ep-1', mode: CheckMode.sensor),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('PRE-01 submission', () {
    test('the five answers are posted against the check session', () async {
      Map<String, dynamic>? body;
      String? path;
      final ok = await CheckSessionClient(
        api: _api(
          MockClient((request) async {
            path = request.url.path;
            body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(jsonEncode({'id': 'p-1'}), 201);
          }),
        ),
      ).submitPreconditions(
        checkSessionId: 'cs-1',
        answers: const PrecheckAnswers(
          rested5Min: true,
          recentActivity30Min: false,
          recentCaffeine30Min: true,
          recentNicotine30Min: false,
          needsRestroom: false,
        ),
      );

      expect(ok, isTrue);
      expect(path, '/v1/check-sessions/cs-1/preconditions');
      expect(body!['rested_5_min'], true);
      expect(body!['recent_caffeine_30_min'], true);
    });

    test('is_ready is never sent — the server derives it', () async {
      Map<String, dynamic>? body;
      await CheckSessionClient(
        api: _api(
          MockClient((request) async {
            body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(jsonEncode({'id': 'p-1'}), 201);
          }),
        ),
      ).submitPreconditions(
        checkSessionId: 'cs-1',
        answers: const PrecheckAnswers(
          rested5Min: false,
          recentActivity30Min: true,
          recentCaffeine30Min: false,
          recentNicotine30Min: false,
          needsRestroom: false,
        ),
      );

      // Otherwise a client could declare itself ready while reporting a confounder.
      expect(body!.containsKey('is_ready'), isFalse);
    });

    test('a failure never throws — the flow has already branched locally', () async {
      final ok = await CheckSessionClient(
        api: _api(MockClient((_) async => http.Response('nope', 500))),
      ).submitPreconditions(
        checkSessionId: 'cs-1',
        answers: const PrecheckAnswers(
          rested5Min: true,
          recentActivity30Min: false,
          recentCaffeine30Min: false,
          recentNicotine30Min: false,
          needsRestroom: false,
        ),
      );

      expect(ok, isFalse);
    });
  });
}
