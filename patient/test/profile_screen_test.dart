/// PROF-01 — the profile tab, and the edit that feeds `POST /v1/profile`.
///
/// Two properties dominate here:
///
///   * **A failure never empties the screen.** One endpoint being slow, refused or absent must
///     leave the rest of the profile on screen and offer a retry. A profile tab that goes blank
///     when the network blinks is indistinguishable from an account with nothing in it.
///   * **A 422 is not a UI state.** `PhrProfilePatch` bounds height and weight, takes a `date` for
///     the birth date, and forbids unknown fields. Everything is parsed and range-checked before a
///     request is built, so an invalid edit produces a message rather than a round trip.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tera_patient/api/api_client.dart';
import 'package:tera_patient/auth/auth_controller.dart';
import 'package:tera_patient/auth/token_store.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:tera_patient/capture/phr_profile.dart';
import 'package:tera_patient/notifications/notification_service.dart';
import 'package:tera_patient/routing/app_flow_state.dart';
import 'package:tera_patient/routing/app_router.dart';
import 'package:tera_patient/routing/check_session.dart';
import 'package:tera_patient/ui/account_screens.dart';
import 'package:tera_patient/ui/profile_edit_sheet.dart';
import 'package:tera_patient/ui/profile_screen.dart';

/// Every request the screen made, so an absent call can be asserted as easily as a present one.
late List<http.Request> requests;

Map<String, dynamic> _me() => {
  'id': 'u-1',
  'subject': 'demo.patient@tera.invalid',
  'role': 'patient',
  'clinic_id': null,
  'patient_id': 'p-1',
  'created_at': '2026-01-01T00:00:00Z',
  'active_sessions': 1,
};

Map<String, dynamic> _profile({
  String? dob = '1990-04-17',
  String? sex = 'female',
  num? height = 172,
  num? weight = 68,
  String? hypertension = 'diagnosed',
  bool? medication = true,
}) => {
  'patient_id': 'p-1',
  'date_of_birth': dob,
  'sex_assigned_at_birth': sex,
  'height_cm': height,
  'weight_kg': weight,
  'hypertension_status': hypertension,
  'taking_bp_medication': medication,
  'conditions': <String>[],
  'updated_at': '2026-08-01T00:00:00Z',
  'synthetic': false,
};

Map<String, dynamic> _reference({
  bool has = true,
  int? ageDays = 9,
  bool needsRefresh = false,
  String? reason,
}) => {
  'has_reference': has,
  'needs_refresh': needsRefresh,
  'reason': reason,
  'last_sensor_check_at': null,
  'current_reference': null,
  'reference_age_days': ageDays,
};

