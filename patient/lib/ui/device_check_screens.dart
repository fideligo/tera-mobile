/// DEV-01, DEV-02 and DEV-03 — the device eligibility check (PM spec section 6).
///
/// Three states of one screen, matching the Figma frames `device eligibillity check.png`, `2` and
/// `3`: a phone held in concentric halos, a headline, a supporting line, and either a progress
/// track or a primary action.
///
/// # The illustration is drawn, not shipped
///
/// The frames use a rendered 3D phone with sensor arcs. There is no asset for it and no time to
/// commission one, so [_SensorHalo] draws the same composition with a `CustomPainter`: concentric
/// halos, a phone body, the camera reticle or a tick, a pulse trace, and arcs that animate
/// outward while the probe runs. It is a clean improvisation rather than a placeholder — it says
/// what the frame says, in the palette, at any screen size, and it costs nothing to ship.
///
/// # What DEV-01 actually does
///
/// It runs the **real** gate — [EligibilityChecker], which requires a torch and a *measured*
/// accelerometer rate — and then files the verdict with the backend through
/// `POST /v1/device/eligibility`. The upload never blocks: a handset that cannot reach the server
/// still knows what it measured, and section 6 puts this check before onboarding precisely so the
/// answer is available offline for the rest of the flow.
///
/// # Neither verdict blocks the account
///
/// Section 6 is explicit ("account tidak diblokir"). DEV-03 continues into the same PHR
/// onboarding as DEV-02, and the patient keeps Home, History, Profile, BP entry and the insight.
/// The only thing a refused handset loses is the sensor capture path.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../capture/device_measurement.dart';
import '../capture/eligibility_check.dart';
import '../routing/check_session.dart';
import '../routing/app_router.dart';
import '../routing/routes.dart';
import 'flow_stub_screen.dart';
import 'tokens.dart';

/// DEV-00 — "First, let's check your phone".
///
/// Shown once before the probe runs. Explains what Tera needs and why, with an expandable
/// "why does Tera need this?" section. The "check my phone" button starts the probe.
class DevicePermissionScreen extends StatelessWidget {
  const DevicePermissionScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    key: screenKey('DEV-01'),
    backgroundColor: TeraColors.paper,
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: TeraSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Spacer(flex: 3),
            const Text(
              "First, let's check\nyour phone",
              style: TextStyle(
                fontSize: TeraText.display,
                fontWeight: FontWeight.w700,
                color: TeraColors.ink,
                height: 1.2,
              ),
            ),
            const SizedBox(height: TeraSpacing.lg),
            const Text(
              'Tera uses your phone\'s camera and motion sensors to capture '
              'cardiovascular signals.\n'
              'We\'ll run a quick compatibility check before your first measurement.',
              style: TextStyle(
                fontSize: TeraText.body,
                color: TeraColors.neutral700,
                height: 1.5,
              ),
            ),
            const Spacer(flex: 2),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(
                  context,
                ).pushReplacementNamed(Routes.deviceChecking),
                style: FilledButton.styleFrom(
                  backgroundColor: TeraColors.paper,
                  foregroundColor: TeraColors.ink,
                  side: const BorderSide(color: TeraColors.ink, width: 1.5),
                ),
                child: const Text('check my phone'),
              ),
            ),
            const SizedBox(height: TeraSpacing.md),
            const _WhyDoesTeraNeedThis(),
            const SizedBox(height: TeraSpacing.xxl),
          ],
        ),
      ),
    ),
  );
}

/// An expandable explanation for why Tera needs camera + sensors.
class _WhyDoesTeraNeedThis extends StatefulWidget {
  const _WhyDoesTeraNeedThis();

  @override
  State<_WhyDoesTeraNeedThis> createState() => _WhyDoesTeraNeedThisState();
}

