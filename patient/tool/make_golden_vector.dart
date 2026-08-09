/// Generates the golden vector: a synthetic paired SCG/PPG capture with a known ground-truth PTT.
///
/// There is no hardware data yet, and the teammate implementing the real signal chain has none
/// either. This is what is available instead: a capture where the answer is known exactly, so an
/// implementation can be checked against something other than "it returned plausible numbers".
///
/// **Synthetic is not real.** Passing this proves an implementation agrees with the contract in
/// `docs/decisions.md` — the fiducial definition, the units, the pairing rule, the drop policy. It
/// proves nothing about behaviour on a human chest. Both statements matter.
///
/// Run from `patient/`:
///
///     dart run tool/make_golden_vector.dart
///
/// Output is deterministic: the same bytes on every machine, every run. The noise source is a
/// hand-rolled LCG rather than `dart:math`'s `Random(seed)`, whose sequence is not guaranteed
/// stable across Dart versions — a fixture that silently changes when the SDK updates is worse
/// than no fixture.
library;

import 'dart:io';
import 'dart:math' as math;

// ---------------------------------------------------------------- parameters ----

/// Capture length. Longer than the 30-beat minimum needs, so the vector is not sitting on the
/// accept/reject boundary — a fixture that flips outcome on a one-beat detection difference tests
/// the threshold rather than the contract.
const double durationSeconds = 35.0;

const double heartRateBpm = 72.0;
const double accelRateHz = 200.0; // the eligibility minimum, deliberately: the harder case
const double cameraFps = 30.0;

/// The ground truth. PTT is modulated by a slow respiratory term so the vector is not degenerate:
/// an implementation that returns a single constant cannot pass it.
const double pttBaseMs = 220.0;
const double pttModulationMs = 20.0;
const double respirationHz = 0.25;

/// First beat, offset from the start so the first PPG foot has clean baseline in front of it.
const double firstBeatSeconds = 0.5;

// SCG: an AO complex modelled as a cosine burst under a Gaussian envelope. The cosine is phased so
// its maximum coincides with the envelope centre, which puts the detectable peak exactly at the
// nominal AO time.
const double scgAmplitude = 0.6; // m/s^2
const double scgCarrierHz = 25.0; // inside the 10-50 Hz AO band
const double scgEnvelopeSigmaSeconds = 0.008;
const double gravity = 9.81;

// PPG: baseline plus a pulse whose upstroke is a straight ramp from the foot.
//
// The ramp is the point. Under the intersecting-tangent rule the tangent at maximum first
// derivative *is* the ramp line, and it meets the pre-foot baseline exactly at the foot — so the
// ground truth is recoverable rather than merely approximated, and the tolerance below measures
// the implementation instead of the fixture's own construction error.
const double roiBaseline = 128.0; // 0-255
const double pulseAmplitude = 40.0;
const double riseFraction = 0.12; // of one beat period
const double decayFraction = 0.18;
const double dicroticCentreFraction = 0.45;
const double dicroticWidthFraction = 0.05;
const double dicroticRelativeAmplitude = 0.3;

/// Noise, small enough not to move a fiducial and large enough that the vector is not a pure
/// analytic signal.
const double accelNoise = 0.01; // m/s^2
const double roiNoise = 0.3; // counts

/// Delivery timing. `clockSeparationNanos` is zero: realtime equals uptime, which is a handset
/// that has not slept since boot. That is the unambiguous shared-basis case, and the contract
/// says a capture proceeds only when the bases are shared.
const int captureStartNanos = 1000000000;
const int accelDeliveryLatencyNanos = 2000000;
const int frameProcessingNanos = 8000000;
const int clockSeparationNanos = 0;

// ---------------------------------------------------------------------- rng ----

/// Numerical Recipes LCG. Deterministic, portable, and adequate for additive noise.
class _Lcg {
  _Lcg(this._state);
  int _state;

  double next() {
    _state = (_state * 1664525 + 1013904223) & 0xFFFFFFFF;
    return _state / 0x100000000;
  }

  /// Two uniforms to one approximately-normal sample, scaled.
  double noise(double scale) => (next() + next() - 1.0) * scale;
}

// ----------------------------------------------------------------- waveforms ----

double _beatPeriod() => 60.0 / heartRateBpm;

/// Ground-truth transit time for the beat at [beatTime], seconds.
double _pttSecondsAt(double beatTime) =>
    (pttBaseMs + pttModulationMs * math.sin(2 * math.pi * respirationHz * beatTime)) / 1000.0;

double _scgAt(double dt) {
  final envelope = math.exp(-(dt * dt) / (2 * scgEnvelopeSigmaSeconds * scgEnvelopeSigmaSeconds));
  return scgAmplitude * envelope * math.cos(2 * math.pi * scgCarrierHz * dt);
}

