/// The four things real hardware disagreed with, and the properties that keep them fixed.
///
/// Every rule exercised here was tuned against no device and was wrong on one. Each test names the
/// observed failure rather than the constant, because the constants will move again and the
/// failures are what must not come back.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sound_mode_advanced/sound_mode_advanced.dart';
import 'package:tera_capture/tera_capture.dart';
import 'package:tera_patient/capture/frame_gate.dart';
import 'package:tera_patient/capture/preflight_check.dart';
import 'package:tera_patient/signal/signal_pipeline.dart';
import 'package:tera_patient/ui/capture_screen.dart';

// ---------------------------------------------------------------------------- helpers

/// A capture built the way `CaptureScreen` builds one: no per-stream verification, because the
/// patient app cannot produce one, and a measured drift instead.
CaptureResult _captureWithDrift(double? driftMillis) {
  final raw =
      jsonDecode(
            File('test/fixtures/ptt_reference_vectors.json').readAsStringSync(),
          )
          as List;
  final c = raw.cast<Map<String, dynamic>>().firstWhere(
    (c) => c['name'] == 'clean_seated',
  );
  final scg = (c['scg'] as List).map((v) => (v as num).toDouble()).toList();
  final ppg = (c['ppg'] as List).map((v) => (v as num).toDouble()).toList();
  final fsScg = (c['fs_scg'] as num).toDouble();
  final fsPpg = (c['fs_ppg'] as num).toDouble();

  return CaptureResult(
    accelerometer: CaptureRecording<AccelSample>(
      samples: [
        for (int i = 0; i < scg.length; i++)
          AccelSample(
            timestampNanos: (i * 1e9 / fsScg).round(),
            x: 0,
            y: 0,
            z: scg[i],
            realtimeAtDeliveryNanos: (i * 1e9 / fsScg).round() + 1000,
            uptimeAtDeliveryNanos: (i * 1e9 / fsScg).round() + 1000,
          ),
      ],
      startedAt: DateTime.utc(2026, 8, 18),
      endedAt: DateTime.utc(2026, 8, 18, 0, 1),
    ),
    frames: CaptureRecording<FrameSample>(
      samples: [
        for (int i = 0; i < ppg.length; i++)
          FrameSample(
            timestampNanos: (i * 1e9 / fsPpg).round(),
            roiMean: ppg[i],
            processingNanos: 500000,
            frameNumber: i,
            realtimeAtDeliveryNanos: (i * 1e9 / fsPpg).round() + 1000,
            uptimeAtDeliveryNanos: (i * 1e9 / fsPpg).round() + 1000,
          ),
      ],
      startedAt: DateTime.utc(2026, 8, 18),
      endedAt: DateTime.utc(2026, 8, 18, 0, 1),
    ),
    clockBasis: CrossStreamClockCheck(
      camera: null,
      accelerometer: null,
      observedDriftMillis: driftMillis,
    ),
    startedAt: DateTime.utc(2026, 8, 18),
  );
}

