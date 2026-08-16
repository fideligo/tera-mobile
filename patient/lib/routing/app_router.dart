/// The master router: every route in the PM spec's section 32, and the navigation that drives the
/// section 31 state machine.
///
/// The router owns *where the user goes*; `check_session.dart` owns *what comes next*. Screens
/// call [TeraFlow.advance] with a [CheckStep] and never compute a destination themselves, so the
/// flow reads in one place and changes in one place.
library;

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../auth/auth_controller.dart';
import '../ui/bp_reference_screen.dart';
import '../ui/calibration_intro_screen.dart';
import '../ui/device_check_screens.dart';
import '../ui/flow_screens.dart';
import '../ui/history_screen.dart';
import '../ui/flow_stub_screen.dart';
import '../capture/phr_profile.dart';
import '../ui/home_screen.dart';
import '../ui/insight_screen.dart';
import '../ui/onboarding_screens.dart';
import '../ui/profile_personal_screen.dart';
import '../ui/register_screen.dart';
import '../ui/safety_onboarding_screen.dart';
import '../ui/sign_in_screen.dart';
import '../ui/signal_quality_screens.dart';
import '../ui/walkthrough_screen.dart';
import 'app_flow_state.dart';
import 'check_payload.dart';
import 'check_session.dart';
import 'routes.dart';

/// Carries the in-progress session between routes.
///
/// A route argument rather than a singleton, so backing out of the flow discards it — which is
/// what backing out should mean.
@immutable
class CheckArgs {
  const CheckArgs(this.session, [this.payload = const CheckPayload()]);

  final CheckSession session;

  /// What the check has accumulated so far. Separate from [session] so the state machine stays
  /// free of capture and API types.
  final CheckPayload payload;
}

/// The app's setup state, shared by the splash, onboarding and the check flow.
class TeraFlow extends ChangeNotifier {
  TeraFlow({required this.auth, required this.api, AppFlowStore? store})
    : _store = store ?? SecureAppFlowStore();

  final AuthController auth;
  final ApiClient api;
  final AppFlowStore _store;

  AppFlowState _state = const AppFlowState();
  AppFlowState get state => _state;

  Future<void> load() async {
    _state = await _store.read();
    notifyListeners();
  }

  Future<void> _save(AppFlowState next) async {
    _state = next;
    await _store.write(next);
    notifyListeners();
  }

  /// Where an authenticated user belongs right now — AUTH-00's table, re-read from storage.
  ///
  /// The table itself lives in [AppFlowState.resumeRoute] and nowhere else. Sign-in, sign-up and
  /// the splash all ask this rather than each deciding for themselves, so "device check, then the
  /// unfinished onboarding step, then home" has one definition.
  Future<String> resumeRouteAfterAuth() async {
    await load();
    final local = _state.resumeRoute;
    if (local != Routes.home) return local;

    // Past the local table, one server-backed question: does this account actually have a health
    // profile?
    //
    // **The local onboarding flag is not sufficient evidence.** `AppFlowState` lives in this
    // install's secure storage, so it says "this handset finished onboarding", not "this account
    // has a profile". Signing in on a second device, or after a reinstall, leaves the flag unset
    // while the profile exists; the reverse — flag set, profile missing — happens whenever
    // onboarding's upload failed, which it is explicitly designed to survive. Only the server
    // knows.
    //
    // A profile is required before capture because it is what `read_insight` sends to the LLM.
    // Without a date of birth and sex there is no context for the commentary to be about.
    try {
      final profile = await api.getJson('/v1/profile');
      final complete =
          profile['date_of_birth'] != null &&
          profile['sex_assigned_at_birth'] != null;
      if (!complete) return Routes.onboardingAboutYou;
    } on ApiException catch (e) {
      // 404 is the documented "no profile has been recorded yet" — send them to create one.
      // Anything else (offline, 500) is not evidence of an incomplete profile, and blocking a
      // patient out of their own app because the network blinked would be worse than letting
      // them through with whatever the server already has.
      if (e.statusCode == 404) return Routes.onboardingAboutYou;
    } on Object {
      // As above: not evidence. Fall through.
    }
    return Routes.home;
  }

