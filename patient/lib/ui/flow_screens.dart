/// Screens that exist to drive the flow, not to be looked at.
///
/// Everything here is routing and state. Where a screen has real logic — the device probe, the
/// pre-check answers, the capture handoff — it is wired properly; where it does not, it is a
/// [FlowStubScreen] naming the spec section it stands for.
library;

import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import '../capture/context_intake.dart';
import '../capture/current_context.dart';
import '../capture/current_context_submitter.dart';
import '../api/api_client.dart';
import '../capture/device_measurement.dart';
import '../capture/eligibility_check.dart';
import '../capture/session_context.dart';
import '../capture/session_submitter.dart';
import '../routing/check_payload.dart';
import '../routing/app_flow_state.dart';
import '../routing/app_router.dart';
import '../routing/check_session.dart';
import '../routing/routes.dart';
import '../signal/signal_pipeline.dart';
import 'capture_screen.dart';
import 'context_intake_screen.dart';
import 'cuff_reading_screen.dart';
import 'flow_stub_screen.dart';

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
    final next = widget.flow.auth.status == AuthStatus.signedIn
        ? widget.flow.state.resumeRoute
        : Routes.login;

    Navigator.of(context).pushNamedAndRemoveUntil(next, (r) => false);
  }

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [Text('Tera'), SizedBox(height: 16), CircularProgressIndicator()],
      ),
    ),
  );
}

/// DEV-01. Runs the real eligibility probe and records the verdict.
class DeviceCheckScreen extends StatefulWidget {
  const DeviceCheckScreen({super.key, required this.flow, this.probe});

  final TeraFlow flow;

  /// Injectable so a routing test does not have to reach for a real camera and accelerometer.
  /// Null uses the real gate.
  final Future<EligibilityResult> Function()? probe;

  @override
  State<DeviceCheckScreen> createState() => _DeviceCheckScreenState();
}

class _DeviceCheckScreenState extends State<DeviceCheckScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    // The existing gate: torch present, and a *measured* accelerometer rate at or above the
    // minimum. `couldNotCheck` is treated as not eligible for routing, which is the conservative
    // reading — the BP-only path still works and nothing is blocked.
    final result = await (widget.probe?.call() ?? EligibilityChecker().check());
    final eligibility = result.canProceed
        ? DeviceEligibility.eligible
        : DeviceEligibility.notEligible;

    await widget.flow.recordEligibility(eligibility);
    if (!mounted) return;

    Navigator.of(context).pushReplacementNamed(
      eligibility == DeviceEligibility.eligible
          ? Routes.deviceEligible
          : Routes.deviceNotEligible,
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('DEV-01')),
    body: const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('Checking your phone sensors'),
          SizedBox(height: 8),
          Text('This takes about 10 seconds. No need to do anything.'),
          SizedBox(height: 24),
          CircularProgressIndicator(),
        ],
      ),
    ),
  );
}

/// DEV-02 and DEV-03. Both continue into PHR onboarding; neither blocks the account.
class DeviceVerdictScreen extends StatelessWidget {
  const DeviceVerdictScreen({
    super.key,
    required this.specId,
    required this.title,
    required this.body,
    required this.cta,
  });

  final String specId;
  final String title;
  final String body;
  final String cta;

  @override
  Widget build(BuildContext context) => FlowStubScreen(
    specId: specId,
    title: title,
    body: body,
    nextLabel: cta,
    onNext: () => Navigator.of(
      context,
    ).pushNamedAndRemoveUntil(Routes.onboardingAboutYou, (r) => false),
  );
}

/// ONB-02 Measurement Safety.
///
/// **Not a stub.** This is the safety gate already built: the pregnancy hard stop and the rhythm
/// question live in [ContextIntakeScreen], which also files the answers to `/v1/patient-context`.
/// The spec's ONB-02 and our intake form ask the same questions for the same reason, so the route
/// points at the real screen rather than duplicating it.
class SafetyOnboardingScreen extends StatelessWidget {
  const SafetyOnboardingScreen({super.key, required this.flow});

  final TeraFlow flow;

  @override
  Widget build(BuildContext context) => ContextIntakeScreen(
    store: SecureContextIntakeStore(),
    api: flow.api,
    onSaved: (_) async {
      await flow.completeOnboardingStep(OnboardingStep.safety);
      if (!context.mounted) return;
      Navigator.of(
        context,
      ).pushNamedAndRemoveUntil(flow.state.onboardingStep.route, (r) => false);
    },
  );
}

