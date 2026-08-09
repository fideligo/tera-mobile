/// Checks the golden vector, not a signal chain.
///
/// The fixture is only worth committing if its documented ground truth can actually be recovered
/// from the samples. A fixture whose answer is unreachable would fail conforming implementations
/// and send someone hunting a bug in their code that lives in ours.
///
/// So this test does two things:
///
///   1. **Integrity.** Sample counts, rates, contiguous frame numbers, monotonic timestamps, and
///      the shared clock basis the contract requires before a capture may proceed.
///   2. **Recoverability.** Recovers each fiducial and compares against `golden_capture_truth.csv`,
///      establishing the tolerance documented in `test/fixtures/README.md`.
///
/// **The recovery code below is not a reference implementation of the signal chain.** It searches a
/// narrow window around each known answer, which a real detector obviously cannot do. It answers
/// "is the truth present in this data", nothing more. The real chain is the teammate's, and the
/// contract it must meet is in `docs/decisions.md`.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:tera_patient/signal/signal_pipeline.dart';

const String fixtureDir = 'test/fixtures';

/// Expected shape, mirroring `tool/make_golden_vector.dart`.
const int expectedBeats = 41;
const double expectedAccelRateHz = 200.0;
const double expectedCameraFps = 30.0;
const double expectedDurationSeconds = 35.0;

/// Established by this test. See `test/fixtures/README.md`.
const double aoToleranceMs = 3.0;
const double footToleranceMs = 3.0;
const double pttToleranceMs = 5.0;

class _Accel {
  const _Accel(this.timeSeconds, this.magnitude);
  final double timeSeconds;
  final double magnitude;
}

class _Frame {
  const _Frame(this.number, this.timeSeconds, this.roiMean);
  final int number;
  final double timeSeconds;
  final double roiMean;
}

class _Truth {
  const _Truth(this.aoSeconds, this.footSeconds, this.pttMs);
  final double aoSeconds;
  final double footSeconds;
  final double pttMs;
}

List<List<String>> _rows(String name) {
  final lines = File('$fixtureDir/$name').readAsLinesSync()
    ..removeWhere((l) => l.trim().isEmpty);
  return [for (final l in lines.skip(1)) l.split(',')];
}

double _originNanos = 0;

List<_Accel> _readAccel() {
  final rows = _rows('golden_capture_accel.csv');
  _originNanos = double.parse(rows.first[0]);
  return [
    for (final r in rows)
      _Accel(
        (double.parse(r[0]) - _originNanos) / 1e9,
        math.sqrt(
          math.pow(double.parse(r[1]), 2) +
              math.pow(double.parse(r[2]), 2) +
              math.pow(double.parse(r[3]), 2),
        ),
      ),
  ];
}

List<_Frame> _readFrames() => [
  for (final r in _rows('golden_capture_frames.csv'))
    _Frame(int.parse(r[0]), (double.parse(r[1]) - _originNanos) / 1e9, double.parse(r[2])),
];

List<_Truth> _readTruth() => [
  for (final r in _rows('golden_capture_truth.csv'))
    _Truth(
      (double.parse(r[1]) - _originNanos) / 1e9,
      (double.parse(r[2]) - _originNanos) / 1e9,
      double.parse(r[3]),
    ),
];

/// AO peak: the largest departure from the gravity baseline near [aboutSeconds].
double _recoverAo(List<_Accel> accel, double aboutSeconds, {double window = 0.05}) {
  final baseline = accel.map((a) => a.magnitude).reduce((a, b) => a + b) / accel.length;
  double bestTime = aboutSeconds;
  double best = -1;
  for (final s in accel) {
    if ((s.timeSeconds - aboutSeconds).abs() > window) continue;
    final deviation = (s.magnitude - baseline).abs();
    if (deviation > best) {
      best = deviation;
      bestTime = s.timeSeconds;
    }
  }
  return bestTime;
}

/// PPG foot by the intersecting-tangent rule the contract specifies: the tangent at maximum first
/// derivative of the upstroke, met with the horizontal through the preceding diastolic minimum.
double _recoverFoot(List<_Frame> frames, double aboutSeconds, {double window = 0.15}) {
  final near = [
    for (final f in frames)
      if ((f.timeSeconds - aboutSeconds).abs() <= window) f,
  ];
  if (near.length < 4) return double.nan;

  int steepest = 0;
  double bestSlope = double.negativeInfinity;
  for (int i = 0; i < near.length - 1; i++) {
    final dt = near[i + 1].timeSeconds - near[i].timeSeconds;
    if (dt <= 0) continue;
    final slope = (near[i + 1].roiMean - near[i].roiMean) / dt;
    if (slope > bestSlope) {
      bestSlope = slope;
      steepest = i;
    }
  }
  if (bestSlope <= 0) return double.nan;

  // Diastolic minimum ahead of the upstroke.
  double baseline = near[steepest].roiMean;
  for (int i = 0; i <= steepest; i++) {
    baseline = math.min(baseline, near[i].roiMean);
  }

  final anchor = near[steepest];
  return anchor.timeSeconds - (anchor.roiMean - baseline) / bestSlope;
}

