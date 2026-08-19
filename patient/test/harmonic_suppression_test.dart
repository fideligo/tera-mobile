/// The lub-dub double-count, reproduced and then suppressed.
///
/// From the first successful hardware capture — 468 Hz accelerometer, 29.8 fps camera, 5.1 ms
/// cross-stream drift, every axis refused:
///
///     [Tera] gate FAILED on axis z: chest beat detection unreliable:
///     peak 119.2 bpm vs spectral 58.0 bpm = 61.2 bpm apart, EC13 limit 11.9 bpm at 119 bpm
///
/// 119.2 / 58.0 = 2.06. The time-domain detector was counting aortic opening and aortic closing as
/// two beats while the spectral estimator held the fundamental.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:tera_patient/capture/dsp/tera_ptt.dart';

/// A seismocardiogram with a second complex, as a real sternum produces.
///
/// Each cardiac cycle carries an aortic-opening burst and, [ejectionPeriodS] later, an
/// aortic-closing burst at [dubRelative] of its amplitude. Both are genuine mechanical events —
/// this is not noise being modelled, it is what the chest wall actually does, and it is why no
/// amount of prominence tuning separates them.
///
/// The default 0.3 is the ratio that reproduces the hardware condition: strong enough that the
/// peak detector counts it, weak enough that the *spectral* estimator still resolves the
/// fundamental, which is what the device log showed.
List<double> lubDubScg({
  required double fs,
  required double hrBpm,
  required double durationS,
  double ejectionPeriodS = 0.32,
  double dubRelative = 0.3,
}) {
  final n = (fs * durationS).round();
  final rr = 60.0 / hrBpm;
  // Gravity, as the handset delivers it. The chain removes its own DC.
  final out = List<double>.filled(n, 9.81);

  void burst(double atS, double amplitude) {
    const ringHz = 14.0;
    const decayS = 0.035;
    final start = (atS * fs).round();
    for (int k = 0; k < (0.12 * fs).round(); k++) {
      final i = start + k;
      if (i < 0 || i >= n) continue;
      final t = k / fs;
      out[i] +=
          amplitude *
          math.exp(-t / decayS) *
          math.sin(2 * math.pi * ringHz * t);
    }
  }

  for (double t = 0.5; t < durationS - 0.5; t += rr) {
    burst(t, 0.05);
    if (dubRelative > 0) burst(t + ejectionPeriodS, 0.05 * dubRelative);
  }
  return out;
}

/// A fingertip PPG with a dicrotic notch — the same valve closure, seen downstream.
List<double> dicroticPpg({
  required double fs,
  required double hrBpm,
  required double durationS,
  double dicroticRelative = 0.3,
}) {
  final rr = 60.0 / hrBpm;
  final n = (fs * durationS).round();
  return [
    for (int i = 0; i < n; i++)
      () {
        final phase = ((i / fs) % rr) / rr;
        final systolic = math.exp(-math.pow(phase - 0.15, 2) / 0.004);
        final dicrotic =
            dicroticRelative * math.exp(-math.pow(phase - 0.45, 2) / 0.006);
        return 128.0 + 12.0 * (systolic + dicrotic);
      }(),
  ];
}

