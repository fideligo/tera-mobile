/// Screens that exist to drive the flow, not to be looked at.
///
/// Everything here is routing and state. Where a screen has real logic — the device probe, the
/// pre-check answers, the capture handoff — it is wired properly; where it does not, it is a
/// [FlowStubScreen] naming the spec section it stands for.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import '../capture/calibration_anchor.dart';
import '../capture/check_session_client.dart';
import '../capture/current_context.dart';
import '../capture/current_context_submitter.dart';
import '../capture/pending_check_store.dart';
import '../api/api_client.dart';
import '../capture/device_measurement.dart';
import '../capture/eligibility_check.dart';
import '../capture/session_context.dart';
import '../capture/session_submitter.dart';
import '../routing/check_payload.dart';
import '../routing/app_router.dart';
import '../routing/check_session.dart';
import '../routing/routes.dart';
import '../signal/signal_pipeline.dart';
import 'capture_screen.dart';
import 'cuff_reading_screen.dart';
import 'flow_stub_screen.dart';
import 'tokens.dart';

/// AUTH-00. Checks auth, then device eligibility, then onboarding, and routes once.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.flow});

  final TeraFlow flow;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _route());
  }

  Future<void> _route() async {
    await widget.flow.load();
    await widget.flow.auth.restore();
    if (!mounted) return;

    // Not authenticated wins over everything: there is no per-user state to resume without it.
    // Past that, the destination is the same table the two auth screens use, asked in the same
    // way — this screen does not get its own opinion about where setup resumes.
    final next = widget.flow.auth.status == AuthStatus.signedIn
        ? await widget.flow.resumeRouteAfterAuth()
        : Routes.login;
    if (!mounted) return;

    Navigator.of(context).pushNamedAndRemoveUntil(next, (r) => false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: TeraColors.page,
    body: Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(TeraRadius.card),
            child: Image.asset(
              'assets/logo.jpeg',
              width: 96,
              height: 96,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(height: TeraSpacing.md),
          const Text(
            'Tera',
            style: TextStyle(
              fontSize: TeraText.section,
              fontWeight: FontWeight.w700,
              color: TeraColors.ink,
            ),
          ),
          const SizedBox(height: TeraSpacing.lg),
          const CircularProgressIndicator(color: TeraColors.brand),
        ],
      ),
    ),
  );
}

/// PRE-01. The five readiness questions, and the only screen that decides between the wait
/// screen and the context screen.
class PrecheckScreen extends StatefulWidget {
  const PrecheckScreen({
    super.key,
    required this.session,
    this.flow,
    this.payload = const CheckPayload(),
  });

  final CheckSession session;
  final TeraFlow? flow;
  final CheckPayload payload;

  @override
  State<PrecheckScreen> createState() => _PrecheckScreenState();
}

class _PrecheckScreenState extends State<PrecheckScreen> {
  bool? _rested;
  bool? _activity;
  bool? _caffeine;
  bool? _nicotine;
  bool? _restroom;
  bool _busy = false;

  Future<void> _next() async {
    setState(() => _busy = true);
    final answers = PrecheckAnswers(
      rested5Min: _rested ?? true,
      recentActivity30Min: _activity ?? false,
      recentCaffeine30Min: _caffeine ?? false,
      recentNicotine30Min: _nicotine ?? false,
      needsRestroom: _restroom ?? false,
    );

    // Filed against the check session opened at the start of the flow.
    final flow = widget.flow;
    final checkSessionId = widget.payload.checkSessionId;
    if (flow != null && checkSessionId != null) {
      try {
        await CheckSessionClient(
          api: flow.api,
        ).submitPreconditions(checkSessionId: checkSessionId, answers: answers);
      } on Object {
        // Continue even if network fails, as the gate is local.
      }
    }

    if (!mounted) return;
    TeraFlow.advance(
      context,
      CheckFlow.afterPrecheck(widget.session, answers),
      payload: widget.payload,
    );
  }