class _WhyDoesTeraNeedThisState extends State<_WhyDoesTeraNeedThis> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      InkWell(
        borderRadius: BorderRadius.circular(TeraRadius.button),
        onTap: () => setState(() => _expanded = !_expanded),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: TeraSpacing.md,
            vertical: 14,
          ),
          decoration: BoxDecoration(
            border: Border.all(color: TeraColors.ink, width: 1.5),
            borderRadius: BorderRadius.circular(TeraRadius.button),
          ),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'why does tera need this?',
                  style: TextStyle(
                    fontSize: TeraText.body,
                    fontWeight: FontWeight.w600,
                    color: TeraColors.ink,
                  ),
                ),
              ),
              AnimatedRotation(
                duration: const Duration(milliseconds: 200),
                turns: _expanded ? 0.5 : 0,
                child: const Icon(Icons.expand_more, color: TeraColors.ink),
              ),
            ],
          ),
        ),
      ),
      AnimatedCrossFade(
        firstChild: const SizedBox.shrink(),
        secondChild: const Padding(
          padding: EdgeInsets.only(
            top: TeraSpacing.md,
            left: TeraSpacing.md,
            right: TeraSpacing.md,
          ),
          child: Text(
            'Tera captures seismocardiography (SCG) signals from your phone\'s '
            'accelerometer and photoplethysmography (PPG) from the camera. '
            'These require a minimum sensor sample rate and torch availability. '
            'The check measures what your phone can actually deliver — not just '
            'what the spec sheet says.',
            style: TextStyle(
              fontSize: TeraText.small,
              color: TeraColors.neutral700,
              height: 1.5,
            ),
          ),
        ),
        crossFadeState: _expanded
            ? CrossFadeState.showSecond
            : CrossFadeState.showFirst,
        duration: const Duration(milliseconds: 200),
      ),
    ],
  );
}

/// DEV-01 — "Checking your phone's sensors".
class DeviceCheckingScreen extends StatefulWidget {
  const DeviceCheckingScreen({super.key, required this.flow, this.probe});

  final TeraFlow flow;

  /// Injectable so a routing test does not have to reach for a real camera and accelerometer.
  /// Null uses the real gate.
  final Future<EligibilityResult> Function()? probe;

  @override
  State<DeviceCheckingScreen> createState() => _DeviceCheckingScreenState();
}

class _DeviceCheckingScreenState extends State<DeviceCheckingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  /// Drives the progress track. The probe measures for a fixed window, so the track is honest
  /// about roughly how long is left rather than being an indeterminate spinner.
  static const _expectedProbeDuration = Duration(seconds: 10);

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: _expectedProbeDuration)
      ..forward();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    // The existing gate: torch present, and a *measured* accelerometer rate at or above the
    // minimum. `couldNotCheck` is treated as not eligible for routing, which is the conservative
    // reading — the BP-only path still works and nothing is blocked.
    final result = await (widget.probe?.call() ?? EligibilityChecker().check());
    final eligibility = result.canProceed
        ? DeviceEligibility.eligible
        : DeviceEligibility.notEligible;

    await widget.flow.recordEligibility(
      eligibility,
      achievedRateHz: result.achievedRateHz,
    );

    // File it with the backend, and never block on it. `GET /v1/device/current` exists so a
    // reinstall does not have to re-probe, but a handset offline at this moment must still be
    // able to finish setup.
    unawaited(_fileVerdict(result));

    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed(
      eligibility == DeviceEligibility.eligible
          ? Routes.deviceEligible
          : Routes.deviceNotEligible,
    );
  }

  Future<void> _fileVerdict(EligibilityResult result) async {
    try {
      await DeviceEligibilityReporter(api: widget.flow.api).submit(result);
    } on Object {
      // Deliberately swallowed. The verdict is already recorded on the handset, which is what
      // the flow reads; the server copy is a convenience.
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: TeraColors.paper,
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: TeraSpacing.lg),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Spacer(),
            _SensorHalo(state: _HaloState.scanning, animation: _pulse),
            const SizedBox(height: TeraSpacing.xxl),
            const _Headline('Checking your phone sensors'),
            const SizedBox(height: TeraSpacing.md),
            const _Supporting(
              'This takes about 10 seconds. No need to do anything.',
            ),
            const SizedBox(height: TeraSpacing.xl),
            AnimatedBuilder(
              animation: _pulse,
              builder: (_, _) => ClipRRect(
                borderRadius: BorderRadius.circular(TeraRadius.pill),
                child: LinearProgressIndicator(
                  value: _pulse.value.clamp(0.02, 0.98),
                  minHeight: 8,
                  backgroundColor: TeraColors.neutral200,
                  valueColor: const AlwaysStoppedAnimation(TeraColors.brand),
                ),
              ),
            ),
            const Spacer(flex: 2),
          ],
        ),
      ),
    ),
  );
}

/// DEV-02 and DEV-03. Both continue into the same PHR onboarding.
class DeviceVerdictScreen extends StatelessWidget {
  const DeviceVerdictScreen({
    super.key,
    required this.specId,
    required this.eligible,
    required this.title,
    required this.body,
    required this.cta,
  });

  final String specId;

