/// Screens that exist to drive the flow, not to be looked at.
///
/// Everything here is routing and state. Where a screen has real logic — the device probe, the
/// pre-check answers, the capture handoff — it is wired properly; where it does not, it is a
/// [FlowStubScreen] naming the spec section it stands for.
library;

import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import '../capture/context_intake.dart';
import '../capture/eligibility_check.dart';
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

/// ONB-01 and ONB-03, until the real forms land. Advances the persisted onboarding step.
class OnboardingStubScreen extends StatelessWidget {
  const OnboardingStubScreen({
    super.key,
    required this.flow,
    required this.step,
    required this.specId,
    required this.title,
    required this.body,
  });

  final TeraFlow flow;
  final OnboardingStep step;
  final String specId;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => FlowStubScreen(
    specId: specId,
    title: title,
    body: body,
    onNext: () async {
      await flow.completeOnboardingStep(step);
      if (!context.mounted) return;
      final next = flow.state.onboardingComplete
          ? Routes.home
          : flow.state.onboardingStep.route;
      Navigator.of(context).pushNamedAndRemoveUntil(next, (r) => false);
    },
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

/// CTX-01. Forks sensor from BP-only.
class CurrentContextScreen extends StatelessWidget {
  const CurrentContextScreen({super.key, required this.session});

  final CheckSession session;

  @override
  Widget build(BuildContext context) => FlowStubScreen(
    specId: 'CTX-01',
    title: 'Anything different today?',
    body: 'Symptoms, how you feel, medication taken as usual.',
    onNext: () => TeraFlow.advance(context, CheckFlow.afterContext(session)),
  );
}

/// BPREF-02 and BP-only input. Reuses the screen that already carries scan, manual entry and the
/// explicit confirmation step.
class BpInputScreen extends StatelessWidget {
  const BpInputScreen({super.key, required this.flow, required this.session});

  final TeraFlow flow;
  final CheckSession session;

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
  const CaptureRouteScreen({super.key, required this.flow, required this.session});

  final TeraFlow flow;
  final CheckSession session;

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
      );
    },
  );
}

/// PROC-01. Submission happens here; the insight follows.
class ProcessingScreen extends StatefulWidget {
  const ProcessingScreen({super.key, required this.flow, required this.session});

  final TeraFlow flow;
  final CheckSession session;

  @override
  State<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends State<ProcessingScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Submission is not wired here yet: SessionResultScreen still owns it, and moving it
      // would mean re-plumbing the capture payload through the router in the same change.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      TeraFlow.advance(context, CheckFlow.afterProcessing(widget.session));
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('PROC-01')),
    body: const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('Putting your check into context'),
          SizedBox(height: 24),
          CircularProgressIndicator(),
        ],
      ),
    ),
  );
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
