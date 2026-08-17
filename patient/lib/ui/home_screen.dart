/// Signed-in landing screen.
///
/// The entry point to the flow: eligibility, then a capture session. Both arrive in M3; this
/// screen is what holds them together and carries sign-out.
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import '../capture/check_session_client.dart';
import '../capture/context_intake.dart';
import '../capture/phr_profile.dart';
import '../capture/session_context.dart';
import '../routing/check_payload.dart';
import '../routing/app_router.dart';
import '../routing/routes.dart';
import 'context_intake_screen.dart';
import 'guest_gate_screen.dart';
import 'symptom_triage_screen.dart';
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

  /// Confirmed cuff readings from the last 7 days, oldest first. Only ever cuff readings: they
  /// are the only entries that carry mmHg (invariant 1), so they are the only thing a
  /// blood-pressure chart can honestly plot.
  List<_BpPoint> _trend = const [];

  /// When phone checks happened, for the tick marks under the chart. Times only — see the note
  /// in [_loadHistory] on why a check has no y-position.
  List<DateTime> _checkMarks = const [];

  /// The most recent history entries of any kind, for Recent Activity.
  List<Map<String, dynamic>> _recent = const [];
  bool _historyLoading = false;

  AuthController get auth => widget.auth;

  /// The stored health profile, for the completion card.
  PhrProfile _profile = const PhrProfile();

  /// Six fields, each worth the same. Was the literal "10% Complete", which never moved however
  /// much a patient filled in — so finishing onboarding changed nothing on screen and the card
  /// looked broken. At 100% the card is removed entirely rather than sitting there at full.
  int get _profileCompletion {
    final filled = [
      _profile.dateOfBirth != null,
      _profile.sexAtBirth != null,
      _profile.heightCm != null,
      _profile.weightKg != null,
      _profile.hypertension != null,
      _profile.takesBpMedication != null,
    ].where((f) => f).length;
    return (filled * 100 / 6).round();
  }

  @override
  void initState() {
    super.initState();
    _intakeStore = widget.intakeStore ?? SecureContextIntakeStore();
    _profileStore = widget.profileStore ?? SecurePhrProfileStore();
    _loadIntake();
    _loadName();
    _loadHistory();
  }

  /// The dashboard's real numbers.
  ///
  /// A guest has no token and therefore no history to fetch — the request would throw
  /// `SessionExpiredException` before it left the handset — so it is not attempted, and the
  /// chart and activity list render their locked state instead of an empty one. "No data yet"
  /// and "not signed in" are different statements and the dashboard says which.
  Future<void> _loadHistory() async {
    final flow = widget.flow;
    if (flow == null || !auth.isSignedIn) return;

    setState(() => _historyLoading = true);
    try {
      final body = await flow.api.getJson('/v1/history?range=7d');
      final entries = (body['entries'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();

      final points = <_BpPoint>[];
      final checks = <DateTime>[];
      for (final e in entries) {
        final at = e['occurred_at'] as String?;
        if (at == null) continue;
        final when = DateTime.tryParse(at);
        if (when == null) continue;

        final sys = e['systolic_mmhg'] as int?;
        final dia = e['diastolic_mmhg'] as int?;
        if (sys != null && dia != null) {
          points.add(_BpPoint(at: when, systolic: sys, diastolic: dia));
          continue;
        }
        // A phone check. It is marked on the chart's timeline but has no y-position, because
        // there is no mmHg to give it: `trend_estimate` has no pressure column and the API does
        // not populate one (invariant 1). Plotting it against the mmHg axis would mean inventing
        // the number the whole design refuses to invent.
        if (e['entry_type'] == 'trend' || e['direction'] != null) {
          checks.add(when);
        }
      }
      points.sort((a, b) => a.at.compareTo(b.at));
      checks.sort();

      if (!mounted) return;
      setState(() {
        _trend = points;
        _checkMarks = checks;
        _recent = entries;
        _historyLoading = false;
      });
    } on Object {
      // A dashboard that cannot reach the server still has to draw. The chart falls back to its
      // empty state, which is honest, rather than to invented points.
      if (mounted) setState(() => _historyLoading = false);
    }
  }

  Future<void> _loadIntake() async {
    final intake = await _intakeStore.read();
    if (!mounted) return;
    setState(() => _intake = intake);
  }

  /// The name given at sign-up, and the completeness the card reports.
  /// Handset-only — see [PhrProfile.displayName].
  Future<void> _loadName() async {
    final profile = await _profileStore.read();
    if (!mounted) return;
    setState(() {
      _displayName = profile.displayName;
      _profile = profile;
    });
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
                padding: const EdgeInsets.symmetric(
                  horizontal: TeraSpacing.lg,
                  vertical: TeraSpacing.md,
                ),
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name == null || name.isEmpty
                                  ? greeting
                                  : '$greeting, $name',
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
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
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
                  if (_profileCompletion < 100)
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: TeraColors.neutral100,
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
                                Text(
                                  '$_profileCompletion% Complete',
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
                                    // Was a literal 0.1, beside the literal "10%".
                                    widthFactor: _profileCompletion / 100,
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
                              onPressed: () => auth.isSignedIn
                                  ? _openIntake(context)
                                  : _requireLoginForProfile(context),
                              style: FilledButton.styleFrom(
                                backgroundColor: TeraColors.brand,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                minimumSize: const Size(0, 36),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                ),
                              ),
                              child: const Text(
                                'Complete Profile',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
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
                      color: TeraColors.page,
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
                        // The "Rising" chip was hard-coded, in red, beside a hard-coded chart.
                        // It now reports the count it is actually drawing, and says nothing about
                        // direction: a direction is the deviation engine's verdict, not something
                        // the dashboard is entitled to infer from a handful of plotted points.
                        Text(
                          auth.isSignedIn
                              ? (_trend.isEmpty && _checkMarks.isEmpty
                                    ? 'Nothing recorded in the last 7 days'
                                    : '${_trend.length} cuff reading'
                                          '${_trend.length == 1 ? '' : 's'} · '
                                          '${_checkMarks.length} phone check'
                                          '${_checkMarks.length == 1 ? '' : 's'}')
                              : 'Sign in to see your readings',
                          style: const TextStyle(
                            color: TeraColors.neutral700,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 24),
                        SizedBox(
                          height: 120,
                          width: double.infinity,
                          child: _LockedIfGuest(
                            locked: !auth.isSignedIn,
                            child: _historyLoading
                                ? const Center(
                                    child: SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  )
                                : (_trend.isEmpty && _checkMarks.isEmpty)
                                ? const Center(
                                    child: Text(
                                      'Your checks and cuff readings will appear here',
                                      style: TextStyle(
                                        color: TeraColors.neutral500,
                                        fontSize: 13,
                                      ),
                                    ),
                                  )
                                : Stack(
                                    children: [
                                      Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          _buildGridLine('200'),
                                          _buildGridLine('100'),
                                          _buildGridLine('0'),
                                        ],
                                      ),
                                      Positioned.fill(
                                        child: CustomPaint(
                                          painter: _ChartPainter(_trend, _checkMarks),
                                        ),
                                      ),
                                    ],
                                  ),
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
                  _LockedIfGuest(
                    locked: !auth.isSignedIn,
                    child: _buildRecentActivityList(),
                  ),
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
    if (!auth.isSignedIn) {
      // Placeholder rows behind the lock overlay, so the blurred shape reads as a list rather
      // than as empty space. Deliberately generic: nothing here is anyone's data.
      return Column(
        children: [
          _buildActivityItem('--', 'Your checks appear here', 'Sign in to see them'),
          const SizedBox(height: 12),
          _buildActivityItem('--', 'Your cuff readings appear here', 'Sign in to see them'),
        ],
      );
    }
    if (_recent.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: TeraColors.paper,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: TeraColors.neutral200),
        ),
        child: const Text(
          'Nothing recorded yet. Your first check will show up here.',
          textAlign: TextAlign.center,
          style: TextStyle(color: TeraColors.neutral700, fontSize: 14),
        ),
      );
    }

    final rows = <Widget>[];
    for (final entry in _recent.take(3)) {
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 12));
      rows.add(
        _buildActivityItem(
          _formatWhen(entry['occurred_at'] as String?),
          _entryTitle(entry),
          _entrySubtitle(entry),
        ),
      );
    }
    return Column(children: rows);
  }

  static String _formatWhen(String? iso) {
    if (iso == null) return '--';
    final at = DateTime.tryParse(iso)?.toLocal();
    if (at == null) return '--';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    return '${months[at.month - 1]} ${at.day} · $hh:$mm';
  }

  /// The title for one history row.
  ///
  /// **A cuff reading is the only kind that shows mmHg** — invariant 1, and the API enforces it
  /// by simply not populating those fields on anything else. A trend shows its direction and
  /// nothing numeric.
  static String _entryTitle(Map<String, dynamic> e) {
    final sys = e['systolic_mmhg'] as int?;
    final dia = e['diastolic_mmhg'] as int?;
    if (sys != null && dia != null) return '$sys / $dia mmHg';

    final direction = e['direction'] as String?;
    if (direction != null) {
      return switch (direction) {
        'increase' => 'BP-related change: upward',
        'decrease' => 'BP-related change: downward',
        _ => 'BP-related trend: stable',
      };
    }
    final rejection = e['rejection_reason'] as String?;
    if (rejection != null) return 'Check could not be used';
    return 'Check recorded';
  }

  static String _entrySubtitle(Map<String, dynamic> e) {
    final parts = <String>[];
    final type = e['entry_type'] as String?;
    if (type == 'cuff_reading') {
      parts.add(e['badge'] as String? ?? 'Confirmed BP');
    } else if (type == 'rejected') {
      parts.add((e['rejection_reason'] as String? ?? '').replaceAll('_', ' '));
    } else {
      parts.add('Phone check');
    }
    if (e['synthetic'] == true) parts.add('DEMO DATA');
    return parts.where((p) => p.isNotEmpty).join(' · ');
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
            child: const Icon(
              Icons.favorite_border,
              color: TeraColors.brand,
              size: 20,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  time,
                  style: const TextStyle(
                    fontSize: 12,
                    color: TeraColors.neutral500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: TeraColors.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 13,
                    color: TeraColors.neutral500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// History and Profile both need a token; a guest has none. Caught here, at the tap, rather
  /// than let the screen's own request fail and show a generic error.
  /// The profile is the one thing a guest genuinely cannot do partway.
  ///
  /// It is not gated to push sign-ups: the profile is what `read_insight` reads when a patient
  /// consents to the AI paragraph — age, sex, height, weight, reported conditions — and there is
  /// nowhere to store it without an account. Collecting it into local storage that no request
  /// will ever carry would be a form that quietly does nothing.
  void _requireLoginForProfile(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TeraRadius.card),
        ),
        backgroundColor: TeraColors.paper,
        title: const Text(
          'Login required',
          style: TextStyle(fontWeight: FontWeight.w700, color: TeraColors.ink),
        ),
        content: const Text(
          'Login required to complete your profile. We need this context to help AI translate '
          'your results accurately.',
          style: TextStyle(color: TeraColors.ink, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              Navigator.of(
                context,
              ).pushNamedAndRemoveUntil(Routes.login, (r) => false);
            },
            style: FilledButton.styleFrom(
              backgroundColor: TeraColors.ink,
              foregroundColor: TeraColors.paper,
            ),
            child: const Text('Log in'),
          ),
        ],
      ),
    );
  }

  void _openGuarded(BuildContext context, String route, String feature) {
    if (auth.isGuest) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => GuestGateScreen(feature: feature),
        ),
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
          _buildNavItem(
            context,
            Icons.history,
            'History',
            false,
            () => _openGuarded(context, Routes.history, 'History'),
          ),
          _buildNavItem(
            context,
            Icons.person_outline,
            'Profile',
            false,
            () => _openGuarded(context, Routes.profile, 'Profile'),
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem(
    BuildContext context,
    IconData icon,
    String label,
    bool isActive,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            color: isActive ? TeraColors.brand : TeraColors.neutral500,
          ),
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
              // **First-time calibration is decided by the record, not by local state.**
              //
              // `flow.startCheck()` consults `BpReferenceStatus`, which lives in this install's
              // storage — so a reinstall or a second handset would walk a patient with months of
              // history back through first-time calibration, and a cleared server account would
              // skip it for someone who has never calibrated. The server's own count is the only
              // thing that answers "has this person ever recorded a reading".
              //
              // Unreachable is treated as "not first time": the calibration path needs the
              // network anyway to be worth anything, and sending someone down it on a failed
              // request would be the worse of the two guesses.
              var isFirstTime = false;
              if (auth.isSignedIn) {
                try {
                  // `type=cuff_reading`, not every entry.
                  //
                  // "Has this person ever calibrated" is a question about cuff readings
                  // specifically. Asking for any history at all counted a rejected capture, or a
                  // trend from a check that was never calibrated, as evidence of calibration —
                  // so the very first check would file *something*, and every check after it
                  // skipped the cuff step forever on that basis.
                  final history = await auth.api.getJson(
                    '/v1/history?range=all&type=cuff_reading&limit=1',
                  );
                  final entries = history['entries'] as List<dynamic>? ?? [];
                  isFirstTime = entries.isEmpty;
                } on Object {
                  isFirstTime = false;
                }
              }

              final step = flow.startCheck();

              // The check session is opened here, before the first screen that collects anything,
              // so PRE-01 and CTX-01 have somewhere to go in both modes.
              String? checkSessionId;
              try {
                final resolved = await SessionContextResolver(
                  api: auth.api,
                ).resolveEpisode();
                checkSessionId = await CheckSessionClient(
                  api: auth.api,
                ).open(episodeId: resolved.episodeId, mode: step.session.mode);
              } on Object {
                // Opening failed - most often the contraindication gate at the door, or no
                // network. The flow still runs and the answers are still collected locally; they
                // simply have nothing to attach to, which the processing screen reports.
              }

              navigator.pushReplacementNamed(
                // History exists, so this is not a first run: go straight into the check the
                // state machine chose. No history, and the calibration intro explains recording
                // with a cuff alongside the phone before it hands over to that same flow.
                isFirstTime ? Routes.checkCalibrationIntro : step.route,
                arguments: CheckArgs(
                  step.session,
                  CheckPayload(
                    checkSessionId: checkSessionId,
                    firstTimeCalibration: isFirstTime,
                  ),
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

/// One confirmed cuff reading, for the dashboard chart.
class _BpPoint {
  const _BpPoint({
    required this.at,
    required this.systolic,
    required this.diastolic,
  });

  final DateTime at;
  final int systolic;
  final int diastolic;
}

class _ChartPainter extends CustomPainter {
  const _ChartPainter(this.points, this.checkMarks);

  /// Real cuff readings, oldest first. Was a hard-coded six-element list.
  final List<_BpPoint> points;

  /// Phone checks, drawn as ticks along the base. They share the chart's time axis but not its
  /// value axis, because a check produces a direction and a magnitude in baseline SDs, never a
  /// pressure. Showing them here is what makes a phone capture visible on the dashboard; giving
  /// them a height would be fabricating a reading.
  final List<DateTime> checkMarks;

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

    final startX = 40.0;
    final w = size.width - startX;
    if (w <= 0) return;

    // Ticks first, so the cuff line sits above them.
    if (checkMarks.isNotEmpty) {
      final all = <DateTime>[...checkMarks, for (final p in points) p.at]..sort();
      final first = all.first.millisecondsSinceEpoch;
      final last = all.last.millisecondsSinceEpoch;
      final span = (last - first).toDouble();
      final tick = Paint()
        ..color = TeraColors.neutral500
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      for (final at in checkMarks) {
        final t = span <= 0
            ? 0.5
            : (at.millisecondsSinceEpoch - first) / span;
        final x = startX + t * w;
        canvas.drawLine(
          Offset(x, size.height),
          Offset(x, size.height - 10),
          tick,
        );
      }
    }

    if (points.isEmpty) return;
    // Systolic, which is the line a patient recognises. Diastolic is drawn under it below.
    final data = [for (final p in points) p.systolic.toDouble()];
    final lower = [for (final p in points) p.diastolic.toDouble()];

    // A single reading has no span to divide across; it is drawn as one dot.
    final dx = data.length == 1 ? 0.0 : w / (data.length - 1);

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

    // Diastolic, same scale, lighter — the pair is what a cuff actually reports.
    final lowerPaint = Paint()
      ..color = TeraColors.neutral400
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final lowerPath = Path();
    for (int i = 0; i < lower.length; i++) {
      final x = startX + i * dx;
      final y = size.height - (lower[i] / 200.0) * size.height;
      if (i == 0) {
        lowerPath.moveTo(x, y);
      } else {
        lowerPath.lineTo(x, y);
      }
    }
    canvas.drawPath(lowerPath, lowerPaint);
  }

  @override
  bool shouldRepaint(covariant _ChartPainter oldDelegate) =>
      oldDelegate.points != points || oldDelegate.checkMarks != checkMarks;
}

/// Blurs its child and puts a sign-in prompt over it, for a guest.
///
/// Blurred rather than hidden or replaced with an empty state, and that distinction is the point:
/// an empty chart says "you have no readings", which is a claim about the patient's record. This
/// says "there is something here and it is not yours to see yet", which is what is actually true
/// of a guest session.
class _LockedIfGuest extends StatelessWidget {
  const _LockedIfGuest({required this.locked, required this.child});

  final bool locked;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!locked) return child;

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        children: [
          // Excluded from semantics as well as sight: a screen reader should not read out the
          // placeholder rows behind the lock as though they were the patient's own history.
          ExcludeSemantics(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
              child: Opacity(opacity: 0.45, child: child),
            ),
          ),
          Positioned.fill(
            child: Container(
              color: TeraColors.paper.withValues(alpha: 0.35),
              alignment: Alignment.center,
              padding: const EdgeInsets.all(TeraSpacing.md),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.lock_outline,
                    size: 22,
                    color: TeraColors.neutral700,
                  ),
                  const SizedBox(height: TeraSpacing.sm),
                  const Text(
                    'Please login to view your history.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: TeraColors.ink,
                      fontWeight: FontWeight.w600,
                      fontSize: TeraText.small,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
