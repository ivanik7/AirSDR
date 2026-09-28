// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/window/{cosine.h, nuttall.h, blackman.h, blackman_harris.h,
// blackman_nuttall.h, hamming.h, hann.h, rectangular.h} (@8c9f5ee).
import 'dart:math' as math;

import '../math/constants.dart';

/// Window function signature `double window(double n, double N)`.
typedef WindowFunc = double Function(double n, double N);

/// cosine.h:6 — Σ (−1)^k·c_k·cos(2πkn/N).
double cosine(double n, double N, List<double> coefs) {
  assert(coefs.isNotEmpty);
  double win = 0.0;
  double sign = 1.0;
  for (int i = 0; i < coefs.length; i++) {
    win += sign * coefs[i] * math.cos(i.toDouble() * 2.0 * dbMPi * n / N);
    sign = -sign;
  }
  return win;
}

const List<double> _nuttallCoefs = [0.355768, 0.487396, 0.144232, 0.012604];
const List<double> _blackmanCoefs = [0.42, 0.5, 0.08];
const List<double> _blackmanHarrisCoefs = [0.35875, 0.48829, 0.14128, 0.01168];
const List<double> _blackmanNuttallCoefs = [0.3635819, 0.4891775, 0.1365995, 0.0106411];
const List<double> _hammingCoefs = [0.54, 0.46];
const List<double> _hannCoefs = [0.5, 0.5];

/// nuttall.h:5
double nuttall(double n, double N) => cosine(n, N, _nuttallCoefs);

/// blackman.h:5
double blackman(double n, double N) => cosine(n, N, _blackmanCoefs);

/// blackman_harris.h:6
double blackmanHarris(double n, double N) => cosine(n, N, _blackmanHarrisCoefs);

/// blackman_nuttall.h:6
double blackmanNuttall(double n, double N) => cosine(n, N, _blackmanNuttallCoefs);

/// hamming.h:5
double hamming(double n, double N) => cosine(n, N, _hammingCoefs);

/// hann.h:5
double hann(double n, double N) => cosine(n, N, _hannCoefs);

/// rectangular.h:5
double rectangular(double n, double N) => 1.0;
