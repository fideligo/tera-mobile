/// Guided capture.
///
/// The proposal's protocol (page 4) specifies **seated**, handset on the sternum. The hackathon
/// UX pass that added the finger-lock stage below also asked for supine ("lie down on your back")
/// instructional copy, referencing an infant-screening app whose own instruction is about the
/// *infant's* posture, not the operator's. That is a real conflict with the documented protocol —
/// posture changes hydrostatic pressure at heart level and could bias PTT — recorded in
/// `docs/decisions.md` rather than silently resolved. What changed here is instructional text
/// only; nothing in the signal chain depends on posture, so it is reversible without touching
/// logic.
///
/// Concurrent, not sequential, and that is the whole method: pulse transit time is defined
/// between two events of *the same cardiac cycle*, so recording SCG for one interval and PPG
/// for the next yields two disjoint beat sets and removes the measurand entirely.
///
/// Camera permission is explained before the dialog appears. A patient asked for camera access
/// by a blood-pressure app with no explanation will reasonably refuse.
///
/// # Why there is no camera preview
///
/// `tera_capture`'s own library docstring is explicit: raw camera frames never cross into Dart —
/// only [FrameSample.roiMean], one derived brightness scalar per frame, ever does (invariant 2).
/// There is no image buffer here a `CameraPreview`-style widget could show, and opening a second,
/// independent camera session just to render one (via the `camera` plugin, not a dependency of
/// this app) risks `CAMERA_IN_USE` against the session `tera_capture` already holds, on hardware
/// this project has never had in hand to test against. The finger-lock meter below is the honest
/// substitute: a live readout **of the real signal**, not a decorative animation.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tera_capture/tera_capture.dart';

import 'tokens.dart';

/// Session length. The proposal specifies a seated session of about a minute; 60 s at a
/// resting heart rate gives roughly sixty beats, which is the sample the quality gate needs.
const Duration sessionDuration = Duration(seconds: 60);

enum CaptureStage { explaining, permission, ready, fingerLock, recording, finished, failed }

/// [_FingerLockController]'s state machine.
enum FingerLockState {
  /// Camera just started; collecting the first baseline window.
  baselining,

  /// Baseline established. Watching for a sustained departure from it.
  waiting,

  /// Departed from baseline; watching for the reading to settle.
  stabilizing,

  /// Settled. The gate is open.
  locked,
}

/// Turns the live [FrameSample.roiMean] stream into a finger-placement gate.
///
/// **What this is not**: a video preview, and not a calibrated brightness threshold — the capture
/// paths have never run on real hardware (see the working root `CLAUDE.md`), so an absolute
/// brightness cut-off chosen without a device to measure against would be a guess dressed up as a
/// number. What it uses instead is relative and self-referential: it records its own baseline the
/// moment the camera opens, then watches for a *sustained departure* from that baseline (a finger
/// arriving changes the reading, in whichever direction locking AE/AWB and a torch actually
/// produce on a given handset) followed by *settling* (a covered lens stops moving once the finger
/// is still). Both conditions are about the shape of the signal, not an absolute reading, so they
/// do not depend on knowing that number in advance.
class _FingerLockController {
  _FingerLockController({
    this.baselineSamples = 12,
    this.windowSamples = 10,
    this.departureFraction = 0.12,
    this.stableCoefficientOfVariation = 0.04,
    this.lockSustainSamples = 8,
  });

  /// Frames averaged to establish the "nothing covering the lens yet" reading.
  final int baselineSamples;

  /// Rolling window used for both the departure check and the stability check.
  final int windowSamples;

  /// Fraction the rolling mean must diverge from the baseline by by, before a finger is
  /// considered present at all. Relative to the baseline, not an absolute brightness unit.
  final double departureFraction;

  /// Rolling coefficient of variation (stddev / mean) below which the signal counts as settled.
  final double stableCoefficientOfVariation;

  /// Consecutive in-window samples the stability condition must hold for before locking, so one
  /// lucky quiet frame cannot start a 60 s recording on a finger that has not really landed yet.
  final int lockSustainSamples;

  final List<double> _baseline = [];
  final List<double> _window = [];
  double? _baselineMean;
  int _stableStreak = 0;

  FingerLockState state = FingerLockState.baselining;

  /// The latest rolling mean, for the live readout. Null until the window has data.
  double? get liveMean => _window.isEmpty ? null : _mean(_window);

  /// 0..1, how far through establishing stability the current streak is. For the meter fill.
  double get lockProgress =>
      state == FingerLockState.locked ? 1.0 : (_stableStreak / lockSustainSamples).clamp(0.0, 1.0);

  static double _mean(List<double> v) => v.reduce((a, b) => a + b) / v.length;

  static double _stddev(List<double> v, double mean) {
    if (v.length < 2) return 0;
    final variance = v.map((x) => (x - mean) * (x - mean)).reduce((a, b) => a + b) / v.length;
    return math.sqrt(variance);
  }

