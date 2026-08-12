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
import '../ui/flow_screens.dart';
import '../ui/flow_stub_screen.dart';
import '../ui/home_screen.dart';
import '../ui/sign_in_screen.dart';
import 'app_flow_state.dart';
import 'check_session.dart';
import 'routes.dart';

/// Carries the in-progress session between routes.
///
/// A route argument rather than a singleton, so backing out of the flow discards it — which is
/// what backing out should mean.
@immutable
class CheckArgs {
  const CheckArgs(this.session);

  final CheckSession session;
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

  Future<void> recordEligibility(DeviceEligibility eligibility) =>
      _save(_state.copyWith(deviceEligibility: eligibility));

  Future<void> completeOnboardingStep(OnboardingStep step) =>
      _save(_state.copyWith(onboardingStep: step.next ?? OnboardingStep.complete));

  Future<void> recordBpReference(DateTime takenAt) => _save(
    _state.copyWith(
      reference: _state.reference.copyWith(
        currentReferenceTakenAt: takenAt,
        forceReferenceRefresh: false,
      ),
    ),
  );

  Future<void> recordSuccessfulSensorCheck(DateTime at) => _save(
    _state.copyWith(reference: _state.reference.copyWith(lastSuccessfulSensorCheckAt: at)),
  );

  /// Section 38's `startCheck`.
  ///
  /// An unchecked device is treated as not eligible: the BP-only path works everywhere and blocks
  /// nobody, whereas assuming eligibility would walk a patient into a capture their phone cannot
  /// perform.
  CheckStep startCheck({DateTime? now}) => CheckFlow.startCheck(
    eligibility: _state.deviceEligibility ?? DeviceEligibility.notEligible,
    reference: _state.reference,
    now: now ?? DateTime.now(),
  );

  /// Replace the current route with the step's, carrying the session forward.
  static void advance(BuildContext context, CheckStep step) =>
      Navigator.of(context).pushReplacementNamed(step.route, arguments: CheckArgs(step.session));

