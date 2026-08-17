/// The router, driven through a real Navigator.
///
/// `check_flow_test.dart` proves the state machine picks the right route. This proves the routes
/// resolve to screens and that walking them lands where the machine says.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tera_patient/api/api_client.dart';
import 'package:tera_patient/auth/auth_controller.dart';
import 'package:tera_patient/auth/token_store.dart';
import 'package:tera_patient/routing/app_flow_state.dart';
import 'package:tera_patient/routing/app_router.dart';
import 'package:tera_patient/routing/check_payload.dart';
import 'package:tera_patient/routing/check_session.dart';
import 'package:tera_patient/routing/routes.dart';
import 'package:tera_patient/signal/signal_pipeline.dart';
import 'package:tera_patient/capture/eligibility_check.dart';
import 'package:tera_patient/ui/cuff_reading_screen.dart';
import 'package:tera_patient/ui/device_check_screens.dart';
import 'package:tera_patient/ui/flow_screens.dart';
import 'package:tera_patient/ui/flow_stub_screen.dart';
import 'package:tera_patient/ui/signal_quality_screens.dart';
import 'package:tera_patient/ui/walkthrough_screen.dart';

TeraFlow _flow(AppFlowState state) {
  final api = ApiClient(
    baseUrl: 'http://test',
    tokenStore: InMemoryTokenStore(),
    httpClient: MockClient((_) async => http.Response('{}', 200)),
    onSessionLost: () {},
  );
  return TeraFlow(
    auth: AuthController(api: api),
    api: api,
    store: InMemoryAppFlowStore(state),
  );
}