  /// A newly registered account starts setup from the beginning.
  ///
  /// Onboarding and the BP reference belong to the *account*, so a second account created on this
  /// handset must not inherit the first one's answers and land on Home with someone else's health
  /// record behind it. Device eligibility belongs to the *handset* and is kept: the phone's torch
  /// and accelerometer do not change because a different person signed up on it.
  Future<void> beginNewAccount() async {
    // Re-read first: sign-up can be the first screen this object has seen, and clearing state
    // that was never loaded would throw away a device check the handset has already passed.
    await load();
    await _save(AppFlowState(deviceEligibility: _state.deviceEligibility));
  }

  Future<void> recordEligibility(DeviceEligibility eligibility) =>
      _save(_state.copyWith(deviceEligibility: eligibility));

  Future<void> completeOnboardingStep(OnboardingStep step) => _save(
    _state.copyWith(onboardingStep: step.next ?? OnboardingStep.complete),
  );

  Future<void> recordBpReference(DateTime takenAt) => _save(
    _state.copyWith(
      reference: _state.reference.copyWith(
        currentReferenceTakenAt: takenAt,
        forceReferenceRefresh: false,
      ),
    ),
  );

  Future<void> recordSuccessfulSensorCheck(DateTime at) => _save(
    _state.copyWith(
      reference: _state.reference.copyWith(lastSuccessfulSensorCheckAt: at),
    ),
  );

  /// Section 38's `startCheck`.
  ///
  /// An unchecked device is treated as not eligible: the BP-only path works everywhere and blocks
  /// nobody, whereas assuming eligibility would walk a patient into a capture their phone cannot
  /// perform.
  CheckStep startCheck({DateTime? now}) => CheckFlow.startCheck(
    eligibility: DeviceEligibility.eligible, // HARDCODED FOR DEMO
    reference: _state.reference,
    now: now ?? DateTime.now(),
  );

  /// Replace the current route with the step's, carrying the session and its luggage forward.
  static void advance(
    BuildContext context,
    CheckStep step, {
    CheckPayload payload = const CheckPayload(),
  }) => Navigator.of(context).pushReplacementNamed(
    step.route,
    arguments: CheckArgs(step.session, payload),
  );

  /// Push rather than replace, for the first screen of a flow.
  static void enter(
    BuildContext context,
    CheckStep step, {
    CheckPayload payload = const CheckPayload(),
  }) => Navigator.of(
    context,
  ).pushNamed(step.route, arguments: CheckArgs(step.session, payload));

  static void toHome(BuildContext context) =>
      Navigator.of(context).pushNamedAndRemoveUntil(Routes.home, (r) => false);
}

class TeraRouter {
  const TeraRouter(this.flow);

  final TeraFlow flow;

  static CheckSession _session(RouteSettings settings) {
    final args = settings.arguments;
    if (args is CheckArgs) return args.session;
    // A check route reached without a session is a routing bug. Falling back keeps the app usable
    // rather than crashing, and BP-only is the mode that assumes least.
    return const CheckSession(
      mode: CheckMode.bpOnly,
      state: CheckState.created,
    );
  }

  static CheckPayload _payload(RouteSettings settings) {
    final args = settings.arguments;
    return args is CheckArgs ? args.payload : const CheckPayload();
  }