  /// Drives the illustration only. Both verdicts route to the same place.
  final bool eligible;

  final String title;
  final String body;
  final String cta;

  @override
  Widget build(BuildContext context) => Scaffold(
    key: screenKey(specId),
    backgroundColor: TeraColors.paper,
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: TeraSpacing.lg),
        child: Column(
          children: [
            const Spacer(),
            _SensorHalo(
              state: eligible ? _HaloState.ready : _HaloState.unavailable,
            ),
            const SizedBox(height: TeraSpacing.xxl),
            _Headline(title),
            const SizedBox(height: TeraSpacing.md),
            _Supporting(body),
            const Spacer(flex: 2),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pushNamedAndRemoveUntil(
                  Routes.onboardingAboutYou,
                  (r) => false,
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: TeraColors.ink,
                  foregroundColor: TeraColors.paper,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(cta),
                    const SizedBox(width: TeraSpacing.sm),
                    const Icon(Icons.chevron_right, size: 22),
                  ],
                ),
              ),
            ),
            const SizedBox(height: TeraSpacing.lg),
            // Section 6, said out loud. A patient told "not supported" needs to know in the same
            // breath that they still have an account and a product.
            if (!eligible)
              const Padding(
                padding: EdgeInsets.only(bottom: TeraSpacing.md),
                child: Text(
                  'You keep your record, your history and your profile. Only the sensor '
                  'check is unavailable.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: TeraText.small,
                    color: TeraColors.neutral700,
                    height: 1.4,
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

// ------------------------------------------------------------------------- illustration

enum _HaloState { scanning, ready, unavailable }

/// The Figma composition, drawn.
class _SensorHalo extends StatelessWidget {
  const _SensorHalo({required this.state, this.animation});

  final _HaloState state;
  final Animation<double>? animation;

  @override
  Widget build(BuildContext context) {
    final size = math.min(MediaQuery.sizeOf(context).width * 0.62, 260.0);
    final painter = animation == null
        ? CustomPaint(
            size: Size.square(size),
            painter: _HaloPainter(state: state, t: 0),
          )
        : AnimatedBuilder(
            animation: animation!,
            builder: (_, _) => CustomPaint(
              size: Size.square(size),
              painter: _HaloPainter(state: state, t: animation!.value),
            ),
          );

    return Semantics(
      label: switch (state) {
        _HaloState.scanning => 'Measuring the camera and motion sensors',
        _HaloState.ready => 'Sensors available',
        _HaloState.unavailable => 'Sensors unavailable',
      },
      child: SizedBox.square(dimension: size, child: painter),
    );
  }
}

class _HaloPainter extends CustomPainter {
  _HaloPainter({required this.state, required this.t});

  final _HaloState state;

  /// 0..1, drives the outward arc sweep while scanning.
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;

    // Concentric halos. Baltic at low opacity rather than a new colour: the palette has five
    // colours and this is not a sixth.
    for (final (radius, opacity) in [(1.0, 0.10), (0.80, 0.16), (0.62, 0.24)]) {
      canvas.drawCircle(
        centre,
        r * radius,
        Paint()..color = TeraColors.baltic.withValues(alpha: opacity),
      );
    }

    _paintArcs(canvas, centre, r);
    _paintPhone(canvas, centre, r);
  }

  /// The sensor arcs either side of the phone. While scanning they sweep outward on a loop; at
  /// rest they sit at full extent.
  void _paintArcs(Canvas canvas, Offset centre, double r) {
    if (state == _HaloState.unavailable) return;

    final progress = state == _HaloState.scanning ? (t * 3) % 1.0 : 1.0;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = r * 0.035;

    for (var band = 0; band < 3; band++) {
      final reach = 0.42 + band * 0.13;
      // Each band fades in as the sweep passes it, so the motion reads as outward.
      final alpha = state == _HaloState.scanning
          ? (1.0 - ((progress - band / 3).abs() * 2.2)).clamp(0.15, 1.0)
          : 0.7 - band * 0.18;
      stroke.color = TeraColors.paper.withValues(alpha: alpha);

      for (final facing in [-1.0, 1.0]) {
        final box = Rect.fromCircle(center: centre, radius: r * reach);
        // Two 70-degree arcs, opening left and right.
        final start = facing > 0 ? -0.61 : math.pi - 0.61;
        canvas.drawArc(box, start, 1.22, false, stroke);
      }
    }
  }

  void _paintPhone(Canvas canvas, Offset centre, double r) {
    final w = r * 0.62;
    final h = r * 1.24;
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: centre, width: w, height: h),
      Radius.circular(w * 0.18),
    );

    canvas.drawRRect(body, Paint()..color = TeraColors.ink);
    final screen = RRect.fromRectAndRadius(
      Rect.fromCenter(center: centre, width: w * 0.88, height: h * 0.94),
      Radius.circular(w * 0.14),
    );
    canvas.drawRRect(screen, Paint()..color = TeraColors.paper);

    // Speaker slot.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: centre.translate(0, -h * 0.40),
          width: w * 0.26,
          height: h * 0.022,
        ),
        Radius.circular(h * 0.02),
      ),
      Paint()..color = TeraColors.ink,
    );

    switch (state) {
      case _HaloState.scanning:
        _paintReticle(canvas, centre.translate(0, -h * 0.14), w * 0.42);
      case _HaloState.ready:
        _paintTick(canvas, centre.translate(0, -h * 0.14), w * 0.20);
      case _HaloState.unavailable:
        _paintUnavailable(canvas, centre.translate(0, -h * 0.14), w * 0.20);
    }

    _paintPulseTrace(canvas, centre.translate(0, h * 0.18), w * 0.66);
  }

  /// The camera-framing corners from the scanning frame.
  void _paintReticle(Canvas canvas, Offset centre, double side) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = side * 0.07
      ..strokeCap = StrokeCap.round
      ..color = TeraColors.baltic;

    final half = side / 2;
    final arm = side * 0.28;
    for (final sx in [-1.0, 1.0]) {
      for (final sy in [-1.0, 1.0]) {
        final corner = centre.translate(half * sx, half * sy);
        canvas.drawLine(corner, corner.translate(-arm * sx, 0), stroke);
        canvas.drawLine(corner, corner.translate(0, -arm * sy), stroke);
      }
    }
  }

  void _paintTick(Canvas canvas, Offset centre, double radius) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = radius * 0.18
      ..strokeCap = StrokeCap.round
      ..color = TeraColors.brand;

    canvas.drawCircle(centre, radius, stroke);
    canvas.drawPath(
      Path()
        ..moveTo(centre.dx - radius * 0.44, centre.dy)
        ..lineTo(centre.dx - radius * 0.10, centre.dy + radius * 0.34)
        ..lineTo(centre.dx + radius * 0.46, centre.dy - radius * 0.32),
      stroke,
    );
  }

  /// A crossed-out sensor. **Not plum, and not red.** DEV-03 is not an error and must not read
  /// as one: the handset is fine, one capability is missing, and the product still works.
  void _paintUnavailable(Canvas canvas, Offset centre, double radius) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = radius * 0.18
      ..strokeCap = StrokeCap.round
      ..color = TeraColors.neutral400;

    canvas.drawCircle(centre, radius, stroke);
    canvas.drawLine(
      centre.translate(-radius * 0.5, -radius * 0.5),
      centre.translate(radius * 0.5, radius * 0.5),
      stroke,
    );
  }

  /// The pulse trace across the lower screen.
  void _paintPulseTrace(Canvas canvas, Offset centre, double width) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width * 0.055
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = state == _HaloState.unavailable
          ? TeraColors.neutral300
          : TeraColors.brand;

    final path = Path();
    const steps = 40;
    final amplitude = width * 0.16;
    for (var i = 0; i <= steps; i++) {
      final f = i / steps;
      final x = centre.dx - width / 2 + width * f;
      final y =
          centre.dy -
          math.sin(f * math.pi * 2) * amplitude * (1 - (f - 0.5).abs());
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(path, stroke);

    if (state != _HaloState.unavailable) {
      canvas.drawCircle(
        Offset(centre.dx + width / 2, centre.dy),
        width * 0.045,
        Paint()..color = TeraColors.brand,
      );
    }
  }

  @override
  bool shouldRepaint(_HaloPainter old) => old.t != t || old.state != state;
}

// ------------------------------------------------------------------------- text

class _Headline extends StatelessWidget {
  const _Headline(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: TextAlign.center,
    style: const TextStyle(
      fontSize: TeraText.display,
      fontWeight: FontWeight.w700,
      color: TeraColors.ink,
      height: 1.25,
    ),
  );
}

class _Supporting extends StatelessWidget {
  const _Supporting(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: TextAlign.center,
    style: const TextStyle(
      fontSize: TeraText.body,
      color: TeraColors.neutral700,
      height: 1.45,
    ),
  );
}
