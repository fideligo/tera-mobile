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

import 'api/api_client.dart';
import 'auth/auth_controller.dart';
import 'auth/token_store.dart';
import 'ui/home_screen.dart';
import 'ui/sign_in_screen.dart';
import 'ui/tokens.dart';

/// The backend, overridable at build time so a demo can point at a laptop on the venue
/// network without a rebuild of the Dart source:
///
///     flutter run --dart-define=TERA_API_URL=http://192.168.1.10:8000
const String apiBaseUrl = String.fromEnvironment(
  'TERA_API_URL',
  defaultValue: 'http://10.0.2.2:8000', // the host machine, as seen from an Android emulator
);

void main() {
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
    _auth.restore();
  }

  @override
  void dispose() {
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
      home: AnimatedBuilder(
        animation: _auth,
        builder: (context, _) => switch (_auth.status) {
          AuthStatus.checking => const _Loading(),
          AuthStatus.signedOut => SignInScreen(auth: _auth),
          AuthStatus.signedIn => HomeScreen(auth: _auth),
        },
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}
