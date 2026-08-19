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
import 'package:tera_patient/capture/dsp/tera_ptt.dart';
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

  // ---------------------------------------------------- the state machine leak

  group('a correctly placed fingertip is never read as an absent one', () {
    // **The measurement behind this group.** Luma is `0.299R + 0.587G + 0.114B`, weighted towards
    // green, and a fingertip lit from behind by the torch is the most green-starved frame the
    // sensor produces. A frame that is unmistakably a covered lens to anyone looking at it lands
    // near luma 73 — which is why the confirmation button, gated on luma > 100, could not be
    // reached on a handset, and why the same arithmetic is a hazard for the abort check.
    const fingerLuma = 0.299 * 200 + 0.587 * 20 + 0.114 * 10;

    test('the frame that broke the button computes where we think it does', () {
      expect(fingerLuma, closeTo(73, 1));
      expect(fingerLuma, lessThan(100));
    });

    test('a dark but strongly red frame is a finger, not an empty lens', () {
      // Luma alone would eventually abort this mid-capture. Requiring red as well cannot make the
      // check fire more often than it did, only less, which is the safe direction for a rule whose
      // false positive discards a minute the patient has already given.
      expect(
        lensReadsUncovered(meanLuma: 40, meanRed: 200),
        isFalse,
        reason: 'a torch-lit fingertip the exposure has pulled down',
      );
    });

    test('a genuinely uncovered lens is still caught', () {
      expect(lensReadsUncovered(meanLuma: 10, meanRed: 12), isTrue);
    });

    test('both channels must agree before a capture is thrown away', () {
      // Neither alone is enough: a bright frame is not uncovered whatever its red, and a red frame
      // is not uncovered whatever its luma.
      expect(lensReadsUncovered(meanLuma: 200, meanRed: 10), isFalse);
      expect(lensReadsUncovered(meanLuma: 10, meanRed: 200), isFalse);
    });

    test('the working frame clears the abort check with room to spare', () {
      expect(lensReadsUncovered(meanLuma: fingerLuma, meanRed: 200), isFalse);
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

  // ---------------------------------------- a refusal states its own arithmetic

  group('every gate refusal carries the figures that produced it', () {
    PttSummary summaryWith({required int n, double sd = 2.0}) =>
        PttSummary(n: n, median: 240, sd: sd, iqr: 3, pairYield: 1.0);

    test('a dual-estimator refusal names both rates and the EC13 limit', () {
      // The patient saw "Sinyal terlalu berisik" for this and for a capture with no signal at all,
      // and the log said nothing either way — which is how a tolerance bug survived a device test.
      final result = qualityGate(
        scgHr: 130,
        scgSpectralHr: 110,
        ppgHr: 130,
        ppgSpectralHr: 130,
        summary: summaryWith(n: 40),
      );

      expect(result.passed, isFalse);
      final detail = result.detail!;
      expect(detail, contains('130'), reason: 'the measured rate');
      expect(detail, contains('110'), reason: 'the rate it disagreed with');
      expect(detail, contains('EC13'), reason: 'which limit was applied');
      expect(detail, contains('13.0'), reason: 'the limit at 130 bpm');
    });

    test('a capture inside EC13 at an elevated rate is no longer refused', () {
      // **The regression.** 12 bpm apart at 130 bpm is inside EC13's 13 and outside both old flat
      // constants, so this was refused as noise where the ML reference accepts it.
      final result = qualityGate(
        scgHr: 130,
        scgSpectralHr: 118,
        ppgHr: 130,
        ppgSpectralHr: 130,
        summary: summaryWith(n: 40),
      );

      expect(result.passed, isTrue);
    });

    test('a resting-rate disagreement the old constant let through is caught', () {
      // The same fix in the other direction: 8 bpm apart at 60 bpm cleared the old flat 10 and is
      // outside EC13's 6. Tightening here is not collateral damage, it is the spec.
      final result = qualityGate(
        scgHr: 60,
        scgSpectralHr: 52,
        ppgHr: 60,
        ppgSpectralHr: 60,
        summary: summaryWith(n: 40),
      );

      expect(result.passed, isFalse);
    });

    test('the cross-sensor refusal names both sensors and its limit', () {
      final result = qualityGate(
        scgHr: 70,
        scgSpectralHr: 70,
        ppgHr: 95,
        ppgSpectralHr: 95,
        summary: summaryWith(n: 40),
      );

      expect(result.passed, isFalse);
      expect(result.detail, contains('chest'));
      expect(result.detail, contains('finger'));
      // Named "cross-sensor limit" rather than "EC13" since the floor stopped being EC13's: this
      // limb carries the consumer-hardware floor, the within-sensor limb still carries EC13, and
      // a log that called both EC13 would hide which one refused.
      expect(result.detail, contains('cross-sensor limit'));
    });

    test('a spread refusal names the spread and the ceiling', () {
      final result = qualityGate(
        scgHr: 70,
        scgSpectralHr: 70,
        ppgHr: 70,
        ppgSpectralHr: 70,
        summary: summaryWith(n: 40, sd: 25),
      );

      expect(result.passed, isFalse);
      expect(result.detail, contains('25.0'));
      expect(result.detail, contains('10.0'), reason: 'the ceiling it missed');
    });

    test('no refusal detail is ever blank, whatever failed', () {
      // A blank where an explanation belongs is how this survived a whole device test.
      for (final summary in [summaryWith(n: 2), summaryWith(n: 40, sd: 99)]) {
        final result = qualityGate(
          scgHr: 70,
          scgSpectralHr: 70,
          ppgHr: 70,
          ppgSpectralHr: 70,
          summary: summary,
        );
        expect(result.detail, isNotNull);
        expect(result.detail, isNotEmpty);
      }
    });
  });
}