void main() {
  const fs = 468.0; // what the handset actually achieved
  const hr = 58.0; // what the spectral estimator actually reported

  group('the failure is reproduced before it is fixed', () {
    test('the reference refractory could not have fixed it', () {
      // `distance = fs * 60 / maxBpm` is 300 ms at any sample rate, and it was already in force —
      // 140 samples at 468 Hz. The spurious peaks sat 503 ms apart, outside it. Stated as
      // arithmetic because "add a 300 ms refractory" is the obvious fix and is a no-op here.
      const observedSpuriousBpm = 119.2;
      expect(60000 / maxBpm, closeTo(300, 0.001));
      expect(60000 / observedSpuriousBpm, greaterThan(60000 / maxBpm));
    });

    test('the spectral estimator holds the fundamental, which is the premise', () {
      // The whole correction rests on this: a harmonic adds energy at 2f, it does not move the
      // peak at f. If this stopped being true the fix would have nothing trustworthy to steer by,
      // so it is asserted rather than assumed.
      final detected = detectScgBeats(
        lubDubScg(fs: fs, hrBpm: hr, durationS: 60),
        fs,
      );
      expect(detected.spectralHr, closeTo(hr, 3.0));
    });
  });

  group('the second pass fires only when it should, and only if it helps', () {
    test('a clean capture is left alone and the estimators stay independent', () {
      // No second complex. The first pass already agrees with the fundamental, so nothing runs.
      // This is the path almost every capture takes, and on it the dual-estimator check retains
      // its full value.
      final detected = detectScgBeats(
        lubDubScg(fs: fs, hrBpm: hr, durationS: 60, dubRelative: 0.0),
        fs,
      );

      expect(detected.harmonicSuppressed, isFalse);
      expect(detected.peakHr, closeTo(hr, 1.0));
      expect(
        (detected.peakHr - detected.spectralHr).abs(),
        lessThanOrEqualTo(hrToleranceBpm(detected.peakHr)),
      );
    });

    test('a lub-dub capture is corrected and lands inside EC13', () {
      // **The fix.** The recording that produced the device log now passes the dual-estimator limb
      // because the detector has stopped counting the valve closing as a beat.
      final detected = detectScgBeats(
        lubDubScg(fs: fs, hrBpm: hr, durationS: 60),
        fs,
      );

      expect(
        detected.harmonicSuppressed,
        isTrue,
        reason: 'the second pass should have been needed here',
      );
      expect(detected.peakHr, closeTo(hr, 3.0));
      expect(
        (detected.peakHr - detected.spectralHr).abs(),
        lessThanOrEqualTo(hrToleranceBpm(detected.peakHr)),
        reason: 'peak ${detected.peakHr} vs spectral ${detected.spectralHr}',
      );
    });

    test('the refractory is derived from the fundamental, not from a constant', () {
      // 0.75 of a beat at 58 bpm is 776 ms, which suppresses a 503 ms echo and which a 300 ms
      // floor cannot. The same fraction at 120 bpm is 375 ms, so the rule adapts rather than
      // imposing a resting-rate assumption on a fast heart.
      double refractoryMs(double bpm) =>
          harmonicRefractoryFraction * 60000.0 / bpm;

      expect(refractoryMs(58), closeTo(776, 1));
      expect(refractoryMs(58), greaterThan(60000 / 119.2));
      expect(refractoryMs(120), closeTo(375, 1));
    });

    test('a rate close to the fundamental never triggers a second pass', () {
      // The trigger has to sit far above any honest disagreement. EC13 at 60 bpm allows 6 bpm, a
      // ratio of 1.1; the trigger is 1.5.
      expect((60.0 + 6.0) / 60.0, lessThan(harmonicSuspicionRatio));
    });
  });

  group('the correction cannot manufacture a passing capture', () {
    test('noise with no rhythm is still refused', () {
      // The constraint only ever removes peaks, so it cannot turn a recording of nothing into a
      // recording of something: a wider refractory on noise gives fewer irregular peaks, not a
      // regular beat train.
      final rng = math.Random(7);
      final analysis = analyseCapture(
        scg: [
          for (int i = 0; i < (fs * 60).round(); i++)
            9.81 + (rng.nextDouble() - 0.5) * 0.4,
        ],
        fsScg: fs,
        ppg: [
          for (int i = 0; i < 30 * 60; i++)
            128.0 + (rng.nextDouble() - 0.5) * 8,
        ],
        fsPpg: 30,
      );
      expect(analysis.gate.passed, isFalse);
    });

    test('a flat capture is not "corrected" into a reading', () {
      final flat = List<double>.filled((fs * 60).round(), 9.81);
      expect(detectScgBeats(flat, fs).harmonicSuppressed, isFalse);
    });

    test('when both estimators are fooled they agree, and the window catches it', () {
      // **The honest limit of this approach, and the reason the plausibility window had to come
      // back.** With a diastolic complex nearly as strong as the systolic one, the envelope's
      // dominant frequency is no longer the fundamental: *both* estimators lock onto a harmonic.
      //
      // The second pass correctly declines — its guide is wrong, so it cannot improve agreement —
      // but the dual-estimator check then passes, because two methods failing the same way agree
      // with each other. Measured here: 187.7 bpm peak against 174.0 bpm spectral is 13.7 apart,
      // inside EC13's 18.8 at that rate. The gate's central check is satisfied by a capture that
      // is wrong by a factor of three.
      final detected = detectScgBeats(
        lubDubScg(fs: fs, hrBpm: hr, durationS: 60, dubRelative: 0.85),
        fs,
      );

      expect(detected.spectralHr, isNot(closeTo(hr, 10.0)));
      expect(detected.harmonicSuppressed, isFalse);
      expect(
        (detected.peakHr - detected.spectralHr).abs(),
        lessThan(hrToleranceBpm(detected.peakHr)),
        reason: 'the two agree — which is exactly the problem',
      );

      // So agreement is not what refuses it. The seated plausibility window is: nobody sits still
      // at 187 bpm, and a capture claiming they did is describing its own detector.
      final gate = qualityGate(
        scgHr: detected.peakHr,
        scgSpectralHr: detected.spectralHr,
        ppgHr: hr,
        ppgSpectralHr: hr,
        summary: const PttSummary(
          n: 40,
          median: 240,
          sd: 2,
          iqr: 3,
          pairYield: 1.0,
        ),
      );
      expect(gate.passed, isFalse);
      expect(gate.detail, contains('plausible window'));
    });
  });

  group('the consumer-hardware tuning', () {
    test('the capture that failed cross-sensor by 0.7 bpm now passes', () {
      // From the device log, after harmonic suppression had already fixed the double-count:
      //
      //     sensorsDisagree — chest 60.3 bpm vs finger 54.2 bpm = 6.1 bpm apart, EC13 limit 5.4
      //
      // EC13's 5 bpm floor is a readout tolerance for one device against a reference. Asking a
      // camera watching a fingertip through skin and an accelerometer resting on a sternum to
      // count within five of each other is a different demand, and the camera is the one that
      // loses beats.
      final gate = qualityGate(
        scgHr: 60.3,
        scgSpectralHr: 60.3,
        ppgHr: 54.2,
        ppgSpectralHr: 54.2,
        summary: const PttSummary(
          n: 40,
          median: 240,
          sd: 3,
          iqr: 4,
          pairYield: 0.8,
        ),
      );
      expect(gate.passed, isTrue, reason: gate.detail);
    });

    test('the within-sensor floor did not move with it', () {
      // The dual-estimator check is the harmonic net. A 6.1 bpm disagreement *inside* one sensor
      // at 60 bpm is still a refusal, because there it means the two estimators of the same signal
      // disagree — which is what a partial harmonic looks like.
      final gate = qualityGate(
        scgHr: 60.3,
        scgSpectralHr: 54.2,
        ppgHr: 60.3,
        ppgSpectralHr: 60.3,
        summary: const PttSummary(
          n: 40,
          median: 240,
          sd: 3,
          iqr: 4,
          pairYield: 0.8,
        ),
      );
      expect(gate.passed, isFalse);
      expect(gate.detail, contains('EC13'));
    });

    test('a genuinely desynchronised pair is still refused', () {
      // The relaxation is bounded. 20 bpm apart is not two sensors watching one heart.
      final gate = qualityGate(
        scgHr: 75.0,
        scgSpectralHr: 75.0,
        ppgHr: 55.0,
        ppgSpectralHr: 55.0,
        summary: const PttSummary(
          n: 40,
          median: 240,
          sd: 3,
          iqr: 4,
          pairYield: 0.8,
        ),
      );
      expect(gate.passed, isFalse);
      expect(gate.detail, contains('cross-sensor limit'));
    });

    test('the dispersion ceiling still refuses what the looser rate check admits', () {
      // **This is what makes relaxing the rate comparison defensible.** The cross-sensor rate
      // check is a cheap proxy for simultaneity; the spread of the intervals it produces is the
      // direct measurement, and that one is untouched. Two streams 6 bpm apart that were not
      // actually watching the same beats produce pairs that scatter, and 25 ms of scatter is
      // refused whatever the rates said.
      final gate = qualityGate(
        scgHr: 60.3,
        scgSpectralHr: 60.3,
        ppgHr: 54.2,
        ppgSpectralHr: 54.2,
        summary: const PttSummary(
          n: 40,
          median: 240,
          sd: 25,
          iqr: 30,
          pairYield: 0.8,
        ),
      );
      expect(gate.passed, isFalse);
      expect(gate.detail, contains('ceiling'));
    });

    test('the wider window cannot pair across two cardiac cycles', () {
      // The property that makes 500 ms safe rather than merely permissive. At 60 bpm a cycle is
      // 1000 ms, so the next beat's foot is never inside the window: a missed beat stays unpaired
      // instead of becoming a wrong pair.
      const restingCycleMs = 1000.0;
      expect(pttMaxSeconds * 1000, lessThan(restingCycleMs / 2 + 1));

      // A beat at t=0 and a foot belonging to the next cycle.
      final paired = pairBeats(const [0.0], const [1.24]);
      expect(paired, isEmpty);
    });

    test('the widened window admits an interval the old one dropped', () {
      final paired = pairBeats(const [0.0], const [0.45]);
      expect(paired.single, closeTo(450, 1e-9));
    });
  });

  group('both streams carry the correction', () {
    test('a healthy dicrotic PPG is not disturbed by it', () {
      // The finger detector gets the same second pass, because the dicrotic notch is the same
      // valve closure arriving by another route and correcting only the chest would move the
      // refusal to the cross-sensor check. On a PPG whose systolic peak dominates it never needs
      // to fire, and this holds it to leaving that case alone.
      final detected = detectPpgFeet(
        dicroticPpg(fs: 30, hrBpm: hr, durationS: 60),
        30,
      );

      expect(detected.harmonicSuppressed, isFalse);
      expect(detected.peakHr, closeTo(hr, 3.0));
      expect(
        (detected.peakHr - detected.spectralHr).abs(),
        lessThanOrEqualTo(hrToleranceBpm(detected.peakHr)),
        reason: 'peak ${detected.peakHr} vs spectral ${detected.spectralHr}',
      );
    });

    test('a whole capture with a lub-dub chest now passes the gate', () {
      // End to end, which is what the device could not do: SCG with a diastolic complex, PPG with
      // a dicrotic notch, at the rates and sample rates the handset actually produced.
      final analysis = analyseCapture(
        scg: lubDubScg(fs: fs, hrBpm: hr, durationS: 60),
        fsScg: fs,
        ppg: dicroticPpg(fs: 30, hrBpm: hr, durationS: 60),
        fsPpg: 30,
      );

      expect(
        analysis.scgHarmonicSuppressed,
        isTrue,
        reason: 'the chest needed it',
      );
      expect(
        (analysis.scgHr - analysis.ppgHr).abs(),
        lessThanOrEqualTo(
          hrToleranceBpm(math.min(analysis.scgHr, analysis.ppgHr)),
        ),
        reason:
            'chest ${analysis.scgHr} vs finger ${analysis.ppgHr} — the cross-sensor check, '
            'which stays fully independent and is the one this must not fake',
      );
    });
  });
}
