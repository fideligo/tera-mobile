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
import 'auth/token_store.dart';
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

  @override
  void initState() {
    super.initState();
    _tokenStore = SecureTokenStore();
    _api = ApiClient(
      baseUrl: apiBaseUrl,
      tokenStore: _tokenStore,
      // Set in M2, when there is a navigator to return to sign-in with.
      onSessionLost: () {},
    );
  }

  @override
  void dispose() {
    _api.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tera',
      debugShowCheckedModeBanner: false,
      theme: buildTeraTheme(),
      home: const _Placeholder(),
    );
  }
}

/// Temporary landing screen. Replaced by the sign-in screen in M2.
class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tera')),
      body: Padding(
        padding: const EdgeInsets.all(TeraSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Patient application',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: TeraColors.ink),
            ),
            const SizedBox(height: TeraSpacing.sm),
            const Text(
              'Sign-in arrives in the next step. Auth client and secure token storage are in '
              'place.',
              style: TextStyle(color: TeraColors.muted, height: 1.4),
            ),
            const SizedBox(height: TeraSpacing.lg),
            Container(
              decoration: systemFlagDecoration(),
              padding: const EdgeInsets.all(TeraSpacing.md),
              child: const Text(
                'Tera monitors change between clinic visits. It does not replace a cuff, does '
                'not diagnose, and does not advise on medication.',
                style: TextStyle(fontSize: 12, height: 1.5, color: TeraColors.ink),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
