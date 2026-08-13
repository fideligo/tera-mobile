/// The numpy operations `tera_ptt.py` leans on, with numpy's exact semantics.
///
/// Every function here has a named counterpart in the reference. Where numpy has a convention that
/// is easy to get subtly wrong — `convolve(mode='same')` offsets, `gradient` edge handling,
/// `percentile` interpolation, `std` degrees of freedom — the convention is reproduced and stated,
/// because a port that is 95% right produces plausible numbers rather than errors.
///
/// This file deliberately mirrors the reference's **scipy-free fallback path**. `tera_ptt.py`
/// ships one for exactly this situation, so the FFT brick-wall band-pass, the FFT Hilbert
/// transform and the simple peak finder are the reference implementation, not an approximation of
/// a Butterworth chain we could not reproduce.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'fft.dart';

double mean(List<double> x) {
  if (x.isEmpty) return double.nan;
  double s = 0;
  for (final v in x) {
    s += v;
  }
  return s / x.length;
}

/// `np.std`. [ddof] 0 is numpy's default; `ptt_summary` asks for 1.
double std(List<double> x, {int ddof = 0}) {
  final n = x.length;
  if (n - ddof <= 0) return double.nan;
  final m = mean(x);
  double acc = 0;
  for (final v in x) {
    acc += (v - m) * (v - m);
  }
  return math.sqrt(acc / (n - ddof));
}

/// `np.median`. Even lengths average the two central values.
double median(List<double> x) {
  if (x.isEmpty) return double.nan;
  final s = List<double>.from(x)..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : 0.5 * (s[n ~/ 2 - 1] + s[n ~/ 2]);
}

/// `np.percentile` with the default linear interpolation.
double percentile(List<double> x, double q) {
  if (x.isEmpty) return double.nan;
  final s = List<double>.from(x)..sort();
  final pos = (q / 100.0) * (s.length - 1);
  final lo = pos.floor();
  final hi = pos.ceil();
  if (lo == hi) return s[lo];
  return s[lo] + (s[hi] - s[lo]) * (pos - lo);
}

/// `np.gradient` for unit spacing: central differences inside, one-sided at both ends.
Float64List gradient(List<double> x) {
  final n = x.length;
  final out = Float64List(n);
  if (n == 0) return out;
  if (n == 1) {
    out[0] = 0;
    return out;
  }
  out[0] = x[1] - x[0];
  out[n - 1] = x[n - 1] - x[n - 2];
  for (int i = 1; i < n - 1; i++) {
    out[i] = (x[i + 1] - x[i - 1]) / 2.0;
  }
  return out;
}

/// `np.convolve(a, v, mode='same')`.
///
/// numpy computes the full convolution of length `n + k - 1` and returns the middle `n` samples,
/// starting at `(k - 1) ~/ 2`. Getting that offset wrong shifts every envelope sample and moves
/// every beat time by a fixed amount — which is precisely the kind of error a constant PTT bias
/// hides.
Float64List convolveSame(List<double> a, List<double> v) {
  final n = a.length;
  final k = v.length;
  if (n == 0 || k == 0) return Float64List(0);
  final full = Float64List(n + k - 1);
  for (int i = 0; i < n; i++) {
    final ai = a[i];
    if (ai == 0) continue;
    for (int j = 0; j < k; j++) {
      full[i + j] += ai * v[j];
    }
  }
  final start = (k - 1) ~/ 2;
  return Float64List.sublistView(full, start, start + n);
}

/// `np.nan_to_num`: NaN becomes 0, infinities become large finite values.
Float64List nanToNum(List<double> x) {
  final out = Float64List(x.length);
  for (int i = 0; i < x.length; i++) {
    final v = x[i];
    if (v.isNaN) {
      out[i] = 0.0;
    } else if (v == double.infinity) {
      out[i] = double.maxFinite;
    } else if (v == double.negativeInfinity) {
      out[i] = -double.maxFinite;
    } else {
      out[i] = v;
    }
  }
  return out;
}

/// `np.unique(np.round(x, decimals))`: round, sort, drop duplicates.
///
/// numpy rounds half to even; this rounds half away from zero. At six decimal places on a time in
/// seconds an exact tie is a measure-zero event, and the difference cannot move a beat by more
/// than a nanosecond.
List<double> uniqueRounded(List<double> x, int decimals) {
  final factor = math.pow(10, decimals).toDouble();
  final rounded = x.map((v) => (v * factor).roundToDouble() / factor).toList()
    ..sort();
  final out = <double>[];
  for (final v in rounded) {
    if (out.isEmpty || out.last != v) out.add(v);
  }
  return out;
}

