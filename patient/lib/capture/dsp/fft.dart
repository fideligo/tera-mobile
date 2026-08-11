/// Discrete Fourier transforms, matching `numpy.fft` for arbitrary lengths.
///
/// The signal chain runs on the handset, so every transform the Python reference performs has to
/// exist here. `tera_ptt.py` uses `np.fft.rfft`, `np.fft.irfft` and a full complex `np.fft.fft`
/// (inside its Hilbert transform), all at whatever length the capture happens to be.
///
/// **Arbitrary length is the hard requirement, not a nicety.** A 30 s capture at 200 Hz is 6000
/// samples. Zero-padding to 8192 would change every frequency bin and therefore every filter edge
/// and every spectral heart rate, so the port would no longer compute what the reference computes.
/// Radix-2 alone cannot do 6000; Bluestein's chirp-z algorithm turns any length into a power-of-two
/// convolution, which can.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// In-place radix-2 Cooley-Tukey. [re] and [im] must have a power-of-two length.
void _fftRadix2(Float64List re, Float64List im, {required bool inverse}) {
  final n = re.length;
  if (n <= 1) return;

  // Bit-reversal permutation.
  for (int i = 1, j = 0; i < n; i++) {
    int bit = n >> 1;
    for (; (j & bit) != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      final tr = re[i];
      re[i] = re[j];
      re[j] = tr;
      final ti = im[i];
      im[i] = im[j];
      im[j] = ti;
    }
  }

  final sign = inverse ? 1.0 : -1.0;
  for (int len = 2; len <= n; len <<= 1) {
    final ang = sign * 2 * math.pi / len;
    final wr = math.cos(ang);
    final wi = math.sin(ang);
    for (int i = 0; i < n; i += len) {
      double curR = 1.0;
      double curI = 0.0;
      for (int k = 0; k < len ~/ 2; k++) {
        final uR = re[i + k];
        final uI = im[i + k];
        final vR = re[i + k + len ~/ 2] * curR - im[i + k + len ~/ 2] * curI;
        final vI = re[i + k + len ~/ 2] * curI + im[i + k + len ~/ 2] * curR;
        re[i + k] = uR + vR;
        im[i + k] = uI + vI;
        re[i + k + len ~/ 2] = uR - vR;
        im[i + k + len ~/ 2] = uI - vI;
        final nextR = curR * wr - curI * wi;
        curI = curR * wi + curI * wr;
        curR = nextR;
      }
    }
  }
}

bool _isPowerOfTwo(int n) => n > 0 && (n & (n - 1)) == 0;

/// Complex DFT of any length, in place. Matches `np.fft.fft` / `np.fft.ifft`.
///
/// `inverse: true` includes numpy's 1/n scaling.
void fft(Float64List re, Float64List im, {bool inverse = false}) {
  final n = re.length;
  if (n == 0) return;

  if (_isPowerOfTwo(n)) {
    _fftRadix2(re, im, inverse: inverse);
  } else {
    _bluestein(re, im, inverse: inverse);
  }

  if (inverse) {
    for (int i = 0; i < n; i++) {
      re[i] /= n;
      im[i] /= n;
    }
  }
}

/// Chirp-z transform. Any length, by way of a power-of-two convolution.
void _bluestein(Float64List re, Float64List im, {required bool inverse}) {
  final n = re.length;
  int m = 1;
  while (m < 2 * n + 1) {
    m <<= 1;
  }

  final sign = inverse ? 1.0 : -1.0;

  // Chirp w[k] = exp(sign * i * pi * k^2 / n), with k^2 reduced mod 2n so the
  // angle stays small enough to keep its precision at 6000 samples.
  final chirpR = Float64List(n);
  final chirpI = Float64List(n);
  for (int k = 0; k < n; k++) {
    final j = (k * k) % (2 * n);
    final ang = sign * math.pi * j / n;
    chirpR[k] = math.cos(ang);
    chirpI[k] = math.sin(ang);
  }

  final aR = Float64List(m);
  final aI = Float64List(m);
  for (int k = 0; k < n; k++) {
    aR[k] = re[k] * chirpR[k] - im[k] * chirpI[k];
    aI[k] = re[k] * chirpI[k] + im[k] * chirpR[k];
  }

  final bR = Float64List(m);
  final bI = Float64List(m);
  bR[0] = chirpR[0];
  bI[0] = -chirpI[0];
  for (int k = 1; k < n; k++) {
    bR[k] = bR[m - k] = chirpR[k];
    bI[k] = bI[m - k] = -chirpI[k];
  }

  _fftRadix2(aR, aI, inverse: false);
  _fftRadix2(bR, bI, inverse: false);
  for (int k = 0; k < m; k++) {
    final pr = aR[k] * bR[k] - aI[k] * bI[k];
    final pi = aR[k] * bI[k] + aI[k] * bR[k];
    aR[k] = pr;
    aI[k] = pi;
  }
  _fftRadix2(aR, aI, inverse: true);
  for (int k = 0; k < m; k++) {
    aR[k] /= m;
    aI[k] /= m;
  }

  for (int k = 0; k < n; k++) {
    re[k] = aR[k] * chirpR[k] - aI[k] * chirpI[k];
    im[k] = aR[k] * chirpI[k] + aI[k] * chirpR[k];
  }
}

/// Real-input DFT. Returns `n ~/ 2 + 1` complex bins, like `np.fft.rfft`.
(Float64List, Float64List) rfft(List<double> x) {
  final n = x.length;
  final re = Float64List(n);
  final im = Float64List(n);
  for (int i = 0; i < n; i++) {
    re[i] = x[i];
  }
  fft(re, im);
  final half = n ~/ 2 + 1;
  return (
    Float64List.sublistView(re, 0, half),
    Float64List.sublistView(im, 0, half),
  );
}

/// Inverse of [rfft] onto a real signal of length [n]. Matches `np.fft.irfft(X, n)`.
Float64List irfft(Float64List specR, Float64List specI, int n) {
  final re = Float64List(n);
  final im = Float64List(n);
  final half = n ~/ 2 + 1;
  for (int k = 0; k < half && k < specR.length; k++) {
    re[k] = specR[k];
    im[k] = specI[k];
  }
  // Hermitian mirror; the Nyquist bin of an even-length transform has no partner.
  for (int k = 1; k < n - half + 1; k++) {
    re[n - k] = specR[k];
    im[n - k] = -specI[k];
  }
  fft(re, im, inverse: true);
  return re;
}

/// Bin centre frequencies for [rfft]. Matches `np.fft.rfftfreq(n, d)`.
Float64List rfftfreq(int n, double d) {
  final half = n ~/ 2 + 1;
  final out = Float64List(half);
  for (int i = 0; i < half; i++) {
    out[i] = i / (d * n);
  }
  return out;
}
