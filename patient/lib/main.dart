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

/// The backend URL, read from `.env` at runtime.
///
/// The key must be present — there is no fallback so the URL never leaks into source.
String get apiBaseUrl => dotenv.env['TERA_API_URL']!;

Future<void> main() async {
  await dotenv.load(fileName: '.env');
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
      title: 'Tera',
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