double _ppgAt(double dt, double period) {
  if (dt < 0 || dt > period) return 0.0;
  final rise = riseFraction * period;
  final systolic = dt <= rise
      ? pulseAmplitude * (dt / rise)
      : pulseAmplitude * math.exp(-(dt - rise) / (decayFraction * period));
  final centre = dicroticCentreFraction * period;
  final width = dicroticWidthFraction * period;
  final dicrotic =
      dicroticRelativeAmplitude *
      pulseAmplitude *
      math.exp(-((dt - centre) * (dt - centre)) / (2 * width * width));
  return systolic + dicrotic;
}

// ---------------------------------------------------------------------- main ----

void main() {
  final period = _beatPeriod();

  // Beat times, and the foot each one pairs with.
  //
  // A beat is only included when its *whole pulse* fits inside the capture: foot plus one period.
  // Otherwise the truth file claims a beat whose PPG upstroke was never recorded, and a correct
  // implementation would report one fewer pair than the ground truth — the fixture would be
  // failing conforming code.
  final beats = <double>[];
  for (double t = firstBeatSeconds; t < durationSeconds; t += period) {
    if (t + _pttSecondsAt(t) + period > durationSeconds) break;
    beats.add(t);
  }

  final feet = [for (final t in beats) t + _pttSecondsAt(t)];

  // ----- accelerometer -----
  final accelRng = _Lcg(20260809);
  final accel = StringBuffer(
    'timestamp_nanos,x_ms2,y_ms2,z_ms2,realtime_at_delivery_nanos,uptime_at_delivery_nanos\n',
  );
  final accelSamples = (durationSeconds * accelRateHz).round();
  for (int i = 0; i < accelSamples; i++) {
    final t = i / accelRateHz;
    double z = gravity;
    for (final beat in beats) {
      final dt = t - beat;
      if (dt.abs() < 6 * scgEnvelopeSigmaSeconds) z += _scgAt(dt);
    }
    final ts = captureStartNanos + (t * 1e9).round();
    final uptime = ts + accelDeliveryLatencyNanos;
    accel.writeln(
      '$ts,${accelRng.noise(accelNoise).toStringAsFixed(6)},'
      '${accelRng.noise(accelNoise).toStringAsFixed(6)},'
      '${z.toStringAsFixed(6)},'
      '${uptime + clockSeparationNanos},$uptime',
    );
  }

  // ----- frames -----
  final roiRng = _Lcg(20260810);
  final frames = StringBuffer(
    'frame_number,timestamp_nanos,roi_mean,processing_nanos,'
    'realtime_at_delivery_nanos,uptime_at_delivery_nanos\n',
  );
  final frameCount = (durationSeconds * cameraFps).round();
  for (int i = 0; i < frameCount; i++) {
    final t = i / cameraFps;
    double roi = roiBaseline;
    for (final foot in feet) {
      roi += _ppgAt(t - foot, period);
    }
    roi += roiRng.noise(roiNoise);
    final ts = captureStartNanos + (t * 1e9).round();
    final uptime = ts + frameProcessingNanos;
    frames.writeln(
      '$i,$ts,${roi.toStringAsFixed(4)},$frameProcessingNanos,'
      '${uptime + clockSeparationNanos},$uptime',
    );
  }

  // ----- ground truth -----
  final truth = StringBuffer('beat_index,ao_timestamp_nanos,foot_timestamp_nanos,ptt_ms\n');
  for (int k = 0; k < beats.length; k++) {
    final ao = captureStartNanos + (beats[k] * 1e9).round();
    final foot = captureStartNanos + (feet[k] * 1e9).round();
    truth.writeln('$k,$ao,$foot,${((feet[k] - beats[k]) * 1000).toStringAsFixed(4)}');
  }

  final dir = Directory('test/fixtures');
  dir.createSync(recursive: true);
  File('${dir.path}/golden_capture_accel.csv').writeAsStringSync(accel.toString());
  File('${dir.path}/golden_capture_frames.csv').writeAsStringSync(frames.toString());
  File('${dir.path}/golden_capture_truth.csv').writeAsStringSync(truth.toString());

  final ptts = [for (int k = 0; k < beats.length; k++) (feet[k] - beats[k]) * 1000];
  ptts.sort();
  stdout.writeln('beats:        ${beats.length}');
  stdout.writeln('accel samples: $accelSamples at ${accelRateHz}Hz');
  stdout.writeln('frames:        $frameCount at ${cameraFps}fps');
  stdout.writeln(
    'ptt ms:        min ${ptts.first.toStringAsFixed(2)} '
    'max ${ptts.last.toStringAsFixed(2)} '
    'mean ${(ptts.reduce((a, b) => a + b) / ptts.length).toStringAsFixed(2)}',
  );
}
