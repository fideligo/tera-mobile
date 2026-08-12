/// The check-session state machine from the PM spec, sections 31 and 38.
///
/// Everything here is **pure**: same inputs, same route, no IO and no clock of its own. `now` is a
/// parameter rather than a call to `DateTime.now()` so the seven-day rule can be tested at its
/// boundary instead of near it.
///
/// The routing decisions live here rather than inside widgets because they are product rules with
/// a written specification, and a rule spread across four `Navigator.push` call sites cannot be
/// read against that specification or tested without pumping a UI.
library;

import 'package:meta/meta.dart';

import 'routes.dart';

/// Section 10: the fork that everything downstream hangs off.
enum DeviceEligibility { eligible, notEligible }

/// Section 38: `session.mode`.
enum CheckMode {
  /// Eligible device: camera + accelerometer capture, producing a PTT trend.
  sensor,

  /// Not eligible: the user still logs and understands cuff readings. Not a degraded sensor
  /// path — a different product loop with its own value.
  bpOnly,
}

/// Section 31's states, named as the diagram names them.
enum CheckState {
  created,
  referenceRequired,
  precheck,
  waiting,
  context,
  walkthrough,
  capture,
  bpInput,
  processing,
  completed,
  failedQuality,
}

/// Section 38's `evaluateSignalQuality` outcome.
enum SignalQuality { accepted, retryableReject }

/// **Prototype product rule, not a clinical calibration expiry.**
///
/// The spec is explicit about this and about the wording that follows from it: never "your
/// calibration expired", always "your BP reference needs a refresh".
const int bpReferenceMaxAgeDays = 7;

/// Section 38's `MAX_ATTEMPTS`, from SIG-03's "3 unsuccessful attempts".
const int maxCaptureAttempts = 3;

/// What the reference rules need to know about the user. A view, not the user record.
@immutable
class BpReferenceStatus {
  const BpReferenceStatus({
    this.currentReferenceTakenAt,
    this.lastSuccessfulSensorCheckAt,
    this.forceReferenceRefresh = false,
  });

  /// Null means no reference has ever been set.
  final DateTime? currentReferenceTakenAt;

  /// Drives the monitoring-gap rule. Null means there has never been one.
  final DateTime? lastSuccessfulSensorCheckAt;

  /// Set by a medication change, a persistent BP-related change needing cuff confirmation, a
  /// major health change, or an explicit refresh from Profile.
  final bool forceReferenceRefresh;

  BpReferenceStatus copyWith({
    DateTime? currentReferenceTakenAt,
    DateTime? lastSuccessfulSensorCheckAt,
    bool? forceReferenceRefresh,
  }) => BpReferenceStatus(
    currentReferenceTakenAt: currentReferenceTakenAt ?? this.currentReferenceTakenAt,
    lastSuccessfulSensorCheckAt:
        lastSuccessfulSensorCheckAt ?? this.lastSuccessfulSensorCheckAt,
    forceReferenceRefresh: forceReferenceRefresh ?? this.forceReferenceRefresh,
  );
}

/// Section 13's PRE-01 answers, and the readiness they imply.
@immutable
class PrecheckAnswers {
  const PrecheckAnswers({
    required this.rested5Min,
    required this.recentActivity30Min,
    required this.recentCaffeine30Min,
    required this.recentNicotine30Min,
    required this.needsRestroom,
  });

  final bool rested5Min;
  final bool recentActivity30Min;
  final bool recentCaffeine30Min;
  final bool recentNicotine30Min;
  final bool needsRestroom;

  /// The spec's "ideal state". Anything else routes to the wait screen.
  bool get isReady =>
      rested5Min &&
      !recentActivity30Min &&
      !recentCaffeine30Min &&
      !recentNicotine30Min &&
      !needsRestroom;

  Map<String, dynamic> toJson() => {
    'rested_5_min': rested5Min,
    'recent_activity_30_min': recentActivity30Min,
    'recent_caffeine_30_min': recentCaffeine30Min,
    'recent_nicotine_30_min': recentNicotine30Min,
    'needs_restroom': needsRestroom,
    'status': isReady ? 'ready' : 'not_ready',
  };
}

/// One run through the check flow.
@immutable
class CheckSession {
  const CheckSession({
    required this.mode,
    required this.state,
    this.attemptCount = 0,
    this.precheck,
  });

  final CheckMode mode;
  final CheckState state;

  /// Capture attempts made. Bounded by [maxCaptureAttempts].
  final int attemptCount;

  final PrecheckAnswers? precheck;

  CheckSession copyWith({CheckState? state, int? attemptCount, PrecheckAnswers? precheck}) =>
      CheckSession(
        mode: mode,
        state: state ?? this.state,
        attemptCount: attemptCount ?? this.attemptCount,
        precheck: precheck ?? this.precheck,
      );
}

/// A state to move to and the route that shows it. Returned together so a caller cannot advance
/// the machine without navigating, or navigate without advancing it.
@immutable
class CheckStep {
  const CheckStep(this.session, this.route);

