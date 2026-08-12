/// Signed-in landing screen.
///
/// The entry point to the flow: eligibility, then a capture session. Both arrive in M3; this
/// screen is what holds them together and carries sign-out.
library;

import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import '../capture/check_session_client.dart';
import '../capture/context_intake.dart';
import '../capture/session_context.dart';
import '../routing/check_payload.dart';
import '../routing/app_router.dart';
import '../routing/routes.dart';
import 'capture_screen.dart';
import 'context_intake_screen.dart';
import 'cuff_reading_screen.dart';
import 'eligibility_screen.dart';
import 'symptom_triage_screen.dart';
import 'session_result_screen.dart';
import 'tokens.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.auth, this.flow, this.intakeStore});

  final AuthController auth;

  /// Null in the older direct-navigation tests. When present, 'Start a spot check' runs the
  /// spec's startCheck() rather than the hardcoded triage-then-eligibility chain.
  final TeraFlow? flow;

  /// Injectable so tests can drive the gate without secure storage.
  final ContextIntakeStore? intakeStore;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final ContextIntakeStore _intakeStore;
  ContextIntake? _intake;

  AuthController get auth => widget.auth;

  @override
  void initState() {
    super.initState();
    _intakeStore = widget.intakeStore ?? SecureContextIntakeStore();
    _loadIntake();
  }

  Future<void> _loadIntake() async {
    final intake = await _intakeStore.read();
    if (!mounted) return;
    setState(() => _intake = intake);
  }

  @override
  Widget build(BuildContext context) {
    final subject = auth.session?.subject ?? '';
    final blocked = !ContextIntakeSafety.allowsTrendGeneration(_intake);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tera'),
        actions: [
          TextButton(
            onPressed: () => auth.signOut(),
            style: TextButton.styleFrom(foregroundColor: TeraColors.paper),
            child: const Text('Sign out'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(TeraSpacing.md),
        children: [
          Text(
            'Signed in as $subject',
            style: const TextStyle(color: TeraColors.neutral700, fontSize: TeraText.small),
          ),
          const SizedBox(height: TeraSpacing.lg),
          const Text(
            'Spot check',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: TeraColors.ink),
          ),
          const SizedBox(height: TeraSpacing.sm),
          const Text(
            'A spot check records two signals at once for about a minute, then compares the '
            'result with your own usual range. It is not a blood-pressure reading.',
            style: TextStyle(color: TeraColors.ink, height: 1.5),
          ),
          const SizedBox(height: TeraSpacing.lg),

          if (blocked) ...[
            Container(
              decoration: systemFlagDecoration(),
              padding: const EdgeInsets.all(TeraSpacing.md),
              child: const Text(
                pregnancyBlockMessage,
                style: TextStyle(color: TeraColors.ink, height: 1.5),
              ),
            ),
            const SizedBox(height: TeraSpacing.md),
          ],

          FilledButton(
            // The gate is applied here as well as inside the intake screen. A blocked patient who
            // backs out of that dialog lands on this screen, and an enabled button would be one
            // tap from the flow the block exists to prevent.
            onPressed: blocked ? null : () => _startSpotCheck(context),
            child: const Text('Start a spot check'),
          ),

          const SizedBox(height: TeraSpacing.xl),
          const Divider(),
          const SizedBox(height: TeraSpacing.lg),

          const Text(
            'About you',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: TeraColors.ink),
          ),
          const SizedBox(height: TeraSpacing.sm),
          Text(
            _intake == null
                ? 'Tera needs a few details before it can tell whether it is suitable for you.'
                : 'Your medication, pregnancy and heart-rhythm answers, on this phone and in '
                      'your Tera account.',
            style: const TextStyle(color: TeraColors.ink, height: 1.5),
          ),
          const SizedBox(height: TeraSpacing.lg),
          OutlinedButton(
            onPressed: () => _openIntake(context),
            child: Text(_intake == null ? 'Answer a few questions' : 'Review your answers'),
          ),

          const SizedBox(height: TeraSpacing.xl),
          const Divider(),
          const SizedBox(height: TeraSpacing.lg),

          const Text(
            'Cuff reading',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: TeraColors.ink),
          ),
          const SizedBox(height: TeraSpacing.sm),
          const Text(
            'Type in the numbers from your upper-arm cuff. These are the blood-pressure '
            'measurements your spot checks are compared against, so record them when your clinic '
            'asks.',
            style: TextStyle(color: TeraColors.ink, height: 1.5),
          ),
          const SizedBox(height: TeraSpacing.lg),
          OutlinedButton(
            onPressed: () => _recordCuffReading(context),
            child: const Text('Record a cuff reading'),
          ),

          const SizedBox(height: TeraSpacing.xl),
          const Divider(),
          const SizedBox(height: TeraSpacing.lg),

          // Section 3's top-level navigation. Stubs for now; the routes exist.
          OutlinedButton(
            onPressed: () => Navigator.of(context).pushNamed(Routes.history),
            child: const Text('History'),
          ),
          const SizedBox(height: TeraSpacing.sm),
          OutlinedButton(
            onPressed: () => Navigator.of(context).pushNamed(Routes.profile),
            child: const Text('Profile'),
          ),
        ],
      ),
    );
  }

  void _openIntake(BuildContext context) {
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => ContextIntakeScreen(
              store: _intakeStore,
              api: auth.api,
              existing: _intake,
              onSaved: (intake) {
                setState(() => _intake = intake);
                Navigator.of(context).pop();
              },
            ),
          ),
        )
        // The blocked path pops without calling onSaved, so the answer is re-read on return
        // rather than trusted to have arrived through the callback.
        .then((_) => _loadIntake());
  }

  void _recordCuffReading(BuildContext context) {
    final navigator = Navigator.of(context);
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => CuffReadingScreen(
          api: auth.api,
          onDone: () => navigator.popUntil((route) => route.isFirst),
        ),
      ),
    );
  }

  /// Triage, then eligibility, then capture, then the terminal steps.
  ///
  /// Each step replaces the one before it, so the back button never lands a patient in the middle
  /// of a recording that has already finished, and 'Done' returns to this screen rather than
  /// unwinding through screens whose work is over.
  ///
  /// **Triage is first.** Invariant 8 requires a red flag to end the session before a measurement
  /// is offered, and putting it after the eligibility probe would make someone reporting chest
  /// pain wait through six seconds of sensor measurement — which can itself end in "this phone
  /// cannot be used", swallowing the report entirely.
  void _startSpotCheck(BuildContext context) {
    final navigator = Navigator.of(context);
    final flow = widget.flow;

    // Invariant 8 comes first either way. The PM spec's startCheck() begins at the BP reference
    // or the pre-check; a patient reporting chest pain must not be walked through either.
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => SymptomTriageScreen(
          api: auth.api,
          onDone: () => navigator.popUntil((route) => route.isFirst),
          onProceed: () async {
            if (flow != null) {
              // Section 38: eligible + needs reference -> BPREF, otherwise PRECHECK; not
              // eligible -> PRECHECK in BP-only mode.
              final step = flow.startCheck();

              // The check session is opened here, before the first screen that collects anything,
              // so PRE-01 and CTX-01 have somewhere to go in both modes.
              String? checkSessionId;
              try {
                final resolved = await SessionContextResolver(
                  api: auth.api,
                ).resolveEpisode();
                checkSessionId = await CheckSessionClient(api: auth.api).open(
                  episodeId: resolved.episodeId,
                  mode: step.session.mode,
                );
              } on Object {
                // Opening failed - most often the contraindication gate at the door, or no
                // network. The flow still runs and the answers are still collected locally; they
                // simply have nothing to attach to, which the processing screen reports.
              }

              navigator.pushReplacementNamed(
                step.route,
                arguments: CheckArgs(
                  step.session,
                  CheckPayload(checkSessionId: checkSessionId),
                ),
              );
              return;
            }
            navigator.pushReplacement(
              MaterialPageRoute<void>(builder: (_) => _eligibilityOnwards(navigator)),
            );
          },
        ),
      ),
    );
  }

  Widget _eligibilityOnwards(NavigatorState navigator) => EligibilityScreen(
    onProceed: (eligibility) => navigator.pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => CaptureScreen(
          onComplete: (capture) => navigator.pushReplacement(
            MaterialPageRoute<void>(
              builder: (_) => SessionResultScreen(
                api: auth.api,
                capture: capture,
                // The eligibility probe already measured this handset; carrying its result
                // forward avoids repeating six seconds of measurement the patient watched.
                eligibility: eligibility,
                onDone: () => navigator.popUntil((route) => route.isFirst),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
