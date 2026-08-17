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
import 'package:tera_patient/ui/flow_stub_screen.dart';
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

/// Field order on each screen, since the rewritten screens dropped the keyed [AuthField].
const _registerFields = {'name': 0, 'email': 1, 'password': 2};
const _loginFields = {'email': 0, 'password': 1};

/// Type into a field by name.
///
/// Resolved by position rather than by label: the labels are the design's, they are in
/// Indonesian, and reading them is what broke these tests when the copy changed. Position is a
/// weaker handle than the [fieldKey] the previous screens carried — restoring those keys is the
/// better fix and is noted in `docs/decisions.md`.
Future<void> _fill(WidgetTester tester, String id, String value) async {
  final onRegister = find.text('Buat Akun Baru').evaluate().isNotEmpty;
  final index = (onRegister ? _registerFields : _loginFields)[id]!;
  await tester.enterText(find.byType(TextFormField).at(index), value);
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

      await _pumpScreen(
        tester,
        harness.flow,
        RegisterScreen(auth: harness.flow.auth),
      );

      await _fill(tester, 'name', 'Budi Santoso');
      await _fill(tester, 'email', 'baru@test.invalid');
      await _fill(tester, 'password', 'kata-sandi-panjang');
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
        RegisterScreen(auth: harness.flow.auth),
      );

      await _fill(tester, 'name', 'Budi Santoso');
      await _fill(tester, 'email', 'baru@test.invalid');
      await _fill(tester, 'password', 'kata-sandi-panjang');
      await tester.tap(find.text('Register'));
      await _pumpFrames(tester);

      final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
      expect(body.keys, unorderedEquals(<String>['subject', 'password']));
      expect(requests.single.body, isNot(contains('Budi')));
    });

    testWidgets('the name is collected but currently goes nowhere', (tester) async {
      // REGRESSION, deliberately pinned rather than deleted. The Name field is required and
      // validated, and the rewritten RegisterScreen then drops it: it is not sent (correct — the
      // backend has nowhere to put it) and no longer written to the local PHR either, so Home's
      // greeting has nothing to read. `users.name` exists in the B2C schema and the dual-write in
      // `auth.py` does not populate it.
      //
      // This test documents where the value stops. When the name is wired to either end, it
      // should fail — and that failure is the reminder to update it.
      final harness = _flow(respond: (_) async => _json(_registered(), 201));

      await _pumpScreen(tester, harness.flow, RegisterScreen(auth: harness.flow.auth));

      await _fill(tester, 'name', 'Budi Santoso');
      await _fill(tester, 'email', 'baru@test.invalid');
      await _fill(tester, 'password', 'kata-sandi-panjang');
      await tester.tap(find.text('Register'));
      await _pumpFrames(tester);

      expect(harness.flow.auth.status, AuthStatus.signedIn);
      // Nothing reached the local PHR: a fresh store is what Home would read.
      expect((await InMemoryPhrProfileStore().read()).displayName, isNull);
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
        RegisterScreen(auth: harness.flow.auth),
      );

      await tester.tap(find.text('Register'));
      await tester.pumpAndSettle();

      expect(find.text('Nama tidak boleh kosong'), findsOneWidget);
      expect(find.text('Email tidak boleh kosong'), findsOneWidget);
      expect(find.text('Kata Sandi tidak boleh kosong'), findsOneWidget);
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
        RegisterScreen(auth: harness.flow.auth),
      );

      await _fill(tester, 'name', 'Budi');
      await _fill(tester, 'email', 'budi.test.invalid');
      await _fill(tester, 'password', 'kata-sandi-panjang');
      await tester.tap(find.text('Register'));
      await tester.pumpAndSettle();

      expect(find.textContaining('email yang valid'), findsOneWidget);
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
        RegisterScreen(auth: harness.flow.auth),
      );

      await _fill(tester, 'name', 'Budi');
      await _fill(tester, 'email', 'budi@test.invalid');
      await _fill(tester, 'password', 'pendek');
      await tester.tap(find.text('Register'));
      await tester.pumpAndSettle();

      expect(find.text('Kata sandi minimal $minPasswordLength karakter'), findsOneWidget);
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
        RegisterScreen(auth: harness.flow.auth),
      );

      await _fill(tester, 'name', 'Budi');
      await _fill(tester, 'email', 'sudah@test.invalid');
      await _fill(tester, 'password', 'kata-sandi-panjang');
      await tester.tap(find.text('Register'));
      await tester.pumpAndSettle();

      // The panel, which stays, and the snack bar, which is what catches the eye.
      expect(find.textContaining('already registered'), findsOneWidget);
      // Still on the form, with the details intact, and not signed in.
      expect(find.text('Register'), findsOneWidget);
      expect(harness.flow.auth.status, isNot(AuthStatus.signedIn));
    });

    testWidgets('an unreachable backend is a connection problem, not a rejection', (tester) async {
      final harness = _flow(respond: (_) async => throw Exception('offline'));

      await _pumpScreen(
        tester,
        harness.flow,
        RegisterScreen(auth: harness.flow.auth),
      );

      await _fill(tester, 'name', 'Budi');
      await _fill(tester, 'email', 'budi@test.invalid');
      await _fill(tester, 'password', 'kata-sandi-panjang');
      await tester.tap(find.text('Register'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not reach Tera'), findsOneWidget);
    });
  });

  group('sign-up hands off to AUTH-00 rather than guessing', () {
    testWidgets('a created account leaves the sign-up screen behind', (tester) async {
      // The rewritten screen routes to the splash, which re-runs the AUTH-00 table. That is a
      // different mechanism from computing `resumeRoute` inline and it reaches the same place;
      // what matters here is that a successful sign-up *leaves*, which is the bug this group was
      // written for.
      final harness = _flow(respond: (_) async => _json(_registered(), 201));
      await _pump(tester, harness.flow, initialRoute: Routes.register);

      await _fill(tester, 'name', 'Budi');
      await _fill(tester, 'email', 'baru@test.invalid');
      await _fill(tester, 'password', 'kata-sandi-panjang');
      await tester.tap(find.text('Register'));
      await _pumpFrames(tester);

      expect(harness.flow.auth.status, AuthStatus.signedIn);
      expect(find.text('Buat Akun Baru'), findsNothing);
    });
  });

  group('signing in navigates', () {
    Future<TeraFlow> signInWith(
      WidgetTester tester,
      AppFlowState state, {
      bool profileComplete = true,
    }) async {
      final harness = _flow(
        // `resumeRouteAfterAuth` asks the server whether this account has a profile before
        // letting anyone reach Home, so the fake has to answer two different questions now.
        // Returning the token body for every path made `/v1/profile` look like a profile with
        // no date of birth, which is exactly what the gate is meant to catch.
        respond: (request) async {
          if (request.url.path.endsWith('/v1/profile')) {
            return _json(
              profileComplete
                  ? {
                      'date_of_birth': '1972-04-11',
                      'sex_assigned_at_birth': 'female',
                    }
                  : {'date_of_birth': null, 'sex_assigned_at_birth': null},
            );
          }
          return _json({
            'access_token': 'a',
            'refresh_token': 'r',
            'role': 'patient',
            'expires_in': 900,
          });
        },
        state: state,
      );
      await _pump(tester, harness.flow, initialRoute: Routes.login);

      await _fill(tester, 'email', 'lama@test.invalid');
      await _fill(tester, 'password', 'kata-sandi-panjang');
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
      expect(find.text('Selamat Datang'), findsNothing);
    });

    testWidgets('an account with no health profile is sent to ONB-01, not Home', (
      tester,
    ) async {
      // The point of the gate: local state says setup finished on this handset, but the account
      // itself has no date of birth or sex on file — which is what `read_insight` needs before
      // the AI paragraph has any context to work from. The server's answer wins.
      await signInWith(
        tester,
        const AppFlowState(
          deviceEligibility: DeviceEligibility.eligible,
          onboardingStep: OnboardingStep.complete,
        ),
        profileComplete: false,
      );

      expect(find.byKey(screenKey('ONB-01')), findsOneWidget);
      expect(find.text('Start Check-In'), findsNothing);
    });

    testWidgets('an unfinished onboarding resumes at its own step', (tester) async {
      await signInWith(
        tester,
        const AppFlowState(
          deviceEligibility: DeviceEligibility.eligible,
          onboardingStep: OnboardingStep.healthContext,
        ),
      );

      expect(find.byKey(screenKey('ONB-03')), findsOneWidget);
    });
  });

  group('a refused sign-in', () {
    testWidgets('says so without revealing whether the account exists, and stays', (tester) async {
      final harness = _flow(respond: (_) async => _json({'detail': 'nope'}, 401));
      await _pump(tester, harness.flow, initialRoute: Routes.login);

      await _fill(tester, 'email', 'lama@test.invalid');
      await _fill(tester, 'password', 'salah-sekali-panjang');
      await tester.tap(find.text('Login'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Incorrect username or password.'), findsOneWidget);
      expect(find.text('Selamat Datang'), findsOneWidget);
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

      expect(find.text('Masukkan email kamu.'), findsOneWidget);
      expect(find.text('Masukkan kata sandi.'), findsOneWidget);
      expect(requests, isEmpty);
    });

    testWidgets('a password shorter than the sign-up minimum is still allowed through', (
      tester,
    ) async {
      // An account created before the minimum changed still has to be able to get in.
      final requests = <http.Request>[];
      final harness = _flow(
        respond: (request) async {
          if (request.url.path.endsWith('/v1/profile')) {
            return _json({
              'date_of_birth': '1972-04-11',
              'sex_assigned_at_birth': 'female',
            });
          }
          return _json({
            'access_token': 'a',
            'refresh_token': 'r',
            'role': 'patient',
            'expires_in': 900,
          });
        },
        requests: requests,
        state: const AppFlowState(
          deviceEligibility: DeviceEligibility.eligible,
          onboardingStep: OnboardingStep.complete,
        ),
      );
      await _pump(tester, harness.flow, initialRoute: Routes.login);

      await _fill(tester, 'email', 'lama@test.invalid');
      await _fill(tester, 'password', 'pendek');
      await tester.tap(find.text('Login'));
      await tester.pumpAndSettle();

      // Counted by path rather than in total: the point of this test is that the short password
      // was not refused on the handset, so exactly one *token* request must have gone out.
      // Sign-in now also asks `/v1/profile` for the EMR gate, which is not what is under test.
      expect(
        requests.where((r) => r.url.path.endsWith('/v1/auth/token')),
        hasLength(1),
      );
      expect(harness.flow.auth.status, AuthStatus.signedIn);
    });
  });

  group('the sign-out listener reacts to a transition, not a value', () {
    testWidgets('pressing Register does not unwind the stack to Login', (tester) async {
      // `AuthController.register` notifies once at the start, to clear a stale error, while the
      // status is still `signedOut`. `main.dart` listens for `signedOut` to send a lost session
      // back to sign-in — and reacting to the value rather than the change popped the Register
      // screen the instant the patient pressed the button. The account was created, the response
      // came back 201, and the screen that was going to navigate no longer existed.
      final harness = _flow(respond: (_) async => _json(_registered(), 201));

      // The real listener, wired the way `main.dart` wires it.
      final navigator = GlobalKey<NavigatorState>();
      var lastStatus = harness.flow.auth.status;
      harness.flow.auth.addListener(() {
        final previous = lastStatus;
        lastStatus = harness.flow.auth.status;
        if (harness.flow.auth.status != AuthStatus.signedOut) return;
        if (previous != AuthStatus.signedIn) return;
        navigator.currentState?.pushNamedAndRemoveUntil(Routes.login, (r) => false);
      });

      _handsetSized(tester);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          onGenerateRoute: TeraRouter(harness.flow).onGenerateRoute,
          initialRoute: Routes.login,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Register'));
      await tester.pumpAndSettle();
      expect(find.text('Buat Akun Baru'), findsOneWidget);

      await _fill(tester, 'name', 'Budi');
      await _fill(tester, 'email', 'baru@test.invalid');
      await _fill(tester, 'password', 'kata-sandi-panjang');
      await tester.tap(find.text('Register'));
      await _pumpFrames(tester);

      // Signed in and moved on, rather than bounced back to the form it started from.
      expect(harness.flow.auth.status, AuthStatus.signedIn);
      expect(find.text('Selamat Datang'), findsNothing);
      expect(find.text('Buat Akun Baru'), findsNothing);
    });

    testWidgets('a genuinely lost session still returns to Login', (tester) async {
      // The behaviour the listener exists for must survive the fix.
      final harness = _flow(respond: (_) async => _json({'detail': 'revoked'}, 401));
      await harness.tokens.write(
        const StoredSession(
          accessToken: 'a',
          refreshToken: 'r',
          role: 'patient',
          subject: 'lama@test.invalid',
        ),
      );
      await harness.flow.auth.restore();
      expect(harness.flow.auth.status, AuthStatus.signedIn);

      var unwound = false;
      var lastStatus = harness.flow.auth.status;
      harness.flow.auth.addListener(() {
        final previous = lastStatus;
        lastStatus = harness.flow.auth.status;
        if (harness.flow.auth.status != AuthStatus.signedOut) return;
        if (previous != AuthStatus.signedIn) return;
        unwound = true;
      });

      await expectLater(
        harness.flow.api.getJson('/v1/episodes'),
        throwsA(isA<SessionExpiredException>()),
      );
      expect(unwound, isTrue);
    });
  });

  group('the two screens reach each other', () {
    testWidgets('sign-in offers sign-up, and sign-up comes back', (tester) async {
      final harness = _flow(respond: (_) async => _json({}, 200));
      await _pump(tester, harness.flow, initialRoute: Routes.login);

      await tester.tap(find.text('Register'));
      await tester.pumpAndSettle();
      expect(find.text('Buat Akun Baru'), findsOneWidget);
      // The real form, not a placeholder.
      expect(find.byType(TextFormField), findsNWidgets(3));

      await tester.tap(find.text('Login'));
      await tester.pumpAndSettle();
      expect(find.text('Selamat Datang'), findsOneWidget);
    });

    testWidgets('the password can be revealed on both screens', (tester) async {
      final harness = _flow(respond: (_) async => _json({}, 200));
      await _pump(tester, harness.flow, initialRoute: Routes.login);

      await _fill(tester, 'password', 'kata-sandi-panjang');
      expect(tester.widget<TextField>(find.byType(TextField).last).obscureText, isTrue);

      // While obscured the button offers 'reveal', which is the crossed-out eye.
      await tester.tap(find.byIcon(Icons.visibility_off_outlined));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField).last).obscureText, isFalse);
    });
  });
}