  Widget _buildYesNoQuestion(
    String question,
    bool? value,
    ValueChanged<bool> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: TeraSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            question,
            style: const TextStyle(
              fontSize: TeraText.body,
              fontWeight: FontWeight.w600,
              color: TeraColors.ink,
              height: 1.4,
            ),
          ),
          const SizedBox(height: TeraSpacing.sm),
          Row(
            children: [
              Expanded(
                child: _buildToggle(
                  label: 'Yes',
                  isSelected: value == true,
                  onTap: () => onChanged(true),
                ),
              ),
              const SizedBox(width: TeraSpacing.sm),
              Expanded(
                child: _buildToggle(
                  label: 'No',
                  isSelected: value == false,
                  onTap: () => onChanged(false),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildToggle({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: isSelected ? TeraColors.brand : TeraColors.paper,
      borderRadius: BorderRadius.circular(TeraRadius.button),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(TeraRadius.button),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            border: Border.all(
              color: isSelected ? TeraColors.brand : TeraColors.neutral300,
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(TeraRadius.button),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: TeraText.body,
              fontWeight: FontWeight.w600,
              color: isSelected ? TeraColors.paper : TeraColors.ink,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TeraColors.paper,
      appBar: AppBar(
        title: const Text(
          'Before your check',
          style: TextStyle(
            color: TeraColors.ink,
            fontSize: TeraText.section,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: TeraColors.paper,
        elevation: 0,
        iconTheme: const IconThemeData(color: TeraColors.ink),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(TeraSpacing.lg),
                children: [
                  const Text(
                    'For a more comparable trend, check that you\'re in a resting condition.',
                    style: TextStyle(
                      fontSize: TeraText.body,
                      color: TeraColors.neutral700,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: TeraSpacing.xl),
                  _buildYesNoQuestion(
                    'Have you rested quietly for at least 5 minutes?',
                    _rested,
                    (v) => setState(() => _rested = v),
                  ),
                  _buildYesNoQuestion(
                    'Have you exercised or been physically active in the last 30 minutes?',
                    _activity,
                    (v) => setState(() => _activity = v),
                  ),
                  _buildYesNoQuestion(
                    'Have you had coffee, tea, or another caffeinated drink in the last 30 minutes?',
                    _caffeine,
                    (v) => setState(() => _caffeine = v),
                  ),
                  _buildYesNoQuestion(
                    'Have you smoked or used nicotine in the last 30 minutes?',
                    _nicotine,
                    (v) => setState(() => _nicotine = v),
                  ),
                  _buildYesNoQuestion(
                    'Do you need to use the restroom?',
                    _restroom,
                    (v) => setState(() => _restroom = v),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(TeraSpacing.lg),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed:
                      (_busy ||
                          _rested == null ||
                          _activity == null ||
                          _caffeine == null ||
                          _nicotine == null ||
                          _restroom == null)
                      ? null
                      : _next,
                  style: FilledButton.styleFrom(
                    backgroundColor: TeraColors.ink,
                    foregroundColor: TeraColors.paper,
                    padding: const EdgeInsets.symmetric(
                      vertical: TeraSpacing.md,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(TeraRadius.button),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        _busy ? 'Saving...' : 'Next',
                        style: const TextStyle(
                          fontSize: TeraText.body,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (!_busy) ...[
                        const SizedBox(width: TeraSpacing.sm),
                        const Icon(Icons.arrow_forward, size: 20),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// CTX-01. Collects the context the intervention matrix reads, then forks sensor from BP-only.
///
/// Nothing here is interpreted on the handset. "Feeling unwell" does not downgrade a result and a
/// missed dose produces no advice — invariant 6. The screen opens in the unremarkable state so an
/// ordinary day is one tap, per the spec's UX rule.
class CurrentContextScreen extends StatefulWidget {
  const CurrentContextScreen({
    super.key,
    required this.flow,
    required this.session,
    this.payload = const CheckPayload(),
  });

  final TeraFlow flow;
  final CheckSession session;
  final CheckPayload payload;

  @override
  State<CurrentContextScreen> createState() => _CurrentContextScreenState();
}

class _CurrentContextScreenState extends State<CurrentContextScreen> {
  bool _sleep = false;
  bool _stress = false;
  bool _unwell = false;
  bool _recentExercise = false;
  bool _moreCaffeine = false;
  bool _nothingUnusual1 = true;

  final Set<ContextSymptom> _symptoms = {};
  bool _otherSymptom = false;
  MedicationStatusToday _medication = MedicationStatusToday.notSure;

  bool _busy = false;

  Future<void> _next() async {
    setState(() => _busy = true);
    final collected = CurrentContext(
      sleepLessThanUsual: _sleep,
      stressHigherThanUsual: _stress,
      feelingUnwell: _unwell,
      symptoms: _symptoms,
      medicationStatusToday: _medication,
    );

    final checkSessionId = widget.payload.checkSessionId;
    if (checkSessionId != null) {
      try {
        await CurrentContextSubmitter(
          api: widget.flow.api,
        ).submitForSession(sessionId: checkSessionId, context: collected);
      } on Object {
        // Fallback local if network fails.
      }
    }

    if (!mounted) return;
    TeraFlow.advance(
      context,
      // Only a first run is shown the cuff intro. Everything else goes straight to the
      // walkthrough — calibration is a one-time step, not a per-check one.
      CheckFlow.afterContext(
        widget.session,
        needsCalibration: widget.payload.firstTimeCalibration,
      ),
      payload: widget.payload.copyWith(context: collected),
    );
  }

  Widget _buildChip(
    String label,
    bool isSelected,
    ValueChanged<bool> onSelected,
  ) {
    return FilterChip(
      label: Text(
        label,
        style: TextStyle(
          fontSize: TeraText.body,
          fontWeight: FontWeight.w500,
          color: isSelected ? TeraColors.brand : TeraColors.ink,
        ),
      ),
      selected: isSelected,
      onSelected: onSelected,
      selectedColor: TeraColors.brand.withValues(alpha: 0.1),
      backgroundColor: TeraColors.paper,
      shape: StadiumBorder(
        side: BorderSide(
          color: isSelected ? TeraColors.brand : TeraColors.neutral300,
          width: 1.5,
        ),
      ),
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(
        horizontal: TeraSpacing.sm,
        vertical: TeraSpacing.sm,
      ),
    );
  }

  Widget _buildSection(String title, Widget content) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: TeraText.section,
            fontWeight: FontWeight.bold,
            color: TeraColors.ink,
            height: 1.2,
          ),
        ),
        const SizedBox(height: TeraSpacing.md),
        content,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TeraColors.paper,
      appBar: AppBar(
        title: const Text(
          'About this check',
          style: TextStyle(
            color: TeraColors.ink,
            fontSize: TeraText.section,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: TeraColors.paper,
        elevation: 0,
        iconTheme: const IconThemeData(color: TeraColors.ink),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(TeraSpacing.lg),
                children: [
                  const Text(
                    'A few quick details help Tera put your result into context.',
                    style: TextStyle(
                      fontSize: TeraText.body,
                      color: TeraColors.neutral700,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: TeraSpacing.xl),
                  _buildSection(
                    'Anything different today?',
                    Wrap(
                      spacing: TeraSpacing.sm,
                      runSpacing: TeraSpacing.sm,
                      children: [
                        _buildChip(
                          'Slept less than usual',
                          _sleep,
                          (v) => setState(() {
                            _sleep = v;
                            _nothingUnusual1 = false;
                          }),
                        ),
                        _buildChip(
                          'Higher stress',
                          _stress,
                          (v) => setState(() {
                            _stress = v;
                            _nothingUnusual1 = false;
                          }),
                        ),
                        _buildChip(
                          'Recent exercise',
                          _recentExercise,
                          (v) => setState(() {
                            _recentExercise = v;
                            _nothingUnusual1 = false;
                          }),
                        ),
                        _buildChip(
                          'More caffeine than usual',
                          _moreCaffeine,
                          (v) => setState(() {
                            _moreCaffeine = v;
                            _nothingUnusual1 = false;
                          }),
                        ),
                        _buildChip(
                          'Feeling unwell',
                          _unwell,
                          (v) => setState(() {
                            _unwell = v;
                            _nothingUnusual1 = false;
                          }),
                        ),
                        _buildChip('Nothing unusual', _nothingUnusual1, (v) {
                          if (v)
                            setState(() {
                              _sleep = false;
                              _stress = false;
                              _unwell = false;
                              _recentExercise = false;
                              _moreCaffeine = false;
                              _nothingUnusual1 = true;
                            });
                        }),
                      ],
                    ),
                  ),
                  const SizedBox(height: TeraSpacing.xl),
                  _buildSection(
                    'How are you feeling?',
                    Wrap(
                      spacing: TeraSpacing.sm,
                      runSpacing: TeraSpacing.sm,
                      children: [
                        _buildChip(
                          'No symptoms',
                          _symptoms.isEmpty && !_otherSymptom,
                          (v) {
                            if (v)
                              setState(() {
                                _symptoms.clear();
                                _otherSymptom = false;
                              });
                          },
                        ),
                        for (final symptom in ContextSymptom.values)
                          _buildChip(
                            symptom.label,
                            _symptoms.contains(symptom),
                            (v) {
                              setState(() {
                                if (v)
                                  _symptoms.add(symptom);
                                else
                                  _symptoms.remove(symptom);
                              });
                            },
                          ),
                        _buildChip(
                          'Other',
                          _otherSymptom,
                          (v) => setState(() => _otherSymptom = v),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: TeraSpacing.xl),
                  _buildSection(
                    'Did you take your blood pressure medication as usual today?',
                    Wrap(
                      spacing: TeraSpacing.sm,
                      runSpacing: TeraSpacing.sm,
                      children: [
                        for (final status in MedicationStatusToday.values)
                          _buildChip(status.label, _medication == status, (v) {
                            if (v) setState(() => _medication = status);
                          }),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(TeraSpacing.lg),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy ? null : _next,
                  style: FilledButton.styleFrom(
                    backgroundColor: TeraColors.ink,
                    foregroundColor: TeraColors.paper,
                    padding: const EdgeInsets.symmetric(
                      vertical: TeraSpacing.md,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(TeraRadius.button),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        _busy ? 'Saving...' : 'Next',
                        style: const TextStyle(
                          fontSize: TeraText.body,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (!_busy) ...[
                        const SizedBox(width: TeraSpacing.sm),
                        const Icon(Icons.arrow_forward, size: 20),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// BPREF-02 and BP-only input. Reuses the screen that already carries scan, manual entry and the
/// explicit confirmation step.
class BpInputScreen extends StatelessWidget {
  const BpInputScreen({
    super.key,
    required this.flow,
    required this.session,
    this.payload = const CheckPayload(),
  });

  final TeraFlow flow;
  final CheckSession session;
  final CheckPayload payload;

  @override
  Widget build(BuildContext context) => CuffReadingScreen(
    api: flow.api,
    checkSessionId: payload.checkSessionId,
    onDone: () async {
      // A saved reading is a reference for the sensor path and the measurement itself for the
      // BP-only path. Either way it refreshes the reference clock.
      await flow.recordBpReference(DateTime.now());
      if (!context.mounted) return;

      if (session.mode == CheckMode.bpOnly) {
        TeraFlow.advance(context, CheckFlow.afterBpConfirmed(session));
      } else {
        // The reference was the thing that was missing; rejoin the common path.
        TeraFlow.advance(context, CheckFlow.afterBpReference(session));
      }
    },
  );
}

/// CAP-01. Runs the real capture, then the real pipeline, and reports the gate's verdict to the
/// state machine.
class CaptureRouteScreen extends StatefulWidget {
  const CaptureRouteScreen({
    super.key,
    required this.flow,
    required this.session,
    this.payload = const CheckPayload(),
  });

  final TeraFlow flow;
  final CheckSession session;
  final CheckPayload payload;

  @override
  State<CaptureRouteScreen> createState() => _CaptureRouteScreenState();
}

class _CaptureRouteScreenState extends State<CaptureRouteScreen> {
  bool _walkthroughDone = false;

  /// Set once the 60 s capture is done and a first-time calibration still owes its cuff reading.
  /// Held rather than passed onward immediately: the reading has to be entered before the session
  /// can be filed, so the flow pauses here instead of at the processing screen.
  SignalResult? _awaitingCuffFor;
  DateTime? _awaitingCuffAt;

  /// The session as this screen now holds it, including attempts made without leaving it.
  ///
  /// A retry after a local rejection remounts [CaptureScreen] in place rather than navigating to
  /// SIG-02 and back, so the incremented attempt count has to live here or every retry would look
  /// like the first one and the three-attempt cap would never be reached.
  CheckSession? _session;
  CheckSession get _current => _session ?? widget.session;

  /// Forces [CaptureScreen] to remount on a retry. It starts its countdown from `initState`, so a
  /// new key is what "resets the capture screen" actually means.
  Key _captureKey = UniqueKey();

  void _advanceWith(
    BuildContext context,
    SignalResult result,
    DateTime capturedAt, {
    int? systolic,
    int? diastolic,
  }) {
    TeraFlow.advance(
      context,
      CheckFlow.afterSensorCapture(_current, SignalQuality.accepted),
      payload: widget.payload.copyWith(
        signal: result,
        capturedAt: capturedAt,
        calibrationSystolic: systolic,
        calibrationDiastolic: diastolic,
      ),
    );
  }

  /// What the patient is told when the capture did not carry a measurement.
  ///
  /// Every reason names something about the *recording*, never about the patient's health — a
  /// refused capture says the phone could not read the signal, and must not read as a finding.
  static String _rejectionDetail(SignalRejection? reason) => switch (reason) {
    SignalRejection.excessiveMotion => 'There was too much movement to read the signal.',
    SignalRejection.insufficientBeats =>
      'Too few heartbeats came through clearly for a measurement.',
    SignalRejection.clockUnstable =>
      'The camera and motion sensor could not be placed on one timeline.',
    SignalRejection.signalProcessingUnavailable =>
      'The analysis could not be completed for this recording.',
    _ => 'The camera and motion signals were not clear enough.',
  };

  /// The local quality gate's dialog. Returns true when the patient wants another attempt.
  ///
  /// Not dismissible: the capture is over and the only two ways forward are another attempt or
  /// leaving, so a stray tap must not drop the patient onto a dead screen.
  Future<bool> _showRetryDialog(SignalResult result) async {
    final again = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TeraRadius.card),
        ),
        backgroundColor: TeraColors.paper,
        title: const Text(
          'This recording cannot be used',
          style: TextStyle(fontWeight: FontWeight.w700, color: TeraColors.ink),
        ),
        content: Text(
          'Recording unstable. Please keep your hand still and try again.'
          '\n\n${_rejectionDetail(result.rejectionReason)}',
          style: const TextStyle(color: TeraColors.ink, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Back to home'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: TeraColors.ink,
              foregroundColor: TeraColors.paper,
            ),
            child: const Text('Try again'),
          ),
        ],
      ),
    );
    return again ?? false;
  }

  /// A capture the local gate refused. **Nothing is submitted.**
  ///
  /// The attempt is counted through the state machine, which is also what decides when three
  /// failures have been reached; past that the existing SIG-03 screen takes over rather than the
  /// dialog repeating forever.
  Future<void> _handleRejected(SignalResult result) async {
    final step = CheckFlow.afterSensorCapture(
      _current,
      SignalQuality.retryableReject,
    );

    if (step.session.state == CheckState.failedQuality) {
      TeraFlow.advance(context, step, payload: widget.payload);
      return;
    }

    final again = await _showRetryDialog(result);
    if (!mounted) return;
    if (!again) {
      TeraFlow.toHome(context);
      return;
    }
    setState(() {
      _session = step.session;
      _captureKey = UniqueKey();
    });
  }

  @override
  Widget build(BuildContext context) {
    // The cuff step of a first-time calibration, shown *after* the 60 s recording — the two
    // measurements are meant to be concurrent, so the number is read off the cuff while the
    // phone recording is still fresh rather than several screens earlier.
    //
    // `CuffReadingScreen` is reused rather than reimplemented: it already carries the scan and
    // manual paths, the plausibility bounds, and the explicit confirmation step, and it files the
    // reading as a real `cuff_reading` through the tested route.
    final pending = _awaitingCuffFor;
    if (pending != null) {
      return CuffReadingScreen(
        api: widget.flow.api,
        checkSessionId: widget.payload.checkSessionId,
        isReference: true,
        onDone: () {
          if (!context.mounted) return;
          _advanceWith(context, pending, _awaitingCuffAt ?? DateTime.now());
        },
      );
    }

    if (!_walkthroughDone) {
      return ScgPpgWalkthroughScreen(
        onDone: () => setState(() => _walkthroughDone = true),
      );
    }
    return CaptureScreen(
      key: _captureKey,
      onComplete: (capture) async {
        // **A completed 60 seconds never leaves the patient with nothing.**
        //
        // `process()` was called unguarded here. Most of it is wrapped internally, but the rate
        // statistics and the clock-basis read at the top of it are not, so a fault there threw
        // straight out of this async callback with nothing to catch it — `TeraFlow.advance` never
        // ran and the capture was simply lost after a full minute of the patient holding still.
        SignalResult result;
        try {
          result = await const TeraSignalPipeline().process(capture);
        } on Object {
          // The chain faulted outright. The minute still happened — but it produced no
          // measurement, and this now says so instead of inventing forty intervals and marking
          // them synthetic on the way to the patient's clinical record.
          result = const SignalResult(
            accepted: false,
            rejectionReason: SignalRejection.signalProcessingUnavailable,
            pttMs: [],
            nBeatsTotal: 0,
            nBeatsUsable: 0,
            quality: {},
            scg: [],
            ppg: [],
          );
        }
        if (!context.mounted) return;

        // **The local gate, before anything is sent.** A refused capture never reaches
        // `SessionSubmitter`, never establishes a calibration, and never counts as a successful
        // sensor check — the three things below all assume a measurement exists.
        if (!result.accepted) {
          await _handleRejected(result);
          return;
        }

        await widget.flow.recordSuccessfulSensorCheck(DateTime.now());
        if (!context.mounted) return;

        // First run: the recording is done, now collect the cuff number that calibrates it.
        if (widget.payload.firstTimeCalibration) {
          // **Written to disk before the cuff screen, because that screen opens the camera.**
          // `image_picker` starts a separate activity and Android may destroy this one behind it;
          // if it does, `_awaitingCuffFor` and the whole payload go with it, and the patient has
          // sat through sixty seconds for nothing. `ProcessingScreen` reads this back when it
          // finds itself with no signal in memory.
          await const PendingCheckStore().save(
            signal: result,
            checkSessionId: widget.payload.checkSessionId,
            capturedAt: capture.startedAt,
          );
          if (!context.mounted) return;
          setState(() {
            _awaitingCuffFor = result;
            _awaitingCuffAt = capture.startedAt;
          });
          return;
        }

        // Always `accepted` once the timer has run: the pipeline's own gate is already
        // hard-accepted for the demo, and the only other way this reached SIG-02 was the fault
        // path above. Signal honesty is carried by `SignalResult.synthetic`, which travels with
        // the payload and is what the record and the result screen are labelled from.
        _advanceWith(context, result, capture.startedAt);
      },
    );
  }
}

class ScgPpgWalkthroughScreen extends StatefulWidget {
  final VoidCallback onDone;
  const ScgPpgWalkthroughScreen({super.key, required this.onDone});

  @override
  State<ScgPpgWalkthroughScreen> createState() =>
      _ScgPpgWalkthroughScreenState();
}

class _ScgPpgWalkthroughScreenState extends State<ScgPpgWalkthroughScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  // Track confirmation for each page
  final List<bool> _confirmed = [false];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TeraColors.paper,
      appBar: AppBar(
        title: const Text(
          'Setup',
          style: TextStyle(
            color: TeraColors.ink,
            fontSize: TeraText.section,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: TeraColors.paper,
        elevation: 0,
        iconTheme: const IconThemeData(color: TeraColors.ink),
        leading: _currentPage > 0
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  _pageController.previousPage(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                  );
                },
              )
            : null,
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Progress dots
            Padding(
              padding: const EdgeInsets.symmetric(vertical: TeraSpacing.md),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  1,
                  (index) => Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: _currentPage == index ? 24 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _currentPage == index
                          ? TeraColors.brand
                          : TeraColors.neutral300,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pageController,
                physics:
                    const NeverScrollableScrollPhysics(), // Disable swipe to force confirmation
                onPageChanged: (i) => setState(() => _currentPage = i),
                children: [
                  // One page, not two. "Place your phone on your chest" used to live here, before
                  // the camera screen — which asked the patient to do the two things in the
                  // physically impossible order: phone flat on the sternum first, then find and
                  // cover a rear lens they can no longer see. Chest placement now happens during
                  // the five-second countdown, after the finger is locked, which is the only
                  // order that actually works one-handed.
                  _buildPage(
                    step: 'Are you seated?',
                    sub:
                        'Sit upright with your back supported, shoulders and head relaxed. Stay '
                        'seated for the whole check — the next screen turns on the camera light.',
                    icon: Icons.airline_seat_recline_normal,
                    confirmText: 'I\'m seated',
                    pageIndex: 0,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(TeraSpacing.lg),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _confirmed[_currentPage] ? widget.onDone : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: TeraColors.ink,
                    foregroundColor: TeraColors.paper,
                    disabledBackgroundColor: TeraColors.neutral300,
                    disabledForegroundColor: TeraColors.neutral500,
                    padding: const EdgeInsets.symmetric(
                      vertical: TeraSpacing.md,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(TeraRadius.button),
                    ),
                  ),
                  child: const Text(
                    'Start camera',
                    style: TextStyle(
                      fontSize: TeraText.body,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPage({
    required String step,
    required String sub,
    required IconData icon,
    required String confirmText,
    required int pageIndex,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: TeraSpacing.xl,
        vertical: TeraSpacing.lg,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          const SizedBox(height: TeraSpacing.xl),
          Container(
            padding: const EdgeInsets.all(TeraSpacing.xxl),
            decoration: BoxDecoration(
              color: TeraColors.brand.withValues(alpha: 0.05),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 80, color: TeraColors.brand),
          ),
          const SizedBox(height: TeraSpacing.xxl),
          Text(
            step,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: TeraText.section,
              fontWeight: FontWeight.bold,
              color: TeraColors.ink,
            ),
          ),
          const SizedBox(height: TeraSpacing.md),
          Text(
            sub,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: TeraText.body,
              color: TeraColors.neutral700,
              height: 1.4,
            ),
          ),
          const Spacer(),
          // Confirmation Toggle
          Material(
            color: _confirmed[pageIndex]
                ? TeraColors.brand.withValues(alpha: 0.1)
                : TeraColors.paper,
            borderRadius: BorderRadius.circular(TeraRadius.button),
            child: InkWell(
              onTap: () {
                setState(() {
                  _confirmed[pageIndex] = !_confirmed[pageIndex];
                });
              },
              borderRadius: BorderRadius.circular(TeraRadius.button),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  vertical: TeraSpacing.md,
                  horizontal: TeraSpacing.md,
                ),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _confirmed[pageIndex]
                        ? TeraColors.brand
                        : TeraColors.neutral300,
                    width: 1.5,
                  ),
                  borderRadius: BorderRadius.circular(TeraRadius.button),
                ),
                child: Row(
                  children: [
                    Icon(
                      _confirmed[pageIndex]
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      color: _confirmed[pageIndex]
                          ? TeraColors.brand
                          : TeraColors.neutral500,
                    ),
                    const SizedBox(width: TeraSpacing.md),
                    Expanded(
                      child: Text(
                        confirmText,
                        style: TextStyle(
                          fontSize: TeraText.body,
                          fontWeight: FontWeight.w600,
                          color: _confirmed[pageIndex]
                              ? TeraColors.brand
                              : TeraColors.ink,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// PROC-01. Submission happens here; the insight follows.
class ProcessingScreen extends StatefulWidget {
  const ProcessingScreen({
    super.key,
    required this.flow,
    required this.session,
    this.payload = const CheckPayload(),
    this.measurements,
  });

  final TeraFlow flow;
  final CheckSession session;
  final CheckPayload payload;

  /// Injectable so a test can exercise the submission and its error handling without a camera.
  /// Null measures the handset for real.
  final Future<DeviceMeasurements> Function()? measurements;

  @override
  State<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends State<ProcessingScreen> {
  String? _error;

  /// Set when the backend refused because pregnancy is recorded. Its own state because it is not
  /// a failure to retry — it is the contraindication gate doing its job.
  bool _contraindicated = false;

  /// A check session opened late, here, because the one at the start of the flow could not be.
  String? _recoveredCheckSessionId;

  /// A capture read back from disk after the activity was destroyed mid-flow.
  SignalResult? _restoredSignal;
  DateTime? _restoredCapturedAt;

  /// The payload as it now stands, including any late-opened check session.
  CheckPayload get _payload => widget.payload.copyWith(
    checkSessionId: _recoveredCheckSessionId,
    signal: _restoredSignal,
    capturedAt: _restoredCapturedAt,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  /// Open a check session now, if the one at the start of the flow never opened.
  ///
  /// **This is why the insight screen said "this check did not produce a result to explain".**
  /// `HomeScreen` opens the check session before the first question, and swallows the failure so
  /// the flow can still run offline — but nothing ever tried again. A single failed request at the
  /// door (an unreachable API is the usual cause: without `TERA_API_URL` the app talks to
  /// `10.0.2.2`, which resolves to nothing from a physical handset) left `checkSessionId` null for
  /// the whole check. The capture still ran, because capture is entirely on-device, and then the
  /// insight had no session to ask about and bailed before making a single call.
  ///
  /// Retrying here costs one request and recovers the entire result path whenever the connection
  /// came back during the minute of capture.
  Future<void> _ensureCheckSession() async {
    if (widget.payload.checkSessionId != null) return;
    try {
      final resolved = await SessionContextResolver(
        api: widget.flow.api,
      ).resolveEpisode();
      final id = await CheckSessionClient(api: widget.flow.api).open(
        episodeId: resolved.episodeId,
        mode: widget.session.mode,
      );
      debugPrint('[TERA] check session recovered late: $id');
      if (mounted) setState(() => _recoveredCheckSessionId = id);
    } on Object catch (e) {
      debugPrint('[TERA] check session STILL unreachable: $e');
      // Still unreachable. The insight screen reports that honestly rather than inventing a
      // result; see its own fallback.
    }
  }

  /// The AI-commentary question. Returns the patient's answer; `false` if they dismissed it.
  ///
  /// Deliberately not dismissible by tapping outside: this is a question about sending health
  /// data to a third party, and an accidental tap must not read as agreement.
  Future<bool> _askAiConsent() async {
    final consent = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TeraRadius.card),
        ),
        backgroundColor: TeraColors.paper,
        title: const Text(
          'Data Privacy Notice',
          style: TextStyle(fontWeight: FontWeight.w700, color: TeraColors.ink),
        ),
        content: const Text(
          'Do you allow sending your results to a public AI API (NVIDIA) for personalized '
          'insights?\n\n'
          'Your result and health profile would be sent — never the recording itself, and '
          'never your name. If you say no, you still get your full result; it simply comes '
          'from Tera alone.',
          style: TextStyle(color: TeraColors.ink, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('No'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: TeraColors.ink,
              foregroundColor: TeraColors.paper,
            ),
            child: const Text('Yes'),
          ),
        ],
      ),
    );
    return consent ?? false;
  }

  /// Read a capture back from disk when there is none in memory.
  ///
  /// The camera intent behind the cuff screen can take this activity down with it — see
  /// `PendingCheckStore`. Without this, the flow arrives here with `signal == null`, takes the
  /// BP-only branch below, and quietly submits nothing after a full minute of recording.
  Future<void> _restorePendingCheck() async {
    if (widget.payload.signal != null) return;

    final pending = await const PendingCheckStore().read();
    if (pending == null || !mounted) return;

    debugPrint(
      '[TERA] restored capture from disk: ptt=${pending.signal.pttMs.length} '
      'checkSessionId=${pending.checkSessionId}',
    );
    setState(() {
      _restoredSignal = pending.signal;
      _restoredCapturedAt = pending.capturedAt;
      _recoveredCheckSessionId ??= pending.checkSessionId;
    });
  }

  /// Establish the calibration this patient's estimates are anchored to.
  ///
  /// Single-point: one confirmed cuff reading plus the session just stored. The server computes
  /// the baseline from the session's own PTT — it is never sent from here, because a handset that
  /// could write its own baseline could make any later reading look however it liked.
  ///
  /// Best effort, and deliberately so: the capture is already filed by the time this runs, and a
  /// failure here costs the estimate on later checks, not this reading. It is skipped entirely
  /// when there is no anchor to point at.
  Future<void> _establishCalibration(
    SessionContext resolved,
    String sessionId,
  ) async {
    const anchors = CalibrationAnchorStore();
    final anchorId = await anchors.read();
    if (anchorId == null) return;

    try {
      await widget.flow.api.postJson('/v1/calibrations', {
        'patient_id': resolved.patientId,
        'device_profile_id': resolved.deviceProfileId,
        'reference_cuff_reading_id': anchorId,
        'session_ids': [sessionId],
      });
      debugPrint('[TERA] calibration established against cuff reading $anchorId');
      // Consumed. Leaving it would re-anchor every future check to the same old reading.
      await anchors.clear();
    } on Object catch (e) {
      debugPrint('[TERA] calibration could not be established: $e');
    }
  }

  Future<void> _run() async {
    await _restorePendingCheck();
    if (!mounted) return;

    final signal = _payload.signal;

    await _ensureCheckSession();
    if (!mounted) return;

    // **BP-only never touches the hardware.** The confirmed reading is the measurement and
    // `CuffReadingScreen` already filed it, so there is no capture to submit and no device to
    // measure. Returning here is what keeps a not-eligible handset off the camera path entirely.
    //
    // It still has a check session, so its context attaches to the same place a sensor check's
    // does and its insight is fetched the same way.
    if (widget.session.mode == CheckMode.bpOnly || signal == null) {
      await _fileContext();
      if (!mounted) return;
      TeraFlow.advance(
        context,
        CheckFlow.afterProcessing(widget.session),
        payload: _payload,
      );
      return;
    }

    try {
      // `resolveLazily`, not `resolve(await _measurements())`. The eager form re-ran the full
      // eligibility probe after every capture and was the direct cause of completed 60-second
      // recordings landing on SIG-02 — see `SessionContextResolver.resolveLazily`.
      final resolved = await SessionContextResolver(
        api: widget.flow.api,
      ).resolveLazily(_measurements);

      debugPrint(
        '[TERA] submitting: checkSessionId=${_payload.checkSessionId} '
        'ptt=${signal.pttMs.length} synthetic=${signal.synthetic}',
      );
      final outcome = await SessionSubmitter(api: widget.flow.api).submit(
        episodeId: resolved.episodeId,
        deviceProfileId: resolved.deviceProfileId,
        startedAt: _payload.capturedAt ?? DateTime.now(),
        signal: signal,
      );

      // First run: the session is stored and the cuff reading is filed, so the calibration
      // that anchors every later estimate can finally be established.
      //
      // **Nothing called this before.** `POST /v1/calibrations` existed, was tested, and had no
      // caller anywhere in the app — so `resolve_at` found nothing in force, `ingest.submit`
      // took its `in_force is None` branch, and every session came back with
      // `estimate_produced: false`. That is the whole reason no estimate has ever appeared; it
      // was never a quality gate or a frame rate.
      await _establishCalibration(resolved, outcome.sessionId);

      // Filed. The disk copy has done its job and must not outlive it — a stale capture
      // reattached to a later check would file a reading against the wrong moment.
      await const PendingCheckStore().clear();

      await _fileContext();

      if (!mounted) return;

      // Move the check into processing. **This request carries nothing**, which is the whole
      // contract: `ProcessIn` is an empty model and whatever is being processed is already
      // stored. It briefly carried `{'scg': [...], 'ppg': [...], 'ai_consent': true}` instead,
      // which broke two ways at once — the empty schema is `extra="forbid"`, so every call 422'd
      // and the flow never reached the insight screen; and shipping the raw accelerometer and
      // ROI-intensity arrays off the handset is precisely what invariant 2 forbids. The derived
      // per-beat intervals in `signal.pttMs` already went up with the session submission above,
      // and that is the deepest granularity the API accepts.
      //
      // Best effort: the session is already filed, so a failure here must not strand the patient
      // short of the result that submission produced.
      final checkSessionId = _payload.checkSessionId;
      if (checkSessionId != null) {
        try {
          await widget.flow.api.postJson(
            '/v1/check-sessions/$checkSessionId/process',
            const {},
          );
        } on Object {
          // Deliberately swallowed — see above.
        }
      }

      if (!mounted) return;

      // The AI question, asked here — after the recording is finished and the session is safely
      // filed, before the result screen is built. Either answer continues to the insight; the
      // only thing it changes is whether that screen asks the backend for the extra paragraph.
      final consent = await _askAiConsent();
      if (!mounted) return;

      TeraFlow.advance(
        context,
        CheckFlow.afterProcessing(widget.session),
        payload: _payload.copyWith(
          submittedSessionId: outcome.sessionId,
          aiConsent: consent,
        ),
      );
    } on DeviceMeasurementFailure catch (e) {
      // **Not a signal-quality outcome, and no longer reported as one.** This means the handset
      // could not be *measured* — the camera or the motion sensor did not answer. Routing it to
      // SIG-02 told a patient who had just held still for a full minute that they had moved,
      // which is both false and unactionable: repositioning a finger cannot fix a camera that
      // will not report its capabilities. It now says what actually happened, and offers a retry.
      if (!mounted) return;
      setState(() => _error = e.reason);
    } on SessionExpiredException {
      // **A guest, or a lapsed session — not an error worth stopping for.**
      //
      // Must be caught above `ApiException`, which it extends: as a plain 401 it was landing in
      // the generic branch below and stranding the patient on this screen with an error, after a
      // full minute of recording. Nothing about the capture failed. It ran, it was analysed on
      // this handset, and the result screen can show what was measured — so the flow continues
      // there and renders the offline card from `payload.signal`.
      //
      // Nothing was submitted, and nothing downstream claims otherwise: there is no check session
      // id, so `InsightScreen` never asks the server for a trend it could not produce anyway.
      debugPrint('[TERA] not authenticated — routing to the local-only result');
      if (!mounted) return;
      TeraFlow.advance(
        context,
        CheckFlow.afterProcessing(widget.session),
        // Consent is recorded as declined rather than left null: with no session there is nothing
        // to send, and leaving it null would make the result screen ask a question whose answer
        // cannot change anything.
        payload: _payload.copyWith(aiConsent: false),
      );
    } on ApiException catch (e) {
      debugPrint('[TERA] API FAILED ${e.statusCode}: ${e.message}');
      if (!mounted) return;
      setState(() {
        // 403 is the server-side contraindication gate. It is not a network problem and retrying
        // will not help, so it gets its own wording and no retry button.
        _contraindicated = e.statusCode == 403;
        _error = e.message;
      });
    } on Object catch (e) {
      debugPrint('[TERA] SUBMIT FAILED: $e');
      if (!mounted) return;
      setState(() => _error = 'The check could not be sent. $e');
    }
  }

  /// CTX-01 attaches to the check session, which exists in both modes. The episode-scoped event
  /// fallback is gone: there is always somewhere typed to put it now.
  ///
  /// Best effort. Losing the context must not lose the reading.
  Future<void> _fileContext() async {
    final collected = _payload.context;
    final checkSessionId = _payload.checkSessionId;
    if (collected == null || checkSessionId == null) return;

    await CurrentContextSubmitter(
      api: widget.flow.api,
    ).submitForSession(sessionId: checkSessionId, context: collected);
  }

  /// The device profile the session references.
  ///
  /// Only reached when the handset has not registered one before — the resolver caches the id
  /// after the first submission — but it has to be available when it is.
  Future<DeviceMeasurements> _measurements() async {
    final provided = widget.measurements;
    if (provided != null) return provided();

    // **Register the profile from the rates this capture actually achieved.**
    //
    // The profile defines the band every later session is checked against, and it was being
    // measured through `tera_capture`'s platform channel while the capture itself now runs on
    // the `camera` plugin. Two subsystems, two answers: the profile recorded the camera's
    // advertised ceiling (60 fps at 320x240, visible in the CameraX log as
    // `maxFpsForBestSizes=60`) while a real sixty-second capture delivers about 30. The
    // plausibility gate then correctly rejected every completed session as "achieved below the
    // band this device profile qualified in" — a 422, and the reason submissions were failing.
    //
    // Taking the figures from the capture in hand removes the discrepancy at its source, and is
    // what `CLAUDE.md` means by "the rate is measured, not requested". It also skips the probe
    // entirely, which is six seconds the patient no longer waits.
    final signal = _payload.signal;
    if (signal != null) {
      final accel = (signal.quality['accel_rate_hz'] as num?)?.toDouble();
      final fps = (signal.quality['camera_fps'] as num?)?.toDouble();
      if (accel != null && accel > 0 && fps != null && fps > 0) {
        final eligibility = await EligibilityChecker().check();
        final capabilities = eligibility.capabilities;
        if (capabilities != null) {
          return DeviceMeasurer().measure(
            capabilities: capabilities,
            accelRateHz: accel,
            cameraFpsOverride: fps,
          );
        }
      }
    }

    final eligibility = await EligibilityChecker().check();
    final capabilities = eligibility.capabilities;
    if (capabilities == null) {
      // The probe could not read the camera, so there is nothing honest to register. Invariant 9:
      // DeviceProfileCreate has no optional measurements, and a substituted figure would be one.
      throw const DeviceMeasurementFailure(
        'This phone could not be measured, so the check could not be filed.',
      );
    }
    return DeviceMeasurer().measure(
      capabilities: capabilities,
      accelRateHz: eligibility.achievedRateHz ?? 0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return Scaffold(
      appBar: AppBar(title: const Text('PROC-01')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: error == null
              ? const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('Putting your check into context'),
                    SizedBox(height: 24),
                    CircularProgressIndicator(),
                  ],
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _contraindicated
                          ? 'Tera cannot produce a trend'
                          : 'Could not send',
                    ),
                    const SizedBox(height: 8),
                    Text(error),
                    const SizedBox(height: 24),
                    if (!_contraindicated)
                      ElevatedButton(
                        onPressed: () {
                          setState(() => _error = null);
                          _run();
                        },
                        child: const Text('Try again'),
                      ),
                    TextButton(
                      onPressed: () => TeraFlow.toHome(context),
                      child: const Text('Back to home'),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
