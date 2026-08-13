/// Signed-in landing screen.
///
/// The entry point to the flow: eligibility, then a capture session. Both arrive in M3; this
/// screen is what holds them together and carries sign-out.
library;

import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import '../capture/check_session_client.dart';
import '../capture/context_intake.dart';
import '../capture/phr_profile.dart';
import '../capture/session_context.dart';
import '../routing/check_payload.dart';
import '../routing/app_router.dart';
import '../routing/routes.dart';
import 'capture_screen.dart';
import 'context_intake_screen.dart';
import 'cuff_reading_screen.dart';
import 'guest_gate_screen.dart';
import 'symptom_triage_screen.dart';
import 'session_result_screen.dart';
import 'tokens.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.auth,
    this.flow,
    this.intakeStore,
    this.profileStore,
  });

  final AuthController auth;

  /// Null in the older direct-navigation tests. When present, 'Start a spot check' runs the
  /// spec's startCheck() rather than the hardcoded triage-then-eligibility chain.
  final TeraFlow? flow;

  /// Injectable so tests can drive the gate without secure storage.
  final ContextIntakeStore? intakeStore;

  /// Where the greeting's name comes from. Injectable for the same reason.
  final PhrProfileStore? profileStore;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final ContextIntakeStore _intakeStore;
  late final PhrProfileStore _profileStore;
  ContextIntake? _intake;
  String? _displayName;

  AuthController get auth => widget.auth;

  @override
  void initState() {
    super.initState();
    _intakeStore = widget.intakeStore ?? SecureContextIntakeStore();
    _profileStore = widget.profileStore ?? SecurePhrProfileStore();
    _loadIntake();
    _loadName();
  }

  Future<void> _loadIntake() async {
    final intake = await _intakeStore.read();
    if (!mounted) return;
    setState(() => _intake = intake);
  }

  /// The name given at sign-up. Handset-only — see [PhrProfile.displayName].
  Future<void> _loadName() async {
    final profile = await _profileStore.read();
    if (!mounted) return;
    setState(() => _displayName = profile.displayName);
  }

  /// Morning, afternoon or evening by the handset clock.
  ///
  /// It had been a constant 'Good Morning', which is wrong for two thirds of the day and reads as
  /// a screen nobody finished.
  static String _greetingFor(int hour) {
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final subject = auth.session?.subject ?? '';
    // The name if we have one, and no name at all if we do not. An account created before the
    // sign-up form collected one gets 'Good evening' rather than an email address read back at
    // them or a stranger's name.
    final name = _displayName?.trim();
    final greeting = _greetingFor(DateTime.now().hour);
    final initial = (name?.isNotEmpty ?? false)
        ? name!.characters.first.toUpperCase()
        : (subject.isNotEmpty ? subject.characters.first.toUpperCase() : 'T');
    final blocked = !ContextIntakeSafety.allowsTrendGeneration(_intake);

    return Scaffold(
      backgroundColor: TeraColors.paper,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: TeraSpacing.lg, vertical: TeraSpacing.md),
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name == null || name.isEmpty ? greeting : '$greeting, $name',
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                                color: TeraColors.ink,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Understand your cardiovascular\npattern and what to do next.',
                              style: TextStyle(
                                fontSize: 14,
                                color: TeraColors.neutral700,
                                height: 1.3,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      CircleAvatar(
                        radius: 24,
                        backgroundColor: TeraColors.ink,
                        child: Text(
                          initial,
                          style: const TextStyle(
                            color: TeraColors.paper,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                  FilledButton(
                    onPressed: blocked ? null : () => _startSpotCheck(context),
                    style: FilledButton.styleFrom(
                      backgroundColor: TeraColors.ink,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 18),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'Start Check-In',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                        ),
                        SizedBox(width: 8),
                        Icon(Icons.chevron_right, size: 20),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
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
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF2F5F8), // Matching the light grey/blueish background
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Complete your health profile',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: TeraColors.ink,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Add a little more context for more personalized\ninsights.',
                          style: TextStyle(
                            fontSize: 12,
                            color: TeraColors.ink,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '10% Complete',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: TeraColors.ink,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Container(
                                  width: 120,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: TeraColors.neutral300,
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: FractionallySizedBox(
                                    alignment: Alignment.centerLeft,
                                    widthFactor: 0.1,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: TeraColors.brand,
                                        borderRadius: BorderRadius.circular(3),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            FilledButton(
                              onPressed: () => _openIntake(context),
                              style: FilledButton.styleFrom(
                                backgroundColor: TeraColors.brand,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                minimumSize: const Size(0, 36),
                                padding: const EdgeInsets.symmetric(horizontal: 20),
                              ),
                              child: const Text(
                                'Complete Profile',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFAFAFA),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: TeraColors.neutral200),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.02),
                          blurRadius: 5,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '7-Day Blood Pressure Trend',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            color: TeraColors.ink,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const Icon(Icons.arrow_upward, color: Colors.red, size: 14),
                            const SizedBox(width: 4),
                            const Text(
                              'Rising',
                              style: TextStyle(
                                color: Colors.red,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        SizedBox(
                          height: 120,
                          width: double.infinity,
                          child: Stack(
                            children: [
                              Column(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  _buildGridLine('200'),
                                  _buildGridLine('100'),
                                  _buildGridLine('0'),
                                ],
                              ),
                              Positioned.fill(
                                child: CustomPaint(
                                  painter: _ChartPainter(),
                                ),
                              ),
                              Positioned(
                                bottom: -24,
                                left: 40,
                                right: 0,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
                                      .map((day) => Text(
                                            day,
                                            style: const TextStyle(
                                              color: TeraColors.neutral400,
                                              fontSize: 12,
                                            ),
                                          ))
                                      .toList(),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24), // For bottom labels
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                  const Text(
                    'Recent Activity',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: TeraColors.ink,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildRecentActivityList(),
                  const SizedBox(height: 48),
                ],
              ),
            ),
            _buildBottomNav(context),
          ],
        ),
      ),
    );
  }

  Widget _buildRecentActivityList() {
    return Column(
      children: [
        _buildActivityItem('Aug 12 · 09:20', 'Persistent BP-related change', 'Phone check · Good signal'),
        const SizedBox(height: 12),
        _buildActivityItem('Aug 11 · 08:50', 'BP-related change', 'Phone check · Good signal'),
        const SizedBox(height: 12),
        _buildActivityItem('Aug 10 · 09:05', '138 / 86 mmHg', 'Confirmed BP · Manual input'),
      ],
    );
  }

  Widget _buildActivityItem(String time, String title, String subtitle) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TeraColors.paper,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TeraColors.neutral200),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: TeraColors.brand.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.favorite_border, color: TeraColors.brand, size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(time, style: const TextStyle(fontSize: 12, color: TeraColors.neutral500)),
                const SizedBox(height: 4),
                Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: TeraColors.ink)),
                const SizedBox(height: 2),
                Text(subtitle, style: const TextStyle(fontSize: 13, color: TeraColors.neutral500)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// History and Profile both need a token; a guest has none. Caught here, at the tap, rather
  /// than let the screen's own request fail and show a generic error.
  void _openGuarded(BuildContext context, String route, String feature) {
    if (auth.isGuest) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => GuestGateScreen(feature: feature)),
      );
      return;
    }
    Navigator.of(context).pushNamed(route);
  }

  Widget _buildBottomNav(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(top: 16, bottom: 24),
      decoration: BoxDecoration(
        color: TeraColors.paper,
        border: Border(top: BorderSide(color: TeraColors.neutral200)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildNavItem(context, Icons.home, 'Home', true, () {}),
          _buildNavItem(context, Icons.history, 'History', false, () => _openGuarded(context, Routes.history, 'History')),
          _buildNavItem(context, Icons.person_outline, 'Profile', false, () => _openGuarded(context, Routes.profile, 'Profile')),
        ],
      ),
    );
  }

  Widget _buildNavItem(BuildContext context, IconData icon, String label, bool isActive, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: isActive ? TeraColors.brand : TeraColors.neutral500),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
              color: isActive ? TeraColors.brand : TeraColors.neutral500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGridLine(String label) {
    return Row(
      children: [
        SizedBox(
          width: 30,
          child: Text(
            label,
            style: const TextStyle(color: TeraColors.neutral400, fontSize: 12),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            height: 1,
            // Simple dashed line effect by using a container with border or just solid for now
            color: TeraColors.neutral300,
          ),
        ),
      ],
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
            throw UnimplementedError('Legacy testing route is removed.');
          },
        ),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paintLine = Paint()
      ..color = TeraColors.baltic
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final paintDot = Paint()
      ..color = TeraColors.paper
      ..style = PaintingStyle.fill;
      
    final paintDotBorder = Paint()
      ..color = TeraColors.baltic
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    // Hardcoded dummy data for chart visualization
    // Mapping y from 0 to 200 into height
    final data = [60.0, 140.0, 120.0, 70.0, 100.0, 120.0];
    
    // Space for y axis label is 40 (30 width + 8 spacing roughly)
    final startX = 40.0;
    final w = size.width - startX;
    if (w <= 0) return;
    
    final dx = w / (data.length - 1);
    
    final path = Path();
    for (int i = 0; i < data.length; i++) {
      final x = startX + i * dx;
      // y-axis goes down, so 200 is at top (0), 0 is at bottom (size.height)
      final y = size.height - (data[i] / 200.0) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    
    canvas.drawPath(path, paintLine);
    
    for (int i = 0; i < data.length; i++) {
      final x = startX + i * dx;
      final y = size.height - (data[i] / 200.0) * size.height;
      canvas.drawCircle(Offset(x, y), 4, paintDot);
      canvas.drawCircle(Offset(x, y), 4, paintDotBorder);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