Future<void> _pump(
  WidgetTester tester,
  TeraFlow flow, {
  required String initialRoute,
  CheckSession? session,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final router = TeraRouter(flow);
  await tester.pumpWidget(
    MaterialApp(
      onGenerateRoute: (settings) => router.onGenerateRoute(
        session == null
            ? settings
            : RouteSettings(name: settings.name, arguments: CheckArgs(session)),
      ),
      initialRoute: initialRoute,
    ),
  );
  await tester.pumpAndSettle();
}

/// Finds a screen by the spec section it implements.
///
/// The spec id used to be the app-bar title, so these tests read it from there. It is a [Key] now
/// — a patient reading "PROF-04" above their own record learns nothing — so the lookup goes
/// through [screenKey] instead. That is also the more durable assertion: a routing test should not
/// break because someone improved a heading.
Finder _screen(String specId) => find.byKey(screenKey(specId));

/// Answer all five PRE-01 questions.
///
/// The screen requires every one of them before Next enables — it no longer defaults to the ideal
/// state, because a defaulted answer is an answer nobody gave, and PRE-01 feeds the insight's
/// comparability rows. The five render in order (rested, activity, caffeine, nicotine, restroom)
/// with a Yes/No pair each, so they are addressed by position.
Future<void> _answerPrecheck(
  WidgetTester tester, {
  bool rested = true,
  bool activity = false,
  bool caffeine = false,
  bool nicotine = false,
  bool restroom = false,
}) async {
  // Each question renders exactly one 'Yes' and one 'No', so both finders are indexed by the
  // question's position — not by how many of each have been tapped.
  final answers = [rested, activity, caffeine, nicotine, restroom];
  for (var i = 0; i < answers.length; i++) {
    await tester.tap(find.text(answers[i] ? 'Yes' : 'No').at(i));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  group('every route in section 32 resolves', () {
    testWidgets('no route in the table returns null', (tester) async {
      final router = TeraRouter(_flow(const AppFlowState()));

      const every = [
        Routes.splash,
        Routes.login,
        Routes.register,
        Routes.deviceChecking,
        Routes.deviceEligible,
        Routes.deviceNotEligible,
        Routes.onboardingAboutYou,
        Routes.onboardingSafety,
        Routes.onboardingHealthContext,
        Routes.home,
        Routes.checkBpReference,
        Routes.checkBpInput,
        Routes.checkBpScan,
        Routes.checkBpConfirm,
        Routes.checkPrecondition,
        Routes.checkWait,
        Routes.checkContext,
        Routes.checkWalkthrough1,
        Routes.checkWalkthrough2,
        Routes.checkWalkthrough3,
        Routes.checkWalkthrough4,
        Routes.checkCapture,
        Routes.checkSignalAccepted,
        Routes.checkSignalAdjust,
        Routes.checkSignalRepeatedFailure,
        Routes.checkProcessing,
        Routes.checkInsight,
        Routes.history,
        Routes.profile,
        Routes.profilePersonal,
        Routes.profileConditions,
        Routes.profileMedications,
        Routes.profileLifestyle,
        Routes.profileFamilyHistory,
        Routes.profileBpReference,
        Routes.profileDevice,
        Routes.profilePrivacy,
      ];

      for (final route in every) {
        expect(
          router.onGenerateRoute(RouteSettings(name: route)),
          isNotNull,
          reason: '$route has no screen',
        );
      }
    });

    testWidgets('a parameterised history route resolves and carries its id', (tester) async {
      await _pump(
        tester,
        _flow(const AppFlowState()),
        initialRoute: Routes.historyDetailFor('evt-123'),
      );

      expect(_screen('HIST-02'), findsOneWidget);
      expect(find.textContaining('evt-123'), findsOneWidget);
    });

    testWidgets('an unknown route is not claimed', (tester) async {
      final router = TeraRouter(_flow(const AppFlowState()));

      expect(
        router.onGenerateRoute(const RouteSettings(name: '/nope')),
        isNull,
      );
    });
  });

  group('the sensor path walks end to end', () {
    testWidgets('pre-check ready, context, four walkthrough steps, capture', (tester) async {
      const session = CheckSession(mode: CheckMode.sensor, state: CheckState.precheck);
      await _pump(
        tester,
        _flow(const AppFlowState(deviceEligibility: DeviceEligibility.eligible)),
        initialRoute: Routes.checkPrecondition,
        session: session,
      );

      expect(find.byType(PrecheckScreen), findsOneWidget);

      // The ideal state, answered rather than assumed.
      await _answerPrecheck(tester);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.byType(CurrentContextScreen), findsOneWidget);

      // Not the cuff intro: this session is not a first run, so calibration is not asked for.
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.byType(WalkthroughScreen), findsOneWidget);

      // WALK-01 to WALK-04 are now four pages of one screen rather than four routes. The
      // `/check/walkthrough/2..4` routes still resolve — the table above proves it — but the flow
      // no longer visits them, so this walks the pages the patient actually sees.
      for (var page = 0; page < 3; page++) {
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
        expect(find.byType(WalkthroughScreen), findsOneWidget);
      }

      // The last step starts the check rather than continuing.
      expect(find.text('Start Check'), findsOneWidget);
      await tester.tap(find.text('Start Check'));
      await tester.pumpAndSettle();

      // Capture, which opens on its own instruction step rather than the camera.
      expect(find.byType(CaptureRouteScreen), findsOneWidget);
    });

    testWidgets('a non-ideal pre-check diverts to the wait screen and back', (tester) async {
      const session = CheckSession(mode: CheckMode.sensor, state: CheckState.precheck);
      await _pump(
        tester,
        _flow(const AppFlowState(deviceEligibility: DeviceEligibility.eligible)),
        initialRoute: Routes.checkPrecondition,
        session: session,
      );

      // Report caffeine in the last 30 minutes.
      await _answerPrecheck(tester, caffeine: true);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      expect(_screen('PRE-02'), findsOneWidget);

      await tester.tap(find.text('I am ready'));
      await tester.pumpAndSettle();

      // Section 31: Waiting returns to Precheck, not onward to Context.
      expect(find.byType(PrecheckScreen), findsOneWidget);
      expect(find.byType(CurrentContextScreen), findsNothing);
    });
  });

  group('the BP-only path forks at context', () {
    testWidgets('context goes to BP input rather than the walkthrough', (tester) async {
      const session = CheckSession(mode: CheckMode.bpOnly, state: CheckState.context);
      await _pump(
        tester,
        _flow(const AppFlowState(deviceEligibility: DeviceEligibility.notEligible)),
        initialRoute: Routes.checkContext,
        session: session,
      );

      expect(find.byType(CurrentContextScreen), findsOneWidget);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      // The real cuff screen, not a walkthrough step and not a stub.
      expect(find.byType(CuffReadingScreen), findsOneWidget);
      expect(find.byType(WalkthroughScreen), findsNothing);
    });
  });

  group('the repeated-failure fork', () {
    testWidgets('the adjust screen names the attempt and offers a retry', (tester) async {
      const session = CheckSession(
        mode: CheckMode.sensor,
        state: CheckState.capture,
        attemptCount: 2,
      );
      await _pump(
        tester,
        _flow(const AppFlowState(deviceEligibility: DeviceEligibility.eligible)),
        initialRoute: Routes.checkSignalAdjust,
        session: session,
      );

      expect(find.byType(SignalAdjustScreen), findsOneWidget);
      expect(find.textContaining('2 of 3'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('repeated failure ends the flow rather than offering another attempt', (
      tester,
    ) async {
      const session = CheckSession(
        mode: CheckMode.sensor,
        state: CheckState.failedQuality,
        attemptCount: 3,
      );
      await _pump(
        tester,
        _flow(const AppFlowState(deviceEligibility: DeviceEligibility.eligible)),
        initialRoute: Routes.checkSignalRepeatedFailure,
        session: session,
      );

      expect(find.byType(SignalRepeatedFailureScreen), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
      expect(find.text('Take a break'), findsOneWidget);
    });
  });

  group('a check route reached without a session does not crash', () {
    testWidgets('it falls back to BP-only, the mode that assumes least', (tester) async {
      await _pump(
        tester,
        _flow(const AppFlowState(deviceEligibility: DeviceEligibility.eligible)),
        initialRoute: Routes.checkContext,
      );

      expect(find.byType(CurrentContextScreen), findsOneWidget);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      // BP-only: the cuff screen, not the walkthrough.
      expect(find.byType(CuffReadingScreen), findsOneWidget);
      expect(find.byType(WalkthroughScreen), findsNothing);
    });
  });

  group('AUTH-00 resume points', () {
    testWidgets('an unchecked device resolves to the device check', (tester) async {
      const state = AppFlowState();
      final flow = _flow(state);
      final router = TeraRouter(flow);

      // The screen itself runs the real sensor gate, which a test has no camera for. Asserting
      // the route resolves is the routing claim; the gate has its own tests.
      expect(router.onGenerateRoute(RouteSettings(name: state.resumeRoute)), isNotNull);
      expect(state.resumeRoute, Routes.devicePermission);
    });

    testWidgets('the device check records the verdict and routes on it', (tester) async {
      final flow = _flow(const AppFlowState());
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final router = TeraRouter(flow);
      await tester.pumpWidget(
        MaterialApp(
          onGenerateRoute: router.onGenerateRoute,
          home: DeviceCheckingScreen(
            flow: flow,
            probe: () async => const EligibilityResult(
              verdict: EligibilityVerdict.notQualified,
              headline: 'no',
              detail: 'no torch',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // A refused handset is recorded as not eligible, and the account is not blocked: the flow
      // continues into onboarding by way of DEV-03.
      expect(flow.state.deviceEligibility, DeviceEligibility.notEligible);
    });

    testWidgets('an incomplete onboarding resumes at its own step', (tester) async {
      const state = AppFlowState(
        deviceEligibility: DeviceEligibility.eligible,
        onboardingStep: OnboardingStep.healthContext,
      );
      await _pump(tester, _flow(state), initialRoute: state.resumeRoute);

      expect(_screen('ONB-03'), findsOneWidget);
    });
  });

  group('the capture survives the screens between it and submission', () {
    testWidgets('SIG-01 hands the payload on rather than dropping it', (
      tester,
    ) async {
      // **The regression this exists for.** SIG-01 sits on the happy path: an accepted capture
      // routes here, waits two seconds, and advances to processing. That advance was made without
      // a `payload:` argument, so the next route was built with a default `CheckPayload` — no
      // signal, no `capturedAt`, no `checkSessionId`, no consent answer.
      //
      // Nothing failed loudly. `ProcessingScreen` treats a null signal as the BP-only path, which
      // submits nothing, so every completed sixty-second recording was discarded two screens
      // after the patient was told "Session accepted" — and the insight then had no capture to
      // report on, which is what "no estimated reading" has been saying.
      const captured = CheckPayload(
        checkSessionId: 'check-session-under-test',
        signal: SignalResult(
          accepted: true,
          pttMs: [240, 241, 242],
          nBeatsTotal: 3,
          nBeatsUsable: 3,
          quality: {},
        ),
      );

      CheckPayload? handedOn;
      final router = TeraRouter(_flow(const AppFlowState()));

      await tester.pumpWidget(
        MaterialApp(
          onGenerateRoute: (settings) {
            // Stop at processing rather than building it: that screen opens the network and the
            // pending-capture store on `initState`, and what is under test is the handover.
            if (settings.name == Routes.checkProcessing) {
              final args = settings.arguments;
              if (args is CheckArgs) handedOn = args.payload;
              return MaterialPageRoute<void>(
                settings: settings,
                builder: (_) => const SizedBox.shrink(),
              );
            }
            return router.onGenerateRoute(settings);
          },
          initialRoute: Routes.checkSignalAccepted,
          onGenerateInitialRoutes: (name) => [
            router.onGenerateRoute(
              RouteSettings(
                name: name,
                arguments: CheckArgs(
                  const CheckSession(
                    mode: CheckMode.sensor,
                    state: CheckState.processing,
                  ),
                  captured,
                ),
              ),
            )!,
          ],
        ),
      );

      // SIG-01 advances itself after two seconds.
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      expect(
        handedOn,
        isNotNull,
        reason: 'SIG-01 never advanced to processing',
      );
      expect(handedOn!.checkSessionId, 'check-session-under-test');
      expect(
        handedOn!.signal?.pttMs,
        isNotEmpty,
        reason: 'the capture must reach the screen that submits it',
      );
    });
  });
}
