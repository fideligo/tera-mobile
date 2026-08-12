/// Route names, one per entry in the PM spec's section 32.
///
/// The tree in that document is the contract between design, the backend spec and this app, so
/// the paths are reproduced verbatim rather than renamed to Dart taste. A screen that does not
/// exist yet still gets its route here: a missing name is a routing bug, a missing screen is a
/// stub, and the two should not look alike.
library;

abstract final class Routes {
  // Entry
  static const splash = '/splash';

  // auth/
  static const login = '/auth/login';
  static const register = '/auth/register';

  // device-check/
  static const deviceChecking = '/device-check/checking';
  static const deviceEligible = '/device-check/eligible';
  static const deviceNotEligible = '/device-check/not-eligible';

  // onboarding/
  static const onboardingAboutYou = '/onboarding/about-you';
  static const onboardingSafety = '/onboarding/safety';
  static const onboardingHealthContext = '/onboarding/health-context';

  static const home = '/home';

  // check/
  static const checkBpReference = '/check/bp-reference';
  static const checkBpInput = '/check/bp-input';
  static const checkBpScan = '/check/bp-scan';
  static const checkBpConfirm = '/check/bp-confirm';
  static const checkPrecondition = '/check/precondition';

  /// PRE-01 fails: not resting yet. The spec's `WAIT_SCREEN`, which section 32 does not name
  /// because it is reached from `precondition` rather than routed to directly.
  static const checkWait = '/check/wait';

  static const checkContext = '/check/context';
  static const checkWalkthrough1 = '/check/walkthrough/1';
  static const checkWalkthrough2 = '/check/walkthrough/2';
  static const checkWalkthrough3 = '/check/walkthrough/3';
  static const checkWalkthrough4 = '/check/walkthrough/4';
  static const checkCapture = '/check/capture';
  static const checkSignalAccepted = '/check/signal-accepted';
  static const checkSignalAdjust = '/check/signal-adjust';
  static const checkSignalRepeatedFailure = '/check/signal-repeated-failure';
  static const checkProcessing = '/check/processing';
  static const checkInsight = '/check/insight';

  // history/
  static const history = '/history';

  /// `history/:eventId`. Built with [historyDetailFor]; parsed by the router.
  static const historyDetailPrefix = '/history/';

  static String historyDetailFor(String eventId) => '$historyDetailPrefix$eventId';

  // profile/
  static const profile = '/profile';
  static const profilePersonal = '/profile/personal';
  static const profileConditions = '/profile/conditions';
  static const profileMedications = '/profile/medications';
  static const profileLifestyle = '/profile/lifestyle';
  static const profileFamilyHistory = '/profile/family-history';
  static const profileBpReference = '/profile/bp-reference';
  static const profileDevice = '/profile/device';
  static const profilePrivacy = '/profile/privacy';

  /// The four walkthrough steps in order, so the flow can advance without string arithmetic.
  static const walkthroughSteps = [
    checkWalkthrough1,
    checkWalkthrough2,
    checkWalkthrough3,
    checkWalkthrough4,
  ];
}
