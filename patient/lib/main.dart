/// Tera patient application.
///
/// The flow this app exists to deliver, in its final shape:
///
///     sign in -> device eligibility -> guided capture -> [terminal step]
///
/// The terminal step is currently a labelled debug CSV export, because the signal-processing
/// chain (beat detection, beat pairing, PTT derivation) does not exist yet. When it arrives,
/// **only that last step changes** — the rest of the flow is built against a stable interface
/// so nothing here has to be rebuilt.
///
/// This is not the device profiler. `profiler/` is a developer harness for measuring handsets
/// and collecting raw data; both apps consume `packages/tera_capture`, and neither depends on
/// the other.
library;

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'api/api_client.dart';
import 'auth/auth_controller.dart';
import 'auth/token_store.dart';
import 'routing/app_router.dart';
import 'routing/routes.dart';
import 'ui/tokens.dart';

/// The backend URL: the dart-define first, then `.env`, then the emulator default.
///
/// **The define was doing nothing.** Both `CLAUDE.md` files document the release build as
/// `--dart-define=TERA_API_URL=http://<laptop-lan-ip>:8000`, and the CI workflow passes it — but
/// this read `dotenv.env['TERA_API_URL']!` and nothing ever consulted the define, so every build
/// took its URL from a gitignored file and the documented command had no effect at all.
///
/// The order is deliberate. A define is baked into the artifact and is what a released APK should
/// use; `.env` stays ahead of the fallback so a local `flutter run` keeps working the way it does
/// today; and the last resort is the emulator's view of the host, which is wrong on a real handset
/// but is at least a stated wrong rather than a crash.
const String _definedApiUrl = String.fromEnvironment('TERA_API_URL');

String get apiBaseUrl {
  if (_definedApiUrl.isNotEmpty) return _definedApiUrl;
  final fromFile = dotenv.env['TERA_API_URL'];
  if (fromFile != null && fromFile.isNotEmpty) return fromFile;
  // 10.0.2.2 is the host as seen from an Android emulator, and unreachable from a real phone.
  return 'http://10.0.2.2:8000';
}

Future<void> main() async {
  // **Not fatal.** `.env` is gitignored, so a clean checkout — CI's, or a teammate's first clone —
  // has none, and this threw before `runApp` and killed the app on the first frame with no error
  // a user could act on. It is a local convenience, not a requirement: the define above is what a
  // built artifact carries.
  try {
    await dotenv.load(fileName: '.env');
  } on Object {
    // Nothing to do. `apiBaseUrl` falls through to the define or the documented default.
  }
  runApp(const TeraPatientApp());
}

class TeraPatientApp extends StatefulWidget {
  const TeraPatientApp({super.key});

  @override
  State<TeraPatientApp> createState() => _TeraPatientAppState();
}

class _TeraPatientAppState extends State<TeraPatientApp> {
  late final TokenStore _tokenStore;
  late final ApiClient _api;
  late final AuthController _auth;
  late final TeraFlow _flow;
  late final TeraRouter _router;
  final _navigator = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    _tokenStore = SecureTokenStore();
    _auth = AuthController(
      api: _api = ApiClient(
        baseUrl: apiBaseUrl,
        tokenStore: _tokenStore,
        // A refresh that cannot be recovered returns the app to sign-in rather than leaving
        // the patient tapping a screen whose requests all fail.
        onSessionLost: () => _auth.onSessionLost(),
      ),
    );
    _flow = TeraFlow(auth: _auth, api: _api);
    _router = TeraRouter(_flow);

    // A session lost mid-flow unwinds to login. The splash re-runs AUTH-00 on the way back in, so
    // the resume point is recomputed rather than remembered from before the session died.
    _lastStatus = _auth.status;
    _auth.addListener(_onAuthChanged);
    // The splash owns restore(); calling it here too would race it.
  }

  /// The last status this listener saw, so it can tell a *transition* from a repeat.
  ///
  /// Load-bearing. [AuthController.signIn] and [AuthController.register] both notify once at the
  /// start, to clear a stale error, while the status is still `signedOut` — and a listener that
  /// reacted to the value rather than the change unwound the whole stack to Login at the moment
  /// the patient pressed Register. The account was created, the response came back 201, and the
  /// screen that was going to navigate had already been popped.
  AuthStatus _lastStatus = AuthStatus.checking;

  void _onAuthChanged() {
    final previous = _lastStatus;
    _lastStatus = _auth.status;

    // Only a session that *was* live and is now gone sends the app back to sign-in.
    if (_auth.status != AuthStatus.signedOut) return;
    if (previous != AuthStatus.signedIn) return;

    _navigator.currentState?.pushNamedAndRemoveUntil(
      Routes.login,
      (r) => false,
    );
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    _auth.dispose();
    _api.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // The label Android shows in the recent-apps switcher. Matched to the launcher label so
      // the two OS surfaces agree; in-app copy stays "Tera", which is how the brand is written in
      // sentences rather than on an icon.
      title: 'TERA',
      debugShowCheckedModeBanner: false,
      theme: buildTeraTheme(),
      navigatorKey: _navigator,
      // AUTH-00 is the entry point for every launch: it resolves auth, then device eligibility,
      // then onboarding, and routes once. Nothing else decides where a launch lands.
      initialRoute: Routes.splash,
      onGenerateRoute: _router.onGenerateRoute,
    );
  }
}
