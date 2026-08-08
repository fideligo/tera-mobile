/// Guided capture.
///
/// The proposal's protocol (page 4): seated, handset on the sternum, fingertip on the rear
/// camera, arm stabilised, with readiness indicators gating the start of recording. This screen
/// walks that, then records both streams concurrently for the session duration.
///
/// Concurrent, not sequential, and that is the whole method: pulse transit time is defined
/// between two events of *the same cardiac cycle*, so recording SCG for one interval and PPG
/// for the next yields two disjoint beat sets and removes the measurand entirely.
///
/// Camera permission is explained before the dialog appears. A patient asked for camera access
/// by a blood-pressure app with no explanation will reasonably refuse.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tera_capture/tera_capture.dart';

import 'tokens.dart';

/// Session length. The proposal specifies a seated session of about a minute; 60 s at a
/// resting heart rate gives roughly sixty beats, which is the sample the quality gate needs.
const Duration sessionDuration = Duration(seconds: 60);

enum CaptureStage { explaining, permission, ready, recording, finished, failed }

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

  @override
  void dispose() {
    _ticker?.cancel();
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
      'Sit down, rest your back, and keep both feet on the floor. Stay seated for the whole '
      'minute — standing or moving changes the result.\n\n'
      'Hold the phone flat against your breastbone with one hand. With the other, cover the '
      'rear camera lens completely with a fingertip. The camera light will come on; that is '
      'how Tera sees your pulse.',
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
      'Get into position first, then start. The recording lasts one minute and cannot be '
      'paused.',
      style: TextStyle(color: TeraColors.ink, height: 1.5),
    ),
    const SizedBox(height: TeraSpacing.lg),
    FilledButton(onPressed: _record, child: const Text('Start recording')),
  ];

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
        style: const TextStyle(fontSize: 12, height: 1.6, color: TeraColors.ink800),
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
