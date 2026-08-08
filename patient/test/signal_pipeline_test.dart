/// The stub must never look like a measurement.
///
/// This is the test that matters most in the mobile app right now. The stub exists so the flow
/// can run end to end before the signal chain is written; the danger is that it produces
/// something the rest of the system treats as real. A fabricated interval becomes a genuine
/// trend in the backend and an estimate on a patient's screen, indistinguishable downstream
/// from a measured one.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tera_capture/tera_capture.dart';
import 'package:tera_patient/capture/capture_session.dart';
import 'package:tera_patient/signal/signal_pipeline.dart';
import 'package:tera_patient/ui/capture_screen.dart';

CaptureResult _capture() {
  final accel = CaptureRecording<AccelSample>(
    samples: List.generate(
      600,
      (i) => AccelSample(
        timestampNanos: i * 2000000,
        x: 0,
        y: 0,
        z: 9.8,
        realtimeAtDeliveryNanos: i * 2000000 + 1000,
        uptimeAtDeliveryNanos: i * 2000000 + 1000,
      ),
    ),
    startedAt: DateTime.utc(2026, 8, 8),
    endedAt: DateTime.utc(2026, 8, 8, 0, 1),
  );
  final frames = CaptureRecording<FrameSample>(
    samples: List.generate(
      120,
      (i) => FrameSample(
        timestampNanos: i * 16666666,
        roiMean: 120.0,
        processingNanos: 500000,
        frameNumber: i,
        realtimeAtDeliveryNanos: i * 16666666 + 1000,
        uptimeAtDeliveryNanos: i * 16666666 + 1000,
      ),
    ),
    startedAt: DateTime.utc(2026, 8, 8),
    endedAt: DateTime.utc(2026, 8, 8, 0, 1),
  );

  return CaptureResult(
    accelerometer: accel,
    frames: frames,
    clockBasis: const CrossStreamClockCheck(camera: null, accelerometer: null),
    startedAt: DateTime.utc(2026, 8, 8),
  );
}

void main() {
  test('the stub rejects every session and produces no intervals', () async {
    final result = await const UnimplementedSignalPipeline().process(_capture());

    expect(result.accepted, isFalse);
    expect(result.pttMs, isEmpty, reason: 'a fabricated interval becomes a real trend');
    expect(result.nBeatsUsable, 0);
    expect(result.nBeatsTotal, 0);
  });

  test('the rejection reason names the real cause, not a signal problem', () async {
    // A judge or a teammate must be able to tell 'the signal was bad' from 'this part of the
    // system does not exist yet'.
    final result = await const UnimplementedSignalPipeline().process(_capture());

    expect(result.rejectionReason, SignalRejection.signalProcessingUnavailable);
    expect(result.rejectionReason!.wireValue, 'signal_processing_unavailable');
    expect(
      result.rejectionReason,
      isNot(SignalRejection.poorSignalQuality),
      reason: 'that would make an unfinished component look like a working one',
    );
  });

  test('the quality block is measured, and what cannot be measured is at its worst', () async {
    final result = await const UnimplementedSignalPipeline().process(_capture());

    // Rates come from the capture that actually happened.
    expect(result.quality['accel_rate_hz'], closeTo(500.0, 1.0));
    expect(result.quality['camera_fps'], closeTo(60.0, 1.0));

    // SNR and motion cannot be computed without the signal chain, so they are reported at
    // their worst rather than invented favourably.
    expect(result.quality['snr_db'], 0.0);
    expect(result.quality['motion_index'], 1.0);
  });

  test('a rejected result cannot be constructed without a reason', () {
    expect(
      () => SignalResult(
        accepted: false,
        pttMs: const [],
        nBeatsTotal: 0,
        nBeatsUsable: 0,
        quality: const {},
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  test('the model version records that this build has no signal chain', () async {
    // The provenance travels with the row, so it never has to be reconstructed from memory.
    expect(signalPipelineVersion, contains('nosignal'));
  });
}

