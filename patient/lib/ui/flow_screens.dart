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
  Widget build(BuildContext context) => const Scaffold(
    body: Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [Text('Tera'), SizedBox(height: 16), CircularProgressIndicator()],
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

  Future<void> _next() async {
    final answers = PrecheckAnswers(
      rested5Min: _rested ?? true,
      recentActivity30Min: _activity ?? false,
      recentCaffeine30Min: _caffeine ?? false,
      recentNicotine30Min: _nicotine ?? false,
      needsRestroom: _restroom ?? false,
    );

    // Filed against the check session opened at the start of the flow. Best effort: the readiness
    // decision has already been made locally and the flow branches on it either way, so losing
    // this loses a record rather than a gate.
    final flow = widget.flow;
    final checkSessionId = widget.payload.checkSessionId;
    if (flow != null && checkSessionId != null) {
      await CheckSessionClient(
        api: flow.api,
      ).submitPreconditions(checkSessionId: checkSessionId, answers: answers);
    }

    if (!mounted) return;
    TeraFlow.advance(
      context,
      CheckFlow.afterPrecheck(widget.session, answers),
      payload: widget.payload,
    );
  }

  Widget _buildYesNoQuestion(String question, bool? value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16.0),
      child: Column(
        children: [
          Text(question, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: () => onChanged(true),
                style: TextButton.styleFrom(
                  foregroundColor: value == true ? Colors.black : Colors.grey,
                  textStyle: TextStyle(fontWeight: value == true ? FontWeight.bold : FontWeight.normal),
                ),
                child: const Text('yes'),
              ),
              const SizedBox(width: 32),
              TextButton(
                onPressed: () => onChanged(false),
                style: TextButton.styleFrom(
                  foregroundColor: value == false ? Colors.black : Colors.grey,
                  textStyle: TextStyle(fontWeight: value == false ? FontWeight.bold : FontWeight.normal),
                ),
                child: const Text('no'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PRE-01'), elevation: 0, backgroundColor: Colors.transparent, iconTheme: const IconThemeData(color: Colors.black)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'For a more comparable trend,\ncheck that you\'re in a resting\ncondition.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 32),
            _buildYesNoQuestion('Have you rested quietly for at least 5 minutes?', _rested, (v) => setState(() => _rested = v)),
            _buildYesNoQuestion('Have you exercised or been physically active in the last 30 minutes?', _activity, (v) => setState(() => _activity = v)),
            _buildYesNoQuestion('Have you had coffee, tea, or another caffeinated drink in the last 30 minutes?', _caffeine, (v) => setState(() => _caffeine = v)),
            _buildYesNoQuestion('Have you smoked or used nicotine in the last 30 minutes?', _nicotine, (v) => setState(() => _nicotine = v)),
            _buildYesNoQuestion('Do you need to use the restroom?', _restroom, (v) => setState(() => _restroom = v)),
            const SizedBox(height: 32),
            Center(
              child: TextButton(
                onPressed: _next,
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('next', style: TextStyle(fontSize: 16, color: Colors.black)),
                    SizedBox(width: 4),
                    Icon(Icons.arrow_forward, size: 16, color: Colors.black),
                  ],
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

  void _next() {
    final collected = CurrentContext(
      sleepLessThanUsual: _sleep,
      stressHigherThanUsual: _stress,
      feelingUnwell: _unwell,
      symptoms: _symptoms,
      medicationStatusToday: _medication,
    );

    TeraFlow.advance(
      context,
      CheckFlow.afterContext(widget.session),
      payload: widget.payload.copyWith(context: collected),
    );
  }

  Widget _buildChip(String label, bool isSelected, ValueChanged<bool> onSelected) {
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: onSelected,
      selectedColor: Colors.black26,
      backgroundColor: Colors.grey.shade200,
      shape: const StadiumBorder(),
      showCheckmark: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('CTX-01'), elevation: 0, backgroundColor: Colors.transparent, iconTheme: const IconThemeData(color: Colors.black)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text('Anything\ndifferent\ntoday?', style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold, height: 1.1)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildChip('Slept less than usual', _sleep, (v) => setState(() { _sleep = v; _nothingUnusual1 = false; })),
                _buildChip('Higher stress', _stress, (v) => setState(() { _stress = v; _nothingUnusual1 = false; })),
                _buildChip('Recent exercise', _recentExercise, (v) => setState(() { _recentExercise = v; _nothingUnusual1 = false; })),
                _buildChip('More caffeine than usual', _moreCaffeine, (v) => setState(() { _moreCaffeine = v; _nothingUnusual1 = false; })),
                _buildChip('Feeling unwell', _unwell, (v) => setState(() { _unwell = v; _nothingUnusual1 = false; })),
                _buildChip('Nothing unusual', _nothingUnusual1, (v) {
                  if (v) setState(() { _sleep = false; _stress = false; _unwell = false; _recentExercise = false; _moreCaffeine = false; _nothingUnusual1 = true; });
                }),
              ],
            ),
            const SizedBox(height: 48),
            const Text('How are you\nfeeling?', style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold, height: 1.1)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildChip('No symptoms', _symptoms.isEmpty && !_otherSymptom, (v) {
                  if (v) setState(() { _symptoms.clear(); _otherSymptom = false; });
                }),
                for (final symptom in ContextSymptom.values)
                  _buildChip(symptom.label, _symptoms.contains(symptom), (v) {
                    setState(() {
                      if (v) _symptoms.add(symptom);
                      else _symptoms.remove(symptom);
                    });
                  }),
                _buildChip('Other', _otherSymptom, (v) => setState(() => _otherSymptom = v)),
              ],
            ),
            const SizedBox(height: 48),
            const Text('additional\ncondition', style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold, height: 1.1)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final status in MedicationStatusToday.values)
                  _buildChip(status.label, _medication == status, (v) {
                    if (v) setState(() => _medication = status);
                  }),
              ],
            ),
            const SizedBox(height: 48),
            Center(
              child: TextButton(
                onPressed: _next,
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('next', style: TextStyle(fontSize: 16, color: Colors.black)),
                    SizedBox(width: 4),
                    Icon(Icons.arrow_forward, size: 16, color: Colors.black),
                  ],
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
      return ScgPpgWalkthroughScreen(onDone: () => setState(() => _walkthroughDone = true));
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
            result.accepted ? SignalQuality.accepted : SignalQuality.retryableReject,
          ),
          // Carried whether accepted or not. A rejected session is still submitted and retained
          // (invariant 3), so processing needs it either way.
          payload: widget.payload.copyWith(signal: result, capturedAt: capture.startedAt),
        );
      },
    );
  }
}

