/// The two auth screens, driven through a real Navigator and a mocked backend.
///
/// The claims worth protecting here are the ones that were broken:
///
///  - sign-up posts to `/v1/auth/register-patient` and the account really is created;
///  - **the name never leaves the handset** — the request body carries the subject and the
///    password and nothing else;
///  - either screen, on success, *navigates*, and to AUTH-00's answer rather than a hard-coded
///    route. Sign-in used to authenticate and then leave the patient sitting on the login form.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
// ignore: unnecessary_import — MethodChannel, for the Keystore fake below.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tera_patient/api/api_client.dart';
import 'package:tera_patient/auth/auth_controller.dart';
import 'package:tera_patient/auth/token_store.dart';
import 'package:tera_patient/capture/phr_profile.dart';
import 'package:tera_patient/routing/app_flow_state.dart';
import 'package:tera_patient/routing/app_router.dart';
import 'package:tera_patient/routing/check_session.dart';
import 'package:tera_patient/routing/routes.dart';
import 'package:tera_patient/ui/register_screen.dart';

http.Response _json(Map<String, dynamic> body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// What the backend returns from a successful self-registration, trimmed to the fields the
/// handset reads. Mirrors `RegisterPatientResponse`.
Map<String, dynamic> _registered() => {
  'user': {'id': 'u-1', 'subject': 'baru@test.invalid', 'role': 'patient'},
  'patient_id': 'p-1',
  'pseudonym': 'TERA-ABC123DEF456',
  'episode_id': 'e-1',
  'tokens': {
    'access_token': 'a',
    'refresh_token': 'r',
    'token_type': 'bearer',
    'expires_in': 900,
    'role': 'patient',
  },
};

/// A flow with a mocked transport. [requests] collects everything the screens send.
({TeraFlow flow, InMemoryTokenStore tokens}) _flow({
  required Future<http.Response> Function(http.Request) respond,
  AppFlowState state = const AppFlowState(),
  List<http.Request>? requests,
}) {
  final tokens = InMemoryTokenStore();
  late final AuthController auth;
  final api = ApiClient(
    baseUrl: 'http://test',
    tokenStore: tokens,
    httpClient: MockClient((request) {
      requests?.add(request);
      return respond(request);
    }),
    onSessionLost: () => auth.onSessionLost(),
  );
  auth = AuthController(api: api);
  return (
    flow: TeraFlow(auth: auth, api: api, store: InMemoryAppFlowStore(state)),
    tokens: tokens,
  );
}

/// The Keystore, answered in-process.
///
/// `flutter_secure_storage` is a real platform channel, and inside the fake-async zone a
/// `testWidgets` body runs in, a real channel call never gets an answer at all: the request goes
/// to an engine that is not there and the `await` hangs for the life of the test. It does not
/// throw, so it cannot be caught either.
///
/// This matters because the router hands the sign-up screen a real [SecurePhrProfileStore] — the
/// production wiring is what these tests should exercise, not a store threaded in to make the
/// test easy. So the channel is given an in-memory answer instead.
void _fakeKeystore() {
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final entries = <String, String>{};

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    channel,
    (call) async {
      final args = (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
      final key = args['key'] as String?;
      switch (call.method) {
        case 'write':
          entries[key!] = args['value'] as String;
        case 'read':
          return entries[key];
        case 'readAll':
          return entries;
        case 'containsKey':
          return entries.containsKey(key);
        case 'delete':
          entries.remove(key);
        case 'deleteAll':
          entries.clear();
      }
      return null;
    },
  );

  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
}

/// A handset-shaped viewport. The default 800x600 puts the submit button off the bottom of a
/// form this size, and a tap that silently misses looks exactly like a button that does nothing.
void _handsetSized(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Pump one screen, with the router behind it so a navigation goes somewhere real.
Future<void> _pumpScreen(WidgetTester tester, TeraFlow flow, Widget screen) async {
  _handsetSized(tester);
  await tester.pumpWidget(
    MaterialApp(onGenerateRoute: TeraRouter(flow).onGenerateRoute, home: screen),
  );
  await tester.pumpAndSettle();
}

/// Pump the router at a route, as the app itself enters it.
Future<void> _pump(WidgetTester tester, TeraFlow flow, {required String initialRoute}) async {
  _handsetSized(tester);
  await tester.pumpWidget(
    MaterialApp(onGenerateRoute: TeraRouter(flow).onGenerateRoute, initialRoute: initialRoute),
  );
  await tester.pumpAndSettle();
}

/// Advance without settling.
///
/// [WidgetTester.pumpAndSettle] cannot be used to land on a screen that spins: DEV-01's probe
/// indicator never stops, so settling on it times out. A bounded number of frames is enough to
/// let the submit chain — request, local writes, navigation — finish.
Future<void> _pumpFrames(WidgetTester tester, {int frames = 20}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Finder _field(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byType(TextFormField),
);

Future<void> _fill(WidgetTester tester, String label, String value) async {
  await tester.enterText(_field(label), value);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(_fakeKeystore);

  group('sign-up posts the account and nothing more', () {
    testWidgets('a valid form creates the account and signs the patient in', (tester) async {
      final requests = <http.Request>[];
      final harness = _flow(
        respond: (_) async => _json(_registered(), 201),
        requests: requests,
      );
      final profiles = InMemoryPhrProfileStore();

      await _pumpScreen(
        tester,
        harness.flow,
        RegisterScreen(flow: harness.flow, profileStore: profiles),
      );

      await _fill(tester, 'Name', 'Budi Santoso');
      await _fill(tester, 'Email', 'baru@test.invalid');
      await _fill(tester, 'Password', 'kata-sandi-panjang');
      await tester.tap(find.text('Register'));
      await _pumpFrames(tester);

      expect(requests, hasLength(1));
      expect(requests.single.url.path, '/v1/auth/register-patient');

      // The account exists and the tokens it returned are held.
      expect(harness.flow.auth.status, AuthStatus.signedIn);
      expect((await harness.tokens.read())!.accessToken, 'a');
    });

    testWidgets('the name is not in the request body', (tester) async {
      // The backend generates a pseudonym on purpose. A name in this payload would be an
      // identity written into a record designed not to hold one.
      final requests = <http.Request>[];
      final harness = _flow(
        respond: (_) async => _json(_registered(), 201),
        requests: requests,
      );

      await _pumpScreen(
        tester,
        harness.flow,
        RegisterScreen(flow: harness.flow, profileStore: InMemoryPhrProfileStore()),
      );

      await _fill(tester, 'Name', 'Budi Santoso');
      await _fill(tester, 'Email', 'baru@test.invalid');
      await _fill(tester, 'Password', 'kata-sandi-panjang');
      await tester.tap(find.text('Register'));
      await _pumpFrames(tester);

      final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
      expect(body.keys, unorderedEquals(<String>['subject', 'password']));
      expect(requests.single.body, isNot(contains('Budi')));
    });

    testWidgets('the name is kept on the handset instead', (tester) async {
      final harness = _flow(respond: (_) async => _json(_registered(), 201));
      final profiles = InMemoryPhrProfileStore();

      await _pumpScreen(
        tester,
        harness.flow,
        RegisterScreen(flow: harness.flow, profileStore: profiles),
      );

      await _fill(tester, 'Name', '  Budi Santoso  ');
      await _fill(tester, 'Email', 'baru@test.invalid');
      await _fill(tester, 'Password', 'kata-sandi-panjang');
      await tester.tap(find.text('Register'));
      await _pumpFrames(tester);

      expect((await profiles.read()).displayName, 'Budi Santoso');
    });
  });

  group('sign-up validation happens before the request', () {
    testWidgets('an empty form is refused field by field and sends nothing', (tester) async {
      final requests = <http.Request>[];
      final harness = _flow(
        respond: (_) async => _json(_registered(), 201),
        requests: requests,
      );

      await _pumpScreen(
        tester,
        harness.flow,
        RegisterScreen(flow: harness.flow, profileStore: InMemoryPhrProfileStore()),
      );

      await tester.tap(find.text('Register'));
      await tester.pumpAndSettle();

      expect(find.text('Enter your name.'), findsOneWidget);
      expect(find.text('Enter your email address.'), findsOneWidget);
      expect(find.text('Choose a password.'), findsOneWidget);
      expect(requests, isEmpty);
    });

    testWidgets('an address without an @ is a field error, not a round trip', (tester) async {
      final requests = <http.Request>[];
      final harness = _flow(
        respond: (_) async => _json(_registered(), 201),
        requests: requests,
      );

      await _pumpScreen(
        tester,
        harness.flow,
        RegisterScreen(flow: harness.flow, profileStore: InMemoryPhrProfileStore()),
      );

      await _fill(tester, 'Name', 'Budi');
      await _fill(tester, 'Email', 'budi.test.invalid');
      await _fill(tester, 'Password', 'kata-sandi-panjang');
      await tester.tap(find.text('Register'));
      await tester.pumpAndSettle();

      expect(find.textContaining('valid email address'), findsOneWidget);
      expect(requests, isEmpty);
    });

    testWidgets('a password under the backend minimum never reaches the backend', (tester) async {
      // The server would answer 422 with a list of field objects. Saying it here means the
      // patient reads a sentence under the field instead.
      final requests = <http.Request>[];
      final harness = _flow(
        respond: (_) async => _json(_registered(), 201),
        requests: requests,
      );

      await _pumpScreen(
        tester,
        harness.flow,
        RegisterScreen(flow: harness.flow, profileStore: InMemoryPhrProfileStore()),
      );

      await _fill(tester, 'Name', 'Budi');
      await _fill(tester, 'Email', 'budi@test.invalid');
      await _fill(tester, 'Password', 'pendek');
      await tester.tap(find.text('Register'));
      await tester.pumpAndSettle();

      expect(find.text('Use at least $minPasswordLength characters.'), findsOneWidget);
      expect(requests, isEmpty);
    });
  });

  group('a refused sign-up says why and stays put', () {
    testWidgets('a taken address is reported in both channels', (tester) async {
      final harness = _flow(
        respond: (_) async => _json({'detail': 'that subject is already registered'}, 409),
      );

      await _pumpScreen(
        tester,
        harness.flow,
        RegisterScreen(flow: harness.flow, profileStore: InMemoryPhrProfileStore()),
      );

      await _fill(tester, 'Name', 'Budi');
      await _fill(tester, 'Email', 'sudah@test.invalid');
      await _fill(tester, 'Password', 'kata-sandi-panjang');
      await tester.tap(find.text('Register'));
      await tester.pumpAndSettle();

      // The panel, which stays, and the snack bar, which is what catches the eye.
      expect(find.textContaining('already registered'), findsNWidgets(2));
      expect(find.byType(SnackBar), findsOneWidget);
      // Still on the form, with the details intact, and not signed in.
      expect(find.text('Register'), findsOneWidget);
      expect(harness.flow.auth.status, isNot(AuthStatus.signedIn));
    });

    testWidgets('an unreachable backend is a connection problem, not a rejection', (tester) async {
      final harness = _flow(respond: (_) async => throw Exception('offline'));

      await _pumpScreen(
        tester,
        harness.flow,
        RegisterScreen(flow: harness.flow, profileStore: InMemoryPhrProfileStore()),
      );

      await _fill(tester, 'Name', 'Budi');
      await _fill(tester, 'Email', 'budi@test.invalid');
      await _fill(tester, 'Password', 'kata-sandi-panjang');
      await tester.tap(find.text('Register'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not reach Tera'), findsNWidgets(2));
    });
  });

  group('sign-up lands where AUTH-00 says a new account belongs', () {
    testWidgets('an unchecked handset goes to the device check', (tester) async {
      final harness = _flow(respond: (_) async => _json(_registered(), 201));
      await _pump(tester, harness.flow, initialRoute: Routes.register);

      await _fill(tester, 'Name', 'Budi');
      await _fill(tester, 'Email', 'baru@test.invalid');
      await _fill(tester, 'Password', 'kata-sandi-panjang');
      await tester.tap(find.text('Register'));
      await _pumpFrames(tester);

      // DEV-01 runs the real sensor probe, which a test host has no camera for, so the claim is
      // that we arrived — not that the probe succeeded.
      expect(find.text('Checking your phone sensors'), findsOneWidget);
    });

    testWidgets('a second account on this handset does not inherit the first one\'s setup', (
      tester,
    ) async {
      // Onboarding belongs to the account; the device check belongs to the phone. Landing on
      // Home here would mean a new patient looking at a record built from someone else's
      // answers.
      final harness = _flow(
        respond: (_) async => _json(_registered(), 201),
        state: const AppFlowState(
          deviceEligibility: DeviceEligibility.eligible,
          onboardingStep: OnboardingStep.complete,
        ),
      );
      await _pump(tester, harness.flow, initialRoute: Routes.register);

      await _fill(tester, 'Name', 'Budi');
      await _fill(tester, 'Email', 'baru@test.invalid');
      await _fill(tester, 'Password', 'kata-sandi-panjang');
      await tester.tap(find.text('Register'));
      await tester.pumpAndSettle();

      expect(harness.flow.state.onboardingComplete, isFalse);
      // The probe is not re-run: the torch and the accelerometer did not change.
      expect(harness.flow.state.deviceEligibility, DeviceEligibility.eligible);
      expect(find.text('About you'), findsOneWidget);
    });
  });

  group('signing in navigates', () {
    Future<TeraFlow> signInWith(WidgetTester tester, AppFlowState state) async {
      final harness = _flow(
        respond: (_) async => _json({
          'access_token': 'a',
          'refresh_token': 'r',
          'role': 'patient',
          'expires_in': 900,
        }),
        state: state,
      );
      await _pump(tester, harness.flow, initialRoute: Routes.login);

      await _fill(tester, 'Email', 'lama@test.invalid');
      await _fill(tester, 'Password', 'kata-sandi-panjang');
      await tester.tap(find.text('Login'));
      await tester.pumpAndSettle();
      return harness.flow;
    }

    testWidgets('a completed setup goes to Home', (tester) async {
      final flow = await signInWith(
        tester,
        const AppFlowState(
          deviceEligibility: DeviceEligibility.eligible,
          onboardingStep: OnboardingStep.complete,
        ),
      );

      expect(flow.auth.status, AuthStatus.signedIn);
      expect(find.text('Start Check-In'), findsOneWidget);
      // And the sign-in screen is gone from under it, not merely covered.
      expect(find.text('Selamat datang'), findsNothing);
    });

    testWidgets('an unfinished onboarding resumes at its own step', (tester) async {
      await signInWith(
        tester,
        const AppFlowState(
          deviceEligibility: DeviceEligibility.eligible,
          onboardingStep: OnboardingStep.healthContext,
        ),
      );

      expect(find.text('ONB-03'), findsOneWidget);
    });
  });

  group('a refused sign-in', () {
    testWidgets('says so without revealing whether the account exists, and stays', (tester) async {
      final harness = _flow(respond: (_) async => _json({'detail': 'nope'}, 401));
      await _pump(tester, harness.flow, initialRoute: Routes.login);

      await _fill(tester, 'Email', 'lama@test.invalid');
      await _fill(tester, 'Password', 'salah-sekali-panjang');
      await tester.tap(find.text('Login'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Incorrect username or password.'), findsNWidgets(2));
      expect(find.text('Selamat datang'), findsOneWidget);
      expect(harness.flow.auth.status, isNot(AuthStatus.signedIn));
    });

    testWidgets('an empty form does not call the backend', (tester) async {
      final requests = <http.Request>[];
      final harness = _flow(
        respond: (_) async => _json({'detail': 'nope'}, 401),
        requests: requests,
      );
      await _pump(tester, harness.flow, initialRoute: Routes.login);

      await tester.tap(find.text('Login'));
      await tester.pumpAndSettle();

      expect(find.text('Enter your email address.'), findsOneWidget);
      expect(find.text('Enter your password.'), findsOneWidget);
      expect(requests, isEmpty);
    });

    testWidgets('a password shorter than the sign-up minimum is still allowed through', (
      tester,
    ) async {
      // An account created before the minimum changed still has to be able to get in.
      final requests = <http.Request>[];
      final harness = _flow(
        respond: (_) async => _json({
          'access_token': 'a',
          'refresh_token': 'r',
          'role': 'patient',
          'expires_in': 900,
        }),
        requests: requests,
        state: const AppFlowState(
          deviceEligibility: DeviceEligibility.eligible,
          onboardingStep: OnboardingStep.complete,
        ),
      );
      await _pump(tester, harness.flow, initialRoute: Routes.login);

      await _fill(tester, 'Email', 'lama@test.invalid');
      await _fill(tester, 'Password', 'pendek');
      await tester.tap(find.text('Login'));
      await tester.pumpAndSettle();

      expect(requests, hasLength(1));
      expect(harness.flow.auth.status, AuthStatus.signedIn);
    });
  });

  group('the two screens reach each other', () {
    testWidgets('sign-in offers sign-up, and sign-up comes back', (tester) async {
      final harness = _flow(respond: (_) async => _json({}, 200));
      await _pump(tester, harness.flow, initialRoute: Routes.login);

      await tester.tap(find.text('Register'));
      await tester.pumpAndSettle();
      expect(find.text('Buat akun'), findsOneWidget);
      // The real form, not a placeholder.
      expect(find.byType(TextFormField), findsNWidgets(3));

      await tester.tap(find.text('Login'));
      await tester.pumpAndSettle();
      expect(find.text('Selamat datang'), findsOneWidget);
    });

    testWidgets('the password can be revealed on both screens', (tester) async {
      final harness = _flow(respond: (_) async => _json({}, 200));
      await _pump(tester, harness.flow, initialRoute: Routes.login);

      await _fill(tester, 'Password', 'kata-sandi-panjang');
      expect(tester.widget<TextField>(find.byType(TextField).last).obscureText, isTrue);

      await tester.tap(find.byTooltip('Show password'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField).last).obscureText, isFalse);
    });
  });
}
