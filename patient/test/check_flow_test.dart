/// The check-session state machine, against the PM spec's sections 31 and 38.
///
/// These are product rules with a written specification, so they are tested as rules — pure
/// functions, no widgets pumped — and the seven-day gap is tested *at* its boundary rather than
/// near it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tera_patient/routing/app_flow_state.dart';
import 'package:tera_patient/routing/check_session.dart';
import 'package:tera_patient/routing/routes.dart';

final _now = DateTime.utc(2026, 8, 12, 9, 0);

BpReferenceStatus _reference({
  DateTime? takenAt,
  DateTime? lastCheck,
  bool forceRefresh = false,
}) => BpReferenceStatus(
  currentReferenceTakenAt: takenAt,
  lastSuccessfulSensorCheckAt: lastCheck,
  forceReferenceRefresh: forceRefresh,
);

const _ready = PrecheckAnswers(
  rested5Min: true,
  recentActivity30Min: false,
  recentCaffeine30Min: false,
  recentNicotine30Min: false,
  needsRestroom: false,
);

void main() {
  group('needsBPReference', () {
    test('no reference at all means one is needed', () {
      expect(CheckFlow.needsBpReference(_reference(), now: _now), isTrue);
    });

    test('a reference with no completed sensor check still needs one', () {
      // An unbounded gap, not a zero one.
      expect(
        CheckFlow.needsBpReference(
          _reference(takenAt: _now.subtract(const Duration(days: 1))),
          now: _now,
        ),
        isTrue,
      );
    });

    test('a recent reference and a recent check needs none', () {
      expect(
        CheckFlow.needsBpReference(
          _reference(
            takenAt: _now.subtract(const Duration(days: 2)),
            lastCheck: _now.subtract(const Duration(days: 2)),
          ),
          now: _now,
        ),
        isFalse,
      );
    });

    group('the seven-day monitoring gap, at its boundary', () {
      test('six days and 23 hours does not trigger a refresh', () {
        expect(
          CheckFlow.needsBpReference(
            _reference(
              takenAt: _now.subtract(const Duration(days: 30)),
              lastCheck: _now.subtract(const Duration(days: 6, hours: 23)),
            ),
            now: _now,
          ),
          isFalse,
        );
      });

      test('exactly seven days does, because the rule is >=', () {
        expect(
          CheckFlow.needsBpReference(
            _reference(
              takenAt: _now.subtract(const Duration(days: 30)),
              lastCheck: _now.subtract(const Duration(days: 7)),
            ),
            now: _now,
          ),
          isTrue,
        );
      });

      test('the rule is seven days', () {
        // A prototype product rule, not a clinical calibration expiry. Changing it changes what
        // the product asks of a patient.
        expect(bpReferenceMaxAgeDays, 7);
      });
    });

    test('the force-refresh flag triggers one on its own', () {
      expect(
        CheckFlow.needsBpReference(
          _reference(
            takenAt: _now.subtract(const Duration(hours: 1)),
            lastCheck: _now.subtract(const Duration(hours: 1)),
            forceRefresh: true,
          ),
          now: _now,
        ),
        isTrue,
      );
    });
  });

  group('startCheck', () {
    test('an eligible device needing a reference goes to BP_REFERENCE_FLOW', () {
      final step = CheckFlow.startCheck(
        eligibility: DeviceEligibility.eligible,
        reference: _reference(),
        now: _now,
      );

      expect(step.session.mode, CheckMode.sensor);
      expect(step.session.state, CheckState.referenceRequired);
      expect(step.route, Routes.checkBpReference);
    });

    test('an eligible device with a current reference goes to PRECHECK', () {
      final step = CheckFlow.startCheck(
        eligibility: DeviceEligibility.eligible,
        reference: _reference(
          takenAt: _now.subtract(const Duration(days: 1)),
          lastCheck: _now.subtract(const Duration(days: 1)),
        ),
        now: _now,
      );

      expect(step.session.mode, CheckMode.sensor);
      expect(step.session.state, CheckState.precheck);
      expect(step.route, Routes.checkPrecondition);
    });

    test('a not-eligible device goes straight to PRECHECK in BP-only mode', () {
      final step = CheckFlow.startCheck(
        eligibility: DeviceEligibility.notEligible,
        reference: _reference(),
        now: _now,
      );

      expect(step.session.mode, CheckMode.bpOnly);
      expect(step.route, Routes.checkPrecondition);
    });

    test('a not-eligible device is never asked for a BP reference', () {
      // It has no sensor trend to reference against, so the number would have no consumer.
      for (final reference in [
        _reference(),
        _reference(forceRefresh: true),
        _reference(lastCheck: _now.subtract(const Duration(days: 400))),
      ]) {
        final step = CheckFlow.startCheck(
          eligibility: DeviceEligibility.notEligible,
          reference: reference,
          now: _now,
        );
        expect(step.route, isNot(Routes.checkBpReference));
      }
    });
  });

  group('afterPrecheck', () {
    test('the ideal state continues to context', () {
      final step = CheckFlow.afterPrecheck(
        const CheckSession(mode: CheckMode.sensor, state: CheckState.precheck),
        _ready,
      );

      expect(step.session.state, CheckState.context);
      expect(step.route, Routes.checkContext);
    });

    test('any single non-ideal answer routes to the wait screen', () {
      const variants = [
        PrecheckAnswers(
          rested5Min: false,
          recentActivity30Min: false,
          recentCaffeine30Min: false,
          recentNicotine30Min: false,
          needsRestroom: false,
        ),
        PrecheckAnswers(
          rested5Min: true,
          recentActivity30Min: true,
          recentCaffeine30Min: false,
          recentNicotine30Min: false,
          needsRestroom: false,
        ),
        PrecheckAnswers(
          rested5Min: true,
          recentActivity30Min: false,
          recentCaffeine30Min: true,
          recentNicotine30Min: false,
          needsRestroom: false,
        ),
        PrecheckAnswers(
          rested5Min: true,
          recentActivity30Min: false,
          recentCaffeine30Min: false,
          recentNicotine30Min: true,
          needsRestroom: false,
        ),
        PrecheckAnswers(
          rested5Min: true,
          recentActivity30Min: false,
          recentCaffeine30Min: false,
          recentNicotine30Min: false,
          needsRestroom: true,
        ),
      ];

      for (final answers in variants) {
        expect(answers.isReady, isFalse);
        final step = CheckFlow.afterPrecheck(
          const CheckSession(mode: CheckMode.sensor, state: CheckState.precheck),
          answers,
        );
        expect(step.session.state, CheckState.waiting);
        expect(step.route, Routes.checkWait);
      }
    });

    test('the answers are kept on the session, and the wait screen returns to the questions', () {
      final waiting = CheckFlow.afterPrecheck(
        const CheckSession(mode: CheckMode.sensor, state: CheckState.precheck),
        const PrecheckAnswers(
          rested5Min: false,
          recentActivity30Min: false,
          recentCaffeine30Min: false,
          recentNicotine30Min: false,
          needsRestroom: false,
        ),
      );

      expect(waiting.session.precheck, isNotNull);
      expect(CheckFlow.afterWait(waiting.session).route, Routes.checkPrecondition);
    });
  });

  group('afterContext forks the two product loops', () {
    test('sensor mode goes to the walkthrough', () {
      final step = CheckFlow.afterContext(
        const CheckSession(mode: CheckMode.sensor, state: CheckState.context),
      );

      expect(step.session.state, CheckState.walkthrough);
      expect(step.route, Routes.checkWalkthrough1);
    });

    test('BP-only mode goes to BP input', () {
      final step = CheckFlow.afterContext(
        const CheckSession(mode: CheckMode.bpOnly, state: CheckState.context),
      );

      expect(step.session.state, CheckState.bpInput);
      expect(step.route, Routes.checkBpInput);
    });
  });

  group('the walkthrough advances one step at a time and then captures', () {
    test('steps 1 to 4, then capture', () {
      const session = CheckSession(mode: CheckMode.sensor, state: CheckState.walkthrough);

      expect(CheckFlow.afterWalkthroughStep(session, 1).route, Routes.checkWalkthrough2);
      expect(CheckFlow.afterWalkthroughStep(session, 2).route, Routes.checkWalkthrough3);
      expect(CheckFlow.afterWalkthroughStep(session, 3).route, Routes.checkWalkthrough4);

      final last = CheckFlow.afterWalkthroughStep(session, 4);
      expect(last.route, Routes.checkCapture);
      expect(last.session.state, CheckState.capture);
    });
  });

  group('afterSensorCapture', () {
    const capturing = CheckSession(mode: CheckMode.sensor, state: CheckState.capture);

    test('an accepted signal goes to processing', () {
      final step = CheckFlow.afterSensorCapture(capturing, SignalQuality.accepted);

      expect(step.session.state, CheckState.processing);
      expect(step.route, Routes.checkProcessing);
      expect(step.session.attemptCount, 1);
    });

    test('a retryable reject offers an adjustment, and counts the attempt', () {
      final step = CheckFlow.afterSensorCapture(capturing, SignalQuality.retryableReject);

      expect(step.route, Routes.checkSignalAdjust);
      expect(step.session.attemptCount, 1);
      expect(CheckFlow.afterAdjust(step.session).route, Routes.checkCapture);
    });

    test('the third consecutive reject ends the session', () {
      var session = capturing;
      var step = CheckFlow.afterSensorCapture(session, SignalQuality.retryableReject);
      session = step.session;
      step = CheckFlow.afterSensorCapture(session, SignalQuality.retryableReject);
      session = step.session;
      expect(step.route, Routes.checkSignalAdjust);

      step = CheckFlow.afterSensorCapture(session, SignalQuality.retryableReject);

      expect(step.session.attemptCount, maxCaptureAttempts);
      expect(step.session.state, CheckState.failedQuality);
      expect(step.route, Routes.checkSignalRepeatedFailure);
    });

    test('the attempt ceiling is three', () {
      expect(maxCaptureAttempts, 3);
    });

    test('a retry that succeeds still reaches processing', () {
      final first = CheckFlow.afterSensorCapture(capturing, SignalQuality.retryableReject);
      final second = CheckFlow.afterSensorCapture(first.session, SignalQuality.accepted);

      expect(second.route, Routes.checkProcessing);
    });
  });

  group('the BP-only path reaches the same insight', () {
    test('a confirmed reading goes straight to processing, then insight', () {
      const session = CheckSession(mode: CheckMode.bpOnly, state: CheckState.bpInput);

      final processing = CheckFlow.afterBpConfirmed(session);
      expect(processing.route, Routes.checkProcessing);

      final insight = CheckFlow.afterProcessing(processing.session);
      expect(insight.route, Routes.checkInsight);
      expect(insight.session.state, CheckState.completed);
    });
  });

  group('AUTH-00 splash routing', () {
    test('an unchecked device goes to the device check', () {
      const state = AppFlowState();

      expect(state.deviceChecked, isFalse);
      expect(state.resumeRoute, Routes.deviceChecking);
    });

    test('a checked device with incomplete onboarding resumes at the unfinished step', () {
      const state = AppFlowState(
        deviceEligibility: DeviceEligibility.eligible,
        onboardingStep: OnboardingStep.safety,
      );

      // The step itself, not the first one: AUTH-00 says "unfinished onboarding step".
      expect(state.resumeRoute, Routes.onboardingSafety);
    });

    test('a complete setup goes home', () {
      const state = AppFlowState(
        deviceEligibility: DeviceEligibility.notEligible,
        onboardingStep: OnboardingStep.complete,
      );

      expect(state.onboardingComplete, isTrue);
      expect(state.resumeRoute, Routes.home);
    });

    test('a not-eligible device still completes onboarding and reaches home', () {
      // Section 6: the account is not blocked, and the user keeps Home, History, Profile and
      // BP input.
      const state = AppFlowState(
        deviceEligibility: DeviceEligibility.notEligible,
        onboardingStep: OnboardingStep.aboutYou,
      );

      expect(state.resumeRoute, Routes.onboardingAboutYou);
    });

    test('onboarding advances through all three screens in order', () {
      expect(OnboardingStep.aboutYou.next, OnboardingStep.safety);
      expect(OnboardingStep.safety.next, OnboardingStep.healthContext);
      expect(OnboardingStep.healthContext.next, OnboardingStep.complete);
      expect(OnboardingStep.complete.next, isNull);
    });
  });

  group('the flow state survives a restart', () {
    test('every field round-trips', () {
      final original = AppFlowState(
        deviceEligibility: DeviceEligibility.eligible,
        onboardingStep: OnboardingStep.healthContext,
        reference: _reference(
          takenAt: DateTime.utc(2026, 8, 1),
          lastCheck: DateTime.utc(2026, 8, 10),
          forceRefresh: true,
        ),
      );

      final restored = AppFlowState.fromJson(original.toJson());

      expect(restored.deviceEligibility, DeviceEligibility.eligible);
      expect(restored.onboardingStep, OnboardingStep.healthContext);
      expect(restored.reference.currentReferenceTakenAt, DateTime.utc(2026, 8, 1));
      expect(restored.reference.lastSuccessfulSensorCheckAt, DateTime.utc(2026, 8, 10));
      expect(restored.reference.forceReferenceRefresh, isTrue);
    });

    test('a fresh install has no eligibility and starts at about-you', () {
      final restored = AppFlowState.fromJson(const AppFlowState().toJson());

      expect(restored.deviceEligibility, isNull);
      expect(restored.onboardingStep, OnboardingStep.aboutYou);
    });

    test('the store round-trips and clears', () async {
      final store = InMemoryAppFlowStore();
      expect((await store.read()).deviceChecked, isFalse);

      await store.write(
        const AppFlowState(
          deviceEligibility: DeviceEligibility.eligible,
          onboardingStep: OnboardingStep.complete,
        ),
      );
      expect((await store.read()).resumeRoute, Routes.home);

      await store.clear();
      expect((await store.read()).resumeRoute, Routes.deviceChecking);
    });
  });
}