  /// Feed one live reading. Returns true the instant the state transitions to [FingerLockState.locked].
  bool addSample(double roiMean) {
    if (state == FingerLockState.baselining) {
      _baseline.add(roiMean);
      if (_baseline.length >= baselineSamples) {
        _baselineMean = _mean(_baseline);
        state = FingerLockState.waiting;
      }
      return false;
    }

    _window.add(roiMean);
    if (_window.length > windowSamples) _window.removeAt(0);
    if (_window.length < windowSamples) return false;

    final mean = _mean(_window);
    final stddev = _stddev(_window, mean);
    final baseline = _baselineMean ?? mean;
    final departed = baseline == 0
        ? mean.abs() > 1
        : (mean - baseline).abs() / baseline.abs() > departureFraction;
    final settled = mean != 0 && (stddev / mean.abs()) < stableCoefficientOfVariation;

    if (!departed) {
      state = FingerLockState.waiting;
      _stableStreak = 0;
      return false;
    }

    if (state == FingerLockState.waiting) state = FingerLockState.stabilizing;

    if (settled) {
      _stableStreak++;
    } else {
      _stableStreak = 0;
    }

    if (_stableStreak >= lockSustainSamples) {
      state = FingerLockState.locked;
      return true;
    }
    return false;
  }
}

class CaptureResult {
  const CaptureResult({
    required this.accelerometer,
    required this.frames,
    required this.clockBasis,
    required this.startedAt,
  });

