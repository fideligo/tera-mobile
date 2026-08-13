import 'dart:async';
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

  int _redIntensity = 0;
  int _consecutiveLockedFrames = 0;

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

  void _checkFingerLock(CameraImage image) {
    int ySum = 0;
    final int width = image.width;
    final int height = image.height;
    final int cx = width ~/ 2;
    final int cy = height ~/ 2;

    for (int dy = -10; dy <= 10; dy++) {
      for (int dx = -10; dx <= 10; dx++) {
        int index = (cy + dy) * width + (cx + dx);
        if (index >= 0 && index < image.planes[0].bytes.length) {
          ySum += image.planes[0].bytes[index];
        }
      }
    }

    int avgLuma = ySum ~/ 441;
    _redIntensity = avgLuma;

    if (avgLuma > 100) {
      _consecutiveLockedFrames++;
      if (_consecutiveLockedFrames > 30) {
        _lockFinger();
      }
    } else {
      _consecutiveLockedFrames = 0;
    }
  }

  void _forceLock() {
    if (!_isFingerLocked && !_isCountingDown) {
      _lockFinger();
    }
  }

  void _lockFinger() {
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
    setState(() {
      _isCountingDown = false;
      _isRecording = true;
    });

    _recordingStartTime = DateTime.now();

    _accelSub = accelerometerEventStream().listen((AccelerometerEvent event) {
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

    int ySum = 0;
    final int width = image.width;
    final int height = image.height;
    final int cx = width ~/ 2;
    final int cy = height ~/ 2;

    for (int dy = -10; dy <= 10; dy++) {
      for (int dx = -10; dx <= 10; dx++) {
        int index = (cy + dy) * width + (cx + dx);
        if (index >= 0 && index < image.planes[0].bytes.length) {
          ySum += image.planes[0].bytes[index];
        }
      }
    }

    int avgLuma = ySum ~/ 441;
    
    // Actively monitor finger presence during recording
    if (avgLuma < 50) {
      _handleFingerRemoved();
      return;
    }

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
                          border: Border.all(
                            color: _isFingerLocked
                                ? TeraColors.brand
                                : Colors.red,
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
                            const Icon(
                              Icons.favorite,
                              color: Colors.red,
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
              padding: const EdgeInsets.all(TeraSpacing.lg),
              child: Text(
                _isRecording
                    ? 'Recording... Please lie still and do not talk.'
                    : _isCountingDown
                    ? 'Get ready...'
                    : 'Cover the rear camera with your finger to begin.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: TeraText.body,
                  color: TeraColors.neutral700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