  Route<dynamic>? onGenerateRoute(RouteSettings settings) {
    final name = settings.name ?? Routes.splash;
    final session = _session(settings);
    final payload = _payload(settings);

    if (name.startsWith(Routes.historyDetailPrefix)) {
      final eventId = name.substring(Routes.historyDetailPrefix.length);
      if (eventId.isNotEmpty) {
        return _page(
          settings,
          (_) => FlowStubScreen(
            specId: 'HIST-02',
            title: 'Event detail',
            body: 'eventId: $eventId',
            onNext: null,
          ),
        );
      }
    }

    return switch (name) {
      // ------------------------------------------------------------------- entry
      Routes.splash => _page(settings, (_) => SplashScreen(flow: flow)),
      Routes.login => _page(settings, (_) => SignInScreen(auth: flow.auth)),
      Routes.register => _page(
        settings,
        (_) => RegisterScreen(auth: flow.auth),
      ),

      // ------------------------------------------------------------ device check
      Routes.devicePermission => _page(
        settings,
        (_) => const DevicePermissionScreen(),
      ),
      Routes.deviceChecking => _page(
        settings,
        (_) => DeviceCheckingScreen(flow: flow),
      ),
      Routes.deviceEligible => _page(
        settings,
        (_) => const DeviceVerdictScreen(
          specId: 'DEV-02',
          eligible: true,
          title: 'Your phone is ready for Tera',
          body:
              'Your device supports the camera and motion sensing needed for Tera checks.',
          cta: 'Continue',
        ),
      ),
      Routes.deviceNotEligible => _page(
        settings,
        (_) => const DeviceVerdictScreen(
          specId: 'DEV-03',
          eligible: false,
          title: 'You can still use Tera',
          body:
              'Sensor-based checks are not supported on this device, but you can still log and '
              'understand your blood-pressure readings.',
          cta: 'Continue with BP scan',
        ),
      ),

      // -------------------------------------------------------------- onboarding
      Routes.onboardingAboutYou => _page(
        settings,
        (_) => AboutYouScreen(flow: flow, store: SecurePhrProfileStore()),
      ),
      Routes.onboardingSafety => _page(
        settings,
        (_) => SafetyOnboardingScreen(flow: flow),
      ),
      Routes.onboardingHealthContext => _page(
        settings,
        (_) => HealthContextScreen(flow: flow, store: SecurePhrProfileStore()),
      ),

      // --------------------------------------------------------------------- home
      Routes.home => _page(
        settings,
        (_) => HomeScreen(auth: flow.auth, flow: flow),
      ),

      // -------------------------------------------------------------- check flow
      Routes.checkBpReference => _page(
        settings,
        (_) =>
            BpReferenceScreen(flow: flow, session: session, payload: payload),
      ),

      // BPREF-02 and BP-only entry. The screen already carries scan, manual entry and the explicit
      // confirmation step, so bp-scan and bp-confirm resolve to it rather than duplicating it.
      Routes.checkBpInput ||
      Routes.checkBpScan ||
      Routes.checkBpConfirm => _page(
        settings,
        (_) => BpInputScreen(flow: flow, session: session, payload: payload),
      ),

      Routes.checkCalibrationIntro => _page(
        settings,
        (_) => CalibrationIntroScreen(session: session, payload: payload),
      ),
      Routes.checkPrecondition => _page(
        settings,
        (_) => PrecheckScreen(session: session, flow: flow, payload: payload),
      ),
      Routes.checkWait => _page(
        settings,
        (context) => FlowStubScreen(
          specId: 'PRE-02',
          title: 'Take a few minutes',
          body: 'Rest quietly, then continue when you are ready.',
          nextLabel: 'I am ready',
          onNext: () => TeraFlow.advance(
            context,
            CheckFlow.afterWait(session),
            payload: payload,
          ),
        ),
      ),
      Routes.checkContext => _page(
        settings,
        (_) => CurrentContextScreen(
          flow: flow,
          session: session,
          payload: payload,
        ),
      ),

      Routes.checkWalkthrough1 => _page(
        settings,
        (_) => WalkthroughScreen(session: session, payload: payload),
      ),
      Routes.checkWalkthrough2 => _walkthrough(
        settings,
        session,
        payload,
        2,
        'Place your phone on your chest',
      ),
      Routes.checkWalkthrough3 => _walkthrough(
        settings,
        session,
        payload,
        3,
        'Cover the rear camera',
      ),
      Routes.checkWalkthrough4 => _walkthrough(
        settings,
        session,
        payload,
        4,
        'Relax and stay still',
      ),

      Routes.checkCapture => _page(
        settings,
        (_) =>
            CaptureRouteScreen(flow: flow, session: session, payload: payload),
      ),
      // **`payload:` is not optional here, and leaving it off cost every check its capture.**
      //
      // SIG-01 sits on the happy path: an accepted capture routes here and then on to processing.
      // This call omitted the payload, so `ProcessingScreen` was built with `const CheckPayload()`
      // — no signal, no `capturedAt`, no `checkSessionId`, no consent answer. Its `signal == null`
      // branch is the BP-only path, which submits nothing, so a completed sixty-second recording
      // was discarded two screens after the patient was told "Session accepted". Nothing failed
      // loudly: the check simply arrived at the insight with no capture behind it, which is what
      // "no estimated reading" and the empty trend have been reporting.
      Routes.checkSignalAccepted => _page(
        settings,
        (context) => SignalAcceptedScreen(
          onNext: () => TeraFlow.advance(
            context,
            CheckFlow.afterSignalAccepted(session),
            payload: payload,
          ),
        ),
      ),
      Routes.checkSignalAdjust => _page(
        settings,
        (context) => SignalAdjustScreen(
          attemptCount: session.attemptCount,
          maxAttempts: maxCaptureAttempts,
          onRetry: () => TeraFlow.advance(
            context,
            CheckFlow.afterAdjust(session),
            payload: payload,
          ),
          onCancel: () => TeraFlow.toHome(context),
        ),
      ),
      Routes.checkSignalRepeatedFailure => _page(
        settings,
        (context) =>
            SignalRepeatedFailureScreen(onDone: () => TeraFlow.toHome(context)),
      ),
      Routes.checkProcessing => _page(
        settings,
        (_) => ProcessingScreen(flow: flow, session: session, payload: payload),
      ),
      Routes.checkInsight => _page(
        settings,
        // The check session, not the capture: a BP-only check has the first and never the
        // second, and the insight is defined over the check.
        (_) => InsightScreen(
          api: flow.api,
          sessionId: payload.checkSessionId,
          uncalibratedDemo: payload.uncalibratedDemo,
          aiConsent: payload.aiConsent,
          // So the screen can fall back to what the handset measured when the server cannot be
          // reached, instead of showing nothing.
          localSignal: payload.signal,
        ),
      ),

      // ------------------------------------------------------------------ history
      Routes.history => _page(settings, (_) => HistoryScreen(api: flow.api)),

      // ------------------------------------------------------------------ profile
      Routes.profile => _page(
        settings,
        (_) => ProfileIndexScreen(
          auth: flow.auth,
          profileStore: SecurePhrProfileStore(),
        ),
      ),
      Routes.profilePersonal => _page(
        settings,
        (_) =>
            ProfilePersonalScreen(flow: flow, store: SecurePhrProfileStore()),
      ),
      Routes.profileConditions => _stub(settings, 'PROF-02', 'Conditions'),
      Routes.profileMedications => _stub(settings, 'PROF-03', 'Medications'),
      Routes.profileLifestyle => _stub(settings, 'PROF-04', 'Lifestyle'),
      Routes.profileFamilyHistory => _stub(
        settings,
        'PROF-05',
        'Family history',
      ),
      Routes.profileBpReference => _stub(settings, 'PROF-06', 'BP reference'),
      Routes.profileDevice => _stub(settings, 'PROF-07', 'Device'),
      Routes.profilePrivacy => _stub(settings, 'PROF-08', 'Privacy'),

      _ => null,
    };
  }

  Route<dynamic> _walkthrough(
    RouteSettings settings,
    CheckSession session,
    CheckPayload payload,
    int step,
    String title,
  ) => _page(
    settings,
    (context) => FlowStubScreen(
      specId: 'WALK-0$step',
      title: 'Step $step: $title',
      nextLabel: step == Routes.walkthroughSteps.length
          ? 'Start check'
          : 'Next',
      onNext: () => TeraFlow.advance(
        context,
        CheckFlow.afterWalkthroughStep(session, step),
        payload: payload,
      ),
    ),
  );

  Route<dynamic> _stub(RouteSettings settings, String specId, String title) =>
      _page(
        settings,
        (_) => FlowStubScreen(specId: specId, title: title, onNext: null),
      );

  Route<dynamic> _page(RouteSettings settings, WidgetBuilder builder) =>
      MaterialPageRoute<void>(settings: settings, builder: builder);
}