  /// Push rather than replace, for the first screen of a flow.
  static void enter(BuildContext context, CheckStep step) =>
      Navigator.of(context).pushNamed(step.route, arguments: CheckArgs(step.session));

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
    return const CheckSession(mode: CheckMode.bpOnly, state: CheckState.created);
  }

  Route<dynamic>? onGenerateRoute(RouteSettings settings) {
    final name = settings.name ?? Routes.splash;
    final session = _session(settings);

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
        (context) => FlowStubScreen(
          specId: 'AUTH-01',
          title: 'Register',
          body: 'Self-registration posts to /v1/auth/register-patient.',
          nextLabel: 'Back to login',
          onNext: () => Navigator.of(context).pop(),
        ),
      ),

      // ------------------------------------------------------------ device check
      Routes.deviceChecking => _page(settings, (_) => DeviceCheckScreen(flow: flow)),
      Routes.deviceEligible => _page(
        settings,
        (_) => const DeviceVerdictScreen(
          specId: 'DEV-02',
          title: 'Your phone is ready for Tera',
          body: 'Your device supports the camera and motion sensing needed for Tera checks.',
          cta: 'Continue',
        ),
      ),
      Routes.deviceNotEligible => _page(
        settings,
        (_) => const DeviceVerdictScreen(
          specId: 'DEV-03',
          title: 'You can still use Tera',
          body:
              'Sensor-based checks are not supported on this device, but you can still log and '
              'understand your blood-pressure readings.',
          cta: 'Continue with BP checks',
        ),
      ),

      // -------------------------------------------------------------- onboarding
      Routes.onboardingAboutYou => _page(
        settings,
        (_) => OnboardingStubScreen(
          flow: flow,
          step: OnboardingStep.aboutYou,
          specId: 'ONB-01',
          title: 'About you',
          body: 'Date of birth, sex assigned at birth, height, weight.',
        ),
      ),
      // ONB-02 is the safety gate already built: the pregnancy hard stop and the rhythm question
      // live in ContextIntakeScreen, so the route points at the real screen.
      Routes.onboardingSafety => _page(settings, (_) => SafetyOnboardingScreen(flow: flow)),
      Routes.onboardingHealthContext => _page(
        settings,
        (_) => OnboardingStubScreen(
          flow: flow,
          step: OnboardingStep.healthContext,
          specId: 'ONB-03',
          title: 'Health context',
          body: 'Hypertension diagnosis, medication, other conditions.',
        ),
      ),

      // --------------------------------------------------------------------- home
      Routes.home => _page(settings, (_) => HomeScreen(auth: flow.auth, flow: flow)),

      // -------------------------------------------------------------- check flow
      Routes.checkBpReference => _page(
        settings,
        (context) => FlowStubScreen(
          specId: 'BPREF-01',
          title: 'Set your blood pressure reference',
          body:
              'Tera uses a recent blood pressure reading as a personal reference for your '
              'BP-related trend. Rest quietly for 5 minutes first.',
          onNext: () => Navigator.of(
            context,
          ).pushReplacementNamed(Routes.checkBpInput, arguments: CheckArgs(session)),
        ),
      ),

      // BPREF-02 and BP-only entry. The screen already carries scan, manual entry and the explicit
      // confirmation step, so bp-scan and bp-confirm resolve to it rather than duplicating it.
      Routes.checkBpInput ||
      Routes.checkBpScan ||
      Routes.checkBpConfirm => _page(
        settings,
        (_) => BpInputScreen(flow: flow, session: session),
      ),

      Routes.checkPrecondition => _page(settings, (_) => PrecheckScreen(session: session)),
      Routes.checkWait => _page(
        settings,
        (context) => FlowStubScreen(
          specId: 'PRE-02',
          title: 'Take a few minutes',
          body: 'Rest quietly, then continue when you are ready.',
          nextLabel: 'I am ready',
          onNext: () => TeraFlow.advance(context, CheckFlow.afterWait(session)),
        ),
      ),
      Routes.checkContext => _page(settings, (_) => CurrentContextScreen(session: session)),

      Routes.checkWalkthrough1 => _walkthrough(settings, session, 1, 'Sit comfortably'),
      Routes.checkWalkthrough2 => _walkthrough(
        settings,
        session,
        2,
        'Place your phone on your chest',
      ),
      Routes.checkWalkthrough3 => _walkthrough(settings, session, 3, 'Cover the rear camera'),
      Routes.checkWalkthrough4 => _walkthrough(settings, session, 4, 'Relax and stay still'),

      Routes.checkCapture => _page(
        settings,
        (_) => CaptureRouteScreen(flow: flow, session: session),
      ),
      Routes.checkSignalAccepted => _page(
        settings,
        (context) => FlowStubScreen(
          specId: 'SIG-01',
          title: 'Session accepted',
          body: 'Signal quality was good.',
          onNext: () => TeraFlow.advance(context, CheckFlow.afterProcessing(session)),
        ),
      ),
      Routes.checkSignalAdjust => _page(
        settings,
        (context) => FlowStubScreen(
          specId: 'SIG-02',
          title: 'Let us adjust your position',
          body: 'Attempt ${session.attemptCount} of $maxCaptureAttempts.',
          nextLabel: 'Try again',
          onNext: () => TeraFlow.advance(context, CheckFlow.afterAdjust(session)),
          secondaryLabel: 'Back to home',
          onSecondary: () => TeraFlow.toHome(context),
        ),
      ),
      Routes.checkSignalRepeatedFailure => _page(
        settings,
        (context) => FlowStubScreen(
          specId: 'SIG-03',
          title: '$maxCaptureAttempts unsuccessful attempts',
          body: 'A few sessions have not come through clearly.',
          nextLabel: 'Back to home',
          onNext: () => TeraFlow.toHome(context),
        ),
      ),
      Routes.checkProcessing => _page(
        settings,
        (_) => ProcessingScreen(flow: flow, session: session),
      ),
      Routes.checkInsight => _page(
        settings,
        (context) => FlowStubScreen(
          specId: 'INS-01',
          title: 'Your insight',
          body: 'Deterministic rule engine plus language layer. Not a diagnosis.',
          nextLabel: 'Done',
          onNext: () => TeraFlow.toHome(context),
        ),
      ),

      // ------------------------------------------------------------------ history
      Routes.history => _page(
        settings,
        (_) => const FlowStubScreen(specId: 'HIST-01', title: 'History', onNext: null),
      ),

      // ------------------------------------------------------------------ profile
      Routes.profile => _page(settings, (_) => const ProfileIndexScreen()),
      Routes.profilePersonal => _stub(settings, 'PROF-01', 'Personal'),
      Routes.profileConditions => _stub(settings, 'PROF-02', 'Conditions'),
      Routes.profileMedications => _stub(settings, 'PROF-03', 'Medications'),
      Routes.profileLifestyle => _stub(settings, 'PROF-04', 'Lifestyle'),
      Routes.profileFamilyHistory => _stub(settings, 'PROF-05', 'Family history'),
      Routes.profileBpReference => _stub(settings, 'PROF-06', 'BP reference'),
      Routes.profileDevice => _stub(settings, 'PROF-07', 'Device'),
      Routes.profilePrivacy => _stub(settings, 'PROF-08', 'Privacy'),

      _ => null,
    };
  }

  Route<dynamic> _walkthrough(
    RouteSettings settings,
    CheckSession session,
    int step,
    String title,
  ) => _page(
    settings,
    (context) => FlowStubScreen(
      specId: 'WALK-0$step',
      title: 'Step $step: $title',
      nextLabel: step == Routes.walkthroughSteps.length ? 'Start check' : 'Next',
      onNext: () =>
          TeraFlow.advance(context, CheckFlow.afterWalkthroughStep(session, step)),
    ),
  );

  Route<dynamic> _stub(RouteSettings settings, String specId, String title) => _page(
    settings,
    (_) => FlowStubScreen(specId: specId, title: title, onNext: null),
  );

  Route<dynamic> _page(RouteSettings settings, WidgetBuilder builder) =>
      MaterialPageRoute<void>(settings: settings, builder: builder);
}