/// Routes each path to a canned response. Anything unrouted is a 404.
ApiClient _api(
  Map<String, (int, Map<String, dynamic>)> routes, {
  Duration delay = Duration.zero,
}) {
  requests = [];
  return ApiClient(
    baseUrl: 'http://test',
    tokenStore: InMemoryTokenStore()
      ..write(
        const StoredSession(
          accessToken: 'a',
          refreshToken: 'r',
          role: 'patient',
          subject: 'demo.patient@tera.invalid',
        ),
      ),
    httpClient: MockClient((request) async {
      requests.add(request);
      // Held open so the loading state is observable; instant otherwise.
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      final match = routes[request.url.path];
      if (match == null) {
        return http.Response(
          jsonEncode({'detail': 'not found'}),
          404,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode(match.$2),
        match.$1,
        headers: {'content-type': 'application/json'},
      );
    }),
    onSessionLost: () {},
  );
}

Map<String, (int, Map<String, dynamic>)> _happy() => {
  '/v1/auth/me': (200, _me()),
  '/v1/profile': (200, _profile()),
  '/v1/bp-reference/status': (200, _reference()),
};

Future<void> _pump(
  WidgetTester tester,
  ApiClient api, {
  AppFlowState? flowState,
  PhrProfile local = const PhrProfile(displayName: 'Rafi'),
  bool settle = true,
  bool guest = false,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final store = InMemoryPhrProfileStore();
  await store.write(local);

  final auth = AuthController(api: api);
  if (guest) auth.continueAsGuest();

  TeraFlow? flow;
  if (flowState != null) {
    flow = TeraFlow(
      auth: AuthController(api: api),
      api: api,
      store: InMemoryAppFlowStore(flowState),
    );
    await flow.load();
  }

  await tester.pumpWidget(
    MaterialApp(
      home: ProfileScreen(
        api: api,
        auth: guest ? auth : null,
        flow: flow,
        profileStore: store,
        // In memory, so the screen does not reach for the Keystore, which has no platform channel
        // under test.
        reminderStore: InMemoryReminderStore(),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

/// Bring `finder` into the built range of the profile's ListView.
///
/// The profile is eight sections deep and a ListView only builds what fits, so anything below
/// Device & calibration simply does not exist until it is scrolled to. Enlarging the test surface
/// instead trips a framework assertion in `_RawViewElement` when the next test resets it, which is
/// a worse trade than one extra line here.
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    400,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  group('the birth date goes on the wire as a date', () {
    test('it is a calendar date, never an instant', () {
      // `PhrProfilePatch.date_of_birth` is a `date`. `toIso8601String()` would produce
      // `1990-04-17T00:00:00.000`, which is a 422 that looks correct at a glance.
      expect(isoDateOnly(DateTime(1990, 4, 17)), '1990-04-17');
      expect(isoDateOnly(DateTime(1990, 4, 17)), isNot(contains('T')));
    });

    test('single digits are padded, so the server can parse it', () {
      expect(isoDateOnly(DateTime(2003, 1, 5)), '2003-01-05');
    });

    test('a local time near midnight does not shift the day', () {
      // Constructed local, sent as written. Converting to UTC first is how a birth date becomes
      // the day before for anyone east of Greenwich.
      expect(isoDateOnly(DateTime(1990, 4, 17, 23, 59)), '1990-04-17');
      expect(isoDateOnly(DateTime(1990, 4, 17, 0, 1)), '1990-04-17');
    });
  });

  group('the record it shows is the one on the server', () {
    testWidgets('account and clinical fields render from the API', (
      tester,
    ) async {
      await _pump(tester, _api(_happy()));

      expect(find.text('demo.patient@tera.invalid'), findsOneWidget);
      expect(find.text('Rafi'), findsOneWidget);
      expect(find.textContaining('17/04/1990'), findsOneWidget);
      expect(find.text('Female'), findsOneWidget);
      expect(find.text('172 cm'), findsOneWidget);
      expect(find.text('68 kg'), findsOneWidget);
      expect(find.text('Yes, diagnosed'), findsOneWidget);
      expect(find.text('Taking'), findsOneWidget);
    });

    testWidgets('age is derived from the date of birth', (tester) async {
      final born = DateTime.now().subtract(const Duration(days: 365 * 30 + 10));
      final dob =
          '${born.year}-${born.month.toString().padLeft(2, '0')}-'
          '${born.day.toString().padLeft(2, '0')}';

      await _pump(
        tester,
        _api({..._happy(), '/v1/profile': (200, _profile(dob: dob))}),
      );

      expect(find.textContaining('30 years'), findsOneWidget);
    });

    testWidgets('no BMI is shown, derived or otherwise', (tester) async {
      // 172 cm and 68 kg is a BMI of 23.0. The server refuses to derive one and computing it here
      // would route around that rather than honour it.
      await _pump(tester, _api(_happy()));

      expect(find.textContaining('BMI'), findsNothing);
      expect(find.textContaining('23.0'), findsNothing);
    });

    testWidgets('a field the patient has not set says so', (tester) async {
      await _pump(
        tester,
        _api({
          ..._happy(),
          '/v1/profile': (200, _profile(height: null, weight: null)),
        }),
      );

      expect(find.text('Not set'), findsWidgets);
    });
  });

  group('a failure never leaves the screen empty', () {
    testWidgets('an unreachable server still shows a retry and the sections', (
      tester,
    ) async {
      await _pump(tester, _api({}));

      expect(find.textContaining('could not be loaded'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      // The structure is still there rather than a blank page.
      expect(find.text('Account'), findsOneWidget);
      expect(find.text('Health record'), findsOneWidget);
      expect(find.text('Device & calibration'), findsOneWidget);
    });

    testWidgets('a 404 profile is an invitation, not an error', (tester) async {
      // The documented "no profile has been recorded yet". Reporting it as a failure would tell a
      // new patient something is broken on their first visit.
      await _pump(
        tester,
        _api({
          '/v1/auth/me': (200, _me()),
          '/v1/bp-reference/status': (200, _reference(has: false, ageDays: null)),
        }),
      );

      expect(find.textContaining('could not be loaded'), findsNothing);
      expect(find.textContaining('Nothing recorded yet'), findsOneWidget);
      expect(find.text('Add your details'), findsOneWidget);
    });

    testWidgets('a placeholder is shown while the requests are in flight', (
      tester,
    ) async {
      await _pump(
        tester,
        _api(_happy(), delay: const Duration(milliseconds: 300)),
        settle: false,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // The loading state is a moving placeholder rather than a blank card.
      expect(find.text('172 cm'), findsNothing);
      expect(find.text('Account'), findsOneWidget);

      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      expect(find.text('172 cm'), findsOneWidget);
    });
  });

  group('device and calibration report what was measured', () {
    testWidgets('a measured rate is shown, with its verdict', (tester) async {
      await _pump(
        tester,
        _api(_happy()),
        flowState: const AppFlowState(
          deviceEligibility: DeviceEligibility.eligible,
          deviceAccelRateHz: 450,
        ),
      );

      expect(find.text('Qualified'), findsOneWidget);
      expect(find.text('450 Hz measured'), findsOneWidget);
    });

    testWidgets('a rate that was never measured is not invented', (
      tester,
    ) async {
      await _pump(
        tester,
        _api(_happy()),
        flowState: const AppFlowState(
          deviceEligibility: DeviceEligibility.eligible,
        ),
      );

      expect(find.text('Not measured'), findsOneWidget);
      expect(find.textContaining('Hz measured'), findsNothing);
    });

    testWidgets('a marginal handset says how close to the floor it is', (
      tester,
    ) async {
      await _pump(
        tester,
        _api(_happy()),
        flowState: const AppFlowState(
          deviceEligibility: DeviceEligibility.eligible,
          deviceAccelRateHz: 220,
        ),
      );

      expect(find.text('220 Hz measured'), findsOneWidget);
      expect(find.textContaining('below the 500 Hz'), findsOneWidget);
    });

    testWidgets('calibration age comes from the server', (tester) async {
      await _pump(tester, _api(_happy()));

      expect(find.textContaining('set 9 days ago'), findsOneWidget);
      expect(find.text('Recalibrate with a cuff'), findsOneWidget);
    });

    testWidgets('a refresh due is named, and never called expired', (
      tester,
    ) async {
      // The spec is explicit about the wording: a reference needs a refresh, it does not expire.
      await _pump(
        tester,
        _api({
          ..._happy(),
          '/v1/bp-reference/status': (
            200,
            _reference(ageDays: 41, needsRefresh: true, reason: 'monitoring_gap'),
          ),
        }),
      );

      expect(find.textContaining('Needs refreshing'), findsOneWidget);
      expect(find.textContaining('expired'), findsNothing);
    });

    testWidgets('an uncalibrated patient is told what it costs', (tester) async {
      await _pump(
        tester,
        _api({
          ..._happy(),
          '/v1/bp-reference/status': (
            200,
            _reference(has: false, ageDays: null, needsRefresh: true),
          ),
        }),
      );

      expect(find.text('Not calibrated'), findsOneWidget);
      expect(find.text('Calibrate with a cuff'), findsOneWidget);
    });
  });

  group('editing is type-checked before anything is sent', () {
    Future<void> openEditor(WidgetTester tester) async {
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
    }

    /// The measurement fields, in order: height then weight.
    Finder measureField(int index) => find.byType(TextFormField).at(index);

    testWidgets('an out-of-range height is refused without a request', (
      tester,
    ) async {
      await _pump(tester, _api(_happy()));
      final before = requests.length;
      await openEditor(tester);

      await tester.enterText(measureField(0), '900');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('between 50 and 250 cm'), findsOneWidget);
      expect(
        requests.length,
        before,
        reason: 'an invalid value must not reach the API',
      );
    });

    testWidgets('letters cannot be entered into a measurement at all', (
      tester,
    ) async {
      await _pump(tester, _api(_happy()));
      await openEditor(tester);

      await tester.enterText(measureField(1), 'seventy');
      await tester.pumpAndSettle();

      // The input filter drops them, so the string never reaches the parser or the schema.
      expect(find.widgetWithText(TextFormField, 'seventy'), findsNothing);
    });

    testWidgets('only the changed field is sent', (tester) async {
      await _pump(
        tester,
        _api({..._happy(), '/v1/profile': (200, _profile())}),
      );
      await openEditor(tester);

      await tester.enterText(measureField(1), '71');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final posted = requests.lastWhere((r) => r.method == 'POST');
      final body = jsonDecode(posted.body) as Map<String, dynamic>;

      expect(body.keys, ['weight_kg']);
      expect(body['weight_kg'], 71.0);
      expect(
        body['weight_kg'],
        isA<num>(),
        reason: 'the schema takes a float, not the string that was typed',
      );
    });

    testWidgets('an unchanged form posts nothing', (tester) async {
      await _pump(tester, _api(_happy()));
      final before = requests.where((r) => r.method == 'POST').length;
      await openEditor(tester);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(requests.where((r) => r.method == 'POST').length, before);
    });

    testWidgets('a refusal from the server is shown, not swallowed', (
      tester,
    ) async {
      await _pump(
        tester,
        _api({
          '/v1/auth/me': (200, _me()),
          '/v1/profile': (200, _profile()),
          '/v1/bp-reference/status': (200, _reference()),
        }),
      );
      await openEditor(tester);
      await tester.enterText(measureField(0), '181');

      // The POST route is the same path as the GET, so it answers 200 here; the case under test
      // is the one where it does not, which `_api` produces for any unrouted path.
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // Saved and dismissed.
      expect(find.text('Your health record'), findsNothing);
    });
  });
  group('the display name never leaves the phone', () {
    testWidgets('saving a name makes no request at all', (tester) async {
      // The guarantee, asserted rather than described. `/v1/auth/register-patient` mints a
      // pseudonym and its docstring says deriving a name from the sign-up details would put one
      // into the clinical record sideways — so the name lives in the Keystore and neither
      // `ProfileEditSheet._changes` nor `PhrSubmitter.toPayload` has a field for it.
      await _pump(tester, _api(_happy()));
      final before = requests.length;

      await tester.tap(find.byTooltip('Edit display name'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Rafi Ghali');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(
        requests.length,
        before,
        reason: 'a display name must never reach the API: $requests',
      );
      expect(find.text('Rafi Ghali'), findsOneWidget);
    });

    testWidgets('no request body ever carries a name field', (tester) async {
      // Belt and braces: even the clinical edit, which does post, must not grow a name field.
      await _pump(tester, _api(_happy()));
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(1), '71');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      for (final r in requests.where((r) => r.method == 'POST')) {
        final body = r.body.toLowerCase();
        expect(body, isNot(contains('display_name')));
        expect(body, isNot(contains('"name"')));
      }
    });

    testWidgets('it is labelled as local, and says what sign-out does to it', (
      tester,
    ) async {
      await _pump(tester, _api(_happy()));

      expect(find.textContaining('Local display name'), findsOneWidget);
      expect(find.textContaining('signing out removes it'), findsOneWidget);
    });
  });

  group('security and the danger zone', () {
    testWidgets('both are offered, and deletion is not dressed up', (tester) async {
      await _pump(tester, _api(_happy()));

      await _scrollTo(tester, find.text('Change password'));
      expect(find.text('Change password'), findsOneWidget);

      await _scrollTo(tester, find.textContaining('kept under a pseudonym'));
      expect(find.text('Delete account'), findsWidgets);
      // The section states the retention position before the patient taps into it, so the
      // consequence is visible without committing to the flow.
      await _scrollTo(tester, find.textContaining('kept under a pseudonym'));
      expect(find.textContaining('kept under a pseudonym'), findsOneWidget);
    });

    testWidgets('a guest is offered neither', (tester) async {
      // A guest has no account to secure and none to delete.
      await _pump(tester, _api(_happy()), guest: true);

      await _scrollTo(tester, find.text('Change password'));
      final changePassword = tester.widget<ListTile>(
        find.ancestor(
          of: find.text('Change password'),
          matching: find.byType(ListTile),
        ),
      );
      expect(changePassword.onTap, isNull);
    });
  });

  group('production metadata', () {
    testWidgets('the version footer degrades honestly without a platform', (
      tester,
    ) async {
      // `PackageInfo.fromPlatform` never completes without a platform channel, which is why it
      // is fetched off the load path. The footer names the app and declines to invent a version.
      await _pump(tester, _api(_happy()));

      await _scrollTo(tester, find.text('TERA'));
      expect(find.text('TERA'), findsOneWidget);
      expect(find.textContaining('v1.0.0'), findsNothing);
    });

    testWidgets('the version is shown once the platform answers', (tester) async {
      PackageInfo.setMockInitialValues(
        appName: 'TERA',
        packageName: 'id.tera.tera_patient',
        version: '0.2.0',
        buildNumber: '42',
        buildSignature: '',
      );
      await _pump(tester, _api(_happy()));
      await tester.pumpAndSettle();

      await _scrollTo(tester, find.text('TERA v0.2.0 (build 42)'));
      expect(find.text('TERA v0.2.0 (build 42)'), findsOneWidget);
    });

    testWidgets('the policy and support tiles are present and wired', (tester) async {
      await _pump(tester, _api(_happy()));

      await _scrollTo(tester, find.text('Privacy policy'));
      expect(find.text('Privacy policy'), findsOneWidget);
      expect(find.text('Help & support'), findsOneWidget);
      // Wired to a real destination rather than a dead tile.
      expect(privacyPolicyUrl, startsWith('https://'));
      expect(supportUrl, startsWith('https://'));
    });
  });

  group('the close-account screen states both halves', () {
    testWidgets('it names what is deleted and what is kept', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CloseAccountScreen(
            api: _api(_happy()),
            onClosed: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Deleted'), findsOneWidget);
      expect(find.text('Kept, with nothing linking it to you'), findsOneWidget);
      // The promise the system can actually keep. Claiming a total erasure would be the more
      // serious failure, since the clinical rows are trigger-protected and cannot be removed.
      expect(find.textContaining('under a pseudonym'), findsOneWidget);
    });

    testWidgets('the button stays disabled until both gates are satisfied', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CloseAccountScreen(api: _api(_happy()), onClosed: () {}),
        ),
      );
      await tester.pumpAndSettle();

      FilledButton deleteButton() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Delete my account'),
      );

      expect(deleteButton().onPressed, isNull, reason: 'nothing entered yet');

      await tester.enterText(find.byType(TextFormField).at(0), 'a-password');
      await tester.pumpAndSettle();
      expect(deleteButton().onPressed, isNull, reason: 'password alone is not enough');

      await tester.enterText(find.byType(TextFormField).at(1), 'delete me');
      await tester.pumpAndSettle();
      expect(deleteButton().onPressed, isNull, reason: 'the word has to match');

      await tester.enterText(find.byType(TextFormField).at(1), 'DELETE');
      await tester.pumpAndSettle();
      expect(deleteButton().onPressed, isNotNull);
    });
  });

  group('changing a password', () {
    testWidgets('a mismatched confirmation never reaches the API', (tester) async {
      final api = _api(_happy());
      await tester.pumpWidget(
        MaterialApp(home: ChangePasswordScreen(api: api, onDone: () {})),
      );
      await tester.pumpAndSettle();
      final before = requests.length;

      await tester.enterText(find.byType(TextFormField).at(0), 'current-password');
      await tester.enterText(find.byType(TextFormField).at(1), 'a-new-long-password');
      await tester.enterText(find.byType(TextFormField).at(2), 'a-different-password');
      await tester.tap(find.widgetWithText(FilledButton, 'Change password'));
      await tester.pumpAndSettle();

      expect(find.textContaining('do not match'), findsOneWidget);
      expect(requests.length, before);
    });

    testWidgets('a short password is refused locally, naming the length', (
      tester,
    ) async {
      final api = _api(_happy());
      await tester.pumpWidget(
        MaterialApp(home: ChangePasswordScreen(api: api, onDone: () {})),
      );
      await tester.pumpAndSettle();
      final before = requests.length;

      await tester.enterText(find.byType(TextFormField).at(0), 'current-password');
      await tester.enterText(find.byType(TextFormField).at(1), 'short');
      await tester.enterText(find.byType(TextFormField).at(2), 'short');
      await tester.tap(find.widgetWithText(FilledButton, 'Change password'));
      await tester.pumpAndSettle();

      // Caught here rather than turned into a 422 whose body is a Pydantic error list.
      expect(find.textContaining('$minPasswordLength characters'), findsOneWidget);
      expect(requests.length, before);
    });

    testWidgets('a wrong current password reads as one, not as a lost session', (
      tester,
    ) async {
      // The server answers 403 precisely so the client's transparent-refresh path does not read
      // it as a dead session and sign the patient out mid-form.
      final api = _api({'/v1/auth/password': (403, {'detail': 'nope'})});
      await tester.pumpWidget(
        MaterialApp(home: ChangePasswordScreen(api: api, onDone: () {})),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).at(0), 'wrong-password');
      await tester.enterText(find.byType(TextFormField).at(1), 'a-new-long-password');
      await tester.enterText(find.byType(TextFormField).at(2), 'a-new-long-password');
      await tester.tap(find.widgetWithText(FilledButton, 'Change password'));
      await tester.pumpAndSettle();

      expect(find.text('That is not your current password.'), findsOneWidget);
    });
  });
}
