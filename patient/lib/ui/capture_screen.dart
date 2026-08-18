import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:tera_capture/tera_capture.dart';
import '../capture/frame_gate.dart';
import '../signal/rejection_messages.dart';
import '../signal/signal_pipeline.dart';
import 'tokens.dart';

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
  CameraController? _cameraController;
  StreamSubscription<AccelerometerEvent>? _accelSub;

  bool _isCameraInitialized = false;
  bool _isFingerLocked = false;
  bool _isCountingDown = false;
  bool _isRecording = false;

  /// The lock phase: the torch is on, the finger is in place, and the screen is measuring what
  /// "this finger on this lens" reads as before anything is recorded against it.
  bool _isLocking = false;
  double _lockProgress = 0;

  int _countdown = 5;
  int _recordingSeconds = 60;

  int _consecutiveLockedFrames = 0;

  // ------------------------------------------------------------ motion rejection

  /// Red-channel readings taken during the lock phase, averaged into [_baselineRed].
  final List<double> _lockSamples = [];

  /// What this fingertip reads as, established immediately before recording starts.
  ///
  /// Null until the lock completes. Every recorded frame is compared against it: a fingertip that
  /// stays put returns a nearly constant red level with the pulse riding on top of it as a small
  /// oscillation, so a *large* departure is the finger moving or lifting rather than a heartbeat.
  double? _baselineRed;

  /// **The two thresholds and their frame counts now live in `capture/frame_gate.dart`.**
  ///
  /// They were tuned here against no hardware and both were wrong on it. Moving them out is not
  /// tidying: the red-channel rule was an absolute level, which cannot be right on two handsets at
  /// once, and stating it as a fraction of the baseline is a change of meaning that deserved
  /// somewhere it could be read and tested. Nothing in this file can be exercised without a
  /// `CameraImage`.
  int _consecutiveMovedFrames = 0;

  /// Consecutive below-threshold frames seen during recording, and the guard that stops several
  /// in-flight frames each raising their own dialog on top of the last.
  int _consecutiveLostFrames = 0;
  bool _fingerLossHandled = false;

  /// Whether the current frame reads as a covered lens. Drives the confirmation button.
  bool _fingerDetected = false;

  final List<AccelSample> _accelSamples = [];
  final List<FrameSample> _frameSamples = [];

  DateTime? _recordingStartTime;

  // ------------------------------------------------------ the shared clock
  //
  // **PTT is a delay between two streams, so both have to be on one clock.** The two streams were
  // each stamped with `DateTime.now()` at the moment their callback ran, which is not one clock —
  // it is two independent measurements of when Dart got around to handling them.
  //
  // For the accelerometer that is actively wrong rather than merely imprecise. Android *batches*
  // sensor events: five samples arrive in a single burst and every one of them takes the delivery
  // time of the burst, so the sample spacing the rate statistics derive is fiction and the beat
  // times are quantised to whenever the platform channel fired. `AccelerometerEvent.timestamp`
  // carries the platform's own `SensorEvent` stamp, taken when the sample was *measured*.
  //
  // It is re-based rather than used directly: the platform stamp may be boot-based while the
  // camera side is not, and only the difference from the first event is meaningful. So the first
  // event pins the platform clock to this Stopwatch, and every later one is placed relative to it.
  final Stopwatch _clock = Stopwatch();
  int? _accelBaseUs;
  double? _accelBaseClockS;

  /// Nanoseconds since the capture started, for a sample the platform stamped [eventUs].
  int _accelTimestampNanos(int eventUs) {
    final nowS = _clock.elapsedMicroseconds / 1e6;
    if (_accelBaseUs == null) {
      _accelBaseUs = eventUs;
      _accelBaseClockS = nowS;
      return (nowS * 1e9).round();
    }
    final t = _accelBaseClockS! + (eventUs - _accelBaseUs!) / 1e6;
    return (t * 1e9).round();
  }

  /// Nanoseconds since the capture started, read now.
  ///
  /// Camera frames get this: the `camera` plugin exposes no platform timestamp, so arrival is the
  /// best available and it is taken *before* any pixel work so the arithmetic cannot push the
  /// stamp later than the moment the frame landed.
  int _frameTimestampNanos() => (_clock.elapsedMicroseconds * 1000);

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;

    final backCamera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    _cameraController = CameraController(
      backCamera,
      ResolutionPreset.low,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    await _cameraController!.initialize();
    await _cameraController!.setFlashMode(FlashMode.torch);
    debugPrint('[TERA] camera ready, torch on');

    if (!mounted) return;

    setState(() {
      _isCameraInitialized = true;
    });

    _cameraController!.startImageStream(_onFrame);
  }

  /// One place deciding what a delivered frame is for, so the three phases cannot disagree.
  void _onFrame(CameraImage image) {
    if (_isRecording) {
      _processRecordingFrame(image);
    } else if (_isLocking) {
      _collectLockSample(image);
    } else if (!_isFingerLocked && !_isCountingDown) {
      _checkFingerLock(image);
    }
  }

  /// Mean luma over a small centred patch of the Y plane.
  ///
  /// Two fixes over the inline arithmetic this replaces, both visible in the device logs:
  ///
  /// * **Row stride.** Y-plane rows are `bytesPerRow` apart, which is *not* `width` — Android
  ///   pads rows for alignment. Indexing by `width` walks a diagonal through the frame and reads
  ///   padding bytes, so the "brightness" being thresholded was partly noise.
  /// * **Cost.** It samples every second pixel rather than all 441. Running the full loop on
  ///   every delivered frame is what produced `ImageReader_JNI: Unable to acquire a buffer item`
  ///   — the callback did not return before the next frame arrived, the pool drained, and the
  ///   stream died mid-recording.
  /// Mean red level over a small centred patch, from the YUV420 planes.
  ///
  /// **Red, not luma, and that is a signal-quality change rather than a cosmetic one.** Fingertip
  /// PPG works because haemoglobin absorbs red light and the absorption changes with each pulse;
  /// the red channel is where that signal actually lives. Luma is a weighted mix dominated by
  /// green, so thresholding and recording it threw away most of the modulation the whole method
  /// depends on.
  ///
  /// `R = Y + 1.402 * (V - 128)`, the standard BT.601 conversion. The V plane is quarter
  /// resolution, so its index is derived from the halved coordinates through `uvRowStride` and
  /// `uvPixelStride` rather than assumed — the same row-stride trap [_meanLuma] documents, one
  /// plane over and with an extra pixel stride that is 2 on most Android devices and 1 on some.
  static double _meanRed(CameraImage image) {
    final y = image.planes[0];
    final v = image.planes[2];
    final yBytes = y.bytes;
    final vBytes = v.bytes;
    final yStride = y.bytesPerRow;
    final uvRowStride = v.bytesPerRow;
    final uvPixelStride = v.bytesPerPixel ?? 1;

    final cx = image.width ~/ 2;
    final cy = image.height ~/ 2;

    double sum = 0;
    int n = 0;
    for (int dy = -10; dy <= 10; dy += 2) {
      final py = cy + dy;
      for (int dx = -10; dx <= 10; dx += 2) {
        final px = cx + dx;
        final yi = py * yStride + px;
        final vi = (py >> 1) * uvRowStride + (px >> 1) * uvPixelStride;
        if (yi >= 0 && yi < yBytes.length && vi >= 0 && vi < vBytes.length) {
          final red = yBytes[yi] + 1.402 * (vBytes[vi] - 128);
          sum += red.clamp(0.0, 255.0);
          n++;
        }
      }
    }
    return n == 0 ? 0.0 : sum / n;
  }

  static double _meanLuma(CameraImage image) {
    final plane = image.planes[0];
    final bytes = plane.bytes;
    final stride = plane.bytesPerRow;
    final cx = image.width ~/ 2;
    final cy = image.height ~/ 2;

    int sum = 0;
    int n = 0;
    for (int dy = -10; dy <= 10; dy += 2) {
      final row = (cy + dy) * stride;
      for (int dx = -10; dx <= 10; dx += 2) {
        final i = row + cx + dx;
        if (i >= 0 && i < bytes.length) {
          sum += bytes[i];
          n++;
        }
      }
    }
    return n == 0 ? 0.0 : sum / n;
  }

  void _checkFingerLock(CameraImage image) {
    final avgLuma = _meanLuma(image);

    final covered = avgLuma > 100;
    if (covered) {
      _consecutiveLockedFrames++;
    } else {
      _consecutiveLockedFrames = 0;
    }

    // A short run rather than one frame, so the button does not flicker on and off under a finger
    // that is already correctly placed. Five frames is about 165 ms — below noticing.
    final detected = _consecutiveLockedFrames >= 5;

    // Rebuild only when the answer *changes*, not on every frame. Without this the confirmation
    // button never enabled: `_consecutiveLockedFrames` climbed but nothing told the UI, so the
    // control stayed greyed out under a finger that was already correctly placed.
    if (detected != _fingerDetected) {
      setState(() => _fingerDetected = detected);
    }

    // **Nothing advances on its own from here.** This used to call `_lockFinger()` once thirty
    // consecutive frames read as covered — about a second — so the screen started measuring a
    // baseline while the patient was still settling their finger, and the button that was supposed
    // to be the gate was frequently never reached. The frame check now does one thing: it decides
    // whether the button is offered.
  }

  /// The patient says the finger is in place. The only way out of the waiting state.
  void _confirmFingerPlaced() {
    if (_isFingerLocked || _isLocking || _isCountingDown || _isRecording) {
      return;
    }
    debugPrint('[TERA] finger confirmed -> locking baseline');
    setState(() => _isFingerLocked = true);
    _beginLocking();
  }

  void _startCountdown() {
    // Stored, not fire-and-forget. This was a bare `Timer.periodic` whose handle nobody kept, so
    // `dispose` could not cancel it: leaving the screen mid-countdown left a timer running against
    // a dead `State`, calling `setState` until its own `!mounted` check happened to fire.
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      setState(() {
        _countdown--;
      });

      if (_countdown <= 0) {
        timer.cancel();
        _startRecording();
      }
    });
  }

  // ------------------------------------------------------------------- locking

  /// Measure what this fingertip reads as, before asking the patient to move the phone.
  ///
  /// **The order here was the other way round and has been changed back deliberately.** The
  /// baseline used to be taken after the chest countdown, on the argument that it should describe
  /// the finger as it will sit for the next minute — moving the phone to the sternum moves the
  /// finger with it, so a baseline taken beforehand describes a position the capture never uses,
  /// and a tight motion check would then fire on the move the screen had just asked for.
  ///
  /// That argument was sound *given a tight, absolute, symmetric threshold*. It is not the
  /// threshold any more. `fingerHasLeftLens` triggers on a 45% fall and ignores every rise, which
  /// is far outside anything repositioning the handset produces while the finger stays on the
  /// lens — so the objection that forced the swap no longer applies, and the cost of the old order
  /// does: it locked while the phone was already flat against the chest, where the patient cannot
  /// see the screen, cannot tell the lock from the countdown, and cannot act on either.
  ///
  /// The two changes are one change. Reverting the threshold without reverting this order would
  /// abort on the chest move again.
  Future<void> _beginLocking() async {
    _lockSamples.clear();
    _consecutiveMovedFrames = 0;
    setState(() {
      _isCountingDown = false;
      _isLocking = true;
      _lockProgress = 0;
    });

    // Before the baseline, so the baseline and the recording share one exposure.
    await _freezeCameraAdaptation();
    if (!mounted) return;

    _lockTimer?.cancel();
    _lockTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final elapsed = timer.tick * 100;
      final progress = (elapsed / _lockDurationMs).clamp(0.0, 1.0);
      setState(() => _lockProgress = progress);

      if (progress < 1.0) return;
      timer.cancel();

      if (_lockSamples.isEmpty) {
        // No frame arrived in two and a half seconds. That is the camera, not the patient, and it
        // is not something to record a baseline of nothing against.
        debugPrint('[TERA] lock failed: no frames');
        _resetToWaiting();
        return;
      }

      _baselineRed = _lockSamples.reduce((a, b) => a + b) / _lockSamples.length;
      debugPrint(
        '[TERA] locked: baselineRed=${_baselineRed!.toStringAsFixed(1)} '
        'from ${_lockSamples.length} frames',
      );
      setState(() {
        _isLocking = false;
        _isCountingDown = true;
      });
      _startCountdown();
    });
  }

  /// Freeze what the camera does to the picture, so the only thing changing is the finger.
  ///
  /// **Auto-exposure is the largest confound in a fingertip PPG.** The pipeline sees a nearly
  /// uniform bright field, concludes it is overexposed, and pulls the gain — which moves the red
  /// mean by far more than a pulse does, is indistinguishable downstream from the finger shifting,
  /// and was one of the two things making the motion check fire on patients who had not moved.
  /// Widening that threshold treats the symptom; this removes the cause.
  ///
  /// **White balance is not lockable through this plugin, and that gap is real.** `camera` 0.12
  /// exposes `setExposureMode` and `setFocusMode` and nothing for AWB — there is no
  /// `setWhiteBalanceMode` to call. Locking it would need a platform channel setting
  /// `CaptureRequest.CONTROL_AWB_MODE` to `OFF` on the Camera2 session. Not done here; named
  /// rather than left silent, because AWB drift moves the red channel specifically and is the
  /// residual after this.
  ///
  /// Failures are swallowed per mode. Plenty of handsets refuse one or both, and a camera that
  /// will not lock is a slightly noisier capture — not a reason to refuse someone a measurement.
  Future<void> _freezeCameraAdaptation() async {
    final controller = _cameraController;
    if (controller == null) return;
    try {
      await controller.setExposureMode(ExposureMode.locked);
      debugPrint('[TERA] exposure locked');
    } on Object catch (e) {
      debugPrint('[TERA] exposure lock unavailable: $e');
    }
    try {
      await controller.setFocusMode(FocusMode.locked);
      debugPrint('[TERA] focus locked');
    } on Object catch (e) {
      debugPrint('[TERA] focus lock unavailable: $e');
    }
  }

  void _collectLockSample(CameraImage image) {
    _lockSamples.add(_meanRed(image));
  }

  /// How long the lock phase runs. Long enough for a stable mean over roughly 75 frames, short
  /// enough that a patient holding still does not wonder whether the app has stopped.
  static const int _lockDurationMs = 2500;

  Timer? _countdownTimer;
  Timer? _lockTimer;
  Timer? _recordingTimer;

  void _startRecording() {
    debugPrint('[TERA] recording started (60s)');
    setState(() {
      _isCountingDown = false;
      _isRecording = true;
    });

    _recordingStartTime = DateTime.now();
    // One clock, started once, read by both streams. Everything downstream that calls a PTT a
    // delay depends on this line.
    _accelBaseUs = null;
    _accelBaseClockS = null;
    _clock
      ..reset()
      ..start();

    // **`samplingPeriod` is not optional here.** The default interval delivered 1027 samples in
    // 60 s on the test handset — about 17 Hz. Seismocardiography needs the aortic-valve-opening
    // fiducial resolved to a few milliseconds, and the proposal's device floor is 200 Hz for
    // exactly that reason: at 17 Hz the sample spacing (~58 ms) is larger than the entire
    // transit-time interval being measured, so no amount of downstream DSP can recover it.
    _accelSub =
        accelerometerEventStream(
          samplingPeriod: SensorInterval.fastestInterval,
        ).listen((AccelerometerEvent event) {
          if (!_isRecording) return;
          final deliveredAtNanos = _clock.elapsedMicroseconds * 1000;
          _accelSamples.add(
            AccelSample(
              x: event.x,
              y: event.y,
              z: event.z,
              // The platform's measurement stamp, re-based onto the shared clock. Not the delivery
              // time — Android batches, and a burst of five samples would otherwise share one.
              timestampNanos: _accelTimestampNanos(
                event.timestamp.microsecondsSinceEpoch,
              ),
              // Kept so the clock-basis check can still see how far delivery lagged measurement.
              realtimeAtDeliveryNanos: deliveredAtNanos,
              uptimeAtDeliveryNanos: deliveredAtNanos,
            ),
          );
        });

    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      setState(() {
        _recordingSeconds--;
      });

      if (_recordingSeconds <= 0) {
        timer.cancel();
        _finishRecording();
      }
    });
  }

  void _processRecordingFrame(CameraImage image) {
    if (_recordingStartTime == null) return;

    // Stamped before any pixel work, so the arithmetic below cannot push the timestamp later than
    // the moment the frame arrived.
    final frameNanos = _frameTimestampNanos();
    final red = _meanRed(image);

    // Finger gone entirely: the lens is dark, whatever the red channel says about it.
    //
    // **Sustained, not instantaneous.** This aborted the whole minute on a single dark frame,
    // which is far too twitchy to survive real hardware: one auto-exposure adjustment, one
    // buffered frame delivered late, or one frame captured while the torch was still ramping is
    // enough to throw away a capture the patient sat through. A finger genuinely leaving the lens
    // stays gone for many consecutive frames, so that is what this requires.
    if (lensReadsUncovered(_meanLuma(image))) {
      _consecutiveLostFrames++;
      if (_consecutiveLostFrames >= uncoveredLensFrameCount) {
        _abortForMotion();
      }
      return;
    }
    _consecutiveLostFrames = 0;

    // Finger no longer on the lens as it was when the baseline was taken.
    //
    // **This is the check that was rejecting still patients**, and it was wrong in two ways at
    // once: it compared against an absolute number of levels, which means something different on
    // every sensor, and it fired on a rise as readily as on a fall — so the exposure pipeline
    // opening up counted as the patient moving. Both are fixed in `fingerHasLeftLens`, which is
    // deliberately generous: what it has to catch is the finger *leaving*, and the uncovered-lens
    // check above is already the second line for that.
    final baseline = _baselineRed;
    if (baseline != null &&
        fingerHasLeftLens(red: red, baselineRed: baseline)) {
      _consecutiveMovedFrames++;
      if (_consecutiveMovedFrames >= fingerLiftFrameCount) {
        debugPrint(
          '[TERA] ABORT: motion, red=${red.toStringAsFixed(1)} '
          'baseline=${baseline.toStringAsFixed(1)}',
        );
        _abortForMotion();
      }
      return;
    }
    _consecutiveMovedFrames = 0;

    _frameSamples.add(
      FrameSample(
        roiMean: red,
        timestampNanos: frameNanos,
        processingNanos: 10000000,
        frameNumber: _frameSamples.length,
        realtimeAtDeliveryNanos: frameNanos,
        uptimeAtDeliveryNanos: frameNanos,
      ),
    );
  }

  /// Abandon the capture because the finger moved, and leave the screen ready to try again.
  ///
  /// Everything acquired so far is discarded rather than submitted short. A capture interrupted by
  /// movement is not a shorter capture — the intervals either side of the movement are measuring
  /// the movement — and `SessionSubmitter` has no way to tell one from the other after the fact.
  Future<void> _abortForMotion() async {
    // Frames arrive in batches, so without this guard every remaining in-flight frame past the
    // threshold pushed its own dialog: the patient had to dismiss a stack of them, and each
    // dismissal restarted the image stream on top of the last.
    if (_fingerLossHandled || !_isRecording) return;
    _fingerLossHandled = true;
    debugPrint(
      '[TERA] ABORT at ${60 - _recordingSeconds}s '
      '(frames=${_frameSamples.length}, accel=${_accelSamples.length})',
    );

    _recordingTimer?.cancel();
    await _accelSub?.cancel();
    _accelSub = null;

    // The torch goes off with the capture. Leaving it burning against someone's fingertip while
    // a dialog waits for a tap is both a surprise and a warm lens; it is turned back on only if
    // they choose to try again.
    try {
      await _cameraController?.stopImageStream();
      await _cameraController?.setFlashMode(FlashMode.off);
    } on Object catch (e) {
      debugPrint('[TERA] could not stand the camera down: $e');
    }

    if (!mounted) return;
    setState(() => _isRecording = false);

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TeraRadius.card),
        ),
        backgroundColor: TeraColors.paper,
        title: const Text(
          'Perekaman dihentikan',
          style: TextStyle(fontWeight: FontWeight.w700, color: TeraColors.ink),
        ),
        content: Text(
          // From the shared table, so the motion abort and the post-capture refusal cannot drift
          // into saying different things about the same reason.
          patientMessageFor(SignalRejection.excessiveMotion),
          style: const TextStyle(color: TeraColors.ink, height: 1.45),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            style: FilledButton.styleFrom(
              backgroundColor: TeraColors.ink,
              foregroundColor: TeraColors.paper,
            ),
            child: const Text('Ulangi'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    await _resetToWaiting();
  }

  /// Return every phase to its starting position and re-arm the camera.
  ///
  /// One place doing this, because the failure modes differ only in what preceded them and a
  /// second copy is how one of them comes to forget a field. The lock samples and the baseline go
  /// with the rest: a baseline measured before an aborted attempt describes a finger position that
  /// no longer applies, and reusing it would compare the next capture against the wrong thing.
  Future<void> _resetToWaiting() async {
    _countdownTimer?.cancel();
    _lockTimer?.cancel();
    _recordingTimer?.cancel();
    await _accelSub?.cancel();
    _accelSub = null;

    if (!mounted) return;
    setState(() {
      _isRecording = false;
      _isLocking = false;
      _isFingerLocked = false;
      _isCountingDown = false;
      _lockProgress = 0;
      _countdown = 5;
      _recordingSeconds = 60;
      _accelSamples.clear();
      _frameSamples.clear();
      _lockSamples.clear();
      _baselineRed = null;
      _consecutiveLockedFrames = 0;
      _consecutiveLostFrames = 0;
      _consecutiveMovedFrames = 0;
      _fingerLossHandled = false;
      _fingerDetected = false;
    });

    final controller = _cameraController;
    if (controller == null) return;
    try {
      await controller.setFlashMode(FlashMode.torch);
      // **Unlocked again, deliberately.** The exposure frozen for the previous attempt was chosen
      // for a finger position that attempt has just established is no longer there. Leaving it
      // locked would measure the next baseline through the last one's settings; auto-exposure is
      // wanted here, during the waiting phase, and frozen again at the next lock.
      try {
        await controller.setExposureMode(ExposureMode.auto);
        await controller.setFocusMode(FocusMode.auto);
      } on Object {
        // Same handsets that refuse the lock refuse the unlock. Nothing is worse than before.
      }
      if (!controller.value.isStreamingImages) {
        await controller.startImageStream(_onFrame);
      }
    } on Object catch (e) {
      debugPrint('[TERA] could not re-arm the camera: $e');
    }
  }

  void _finishRecording() async {
    // **The single number the ML handover asks for back.** Android treats the requested sampling
    // period as a hint, not a contract, so what was asked for says nothing about what arrived.
    // This is measured from the platform timestamps, which is the only figure worth reporting.
    final elapsedS = _clock.elapsedMicroseconds / 1e6;
    final accelHz = elapsedS <= 0 ? 0.0 : _accelSamples.length / elapsedS;
    final ppgHz = elapsedS <= 0 ? 0.0 : _frameSamples.length / elapsedS;
    debugPrint(
      '[Tera] recording finished in ${elapsedS.toStringAsFixed(1)}s: '
      'accel ${_accelSamples.length} samples = ${accelHz.toStringAsFixed(1)} Hz, '
      'camera ${_frameSamples.length} frames = ${ppgHz.toStringAsFixed(1)} fps',
    );
    // **Whether the two streams are still the same distance apart as when they started.**
    //
    // This is what `clock_unstable` now means, and it is the whole of the cross-stream timing
    // question once one clock stamps both. See `_crossStreamDriftMillis`.
    final drift = _crossStreamDriftMillis();
    debugPrint(
      '[Tera] cross-stream drift: '
      '${drift == null ? 'not measurable' : '${drift.toStringAsFixed(1)} ms'}',
    );

    setState(() {
      _isRecording = false;
    });
    _clock.stop();

    await _accelSub?.cancel();
    await _cameraController?.stopImageStream();
    await _cameraController?.setFlashMode(FlashMode.off);

    final result = CaptureResult(
      accelerometer: CaptureRecording<AccelSample>(
        samples: _accelSamples,
        startedAt: _recordingStartTime ?? DateTime.now(),
        endedAt: DateTime.now(),
      ),
      frames: CaptureRecording<FrameSample>(
        samples: _frameSamples,
        startedAt: _recordingStartTime ?? DateTime.now(),
        endedAt: DateTime.now(),
      ),
      // **The two verifications stay null, and that is why this had to change.**
      //
      // They answer "does this handset timestamp in the realtime base or the uptime base?", which
      // needs both platform clocks read back to back at delivery — a platform channel this app
      // does not have and the profiler does. Passing `const CrossStreamClockCheck(camera: null,
      // accelerometer: null)` therefore made `sharedBasis` null on every capture, and the
      // pipeline's precondition refused every one of them as `clock_unstable`. Not a threshold
      // that was too tight: a question that could not be answered here at all.
      //
      // What this app can answer, because it stamps both streams off one `Stopwatch`, is whether
      // they drifted apart. That is the figure the check now runs on.
      clockBasis: CrossStreamClockCheck(
        camera: null,
        accelerometer: null,
        observedDriftMillis: drift,
      ),
      startedAt: _recordingStartTime ?? DateTime.now(),
    );

    widget.onComplete(result);
  }

  /// Relative drift between the accelerometer and camera streams across the capture, in ms.
  ///
  /// Both streams are placed on `_clock`, so a *shared* offset between them is expected and
  /// uninteresting — the accelerometer's first sample simply arrives a little before or after the
  /// first frame, and a fixed offset cancels out of a change in transit time. What matters is
  /// whether that gap is still the same at the end of the minute, so the start skew is subtracted
  /// from the end skew and what remains is the part that does not cancel.
  ///
  /// Immune to dropped frames by construction: it reads the timestamps that arrived and never
  /// counts how many were expected. A capture that lost a third of its frames but kept time still
  /// passes here, and is judged on its rates by the quality gate instead.
  ///
  /// Null when either stream is too short to have two ends — a genuine failure, and one the
  /// pipeline's precondition still refuses.
  double? _crossStreamDriftMillis() {
    if (_accelSamples.length < 2 || _frameSamples.length < 2) return null;
    final startSkew =
        _accelSamples.first.timestampNanos - _frameSamples.first.timestampNanos;
    final endSkew =
        _accelSamples.last.timestampNanos - _frameSamples.last.timestampNanos;
    return (endSkew - startSkew) / 1e6;
  }

  @override
  void dispose() {
    // Every timer, not just the recording one. `_startCountdown` and `_beginLocking` both hold
    // periodic timers that call `setState`; leaving either running past disposal is a callback
    // against a dead `State` and a retained reference to this whole subtree.
    _countdownTimer?.cancel();
    _lockTimer?.cancel();
    _recordingTimer?.cancel();
    _accelSub?.cancel();

    final controller = _cameraController;
    _cameraController = null;
    if (controller != null) {
      // Sequenced, and failures swallowed. Disposing a controller mid-stream throws on some
      // devices, and a throw inside `dispose` takes the route down with it — the patient would
      // see a crash for the crime of pressing back during a capture.
      () async {
        try {
          if (controller.value.isStreamingImages) {
            await controller.stopImageStream();
          }
          await controller.setFlashMode(FlashMode.off);
        } on Object catch (e) {
          debugPrint('[TERA] camera teardown: $e');
        } finally {
          await controller.dispose();
        }
      }();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isCameraInitialized) {
      return const Scaffold(
        backgroundColor: TeraColors.paper,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: TeraColors.paper,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(TeraSpacing.lg),
              child: Text(
                _isRecording
                    ? 'Perekaman berlangsung'
                    : _isCountingDown
                    ? 'Pindahkan HP ke dada'
                    : _isLocking
                    ? 'Mengunci baseline...'
                    : 'Letakkan jari telunjuk Anda menutupi kamera dan flash.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: TeraText.section,
                  fontWeight: FontWeight.bold,
                  color: TeraColors.ink,
                ),
              ),
            ),

            Expanded(
              child: Center(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 200,
                      height: 200,
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(TeraRadius.card),
                        // Brand when the finger is placed, plum when it is not. Plum is the
                        // system-state colour and that is exactly what this is: the app cannot
                        // read the camera, which says nothing about the patient. Red was doing
                        // the same job in a hue the palette forbids.
                        border: Border.all(
                          color: (_isFingerLocked || _isLocking)
                              ? TeraColors.brand
                              : TeraColors.plum,
                          width: 6,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(
                          TeraRadius.card - 6,
                        ),
                        child: CameraPreview(_cameraController!),
                      ),
                    ),
                    if (_isLocking)
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 72,
                            height: 72,
                            child: CircularProgressIndicator(
                              value: _lockProgress,
                              strokeWidth: 6,
                              backgroundColor: TeraColors.paper,
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                TeraColors.brand,
                              ),
                            ),
                          ),
                          const SizedBox(height: TeraSpacing.sm),
                          const Text(
                            'Mengunci baseline...',
                            style: TextStyle(
                              fontSize: TeraText.body,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              shadows: [
                                Shadow(color: Colors.black, blurRadius: 10),
                              ],
                            ),
                          ),
                        ],
                      ),
                    if (_isCountingDown)
                      Text(
                        '$_countdown',
                        style: const TextStyle(
                          fontSize: 72,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          shadows: [
                            Shadow(color: Colors.black, blurRadius: 10),
                          ],
                        ),
                      ),
                    if (_isRecording)
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Paper, not red. A recording indicator on top of a live camera
                          // preview needs contrast, not a hue — and a red heart pulsing over a
                          // blood-pressure capture is the most loaded image the app could put
                          // in front of someone mid-measurement.
                          const Icon(
                            Icons.favorite,
                            color: TeraColors.paper,
                            size: 48,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '$_recordingSeconds s',
                            style: const TextStyle(
                              fontSize: 36,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              shadows: [
                                Shadow(color: Colors.black, blurRadius: 10),
                              ],
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(
                TeraSpacing.lg,
                TeraSpacing.lg,
                TeraSpacing.lg,
                TeraSpacing.sm,
              ),
              child: Text(
                _isLocking
                    ? 'Tahan posisi. Tera sedang mengukur bagaimana jari Anda menempel pada '
                          'lensa.'
                    : _isRecording
                    ? 'Tetap diam, tempelkan HP di dada, dan jangan berbicara.'
                    // The chest-placement instruction lives here, in the countdown, and nowhere
                    // earlier — the finger step happens while the patient can still see both the
                    // screen and the rear lens.
                    : _isCountingDown
                    ? 'Pindahkan HP ke dada sekarang. Jangan lepaskan jari Anda.'
                    : 'Layar akan terlihat merah terang jika jari sudah menutupi kamera dan '
                          'flash dengan benar.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: _isCountingDown ? TeraText.section : TeraText.body,
                  fontWeight: _isCountingDown
                      ? FontWeight.w700
                      : FontWeight.w400,
                  color: _isCountingDown
                      ? TeraColors.ink
                      : TeraColors.neutral700,
                  height: 1.4,
                ),
              ),
            ),

            // **The gate.** Nothing before this point does anything but show the feed: no
            // baseline, no countdown, no recording. It stays disabled until the frame check says
            // the lens is covered, so the button cannot start a capture of an empty lens — that
            // check no longer advances the screen by itself, it only decides whether this is
            // offered.
            if (!_isRecording && !_isCountingDown && !_isLocking)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  TeraSpacing.lg,
                  0,
                  TeraSpacing.lg,
                  TeraSpacing.lg,
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _fingerDetected ? _confirmFingerPlaced : null,
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
                      _fingerDetected
                          ? 'Jari saya sudah pas'
                          : 'Letakkan jari pada kamera',
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
}
