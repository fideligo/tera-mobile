/// The three onboarding screens as screens (PM spec section 7).
///
/// `flow_data_test.dart` covers the data — what round-trips, what the bounds are. This covers the
/// behaviour a patient meets: what the form refuses, what it remembers, and the two rules in
/// section 7 that are easy to write and easy to get wrong.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tera_patient/api/api_client.dart';
import 'package:tera_patient/auth/auth_controller.dart';
import 'package:tera_patient/auth/token_store.dart';
import 'package:tera_patient/capture/context_intake.dart';
import 'package:tera_patient/capture/phr_profile.dart';
import 'package:tera_patient/routing/app_flow_state.dart';
import 'package:tera_patient/routing/app_router.dart';
import 'package:tera_patient/ui/onboarding_screens.dart';
import 'package:tera_patient/ui/safety_onboarding_screen.dart';

TeraFlow _flow({AppFlowState state = const AppFlowState(), List<http.Request>? requests}) {
  late final AuthController auth;
  final api = ApiClient(
    baseUrl: 'http://test',
    tokenStore: InMemoryTokenStore(),
    httpClient: MockClient((request) async {
      requests?.add(request);
      return http.Response('{}', 200);
    }),
    onSessionLost: () => auth.onSessionLost(),
  );
  auth = AuthController(api: api);
  return TeraFlow(auth: auth, api: api, store: InMemoryAppFlowStore(state));
}

Future<void> _pump(WidgetTester tester, TeraFlow flow, Widget screen) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(onGenerateRoute: TeraRouter(flow).onGenerateRoute, home: screen),
  );
  await tester.pumpAndSettle();
}

