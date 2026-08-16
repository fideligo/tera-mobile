/// PROF-01 — the patient's own record, read from the server.
///
/// # What it reads, and why it is three requests
///
///   * `GET /v1/auth/me` — the account. `subject` is the sign-in identifier; there is no name
///     field, and that is deliberate (see [_accountSection]).
///   * `GET /v1/profile` — the clinical record. **404 is a state, not an error**: it is the
///     documented "no profile has been recorded yet", and it means the section renders an
///     invitation to fill it in rather than a failure.
///   * `GET /v1/bp-reference/status` — the calibration standing, computed server-side. The handset
///     keeps its own copy of some of this in `AppFlowState`, but that copy is per-install and
///     wrong after a reinstall or on a second phone; this is the answer that survives both.
///
/// The three are issued together and settle independently. One failing does not blank the others,
/// because a profile screen that goes empty when one endpoint is slow is indistinguishable from an
/// account with nothing in it.
///
/// # No BMI
///
/// Height and weight are shown as given and never combined. `PhrProfileOut` refuses to derive one
/// server-side — "the spec forbids deriving one and invariant 6 forbids the class of thing" — and
/// computing the same figure on the handset would be routing around that rather than honouring it.
library;

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../auth/auth_controller.dart';
import '../capture/phr_profile.dart';
import '../routing/app_flow_state.dart';
import '../routing/app_router.dart';
import '../routing/check_session.dart';
import '../routing/routes.dart';
import 'cuff_reading_screen.dart';
import 'profile_edit_sheet.dart';
import 'tokens.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.api,
    this.auth,
    this.flow,
    this.profileStore,
  });

  final ApiClient api;

  /// Null only in tests that render this screen in isolation; the router always supplies it.
  final AuthController? auth;

  /// Supplies the locally-recorded device verdict. Null in isolation tests.
  final TeraFlow? flow;

  /// Injectable for tests; the real store otherwise.
  final PhrProfileStore? profileStore;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final PhrProfileStore _store =
      widget.profileStore ?? SecurePhrProfileStore();

  bool _loading = true;

  /// Set when the account itself could not be read. Rendered as a banner above whatever did
  /// arrive, never in place of it.
  String? _error;

  Map<String, dynamic>? _me;
  Map<String, dynamic>? _profile;
  Map<String, dynamic>? _reference;

  /// True when the server answered 404 — a profile that has not been filled in yet, which is a
  /// different thing from one that could not be fetched.
  bool _profileMissing = false;

  PhrProfile _local = const PhrProfile();

  AuthController? get auth => widget.auth;
  bool get _isGuest => auth?.isGuest ?? false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    _local = await _store.read();

    if (_isGuest) {
      // A guest has no account and no record. Asking the API would 401 four times and report it
      // as a failure, which it is not.
      if (mounted) setState(() => _loading = false);
      return;
    }

    // Issued together, settled independently. `Future.wait` would surface the first rejection and
    // discard the others' results, which is exactly the behaviour this screen must not have.
    final results = await Future.wait([
      _get('/v1/auth/me'),
      _get('/v1/profile'),
      _get('/v1/bp-reference/status'),
    ]);
    if (!mounted) return;

    final me = results[0];
    final profile = results[1];
    final reference = results[2];

    setState(() {
      _me = me.body;
      _profile = profile.body;
      _reference = reference.body;
      _profileMissing = profile.statusCode == 404;
      // Only the account read is reported as a failure. A missing profile is a state, and the
      // reference status is supporting detail whose absence costs one section rather than the
      // screen.
      _error = me.body == null ? (me.message ?? 'Could not reach the server.') : null;
      _loading = false;
    });
  }

  Future<_Fetched> _get(String path) async {
    try {
      return _Fetched(body: await widget.api.getJson(path));
    } on ApiException catch (e) {
      return _Fetched(statusCode: e.statusCode, message: e.message);
    } on Object catch (e) {
      return _Fetched(message: 'Could not reach the server. $e');
    }
  }

  // ------------------------------------------------------------------- editing

  Future<void> _editClinical() async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: TeraColors.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(TeraRadius.card)),
      ),
      builder: (_) => ProfileEditSheet(api: widget.api, current: _profile),
    );
    if (saved == true && mounted) await _load();
  }

  Future<void> _recordCuffReading() async {
    final navigator = Navigator.of(context);
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => CuffReadingScreen(
          api: widget.api,
          isReference: true,
          onDone: () => navigator.pop(),
        ),
      ),
    );
    if (mounted) await _load();
  }

  /// Clear the session and go back to the door.
  ///
  /// Two halves, and both matter. [AuthController.signOut] wipes every local store — not just the
  /// tokens — so nothing of this patient is left for whoever signs in next. The navigation is
  /// `pushNamedAndRemoveUntil` rather than a pop, because every screen behind this one was built
  /// for a signed-in patient and leaving them on the stack would let the back gesture walk into a
  /// record its owner has just signed out of.
  Future<void> _logOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TeraRadius.card),
        ),
        backgroundColor: TeraColors.paper,
        title: const Text(
          'Log out?',
          style: TextStyle(fontWeight: FontWeight.w700, color: TeraColors.ink),
        ),
        content: const Text(
          'Your records stay on your account and will be here when you sign back in. Everything '
          'this phone holds about you is removed.',
          style: TextStyle(color: TeraColors.ink, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: TeraColors.plum,
              foregroundColor: TeraColors.paper,
            ),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // Best effort on the network half — the local wipe runs either way, because a logout that
    // cannot reach the server must still empty this handset.
    try {
      await auth?.signOut();
    } on Object {
      // Deliberately swallowed; see above.
    }
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil(Routes.login, (r) => false);
  }

  // --------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TeraColors.page,
      appBar: AppBar(
        title: const Text(
          'Profile',
          style: TextStyle(color: TeraColors.ink, fontWeight: FontWeight.bold),
        ),
        backgroundColor: TeraColors.paper,
        elevation: 0,
        iconTheme: const IconThemeData(color: TeraColors.ink),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(TeraSpacing.md),
          children: [
            if (_error != null) ...[_errorBanner(), const SizedBox(height: TeraSpacing.md)],
            _accountSection(),
            const SizedBox(height: TeraSpacing.md),
            _clinicalSection(),
            const SizedBox(height: TeraSpacing.md),
            _deviceSection(),
            const SizedBox(height: TeraSpacing.lg),
            _signOutButton(),
            const SizedBox(height: TeraSpacing.lg),
          ],
        ),
      ),
    );
  }

  Widget _errorBanner() => Container(
    padding: const EdgeInsets.all(TeraSpacing.md),
    decoration: systemFlagDecoration(),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Some of your profile could not be loaded',
          style: TextStyle(fontWeight: FontWeight.w700, color: TeraColors.ink),
        ),
        const SizedBox(height: 6),
        Text(
          '$_error Anything already on this phone is shown below.',
          style: const TextStyle(
            color: TeraColors.ink,
            fontSize: TeraText.small,
            height: 1.4,
          ),
        ),
        const SizedBox(height: TeraSpacing.md),
        OutlinedButton(onPressed: _load, child: const Text('Try again')),
      ],
    ),
  );

  // ------------------------------------------------------------------- account

  /// Name and sign-in identifier.
  ///
  /// **The name is this handset's, not the server's.** `/v1/auth/register-patient` takes a subject
  /// and a password and generates a pseudonym; its docstring says outright that deriving a name
  /// from the sign-up details would put one into the clinical record sideways. So the name greets
  /// the patient on their own phone and never travels, and this section says so rather than
  /// leaving them wondering why it is not on their other device.
  Widget _accountSection() {
    final name = _local.displayName?.trim();
    final subject = _me?['subject'] as String?;

    return _Card(
      title: 'Account',
      children: [
        if (_loading) ...[
          const _ShimmerLine(width: 180),
          const SizedBox(height: TeraSpacing.sm),
          const _ShimmerLine(width: 240),
        ] else ...[
          _Row(
            label: 'Name',
            value: _isGuest
                ? 'Guest'
                : (name == null || name.isEmpty ? 'Not set' : name),
          ),
          _Row(
            label: 'Email',
            value: _isGuest ? 'Not signed in' : (subject ?? 'Unavailable'),
          ),
          const SizedBox(height: TeraSpacing.sm),
          const Text(
            'Your name is kept on this phone only — Tera does not store it on the server, so it '
            'will not follow you to another device.',
            style: TextStyle(
              color: TeraColors.neutral700,
              fontSize: TeraText.micro,
              height: 1.4,
            ),
          ),
        ],
      ],
    );
  }

  // ------------------------------------------------------------------ clinical

  Widget _clinicalSection() {
    final profile = _profile;

    return _Card(
      title: 'Health record',
      action: _loading || _isGuest
          ? null
          : TextButton(onPressed: _editClinical, child: const Text('Edit')),
      children: [
        if (_loading) ...[
          for (var i = 0; i < 5; i++) ...[
            const _ShimmerLine(width: double.infinity),
            const SizedBox(height: TeraSpacing.sm),
          ],
        ] else if (_isGuest) ...[
          const Text(
            'Guest checks are not saved, so there is no health record to show. Create an account '
            'to keep one.',
            style: TextStyle(color: TeraColors.ink, height: 1.45),
          ),
        ] else if (_profileMissing || profile == null) ...[
          const Text(
            'Nothing recorded yet. Your date of birth and sex are what let Tera read a check in '
            'context; height, weight and your BP history refine it.',
            style: TextStyle(color: TeraColors.ink, height: 1.45),
          ),
          const SizedBox(height: TeraSpacing.md),
          FilledButton(
            onPressed: _editClinical,
            style: FilledButton.styleFrom(
              backgroundColor: TeraColors.ink,
              foregroundColor: TeraColors.paper,
            ),
            child: const Text('Add your details'),
          ),
        ] else ...[
          _Row(label: 'Date of birth', value: _dateOfBirthText(profile)),
          _Row(
            label: 'Sex at birth',
            value: _labelFor(
              SexAtBirth.fromWire(profile['sex_assigned_at_birth'] as String?)?.label,
            ),
          ),
          _Row(label: 'Height', value: _measure(profile['height_cm'], 'cm')),
          _Row(label: 'Weight', value: _measure(profile['weight_kg'], 'kg')),
          _Row(
            label: 'Blood pressure history',
            value: _labelFor(
              HypertensionStatus.fromWire(
                profile['hypertension_status'] as String?,
              )?.label,
            ),
          ),
          _Row(
            label: 'BP medication',
            value: switch (profile['taking_bp_medication'] as bool?) {
              true => 'Taking',
              false => 'Not taking',
              null => 'Not set',
            },
          ),
        ],
      ],
    );
  }

  /// Date of birth, with the age it implies.
  ///
  /// Age is arithmetic on a date the patient gave, not an interpretation of it — unlike a BMI,
  /// which combines two measurements into a third figure the record deliberately does not hold.
  String _dateOfBirthText(Map<String, dynamic> profile) {
    final raw = profile['date_of_birth'] as String?;
    if (raw == null) return 'Not set';
    final dob = DateTime.tryParse(raw);
    if (dob == null) return raw;

    final now = DateTime.now();
    var age = now.year - dob.year;
    if (now.month < dob.month || (now.month == dob.month && now.day < dob.day)) {
      age -= 1;
    }
    final d = dob.day.toString().padLeft(2, '0');
    final m = dob.month.toString().padLeft(2, '0');
    return '$d/$m/${dob.year}  ·  $age years';
  }

  static String _labelFor(String? label) => label ?? 'Not set';

  static String _measure(Object? value, String unit) {
    final n = (value as num?)?.toDouble();
    if (n == null) return 'Not set';
    // Whole numbers without a trailing `.0`; anything else to one place.
    final text = n == n.roundToDouble()
        ? n.round().toString()
        : n.toStringAsFixed(1);
    return '$text $unit';
  }

  // -------------------------------------------------------------------- device

  Widget _deviceSection() {
    final state = widget.flow?.state ?? const AppFlowState();
    final eligibility = state.deviceEligibility;
    final rate = state.deviceAccelRateHz;

    return _Card(
      title: 'Device & calibration',
      children: [
        _Row(
          label: 'This phone',
          value: switch (eligibility) {
            DeviceEligibility.eligible => 'Qualified',
            DeviceEligibility.notEligible => 'Not qualified',
            null => 'Not checked yet',
          },
        ),
        _Row(
          label: 'Motion sensor',
          // Never a nominal figure. Null means the probe has not run or could not measure, and
          // saying so beats printing a rate nobody observed.
          value: rate == null
              ? 'Not measured'
              : '${rate.toStringAsFixed(0)} Hz measured',
        ),
        if (rate != null && rate < targetRateHz) ...[
          const SizedBox(height: 6),
          Text(
            rate < minimumRateHz
                ? 'Below the ${minimumRateHz.toStringAsFixed(0)} Hz Tera needs. Sensor checks on '
                      'this phone would carry more timing error than the change they measure.'
                : 'Above the ${minimumRateHz.toStringAsFixed(0)} Hz minimum, below the '
                      '${targetRateHz.toStringAsFixed(0)} Hz Tera works best with. More checks '
                      'may be set aside as unusable.',
            style: const TextStyle(
              color: TeraColors.neutral700,
              fontSize: TeraText.micro,
              height: 1.4,
            ),
          ),
        ],
        const SizedBox(height: TeraSpacing.md),
        const Divider(height: 1),
        const SizedBox(height: TeraSpacing.md),
        if (_loading) ...[
          const _ShimmerLine(width: double.infinity),
        ] else ...[
          _Row(label: 'Cuff calibration', value: _calibrationValue()),
          if (_calibrationNote() case final note?) ...[
            const SizedBox(height: 6),
            Text(
              note,
              style: const TextStyle(
                color: TeraColors.neutral700,
                fontSize: TeraText.micro,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: TeraSpacing.md),
          OutlinedButton(
            onPressed: _isGuest ? null : _recordCuffReading,
            child: Text(
              (_reference?['has_reference'] as bool? ?? false)
                  ? 'Recalibrate with a cuff'
                  : 'Calibrate with a cuff',
            ),
          ),
        ],
      ],
    );
  }

  String _calibrationValue() {
    final reference = _reference;
    if (reference == null) return 'Unavailable';
    if (reference['has_reference'] != true) return 'Not calibrated';

    final age = reference['reference_age_days'] as int?;
    final stale = reference['needs_refresh'] == true;
    final when = switch (age) {
      null => 'set',
      0 => 'set today',
      1 => 'set yesterday',
      _ => 'set $age days ago',
    };
    return stale ? 'Needs refreshing · $when' : when;
  }

  /// Why a refresh is being asked for, in the patient's terms.
  ///
  /// The server names the reason and the client picks the wording — the same split the insight
  /// uses. The wording avoids "expired": the reference does not stop being a real measurement, it
  /// stops being a reliable anchor, and the spec is explicit that it is described as needing a
  /// refresh rather than as having lapsed.
  String? _calibrationNote() {
    final reference = _reference;
    if (reference == null) {
      return 'Tera could not check your calibration standing just now.';
    }
    if (reference['has_reference'] != true) {
      return 'One reading from an upper-arm cuff sets your personal baseline. Estimates need it.';
    }
    if (reference['needs_refresh'] != true) return null;

    return switch (reference['reason'] as String?) {
      'medication_change' =>
        'A medication change was recorded, so the baseline needs setting again.',
      'monitoring_gap' =>
        'It has been a while since your last completed check. A fresh cuff reading re-anchors '
            'your estimates.',
      'persistent_deviation' =>
        'Recent checks have sat away from your baseline. A cuff reading confirms where you are.',
      _ =>
        'Your baseline has drifted out of the window Tera can estimate against. A fresh cuff '
            'reading restores the numbers.',
    };
  }

  Widget _signOutButton() => OutlinedButton(
    onPressed: _logOut,
    style: OutlinedButton.styleFrom(
      foregroundColor: TeraColors.plum,
      side: const BorderSide(color: TeraColors.plum),
      padding: const EdgeInsets.symmetric(vertical: TeraSpacing.md),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(TeraRadius.button),
      ),
    ),
    child: Text(
      _isGuest ? 'Leave guest mode' : 'Log out',
      style: const TextStyle(fontSize: TeraText.body, fontWeight: FontWeight.bold),
    ),
  );
}