/// PRE-01. The five readiness questions, and the only screen that decides between the wait
/// screen and the context screen.
class PrecheckScreen extends StatefulWidget {
  const PrecheckScreen({super.key, required this.session});

  final CheckSession session;

  @override
  State<PrecheckScreen> createState() => _PrecheckScreenState();
}

class _PrecheckScreenState extends State<PrecheckScreen> {
  bool _rested = true;
  bool _activity = false;
  bool _caffeine = false;
  bool _nicotine = false;
  bool _restroom = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PRE-01')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Before your check'),
          SwitchListTile(
            value: _rested,
            onChanged: (v) => setState(() => _rested = v),
            title: const Text('Rested quietly for at least 5 minutes'),
          ),
          SwitchListTile(
            value: _activity,
            onChanged: (v) => setState(() => _activity = v),
            title: const Text('Active in the last 30 minutes'),
          ),
          SwitchListTile(
            value: _caffeine,
            onChanged: (v) => setState(() => _caffeine = v),
            title: const Text('Caffeine in the last 30 minutes'),
          ),
          SwitchListTile(
            value: _nicotine,
            onChanged: (v) => setState(() => _nicotine = v),
            title: const Text('Nicotine in the last 30 minutes'),
          ),
          SwitchListTile(
            value: _restroom,
            onChanged: (v) => setState(() => _restroom = v),
            title: const Text('Need the restroom'),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () => TeraFlow.advance(
              context,
              CheckFlow.afterPrecheck(
                widget.session,
                PrecheckAnswers(
                  rested5Min: _rested,
                  recentActivity30Min: _activity,
                  recentCaffeine30Min: _caffeine,
                  recentNicotine30Min: _nicotine,
                  needsRestroom: _restroom,
                ),
              ),
            ),
            child: const Text('Next'),
          ),
        ],
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
  final Set<ContextSymptom> _symptoms = {};
  MedicationStatusToday _medication = MedicationStatusToday.notSure;

  void _next() {
    final collected = CurrentContext(
      sleepLessThanUsual: _sleep,
      stressHigherThanUsual: _stress,
      feelingUnwell: _unwell,
      symptoms: _symptoms,
      medicationStatusToday: _medication,
    );

    // Not filed here. `POST /v1/check-sessions/{id}/context` needs a session id, and the session
    // does not exist until the check is submitted, so the context rides in the payload and
    // processing files it once there is something to attach it to.
    TeraFlow.advance(
      context,
      CheckFlow.afterContext(widget.session),
      payload: widget.payload.copyWith(context: collected),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('CTX-01')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Anything different today?'),
          CheckboxListTile(
            value: _sleep,
            onChanged: (v) => setState(() => _sleep = v ?? false),
            title: const Text('Slept less than usual'),
          ),
          CheckboxListTile(
            value: _stress,
            onChanged: (v) => setState(() => _stress = v ?? false),
            title: const Text('More stressed than usual'),
          ),
          CheckboxListTile(
            value: _unwell,
            onChanged: (v) => setState(() => _unwell = v ?? false),
            title: const Text('Feeling unwell'),
          ),
          const SizedBox(height: 8),
          const Text('Any of these right now?'),
          for (final symptom in ContextSymptom.values)
            CheckboxListTile(
              value: _symptoms.contains(symptom),
              onChanged: (v) => setState(() {
                if (v ?? false) {
                  _symptoms.add(symptom);
                } else {
                  _symptoms.remove(symptom);
                }
              }),
              title: Text(symptom.label),
            ),
          const SizedBox(height: 8),
          const Text('Blood pressure medication today'),
          DropdownButton<MedicationStatusToday>(
            value: _medication,
            isExpanded: true,
            onChanged: (v) => setState(() => _medication = v ?? MedicationStatusToday.notSure),
            items: [
              for (final status in MedicationStatusToday.values)
                DropdownMenuItem(value: status, child: Text(status.label)),
            ],
          ),
          const SizedBox(height: 16),
          ElevatedButton(onPressed: _next, child: const Text('Next')),
        ],
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
class CaptureRouteScreen extends StatelessWidget {
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
  Widget build(BuildContext context) => CaptureScreen(
    onComplete: (capture) async {
      final result = await const TeraSignalPipeline().process(capture);
      if (!context.mounted) return;

      if (result.accepted) {
        await flow.recordSuccessfulSensorCheck(DateTime.now());
        if (!context.mounted) return;
      }

      TeraFlow.advance(
        context,
        CheckFlow.afterSensorCapture(
          session,
          result.accepted ? SignalQuality.accepted : SignalQuality.retryableReject,
        ),
        // Carried whether accepted or not. A rejected session is still submitted and retained
        // (invariant 3), so processing needs it either way.
        payload: payload.copyWith(signal: result, capturedAt: capture.startedAt),
      );
    },
  );
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final signal = widget.payload.signal;

    // **BP-only never touches the hardware.** The confirmed reading is the measurement and
    // `CuffReadingScreen` already filed it, so there is no session to submit and no device to
    // measure. Returning here is what keeps a not-eligible handset off the camera path entirely.
    if (widget.session.mode == CheckMode.bpOnly || signal == null) {
      await _fileContextForBpOnly();
      if (!mounted) return;
      TeraFlow.advance(
        context,
        CheckFlow.afterProcessing(widget.session),
        payload: widget.payload,
      );
      return;
    }

    try {
      final resolved = await SessionContextResolver(
        api: widget.flow.api,
      ).resolve(await _measurements());

      final outcome = await SessionSubmitter(api: widget.flow.api).submit(
        episodeId: resolved.episodeId,
        deviceProfileId: resolved.deviceProfileId,
        startedAt: widget.payload.capturedAt ?? DateTime.now(),
        signal: signal,
      );

      // CTX-01 attaches to the session, so it can only be filed now that one exists. Best effort:
      // losing the context must not lose the reading.
      final collected = widget.payload.context;
      if (collected != null) {
        await CurrentContextSubmitter(
          api: widget.flow.api,
        ).submitForSession(sessionId: outcome.sessionId, context: collected);
      }

      if (!mounted) return;
      TeraFlow.advance(
        context,
        CheckFlow.afterProcessing(widget.session),
        payload: widget.payload.copyWith(submittedSessionId: outcome.sessionId),
      );
    } on DeviceMeasurementFailure {
      // **Not a generic error.** The handset could not be measured, which is a hardware problem
      // the patient can act on by repositioning — SIG-02's whole purpose. It routes through the
      // same attempt counter as a rejected capture, so three of these end the check rather than
      // looping forever.
      if (!mounted) return;
      TeraFlow.advance(
        context,
        CheckFlow.afterSensorCapture(widget.session, SignalQuality.retryableReject),
        payload: widget.payload,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        // 403 is the server-side contraindication gate. It is not a network problem and retrying
        // will not help, so it gets its own wording and no retry button.
        _contraindicated = e.statusCode == 403;
        _error = e.message;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _error = 'The check could not be sent. $e');
    }
  }

  /// BP-only has no session to attach context to, so it falls back to the episode-scoped event.
  /// Recorded as a gap in `docs/decisions.md`, not a design.
  Future<void> _fileContextForBpOnly() async {
    final collected = widget.payload.context;
    if (collected == null) return;
    try {
      final resolved = await SessionContextResolver(api: widget.flow.api).resolveEpisode();
      await CurrentContextSubmitter(
        api: widget.flow.api,
      ).submit(episodeId: resolved.episodeId, context: collected);
    } on Object {
      // Never blocks. See the submitter's docstring.
    }
  }

  /// The device profile the session references.
  ///
  /// Only reached when the handset has not registered one before — the resolver caches the id
  /// after the first submission — but it has to be available when it is.
  Future<DeviceMeasurements> _measurements() async {
    final provided = widget.measurements;
    if (provided != null) return provided();

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
                    Text(_contraindicated ? 'Tera cannot produce a trend' : 'Could not send'),
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

class ProfileIndexScreen extends StatelessWidget {
  const ProfileIndexScreen({super.key});

  static const _entries = <(String, String)>[
    ('Personal', Routes.profilePersonal),
    ('Conditions', Routes.profileConditions),
    ('Medications', Routes.profileMedications),
    ('Lifestyle', Routes.profileLifestyle),
    ('Family history', Routes.profileFamilyHistory),
    ('BP reference', Routes.profileBpReference),
    ('Device', Routes.profileDevice),
    ('Privacy', Routes.profilePrivacy),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Profile')),
    body: ListView(
      children: [
        for (final (label, route) in _entries)
          ListTile(
            title: Text(label),
            onTap: () => Navigator.of(context).pushNamed(route),
          ),
      ],
    ),
  );
}