void main() {
  late List<_Accel> accel;
  late List<_Frame> frames;
  late List<_Truth> truth;

  setUpAll(() {
    accel = _readAccel();
    frames = _readFrames();
    truth = _readTruth();
  });

  group('fixture integrity', () {
    test('sample counts match the declared rates and duration', () {
      expect(accel.length, (expectedDurationSeconds * expectedAccelRateHz).round());
      expect(frames.length, (expectedDurationSeconds * expectedCameraFps).round());
      expect(truth.length, expectedBeats);
    });

    test('achieved rates are the declared rates', () {
      final accelSpan = accel.last.timeSeconds - accel.first.timeSeconds;
      final frameSpan = frames.last.timeSeconds - frames.first.timeSeconds;
      expect((accel.length - 1) / accelSpan, closeTo(expectedAccelRateHz, 0.5));
      expect((frames.length - 1) / frameSpan, closeTo(expectedCameraFps, 0.5));
    });

    test('frame numbers are contiguous, so the vector has no dropped frames', () {
      for (int i = 0; i < frames.length; i++) {
        expect(frames[i].number, i);
      }
    });

    test('timestamps are strictly increasing in both streams', () {
      for (int i = 1; i < accel.length; i++) {
        expect(accel[i].timeSeconds, greaterThan(accel[i - 1].timeSeconds));
      }
      for (int i = 1; i < frames.length; i++) {
        expect(frames[i].timeSeconds, greaterThan(frames[i - 1].timeSeconds));
      }
    });

    test('both streams share a clock basis, which the contract requires to proceed', () {
      // realtime == uptime on every row: a handset that has not slept, the unambiguous shared case.
      for (final name in ['golden_capture_accel.csv', 'golden_capture_frames.csv']) {
        final rows = _rows(name);
        final realtime = name.startsWith('golden_capture_accel') ? 4 : 4;
        final uptime = realtime + 1;
        for (final r in rows) {
          expect(r[realtime], r[uptime], reason: '$name: realtime and uptime must agree');
        }
      }
    });

    test('every ground-truth interval is inside the plausible range', () {
      for (final t in truth) {
        expect(t.pttMs, inInclusiveRange(pttMinMs, pttMaxMs));
      }
    });

    test('the vector clears the usable-beat minimum with margin', () {
      expect(truth.length, greaterThan(minUsableBeats));
    });

    test('the interval count stays inside the invariant 2 array bound', () {
      expect(truth.length, lessThanOrEqualTo(maxPttArrayLength));
    });

    test('the truth is not degenerate — a constant would not pass', () {
      final values = [for (final t in truth) t.pttMs];
      expect(values.reduce(math.max) - values.reduce(math.min), greaterThan(20.0));
    });
  });

  group('the ground truth is recoverable from the samples', () {
    test('AO peaks are recoverable within tolerance', () {
      for (final t in truth) {
        final recovered = _recoverAo(accel, t.aoSeconds);
        expect(
          (recovered - t.aoSeconds).abs() * 1000,
          lessThanOrEqualTo(aoToleranceMs),
          reason: 'AO at ${t.aoSeconds}s recovered at ${recovered}s',
        );
      }
    });

    test('PPG feet are recoverable by intersecting tangent within tolerance', () {
      for (final t in truth) {
        final recovered = _recoverFoot(frames, t.footSeconds);
        expect(recovered.isNaN, isFalse, reason: 'no foot recovered near ${t.footSeconds}s');
        expect(
          (recovered - t.footSeconds).abs() * 1000,
          lessThanOrEqualTo(footToleranceMs),
          reason: 'foot at ${t.footSeconds}s recovered at ${recovered}s',
        );
      }
    });

    test('recovered intervals match the ground-truth PTT within tolerance', () {
      for (final t in truth) {
        final ptt = (_recoverFoot(frames, t.footSeconds) - _recoverAo(accel, t.aoSeconds)) * 1000;
        expect(
          (ptt - t.pttMs).abs(),
          lessThanOrEqualTo(pttToleranceMs),
          reason: 'expected ${t.pttMs}ms, recovered ${ptt}ms',
        );
      }
    });
  });
}