/// The eligibility thresholds, mirrored for wording only.
///
/// `eligibility_check.dart` owns the rule and the gate; these are here so the copy can name the
/// same figures without this screen importing the prober.
const double minimumRateHz = 200.0;
const double targetRateHz = 500.0;

/// One request's outcome, kept whole so a 404 can be told from a failure.
class _Fetched {
  const _Fetched({this.body, this.statusCode, this.message});

  final Map<String, dynamic>? body;
  final int? statusCode;
  final String? message;
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.children, this.action});

  final String title;
  final List<Widget> children;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(TeraSpacing.md),
    decoration: BoxDecoration(
      color: TeraColors.paper,
      borderRadius: BorderRadius.circular(TeraRadius.card),
      border: Border.all(color: TeraColors.neutral200),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: TeraText.body,
                  fontWeight: FontWeight.w700,
                  color: TeraColors.ink,
                ),
              ),
            ),
            if (action != null) action!,
          ],
        ),
        const SizedBox(height: TeraSpacing.sm),
        ...children,
      ],
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 4,
          child: Text(
            label,
            style: const TextStyle(
              color: TeraColors.neutral700,
              fontSize: TeraText.small,
            ),
          ),
        ),
        Expanded(
          flex: 5,
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: TeraColors.ink,
              fontSize: TeraText.small,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
}

/// A placeholder bar that moves, so a slow network reads as loading rather than as empty.
///
/// Hand-rolled rather than pulled from a shimmer package: it is twenty lines, and every new
/// dependency needs a justification in `docs/decisions.md` that this would not survive.
class _ShimmerLine extends StatefulWidget {
  const _ShimmerLine({required this.width});

  final double width;

  @override
  State<_ShimmerLine> createState() => _ShimmerLineState();
}

class _ShimmerLineState extends State<_ShimmerLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) {
      final t = _controller.value;
      return Container(
        width: widget.width,
        height: 14,
        margin: const EdgeInsets.symmetric(vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(TeraRadius.field),
          gradient: LinearGradient(
            begin: Alignment(-1 - 2 * (1 - t), 0),
            end: Alignment(1 - 2 * (1 - t), 0),
            colors: const [
              TeraColors.neutral100,
              TeraColors.neutral200,
              TeraColors.neutral100,
            ],
          ),
        ),
      );
    },
  );
}