  final CheckSession session;
  final String route;
}

abstract final class CheckFlow {
  /// Section 38's `needsBPReference`.
  ///
  /// Three independent reasons, checked in the spec's order. Only sensor-mode sessions ask.
  static bool needsBpReference(BpReferenceStatus status, {required DateTime now}) {
    if (status.currentReferenceTakenAt == null) return true;

    final lastCheck = status.lastSuccessfulSensorCheckAt;
    // Never having completed a sensor check is an unbounded gap, not a zero one.
    if (lastCheck == null) return true;
    if (now.difference(lastCheck).inDays >= bpReferenceMaxAgeDays) return true;

    return status.forceReferenceRefresh;
  }

  /// Section 38's `startCheck`.
  ///
  /// A not-eligible device goes straight to the pre-check: it has no sensor trend to reference
  /// against, so asking it for a BP reference would be asking for a number nothing consumes.
  static CheckStep startCheck({
    required DeviceEligibility eligibility,
    required BpReferenceStatus reference,
    required DateTime now,
  }) {
    if (eligibility == DeviceEligibility.eligible) {
      const session = CheckSession(mode: CheckMode.sensor, state: CheckState.created);
      if (needsBpReference(reference, now: now)) {
        return CheckStep(
          session.copyWith(state: CheckState.referenceRequired),
          Routes.checkBpReference,
        );
      }
      return CheckStep(session.copyWith(state: CheckState.precheck), Routes.checkPrecondition);
    }

    const session = CheckSession(mode: CheckMode.bpOnly, state: CheckState.created);
    return CheckStep(session.copyWith(state: CheckState.precheck), Routes.checkPrecondition);
  }

  /// After BPREF: the reference is set, so the session joins the common path.
  static CheckStep afterBpReference(CheckSession session) =>
      CheckStep(session.copyWith(state: CheckState.precheck), Routes.checkPrecondition);

  /// Section 38's `afterPrecheck`.
  static CheckStep afterPrecheck(CheckSession session, PrecheckAnswers answers) {
    final next = session.copyWith(precheck: answers);
    if (!answers.isReady) {
      return CheckStep(next.copyWith(state: CheckState.waiting), Routes.checkWait);
    }
    return CheckStep(next.copyWith(state: CheckState.context), Routes.checkContext);
  }

  /// The wait screen's only exit: back to the pre-check questions, per section 31.
  static CheckStep afterWait(CheckSession session) =>
      CheckStep(session.copyWith(state: CheckState.precheck), Routes.checkPrecondition);

  /// Section 38's `afterContext`. This is where the two product loops diverge.
  static CheckStep afterContext(CheckSession session) {
    if (session.mode == CheckMode.sensor) {
      return CheckStep(
        session.copyWith(state: CheckState.walkthrough),
        Routes.checkWalkthrough1,
      );
    }
    return CheckStep(session.copyWith(state: CheckState.bpInput), Routes.checkBpInput);
  }

  /// Walkthrough steps 1-4, then capture. Returns null past the last step's successor, which
  /// would be a bug in the caller rather than a state.
  static CheckStep afterWalkthroughStep(CheckSession session, int completedStep) {
    if (completedStep < Routes.walkthroughSteps.length) {
      return CheckStep(session, Routes.walkthroughSteps[completedStep]);
    }
    return CheckStep(session.copyWith(state: CheckState.capture), Routes.checkCapture);
  }

  /// Section 38's `afterSensorCapture`.
  ///
  /// The attempt is counted here, on the way out of capture, so a retry that never reaches the
  /// gate cannot inflate the count and a rejected attempt always does.
  static CheckStep afterSensorCapture(CheckSession session, SignalQuality quality) {
    final attempted = session.copyWith(attemptCount: session.attemptCount + 1);

    if (quality == SignalQuality.accepted) {
      return CheckStep(attempted.copyWith(state: CheckState.processing), Routes.checkSignalAccepted);
    }
    if (attempted.attemptCount < maxCaptureAttempts) {
      return CheckStep(attempted.copyWith(state: CheckState.capture), Routes.checkSignalAdjust);
    }
    return CheckStep(
      attempted.copyWith(state: CheckState.failedQuality),
      Routes.checkSignalRepeatedFailure,
    );
  }

  static CheckStep afterSignalAccepted(CheckSession session) =>
      CheckStep(session.copyWith(state: CheckState.processing), Routes.checkProcessing);

  /// SIG-02's "Try again": back to capture, with the attempt count preserved.
  static CheckStep afterAdjust(CheckSession session) =>
      CheckStep(session.copyWith(state: CheckState.capture), Routes.checkCapture);

  /// BP-only: a confirmed reading is the measurement, so it goes straight to processing.
  static CheckStep afterBpConfirmed(CheckSession session) =>
      CheckStep(session.copyWith(state: CheckState.processing), Routes.checkProcessing);

  static CheckStep afterProcessing(CheckSession session) =>
      CheckStep(session.copyWith(state: CheckState.completed), Routes.checkInsight);
}
