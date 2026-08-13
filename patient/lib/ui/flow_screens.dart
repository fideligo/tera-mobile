/// Screens that exist to drive the flow, not to be looked at.
///
/// Everything here is routing and state. Where a screen has real logic — the device probe, the
/// pre-check answers, the capture handoff — it is wired properly; where it does not, it is a
/// [FlowStubScreen] naming the spec section it stands for.
library;

import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import '../capture/check_session_client.dart';
import '../capture/current_context.dart';
import '../capture/current_context_submitter.dart';
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
      CheckFlow.afterContext(widget.session),
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

  @override
  Widget build(BuildContext context) {
    if (!_walkthroughDone) {
      return ScgPpgWalkthroughScreen(
        onDone: () => setState(() => _walkthroughDone = true),
      );
    }
    return CaptureScreen(
      onComplete: (capture) async {
        final result = await const TeraSignalPipeline().process(capture);
        if (!context.mounted) return;

        if (result.accepted) {
          await widget.flow.recordSuccessfulSensorCheck(DateTime.now());
          if (!context.mounted) return;
        }

        TeraFlow.advance(
          context,
          CheckFlow.afterSensorCapture(
            widget.session,
            result.accepted
                ? SignalQuality.accepted
                : SignalQuality.retryableReject,
          ),
          // Carried whether accepted or not. A rejected session is still submitted and retained
          // (invariant 3), so processing needs it either way.
          payload: widget.payload.copyWith(
            signal: result,
            capturedAt: capture.startedAt,
          ),
        );
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
  final List<bool> _confirmed = [false, false, false, false];

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
                  2,
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
                  _buildPage(
                    step: 'STEP 1: Sit upright',
                    sub:
                        'Sit upright (seated) with your back supported, shoulders and head relaxed.',
                    icon: Icons.airline_seat_recline_normal,
                    confirmText: 'I\'m seated',
                    pageIndex: 0,
                  ),
                  _buildPage(
                    step: 'STEP 2: Place your phone on your chest',
                    sub:
                        'Hold your phone with one hand and place it flat against the center of your chest, screen facing you.',
                    icon: Icons.phone_android,
                    confirmText: 'My phone is in position',
                    pageIndex: 1,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(TeraSpacing.lg),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _confirmed[_currentPage]
                      ? () {
                          if (_currentPage < 1) {
                            _pageController.nextPage(
                              duration: const Duration(milliseconds: 300),
                              curve: Curves.easeInOut,
                            );
                          } else {
                            widget.onDone();
                          }
                        }
                      : null,
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
                  child: Text(
                    _currentPage < 1 ? 'Next' : 'Start Camera',
                    style: const TextStyle(
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final signal = widget.payload.signal;

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

      await _fileContext();

      if (!mounted) return;

      final bool? consent = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text('Data Privacy Notice'),
            content: const Text(
              'Your data will be sent securely to NVIDIA NIM public AI to generate insights. Do you consent?',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Decline'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('I Consent'),
              ),
            ],
          );
        },
      );

      if (consent != true) {
        TeraFlow.toHome(context);
        return;
      }

      if (!mounted) return;
      
      // POST the sensor data to the ML backend route / rule engine
      if (widget.payload.checkSessionId != null) {
        await widget.flow.api.postJson(
          '/v1/check-sessions/${widget.payload.checkSessionId}/process',
          {
            'scg': signal.scg,
            'ppg': signal.ppg,
            'ai_consent': true,
          }
        );
      }

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
        CheckFlow.afterSensorCapture(
          widget.session,
          SignalQuality.retryableReject,
        ),
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

  /// CTX-01 attaches to the check session, which exists in both modes. The episode-scoped event
  /// fallback is gone: there is always somewhere typed to put it now.
  ///
  /// Best effort. Losing the context must not lose the reading.
  Future<void> _fileContext() async {
    final collected = widget.payload.context;
    final checkSessionId = widget.payload.checkSessionId;
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

class ProfileIndexScreen extends StatelessWidget {
  const ProfileIndexScreen({super.key});

  static const _entries = <(String, String, IconData)>[
    ('Personal Details', Routes.profilePersonal, Icons.person_outline),
    ('Health Conditions', Routes.profileConditions, Icons.favorite_border),
    ('Medications', Routes.profileMedications, Icons.medication_outlined),
    (
      'Lifestyle & Risk Factors',
      Routes.profileLifestyle,
      Icons.directions_walk,
    ),
    ('Family History', Routes.profileFamilyHistory, Icons.family_restroom),
    (
      'BP Reference & Monitoring',
      Routes.profileBpReference,
      Icons.monitor_heart_outlined,
    ),
    ('Device Eligibility', Routes.profileDevice, Icons.smartphone),
    ('Data & Privacy', Routes.profilePrivacy, Icons.privacy_tip_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: AppBar(
        title: const Text(
          'Profile',
          style: TextStyle(
            color: Color(0xFF1E293B),
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF1E293B)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Header
          Row(
            children: [
              const CircleAvatar(
                radius: 32,
                backgroundColor: Color(0xFF0F172A),
                child: Text(
                  'T',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text(
                    'Tera User',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1E293B),
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'user@example.com',
                    style: TextStyle(fontSize: 14, color: Color(0xFF64748B)),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 32),
          // Completion
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      'Health Profile',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1E293B),
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      '65% complete',
                      style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                    ),
                  ],
                ),
                FilledButton(
                  onPressed: () {},
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text(
                    'Complete',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          const Text(
            'Settings',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1E293B),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(
              children: _entries
                  .map(
                    (entry) => Column(
                      children: [
                        ListTile(
                          leading: Icon(
                            entry.$3,
                            color: const Color(0xFF64748B),
                          ),
                          title: Text(
                            entry.$1,
                            style: const TextStyle(
                              color: Color(0xFF334155),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          trailing: const Icon(
                            Icons.chevron_right,
                            color: Color(0xFFCBD5E1),
                          ),
                          onTap: () =>
                              Navigator.of(context).pushNamed(entry.$2),
                        ),
                        if (entry != _entries.last)
                          const Divider(height: 1, indent: 56),
                      ],
                    ),
                  )
                  .toList(),
            ),
          ),
          const SizedBox(height: 24),
          TextButton(
            onPressed: () {},
            child: const Text(
              'Log Out',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 48),
        ],
      ),
    );
  }
}