/// The reference's `_fft_band`: zero every bin outside `[lo, hi]` and transform back.
///
/// A brick wall, not a Butterworth. That is what the reference's scipy-free path does, and
/// matching it is the point.
Float64List fftBand(List<double> x, double fs, double lo, double hi) {
  final n = x.length;
  if (n == 0) return Float64List(0);
  final m = mean(x);
  final centred = List<double>.generate(n, (i) => x[i] - m);
  final (specR, specI) = rfft(centred);
  final freqs = rfftfreq(n, 1.0 / fs);
  for (int i = 0; i < specR.length; i++) {
    if (freqs[i] < lo || freqs[i] > hi) {
      specR[i] = 0;
      specI[i] = 0;
    }
  }
  return irfft(specR, specI, n);
}

/// `_bandpass` on the scipy-free path: NaN-scrubbed, then brick-walled with the reference's
/// `min(hi, 0.49 * fs)` ceiling.
Float64List bandpass(List<double> x, double fs, double lo, double hi) {
  final clean = nanToNum(x);
  return fftBand(clean, fs, lo, math.min(hi, 0.49 * fs));
}

/// Magnitude of the analytic signal — `np.abs(hilbert(x))` with the reference's FFT Hilbert.
Float64List hilbertEnvelope(List<double> x) {
  final n = x.length;
  if (n == 0) return Float64List(0);
  final re = Float64List(n);
  final im = Float64List(n);
  for (int i = 0; i < n; i++) {
    re[i] = x[i];
  }
  fft(re, im);

  // h: 1 at DC (and Nyquist when n is even), 2 across the positive frequencies, 0 elsewhere.
  final h = Float64List(n);
  h[0] = 1;
  if (n.isEven) {
    h[n ~/ 2] = 1;
    for (int i = 1; i < n ~/ 2; i++) {
      h[i] = 2;
    }
  } else {
    for (int i = 1; i < (n + 1) ~/ 2; i++) {
      h[i] = 2;
    }
  }
  for (int i = 0; i < n; i++) {
    re[i] *= h[i];
    im[i] *= h[i];
  }
  fft(re, im, inverse: true);

  final out = Float64List(n);
  for (int i = 0; i < n; i++) {
    out[i] = math.sqrt(re[i] * re[i] + im[i] * im[i]);
  }
  return out;
}

/// `_envelope`: mean-removed band-pass, Hilbert magnitude, then a 50 ms moving average.
Float64List envelope(List<double> x, double fs, double lo, double hi) {
  final m = mean(x);
  final centred = List<double>.generate(x.length, (i) => x[i] - m);
  final filtered = bandpass(centred, fs, lo, hi);
  final env = hilbertEnvelope(filtered);
  final k = math.max((0.05 * fs).toInt(), 1);
  final kernel = List<double>.filled(k, 1.0 / k);
  return convolveSame(env, kernel);
}

/// `_spectral_hr`: the dominant envelope frequency between 0.8 and 3.0 Hz, in bpm.
///
/// This is the second, independent heart-rate estimate the dual-estimator gate compares against
/// the peak-detected one.
double spectralHr(List<double> env, double fs) {
  if (env.isEmpty) return double.nan;
  final m = mean(env);
  final centred = List<double>.generate(env.length, (i) => env[i] - m);
  final (specR, specI) = rfft(centred);
  final freqs = rfftfreq(env.length, 1.0 / fs);

  int count = 0;
  double best = -1;
  double bestFreq = double.nan;
  for (int i = 0; i < specR.length; i++) {
    if (freqs[i] < 0.8 || freqs[i] > 3.0) continue;
    count++;
    final mag = math.sqrt(specR[i] * specR[i] + specI[i] * specI[i]);
    if (mag > best) {
      best = mag;
      bestFreq = freqs[i];
    }
  }
  if (count < 2) return double.nan;
  return 60.0 * bestFreq;
}

/// The reference's scipy-free `find_peaks`.
///
/// Candidates are strict-rising, non-rising-after samples. `prominence` here is the reference's
/// own simplification — an absolute floor at `median(x) + prominence`, not scipy's topographic
/// prominence. Then a greedy pass in descending amplitude enforces the minimum separation.
List<int> findPeaks(List<double> x, {int distance = 1, double? prominence}) {
  final n = x.length;
  if (n < 3) return const [];

  var candidates = <int>[];
  for (int i = 1; i < n - 1; i++) {
    if (x[i] > x[i - 1] && x[i] >= x[i + 1]) candidates.add(i);
  }
  if (prominence != null) {
    final floor = median(x) + prominence;
    candidates = candidates.where((i) => x[i] >= floor).toList();
  }
  if (candidates.isEmpty) return const [];

  final order = List<int>.from(candidates)
    ..sort((a, b) => x[b].compareTo(x[a]));
  final taken = List<bool>.filled(n, false);
  final keep = <int>[];
  for (final i in order) {
    final lo = math.max(0, i - distance);
    final hi = math.min(n, i + distance + 1);
    var blocked = false;
    for (int j = lo; j < hi; j++) {
      if (taken[j]) {
        blocked = true;
        break;
      }
    }
    if (!blocked) {
      keep.add(i);
      taken[i] = true;
    }
  }
  keep.sort();
  return keep;
}
