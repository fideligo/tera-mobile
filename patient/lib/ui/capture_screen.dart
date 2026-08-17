import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:tera_capture/tera_capture.dart';
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

  int _countdown = 5;
  int _recordingSeconds = 60;

  int _consecutiveLockedFrames = 0;

  /// Consecutive below-threshold frames seen during recording, and the guard that stops several
  /// in-flight frames each raising their own dialog on top of the last.
  int _consecutiveLostFrames = 0;
  bool _fingerLossHandled = false;

  /// Whether the current frame reads as a covered lens. Drives the confirmation button.
  bool _fingerDetected = false;

  /// Below this mean luma the lens is treated as uncovered. A fingertip against the lens with the
  /// torch on reads far brighter than this; an uncovered lens in a lit room reads far darker.
  static const int _fingerLostLumaThreshold = 50;

  /// How many consecutive frames must be below that before the recording is stopped. At roughly
  /// 30 fps this is about half a second — long enough to ignore a single bad frame, short enough
  /// that a patient is not left recording nothing.
  static const int _fingerLostFrameCount = 15;

  final List<AccelSample> _accelSamples = [];
  final List<FrameSample> _frameSamples = [];

  DateTime? _recordingStartTime;

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

    _cameraController!.startImageStream((CameraImage image) {
      if (_isRecording) {
        _processRecordingFrame(image);
      } else if (!_isFingerLocked && !_isCountingDown) {
        _checkFingerLock(image);
      }
    });
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

    final detected = avgLuma > 100;
    if (detected) {
      _consecutiveLockedFrames++;
    } else {
      _consecutiveLockedFrames = 0;
    }

    // Rebuild only when the answer *changes*, not on every frame. Without this the confirmation
    // button never enabled: `_consecutiveLockedFrames` climbed but nothing told the UI, so the
    // control stayed greyed out under a finger that was already correctly placed.
    if (detected != _fingerDetected) {
      setState(() => _fingerDetected = detected);
    }

    if (_consecutiveLockedFrames > 30) {
      _lockFinger();
    }
  }

  void _forceLock() {
    if (!_isFingerLocked && !_isCountingDown) {
      _lockFinger();
    }
  }

  void _lockFinger() {
    debugPrint('[TERA] finger locked -> 5s countdown');
    setState(() {
      _isFingerLocked = true;
      _isCountingDown = true;
    });

    _startCountdown();
  }

  void _startCountdown() {
    Timer.periodic(const Duration(seconds: 1), (timer) {
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

  Timer? _recordingTimer;

  void _startRecording() {
    debugPrint('[TERA] recording started (60s)');
    setState(() {
      _isCountingDown = false;
      _isRecording = true;
    });

    _recordingStartTime = DateTime.now();

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
          _accelSamples.add(AccelSample(
            x: event.x,
            y: event.y,
            z: event.z,
            timestampNanos: DateTime.now().microsecondsSinceEpoch * 1000,
            realtimeAtDeliveryNanos: 0,
            uptimeAtDeliveryNanos: 0,
          ));
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

    final avgLuma = _meanLuma(image);

    // Actively monitor finger presence during recording.
    //
    // **Sustained, not instantaneous.** This aborted the whole minute on a single dark frame,
    // which is far too twitchy to survive real hardware: one auto-exposure adjustment, one
    // buffered frame delivered late, or one frame captured while the torch was still ramping is
    // enough to throw away a capture the patient sat through. A finger genuinely leaving the lens
    // stays gone for many consecutive frames, so that is what this now requires.
    if (avgLuma < _fingerLostLumaThreshold) {
      _consecutiveLostFrames++;
      if (_consecutiveLostFrames >= _fingerLostFrameCount) {
        _handleFingerRemoved();
      }
      return;
    }
    _consecutiveLostFrames = 0;

    _frameSamples.add(FrameSample(
      roiMean: avgLuma.toDouble(),
      timestampNanos: DateTime.now().microsecondsSinceEpoch * 1000,
      processingNanos: 10000000,
      frameNumber: _frameSamples.length,
      realtimeAtDeliveryNanos: 0,
      uptimeAtDeliveryNanos: 0,
    ));
  }
  
  void _handleFingerRemoved() {
    // Frames arrive in batches, so without this guard every remaining in-flight frame past the
    // threshold pushed its own dialog — the patient had to dismiss a stack of them, and each
    // dismissal restarted the image stream again on top of the last.
    if (_fingerLossHandled || !_isRecording) return;
    _fingerLossHandled = true;
    debugPrint(
      '[TERA] ABORT: finger lost at ${60 - _recordingSeconds}s '
      '(frames=${_frameSamples.length}, accel=${_accelSamples.length})',
    );

    _recordingTimer?.cancel();
    _accelSub?.cancel();
    _cameraController?.stopImageStream();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Recording Paused'),
        content: const Text('Your finger moved from the camera. Let\'s adjust your position and try again.'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              setState(() {
                _isRecording = false;
                _isFingerLocked = false;
                _isCountingDown = false;
                _countdown = 5;
                _recordingSeconds = 60;
                _accelSamples.clear();
                _frameSamples.clear();
                _consecutiveLockedFrames = 0;
                _consecutiveLostFrames = 0;
                _fingerLossHandled = false;
              });
              // Restart image stream for checking
              _cameraController?.startImageStream((CameraImage image) {
                if (_isRecording) {
                  _processRecordingFrame(image);
                } else if (!_isFingerLocked && !_isCountingDown) {
                  _checkFingerLock(image);
                }
              });
            },
            child: const Text('Try Again'),
          ),
        ],
      ),
    );
  }

  void _finishRecording() async {
    debugPrint(
      '[TERA] recording finished: frames=${_frameSamples.length} '
      'accel=${_accelSamples.length}',
    );
    setState(() {
      _isRecording = false;
    });

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
      clockBasis: const CrossStreamClockCheck(
        camera: null,
        accelerometer: null,
      ),
      startedAt: _recordingStartTime ?? DateTime.now(),
    );

    widget.onComplete(result);
  }

  @override
  void dispose() {
    _accelSub?.cancel();
    if (_cameraController != null) {
      _cameraController!.setFlashMode(FlashMode.off).then((_) {
        _cameraController!.dispose();
      });
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
            const Padding(
              padding: EdgeInsets.all(TeraSpacing.lg),
              child: Text(
                'Place your index finger over the rear camera and flash to lock. Stay relaxed and seated.',
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
                child: GestureDetector(
                  onTap: _forceLock,
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
                            color: _isFingerLocked
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
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(
                TeraSpacing.lg,
                TeraSpacing.lg,
                TeraSpacing.lg,
                TeraSpacing.sm,
              ),
              child: Text(
                _isRecording
                    ? 'Recording. Stay still, keep the phone against your chest, and do not '
                          'talk.'
                    // The chest-placement instruction lives here, in the countdown, and nowhere
                    // earlier. Asking for it before the finger step meant asking someone to put
                    // the phone flat on their sternum and *then* locate a rear lens they can no
                    // longer see.
                    : _isCountingDown
                    ? 'Place the phone on your chest now. Do not move your finger.'
                    : 'Cover the rear camera and flash with your finger, and hold it steady.',
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

            // The explicit confirmation Task 1 asks for. It stays disabled until the finger-lock
            // baseline is met, so the button cannot start a recording of an uncovered lens — but
            // the lock also fires on its own once held, so a patient who is already steady never
            // has to reach for it.
            if (!_isRecording && !_isCountingDown)
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
                    onPressed: _fingerDetected ? _forceLock : null,
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
                          ? 'My finger is placed correctly'
                          : 'Waiting for your finger...',
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