class ScgPpgWalkthroughScreen extends StatefulWidget {
  final VoidCallback onDone;
  const ScgPpgWalkthroughScreen({super.key, required this.onDone});

  @override
  State<ScgPpgWalkthroughScreen> createState() => _ScgPpgWalkthroughScreenState();
}

class _ScgPpgWalkthroughScreenState extends State<ScgPpgWalkthroughScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  bool _ready = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: (i) => setState(() => _currentPage = i),
                children: [
                  _buildPage(
                    step: 'STEP 1: Sit comfortably',
                    sub: 'Sit upright with your back supported\nand both feet flat on the floor.',
                    icon: Icons.chair_alt,
                  ),
                  _buildPage(
                    step: 'STEP 2: Place your phone on\nyour chest',
                    sub: 'Hold your phone with one hand and\nplace it flat against the center of your\nchest.',
                    icon: Icons.phone_android,
                  ),
                  _buildPage(
                    step: 'STEP 3: Cover the rear camera',
                    sub: 'With your other hand, gently place your\nindex finger over the rear camera and\nflash.',
                    icon: Icons.camera_rear,
                  ),
                  _buildPage(
                    step: 'STEP 4: Relax and stay still',
                    sub: 'Keep your position and avoid moving\nor talking during the check.',
                    icon: Icons.self_improvement,
                  ),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(4, (index) => Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: 24,
                height: 4,
                decoration: BoxDecoration(
                  color: _currentPage == index ? const Color(0xFF0F3057) : Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              )),
            ),
            const SizedBox(height: 32),
            if (_currentPage == 3)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.withOpacity(0.2)),
                  ),
                  child: CheckboxListTile(
                    value: _ready,
                    onChanged: (v) => setState(() => _ready = v ?? false),
                    title: const Text("I'm ready"),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0F3057),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: () {
                    if (_currentPage < 3) {
                      _pageController.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeIn);
                    } else if (_ready) {
                      widget.onDone();
                    }
                  },
                  child: Text(_currentPage < 3 ? 'Next' : 'Start Check'),
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: () {
                if (_currentPage > 0) {
                  _pageController.previousPage(duration: const Duration(milliseconds: 300), curve: Curves.easeIn);
                } else {
                  Navigator.of(context).pop();
                }
              },
              icon: const Icon(Icons.chevron_left, color: Color(0xFF0F3057)),
              label: const Text('Back', style: TextStyle(color: Color(0xFF0F3057))),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildPage({required String step, required String sub, required IconData icon}) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(step, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF0F3057))),
          const SizedBox(height: 16),
          Text(sub, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, color: Colors.black87)),
          const SizedBox(height: 64),
          Icon(icon, size: 100, color: Colors.grey.shade400),
          const SizedBox(height: 32),
          if (icon == Icons.camera_rear || icon == Icons.chair_alt || icon == Icons.phone_android || icon == Icons.self_improvement)
            const Icon(Icons.favorite, size: 32, color: Colors.deepOrange),
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