void main() {
  // ------------------------------------------------------------------------- task 4

  group('the cross-stream check can be satisfied on a real handset', () {
    test('the capture the screen used to build is refused, which is the bug', () async {
      // This is the exact value `_finishRecording` passed for every capture: a const check with
      // no verifications, because reading both boot clocks at delivery needs a platform channel
      // the patient app does not have. `sharedBasis` is null, the precondition wants true, and
      // so **every** capture on hardware came back `clock_unstable` however still the patient
      // held. Not a tolerance that was too tight — a question that could not be answered here.
      final result = await const TeraSignalPipeline().process(
        _captureWithDrift(null),
      );

      expect(result.accepted, isFalse);
      expect(result.rejectionReason, SignalRejection.clockUnstable);
    });

    test('the same capture with a measured drift is not refused for it', () async {
      final result = await const TeraSignalPipeline().process(
        _captureWithDrift(40),
      );

      // What it goes on to conclude about the signal is the signal gate's business. The only
      // claim here is that it is no longer stopped before analysis by a question about clocks.
      expect(result.rejectionReason, isNot(SignalRejection.clockUnstable));
    });

    test('drift the width of a sensor batch is well inside tolerance', () {
      // The benign sources: the two streams start and stop staggered by at most one camera frame
      // (~33 ms) plus one sensor batch (~100 ms). If that were near the limit the gate would be
      // back to refusing still patients, which is the failure being fixed.
      const worstBenign = 33.0 + 100.0;
      expect(worstBenign, lessThan(maxCrossStreamDriftMillis / 3));
    });

    test('streams running at different rates are still refused', () async {
      final result = await const TeraSignalPipeline().process(
        _captureWithDrift(maxCrossStreamDriftMillis + 1),
      );

      // The tolerance is not an amnesty. A gap that grows through the capture is two clocks at
      // different speeds, and every interval across them is wrong by an amount that increases —
      // which is the one failure mode that produces confident nonsense looking normal elsewhere.
      expect(result.accepted, isFalse);
      expect(result.rejectionReason, SignalRejection.clockUnstable);
    });

    test('sign does not matter; either stream may be the fast one', () {
      const ahead = CrossStreamClockCheck(
        camera: null,
        accelerometer: null,
        observedDriftMillis: -(maxCrossStreamDriftMillis + 1),
      );
      expect(ahead.sharedBasis, isFalse);
    });

    test('a rejected capture still reports a clock figure the API accepts', () async {
      // Invariant 3: the session is retained. `SessionQuality.clock_offset_ms` is bounded
      // +/-10,000 ms, and the captures that fail this gate are exactly the ones whose drift can
      // exceed that — an out-of-range value is a 422 that discards the row it was meant to explain.
      final result = await const TeraSignalPipeline().process(
        _captureWithDrift(75000),
      );

      final offset = result.quality['clock_offset_ms'] as double;
      expect(offset, lessThanOrEqualTo(10000.0));
      expect(offset, greaterThanOrEqualTo(-10000.0));
    });

    test('the profiler path is untouched by any of this', () {
      // The per-stream verification still answers the boot-clock question where it can be asked.
      // Nothing above may weaken it: a handset declaring one base and stamping in another is a
      // real finding, and the drift branch only applies when a drift was actually measured.
      ClockBasisVerification v(String name, ObservedClockBasis basis) =>
          ClockBasisVerification(
            streamName: name,
            observed: basis,
            declaredSource: null,
            medianRealtimeLagMillis: 0,
            medianUptimeLagMillis: 0,
            clockSeparationMillis: 4200,
            sampleCount: 100,
          );

      const noDrift = null;
      final mismatched = CrossStreamClockCheck(
        camera: v('camera', ObservedClockBasis.realtime),
        accelerometer: v('accelerometer', ObservedClockBasis.uptime),
        observedDriftMillis: noDrift,
      );
      expect(mismatched.sharedBasis, isFalse);
    });
  });

  // ------------------------------------------------------------------------- task 1

  group('the finger check does not fire on a patient holding still', () {
    // A fingertip PPG's pulsatile component is on the order of 1-2% of the DC level. If a
    // heartbeat can trip this, every capture aborts partway through and the report reads as
    // movement.
    test('a pulse does not read as the finger leaving', () {
      for (final baseline in [60.0, 120.0, 210.0]) {
        for (final swing in [0.01, 0.02, 0.05]) {
          expect(
            fingerHasLeftLens(
              red: baseline * (1 - swing),
              baselineRed: baseline,
            ),
            isFalse,
            reason: 'a ${(swing * 100).round()}% dip at baseline $baseline',
          );
        }
      }
    });

    test('an auto-exposure step does not read as the finger leaving', () {
      // Both directions. The old rule was `(red - baseline).abs() > 28`, so the gain control
      // opening up counted as movement just as readily as the finger going — and on a bright
      // sensor 28 levels is a routine AE step, which is how a still patient was aborted.
      expect(fingerHasLeftLens(red: 210 + 35, baselineRed: 210), isFalse);
      expect(fingerHasLeftLens(red: 210 - 35, baselineRed: 210), isFalse);
    });

    test('a rise is never movement, however large', () {
      // A finger leaving a torch-lit lens makes the red channel fall. Nothing about it makes the
      // channel climb; a climb is the pipeline or the torch, and it belongs to the luma check.
      expect(fingerHasLeftLens(red: 255, baselineRed: 60), isFalse);
    });

    test('the finger actually leaving is still caught', () {
      for (final baseline in [60.0, 120.0, 210.0]) {
        expect(
          fingerHasLeftLens(red: baseline * 0.2, baselineRed: baseline),
          isTrue,
          reason: 'a lift at baseline $baseline',
        );
      }
    });

    test('the rule means the same thing on a dark and a bright sensor', () {
      // **The defect this replaces.** An absolute 28 levels is a 13% departure against a baseline
      // of 210 and a 47% departure against a baseline of 60, so one constant was simultaneously
      // too tight on bright sensors and too loose on dark ones. Scaling to the baseline removes
      // the handset from the question, which is what makes the figure portable at all.
      const fraction = 0.30;
      for (final baseline in [40.0, 90.0, 160.0, 240.0]) {
        expect(
          fingerHasLeftLens(
            red: baseline * (1 - fraction),
            baselineRed: baseline,
          ),
          isFalse,
          reason: 'a $fraction drop must read the same at baseline $baseline',
        );
      }
    });

    test('a nonsense baseline does not abort the capture', () {
      // A lock that produced zero is a failed lock, not a lifted finger, and it must not turn
      // into a motion abort the patient is asked to explain.
      expect(fingerHasLeftLens(red: 0, baselineRed: 0), isFalse);
    });

    test('one bad frame is never enough', () {
      // Already corrected once: the earlier check aborted on a single dark frame, so one late
      // buffer or one frame caught during the torch ramp discarded the whole minute.
      expect(fingerLiftFrameCount, greaterThan(1));
      expect(uncoveredLensFrameCount, greaterThan(1));
    });
  });

  // ------------------------------------------------------------------------- task 2

  group('the pre-flight gate', () {
    test('a silent ringer is the pass, and the only one', () {
      expect(
        preflightStatusFor(RingerModeStatus.silent),
        PreflightStatus.silenced,
      );
      expect(preflightStatusFor(RingerModeStatus.silent).mayProceed, isTrue);
    });

    test('vibrate is a failure, not a partial pass', () {
      // It is the quietest mode for the patient and the loudest for the accelerometer: it
      // vibrates the chassis on every notification, which is precisely the artefact being avoided.
      expect(
        preflightStatusFor(RingerModeStatus.vibrate),
        PreflightStatus.mayVibrate,
      );
      expect(preflightStatusFor(RingerModeStatus.vibrate).mayProceed, isFalse);
      expect(preflightStatusFor(RingerModeStatus.normal).mayProceed, isFalse);
    });

    test('the manual override is offered only when the read failed', () {
      // A bypass next to "your ringer is on" is not a safeguard, it is a button people press. It
      // exists for the platform that will not answer — iOS restricts this read outright — and not
      // as an escape from an answer that came back and said no.
      expect(
        preflightStatusFor(RingerModeStatus.unknown).needsAcknowledgement,
        isTrue,
      );
      expect(
        preflightStatusFor(RingerModeStatus.vibrate).needsAcknowledgement,
        isFalse,
      );
      expect(
        preflightStatusFor(RingerModeStatus.normal).needsAcknowledgement,
        isFalse,
      );
      expect(
        preflightStatusFor(RingerModeStatus.silent).needsAcknowledgement,
        isFalse,
      );
    });

    test('an unreadable state is never silently treated as a pass', () {
      expect(preflightStatusFor(RingerModeStatus.unknown).mayProceed, isFalse);
    });

    test('the real reader converts a platform failure into unreadable', () async {
      // No platform channel is registered in a unit test, so this exercises the catch in
      // `readRingerMode` itself rather than a stub of it.
      expect(await readRingerMode(), RingerModeStatus.unknown);
      expect(await runPreflight(), PreflightStatus.unreadable);
    });
  });
}