  final CaptureRecording<AccelSample> accelerometer;
  final CaptureRecording<FrameSample> frames;
  final CrossStreamClockCheck clockBasis;
  final DateTime startedAt;
}

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key, required this.onComplete});

  final void Function(CaptureResult) onComplete;

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  final _capture = TeraCapture();

  CaptureStage _stage = CaptureStage.explaining;
  String? _error;
  int _accelSamples = 0;
  int _frames = 0;
  Duration _elapsed = Duration.zero;
  Timer? _ticker;

  // ── Finger lock (Task 1) ──────────────────────────────────────────────────
  StreamSubscription<FrameSample>? _fingerLockSub;
  Timer? _lockOverrideTimer;
  FingerLockState _lockState = FingerLockState.baselining;
  double? _liveRoiMean;
  double _lockProgress = 0;

  /// After [_lockOverrideDelay] of never settling, a manual way through — this heuristic has
  /// never been validated against real hardware (working root `CLAUDE.md`), and a demo must not
  /// dead-end on a device it happens to misjudge.
  bool _lockOverrideAvailable = false;
  static const _lockOverrideDelay = Duration(seconds: 20);

  @override
  void dispose() {
    _ticker?.cancel();
    _lockOverrideTimer?.cancel();
    _fingerLockSub?.cancel();
    if (_stage == CaptureStage.fingerLock) {
      // Best effort: the widget is gone either way, but an open camera session left running
      // would poison whatever tries to open it next.
      _capture.stopCamera().catchError((_) {});
    }
    super.dispose();
  }

  Future<void> _requestPermission() async {
    setState(() => _stage = CaptureStage.permission);
    try {
      final granted = await _capture.ensureCameraPermission();
      setState(() {
        _stage = granted ? CaptureStage.ready : CaptureStage.failed;
        _error = granted
            ? null
            : 'Tera needs the camera to see your pulse. Without it a spot check cannot be '
                  'recorded. You can allow it in your phone settings.';
      });
    } on Object catch (e) {
      setState(() {
        _stage = CaptureStage.failed;
        _error = 'Could not ask for camera access. $e';
      });
    }
  }

  /// Starts the camera early — before the timed 60 s recording — so the finger-lock meter has a
  /// live signal to gate on. [_record] below reuses this same session; [TeraCapture.startCamera]
  /// is a no-op once a session is already open, so nothing restarts and no frame is lost between
  /// the two stages.
  Future<void> _beginFingerLock() async {
    final controller = _FingerLockController();
    setState(() {
      _stage = CaptureStage.fingerLock;
      _lockState = FingerLockState.baselining;
      _liveRoiMean = null;
      _lockProgress = 0;
      _lockOverrideAvailable = false;
    });

    _lockOverrideTimer = Timer(_lockOverrideDelay, () {
      if (mounted && _stage == CaptureStage.fingerLock) {
        setState(() => _lockOverrideAvailable = true);
      }
    });

    try {
      await _capture.startCamera(const CaptureConfig());
      _fingerLockSub = _capture.frameSamples.listen((sample) {
        final locked = controller.addSample(sample.roiMean);
        if (!mounted) return;
        setState(() {
          _liveRoiMean = controller.liveMean;
          _lockState = controller.state;
          _lockProgress = controller.lockProgress;
        });
        if (locked) _onFingerLocked();
      });
    } on Object catch (e) {
      _lockOverrideTimer?.cancel();
      if (mounted) {
        setState(() {
          _stage = CaptureStage.failed;
          _error = 'Could not start the camera. $e';
        });
      }
    }
  }

  void _onFingerLocked() {
    _lockOverrideTimer?.cancel();
    _fingerLockSub?.cancel();
    _fingerLockSub = null;
    unawaited(_record());
  }

  /// The manual override, once [_lockOverrideAvailable]. The camera is already open and stays
  /// that way — [_record] below is what actually stops it, on completion or failure.
  void _skipFingerLock() {
    _lockOverrideTimer?.cancel();
    _fingerLockSub?.cancel();
    _fingerLockSub = null;
    unawaited(_record());
  }

  Future<void> _record() async {
    setState(() {
      _stage = CaptureStage.recording;
      _elapsed = Duration.zero;
      _accelSamples = 0;
      _frames = 0;
    });

    final startedAt = DateTime.now();
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() => _elapsed = DateTime.now().difference(startedAt));
    });

    try {
      // Both streams start together and run for the same window. Anything else would pair
      // beats that never coexisted.
      final accelFuture = _capture.recordAccelerometer(
        sessionDuration,
        onProgress: (n) => mounted ? setState(() => _accelSamples = n) : null,
      );
      final frameFuture = _capture.recordCamera(
        sessionDuration,
        config: const CaptureConfig(),
        onProgress: (n) => mounted ? setState(() => _frames = n) : null,
      );

      final accelerometer = await accelFuture;
      final frames = await frameFuture;

      _ticker?.cancel();

      final basis = CrossStreamClockCheck(
        camera: frames.clockBasis(null),
        accelerometer: accelerometer.clockBasis,
      );

      if (!mounted) return;
      setState(() => _stage = CaptureStage.finished);
      widget.onComplete(
        CaptureResult(
          accelerometer: accelerometer,
          frames: frames,
          clockBasis: basis,
          startedAt: startedAt,
        ),
      );
    } on Object catch (e) {
      _ticker?.cancel();
      if (mounted) {
        setState(() {
          _stage = CaptureStage.failed;
          _error = 'The recording stopped. $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Spot check')),
      body: ListView(
        padding: const EdgeInsets.all(TeraSpacing.md),
        children: switch (_stage) {
          CaptureStage.explaining => _explaining(),
          CaptureStage.permission => [const LinearProgressIndicator()],
          CaptureStage.ready => _ready(),
          CaptureStage.fingerLock => _fingerLock(),
          CaptureStage.recording => _recording(),
          CaptureStage.finished => [const Text('Recording complete.')],
          CaptureStage.failed => _failed(),
        },
      ),
    );
  }

  List<Widget> _explaining() => [
    const Text(
      'Before you start',
      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: TeraColors.ink),
    ),
    const SizedBox(height: TeraSpacing.sm),
    const Text(
      'Lie down on your back (supine) and place the phone flat against your breastbone, '
      'screen facing up. Stay in that position for the whole minute — standing, moving or '
      'talking changes the result.\n\n'
      'With your other hand, cover the rear camera lens and its light completely with a '
      'fingertip. The camera light will come on; that is how Tera sees your pulse.',
      style: TextStyle(color: TeraColors.ink, height: 1.6),
    ),
    const SizedBox(height: TeraSpacing.lg),
    Container(
      decoration: systemFlagDecoration(),
      padding: const EdgeInsets.all(TeraSpacing.md),
      child: const Text(
        'Tera will ask to use your camera next. It records the brightness of your fingertip, '
        'not an image, and nothing from the camera leaves this phone.',
        style: TextStyle(fontSize: 13, height: 1.5, color: TeraColors.ink),
      ),
    ),
    const SizedBox(height: TeraSpacing.lg),
    FilledButton(onPressed: _requestPermission, child: const Text('Continue')),
  ];

  List<Widget> _ready() => [
    const Text(
      'Ready',
      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: TeraColors.ink),
    ),
    const SizedBox(height: TeraSpacing.sm),
    const Text(
      'Lie down with the phone on your chest first, then continue. Tera will check that your '
      'finger is placed correctly before the one-minute recording — which cannot be paused — '
      'begins.',
      style: TextStyle(color: TeraColors.ink, height: 1.5),
    ),
    const SizedBox(height: TeraSpacing.lg),
    FilledButton(onPressed: _beginFingerLock, child: const Text('Check finger placement')),
  ];

  List<Widget> _fingerLock() {
    final state = _lockState;
    final label = switch (state) {
      FingerLockState.baselining => 'Reading the lens…',
      FingerLockState.waiting => 'Waiting for your finger',
      FingerLockState.stabilizing => 'Hold still…',
      FingerLockState.locked => 'Locked — starting the recording',
    };
    final liveMean = _liveRoiMean;

    return [
      const Text(
        'Finger lock',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: TeraColors.ink),
      ),
      const SizedBox(height: TeraSpacing.sm),
      const Text(
        'Cover the rear camera lens and its light completely with your fingertip and keep it '
        'still. Tera cannot show you a picture of the lens — the camera image never leaves the '
        'sensor, by design — so this reads the same brightness signal the measurement itself '
        'uses, live, and only starts recording once it settles.',
        style: TextStyle(color: TeraColors.neutral700, height: 1.5, fontSize: TeraText.small),
      ),
      const SizedBox(height: TeraSpacing.xl),
      _FingerLockMeter(state: state, progress: _lockProgress),
      const SizedBox(height: TeraSpacing.md),
      Center(
        child: Text(
          label,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: TeraColors.ink),
        ),
      ),
      const SizedBox(height: TeraSpacing.xs),
      Center(
        child: Text(
          liveMean == null ? 'Reading…' : 'Live signal: ${liveMean.toStringAsFixed(1)}',
          style: const TextStyle(fontSize: TeraText.small, color: TeraColors.neutral700),
        ),
      ),
      if (_lockOverrideAvailable && state != FingerLockState.locked) ...[
        const SizedBox(height: TeraSpacing.xl),
        Container(
          decoration: systemFlagDecoration(),
          padding: const EdgeInsets.all(TeraSpacing.md),
          child: const Text(
            'Still not locking? Uneven light or a light touch can confuse this check. If you '
            'are confident your finger fully covers the lens and the light, you can start '
            'anyway.',
            style: TextStyle(fontSize: TeraText.small, color: TeraColors.ink, height: 1.4),
          ),
        ),
        const SizedBox(height: TeraSpacing.sm),
        OutlinedButton(onPressed: _skipFingerLock, child: const Text('Start anyway')),
      ],
    ];
  }

  List<Widget> _recording() {
    final remaining = sessionDuration - _elapsed;
    final seconds = remaining.inSeconds.clamp(0, sessionDuration.inSeconds);

    return [
      const Text(
        'Recording',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: TeraColors.ink),
      ),
      const SizedBox(height: TeraSpacing.sm),
      Text(
        '$seconds seconds left',
        style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w600, color: TeraColors.ink),
      ),
      const SizedBox(height: TeraSpacing.md),
      LinearProgressIndicator(
        value: sessionDuration.inMilliseconds == 0
            ? 0
            : _elapsed.inMilliseconds / sessionDuration.inMilliseconds,
      ),
      const SizedBox(height: TeraSpacing.lg),
      const Text(
        'Keep still. Keep your fingertip on the lens.',
        style: TextStyle(color: TeraColors.ink, height: 1.5),
      ),
      const SizedBox(height: TeraSpacing.lg),
      // Live counts, so a patient can see it is working and an engineer can see it is not.
      Text(
        'Motion readings: $_accelSamples\nCamera frames: $_frames',
        style: const TextStyle(fontSize: TeraText.small, height: 1.6, color: TeraColors.neutral700),
      ),
    ];
  }

  List<Widget> _failed() => [
    Container(
      decoration: systemFlagDecoration(),
      padding: const EdgeInsets.all(TeraSpacing.md),
      child: Text(
        _error ?? 'The spot check could not be completed.',
        style: const TextStyle(color: TeraColors.ink, height: 1.5),
      ),
    ),
    const SizedBox(height: TeraSpacing.lg),
    OutlinedButton(
      onPressed: () => setState(() {
        _stage = CaptureStage.explaining;
        _error = null;
      }),
      child: const Text('Try again'),
    ),
  ];
}

/// The real-time visual indicator Task 1 asked for, honestly scoped: a live meter over the
/// actual [FrameSample.roiMean] signal, not a video preview `tera_capture` cannot provide. Fill
/// and colour both track [_FingerLockController]'s real state, frame by frame.
class _FingerLockMeter extends StatelessWidget {
  const _FingerLockMeter({required this.state, required this.progress});

  final FingerLockState state;
  final double progress;

  Color get _color => switch (state) {
    FingerLockState.baselining => TeraColors.neutral400,
    FingerLockState.waiting => TeraColors.neutral500,
    FingerLockState.stabilizing => TeraColors.baltic,
    FingerLockState.locked => TeraColors.brand,
  };

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(TeraRadius.pill),
        child: SizedBox(
          height: 16,
          child: LinearProgressIndicator(
            // Indeterminate while the baseline is still being established — there is nothing
            // to show progress toward yet.
            value: state == FingerLockState.baselining ? null : progress,
            backgroundColor: TeraColors.neutral200,
            valueColor: AlwaysStoppedAnimation<Color>(_color),
          ),
        ),
      ),
    ],
  );
}