/// Advance a bounded number of frames.
///
/// [WidgetTester.pumpAndSettle] cannot be used after a submit: the button swaps its label for a
/// `CircularProgressIndicator` while `_busy`, and that never stops animating, so settling on it
/// times out. Bounded pumping is enough for the writes and the navigation to finish.
Future<void> _pumpFrames(WidgetTester tester, {int frames = 25}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// Tap an answer row or button by its visible text.
///
/// [occurrence] disambiguates labels that repeat across questions — ONB-03 has three "Not sure"
/// rows, one per question, and tapping the wrong one silently answers the wrong question.
Future<void> _tapText(WidgetTester tester, String text, {int occurrence = 0}) async {
  // `findRichText` because the question headings carry the required-marker asterisk as a
  // TextSpan, and a plain `find.text` skips `Text.rich` entirely.
  final finder = find.text(text, findRichText: true).at(occurrence);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await _pumpFrames(tester);
}

void main() {
  group('ONB-01 — About You', () {
    testWidgets('the optional fields really are optional', (tester) async {
      // Section 7 marks height and weight "recommended, boleh skip". A form that refuses without
      // them would be a form that contradicts its own asterisks.
      final store = InMemoryPhrProfileStore();
      final flow = _flow();
      await _pump(tester, flow, AboutYouScreen(flow: flow, store: store));

      await _tapText(tester, 'Male');
      // The date picker is the only way to set a DOB, so it is driven rather than faked.
      await _tapText(tester, 'Choose your date of birth');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      await _tapText(tester, 'Next');

      final saved = await store.read();
      expect(saved.sexAtBirth, SexAtBirth.male);
      expect(saved.dateOfBirth, isNotNull);
      expect(saved.heightCm, isNull);
      expect(saved.weightKg, isNull);
      expect(flow.state.onboardingStep, OnboardingStep.safety);
    });

    testWidgets('an implausible height is refused before anything is saved', (tester) async {
      final store = InMemoryPhrProfileStore();
      final flow = _flow();
      await _pump(tester, flow, AboutYouScreen(flow: flow, store: store));

      await _tapText(tester, 'Female');
      await _tapText(tester, 'Choose your date of birth');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, '1680');
      await _tapText(tester, 'Next');

      expect(find.textContaining('between 50 and 250 cm'), findsOneWidget);
      expect((await store.read()).sexAtBirth, isNull);
      expect(flow.state.onboardingStep, OnboardingStep.aboutYou);
    });

    testWidgets('no BMI is computed, and the screen says so', (tester) async {
      final flow = _flow();
      await _pump(
        tester,
        flow,
        AboutYouScreen(flow: flow, store: InMemoryPhrProfileStore()),
      );

      expect(find.textContaining('does not calculate a BMI'), findsOneWidget);
    });
  });

  group('ONB-02 — Measurement Safety', () {
    testWidgets('pregnancy closes the contraindication gate', (tester) async {
      final intake = InMemoryContextIntakeStore();
      final flow = _flow();
      await _pump(
        tester,
        flow,
        SafetyOnboardingScreen(
          flow: flow,
          intakeStore: intake,
          profileStore: InMemoryPhrProfileStore(),
        ),
      );

      await _tapText(tester, 'Pregnant');
      await _tapText(tester, 'No');
      await _tapText(tester, 'Next');

      // The hard stop is shown before the step advances, and it is the gate's own wording.
      expect(find.text(pregnancyBlockTitle), findsOneWidget);
      await tester.tap(find.text('I understand'));
      await tester.pumpAndSettle();

      final saved = await intake.read();
      expect(saved!.pregnant, PregnancyAnswer.yes);
      expect(ContextIntakeSafety.allowsTrendGeneration(saved), isFalse);
    });

    testWidgets('"recently gave birth" asks for the date and does not claim pregnancy', (
      tester,
    ) async {
      // The wire enum has no fourth value, so the answer is recorded on the handset and sent as
      // `no`. Sending `yes` would tell a postpartum patient the method is unvalidated *in
      // pregnancy*, which is not a true statement about them.
      final intake = InMemoryContextIntakeStore();
      final profile = InMemoryPhrProfileStore();
      final flow = _flow();
      await _pump(
        tester,
        flow,
        SafetyOnboardingScreen(flow: flow, intakeStore: intake, profileStore: profile),
      );

      await _tapText(tester, 'Recently gave birth');
      // `textContaining`, not `text`: the heading is a `Text.rich` whose plain text ends with
      // the required-marker asterisk, so an exact match never hits it.
      expect(
        find.textContaining('When did you give birth?', findRichText: true),
        findsOneWidget,
      );

      // The date is required once that answer is chosen.
      await _tapText(tester, 'No');
      await _tapText(tester, 'Next');
      expect(find.textContaining('date you gave birth'), findsOneWidget);

      await _tapText(tester, 'Choose the date');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await _tapText(tester, 'Next');

      final saved = await intake.read();
      expect(saved!.pregnant, PregnancyAnswer.no);
      expect(find.text(pregnancyBlockTitle), findsNothing);

      // But the answer is not lost.
      final stored = await profile.read();
      expect(stored.postpartum, isTrue);
      expect(stored.postpartumDate, isNotNull);
    });

    testWidgets('"not sure" about rhythm is not recorded as a diagnosis', (tester) async {
      final intake = InMemoryContextIntakeStore();
      final profile = InMemoryPhrProfileStore();
      final flow = _flow();
      await _pump(
        tester,
        flow,
        SafetyOnboardingScreen(flow: flow, intakeStore: intake, profileStore: profile),
      );

      await _tapText(tester, 'Neither');
      await _tapText(tester, 'Not sure');
      await _tapText(tester, 'Next');

      expect((await intake.read())!.knownArrhythmia, isFalse);
      // Kept as itself on the handset, distinct from a plain "no".
      expect((await profile.read()).rhythmAnswer, 'notSure');
    });

    testWidgets('both questions are required', (tester) async {
      final flow = _flow();
      await _pump(
        tester,
        flow,
        SafetyOnboardingScreen(
          flow: flow,
          intakeStore: InMemoryContextIntakeStore(),
          profileStore: InMemoryPhrProfileStore(),
        ),
      );

      await _tapText(tester, 'Next');
      expect(find.textContaining('Answer both questions'), findsOneWidget);
      expect(flow.state.onboardingStep, OnboardingStep.aboutYou);
    });
  });

  group('ONB-03 — Health Context', () {
    Future<InMemoryPhrProfileStore> answerBoth(WidgetTester tester, TeraFlow flow) async {
      final store = InMemoryPhrProfileStore();
      await _pump(tester, flow, HealthContextScreen(flow: flow, store: store));
      await _tapText(tester, 'Yes, diagnosed');
      await _tapText(tester, 'Yes');
      return store;
    }

    testWidgets('"None of these" clears the conditions already ticked', (tester) async {
      final flow = _flow();
      final store = await answerBoth(tester, flow);

      await _tapText(tester, 'Diabetes');
      await _tapText(tester, 'High cholesterol');
      await _tapText(tester, 'None of these');
      await _tapText(tester, 'Finish');

      expect((await store.read()).conditions, isEmpty);
    });

    testWidgets('"Not sure" is mutually exclusive with a named condition', (tester) async {
      // Otherwise the record says both "I have diabetes" and "I do not know what I have", which
      // is not an answer anybody can read later.
      final flow = _flow();
      final store = await answerBoth(tester, flow);

      // The condition list's "Not sure" — the third on the screen.
      await _tapText(tester, 'Not sure', occurrence: 2);
      await _tapText(tester, 'Diabetes');
      await _tapText(tester, 'Finish');

      // Ticking a condition clears "Not sure" rather than sitting alongside it.
      expect((await store.read()).conditions, {KnownCondition.diabetes});
    });

    testWidgets('an untouched condition list is refused rather than read as "none"', (
      tester,
    ) async {
      // Invariant 7 in miniature: "no conditions" and "not answered" are different statements.
      final flow = _flow();
      final store = await answerBoth(tester, flow);

      await _tapText(tester, 'Finish');

      expect(find.textContaining('None of these'), findsWidgets);
      expect(flow.state.onboardingComplete, isFalse);
      expect((await store.read()).hypertension, isNull);
    });

    testWidgets('"Not sure" about medication is stored as unanswered, not as no', (
      tester,
    ) async {
      // `/v1/profile` takes a nullable bool. Recording "not sure" as false would assert
      // something the patient explicitly declined to assert.
      final store = InMemoryPhrProfileStore();
      final flow = _flow();
      await _pump(tester, flow, HealthContextScreen(flow: flow, store: store));

      await _tapText(tester, 'Yes, diagnosed');
      // The medication question's "Not sure", not the hypertension question's.
      await _tapText(tester, 'Not sure', occurrence: 1);
      await _tapText(tester, 'None of these');
      await _tapText(tester, 'Finish');

      final saved = await store.read();
      expect(saved.hypertension, HypertensionStatus.diagnosed);
      expect(saved.takesBpMedication, isNull);
    });
  });

  group('onboarding never blocks on the network', () {
    testWidgets('a failed upload still advances the step', (tester) async {
      // A form that will not advance because a request failed strands a patient at step one of
      // three, with no way past it.
      late final AuthController auth;
      final api = ApiClient(
        baseUrl: 'http://test',
        tokenStore: InMemoryTokenStore(),
        httpClient: MockClient((_) async => throw Exception('offline')),
        onSessionLost: () => auth.onSessionLost(),
      );
      auth = AuthController(api: api);
      final flow = TeraFlow(auth: auth, api: api, store: InMemoryAppFlowStore());

      final store = InMemoryPhrProfileStore();
      await _pump(tester, flow, AboutYouScreen(flow: flow, store: store));

      await _tapText(tester, 'Male');
      await _tapText(tester, 'Choose your date of birth');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await _tapText(tester, 'Next');

      expect(flow.state.onboardingStep, OnboardingStep.safety);
      expect((await store.read()).sexAtBirth, SexAtBirth.male);
    });
  });
}
