// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/taps/{tap.h, estimate_tap_count.h, windowed_sinc.h, low_pass.h,
// high_pass.h, band_pass.h, from_array.h, raised_cosine.h, root_raised_cosine.h} (@8c9f5ee).
//
// `tap<T>` becomes [Taps]: a Float32List (real taps) or an interleaved Float32List (complex
// taps) plus `size` (number of taps). Tap design is done in double like the C++ and stored
// as float, matching the C++ `(float)` store.
import 'dart:math' as math;
import 'dart:typed_data';

import '../math/math.dart';
import '../window/windows.dart';

/// tap.h:6 — `tap<T> { T* taps; unsigned size; }`.
class Taps {
  Taps.real(this.taps)
      : size = taps.length,
        isComplex = false;

  Taps.complex(this.taps)
      : size = taps.length >> 1,
        isComplex = true;

  /// Real: `size` floats. Complex: `2·size` interleaved floats.
  final Float32List taps;

  /// Number of taps.
  final int size;

  final bool isComplex;
}

/// estimate_tap_count.h:4 — `(int)(3.8·sr/tw)`.
int estimateTapCount(double transWidth, double samplerate) => (3.8 * samplerate / transWidth).truncate();

/// windowed_sinc.h:8 (T = float).
Taps windowedSinc(int count, double omega, WindowFunc window, [double norm = 1.0]) {
  final taps = Float32List(count);
  final half = count / 2.0;
  final corr = norm * omega / dbMPi;
  for (int i = 0; i < count; i++) {
    final t = i - half + 0.5;
    taps[i] = sinc(t * omega) * window(t - half, count.toDouble()) * corr;
  }
  return Taps.real(taps);
}

/// Complex window function (returns (re, im) through [out]).
typedef ComplexWindowFunc = void Function(double n, double N, Float64List out);

/// windowed_sinc.h:8 (T = complex_t): `cplx = {(float)sinc(t·ω), 0}; tap = cplx·window·corr`.
Taps windowedSincComplex(int count, double omega, ComplexWindowFunc window, [double norm = 1.0]) {
  final taps = Float32List(count * 2);
  final half = count / 2.0;
  final corr = norm * omega / dbMPi;
  final w = Float64List(2);
  for (int i = 0; i < count; i++) {
    final t = i - half + 0.5;
    // (float) cast of the sinc as in C++
    final s = _f32(sinc(t * omega));
    window(t - half, count.toDouble(), w);
    // complex_t * complex_t (float math), then * double corr (cast to float)
    final wr = _f32(w[0]), wi = _f32(w[1]);
    final pr = _f32(s * wr), pi = _f32(s * wi);
    final c = _f32(corr);
    taps[2 * i] = pr * c;
    taps[2 * i + 1] = pi * c;
  }
  return Taps.complex(taps);
}

final Float32List _f32buf = Float32List(1);

/// Rounds a double to float32 precision.
double _f32(double x) {
  _f32buf[0] = x;
  return _f32buf[0];
}

/// windowed_sinc.h:34 — cutoff/samplerate overload.
Taps windowedSincHz(int count, double cutoff, double samplerate, WindowFunc window, [double norm = 1.0]) =>
    windowedSinc(count, hzToRads(cutoff, samplerate), window, norm);

/// low_pass.h:7
Taps lowPass(double cutoff, double transWidth, double sampleRate, [bool oddTapCount = false]) {
  int count = estimateTapCount(transWidth, sampleRate);
  if (oddTapCount && (count % 2) == 0) {
    count++;
  }
  return windowedSincHz(count, cutoff, sampleRate, nuttall);
}

/// high_pass.h:7
Taps highPass(double cutoff, double transWidth, double sampleRate, [bool oddTapCount = false]) {
  int count = estimateTapCount(transWidth, sampleRate);
  if (oddTapCount && (count % 2) == 0) {
    count++;
  }
  return windowedSincHz(count, (sampleRate / 2.0) - cutoff, sampleRate, (n, N) {
    // (int)round(n) % 2 — C++ `%` keeps the sign of the dividend, so -3 % 2 == -1 (truthy).
    return nuttall(n, N) * ((_cRound(n) % 2 != 0) ? -1.0 : 1.0);
  });
}

/// C `round()` (half away from zero; Dart `round()` is the same). The caller tests `% 2 != 0`:
/// Dart `%` is non-negative while C's keeps the sign, but "odd" has the same truthiness.
int _cRound(double x) => x.round();

/// band_pass.h:10 (T = float): window `2·cosf(ω₀·n)·nuttall`.
Taps bandPass(double bandStart, double bandStop, double transWidth, double sampleRate, [bool oddTapCount = false]) {
  assert(bandStop > bandStart);
  final offsetOmega = _f32(hzToRads((bandStart + bandStop) / 2.0, sampleRate));
  int count = estimateTapCount(transWidth, sampleRate);
  if (oddTapCount && (count % 2) == 0) {
    count++;
  }
  return windowedSincHz(count, (bandStop - bandStart) / 2.0, sampleRate, (n, N) {
    // 2.0f * cosf(offsetOmega * (float)n) * nuttall(n, N): float·float product, then × double
    final c = _f32(math.cos(_f32(offsetOmega * _f32(n))));
    return _f32(2.0 * c) * nuttall(n, N);
  });
}

/// band_pass.h:10 (T = complex_t): window `phasor(−ω₀·n)·nuttall` (taps pre-flipped because
/// the FIR computes a correlation).
Taps bandPassComplex(double bandStart, double bandStop, double transWidth, double sampleRate,
    [bool oddTapCount = false]) {
  assert(bandStop > bandStart);
  final offsetOmega = _f32(hzToRads((bandStart + bandStop) / 2.0, sampleRate));
  int count = estimateTapCount(transWidth, sampleRate);
  if (oddTapCount && (count % 2) == 0) {
    count++;
  }
  return windowedSincComplex(count, hzToRads((bandStop - bandStart) / 2.0, sampleRate), (n, N, out) {
    // math::phasor(-offsetOmega * (float)n) * window::nuttall(n, N)
    final x = _f32(-offsetOmega * _f32(n));
    final w = nuttall(n, N);
    out[0] = _f32(math.cos(x)) * _f32(w);
    out[1] = _f32(math.sin(x)) * _f32(w);
  });
}

/// from_array.h:7
Taps fromArray(List<double> taps) => Taps.real(Float32List.fromList(taps));

/// raised_cosine.h:9 — ported verbatim (including its unusual formula); not used by the radio
/// path.
Taps raisedCosine(int count, double beta, double ts) {
  final taps = Float32List(count);
  final half = count / 2.0;
  final limit = ts / (2.0 * beta);
  for (int i = 0; i < count; i++) {
    final t = i - half + 0.5;
    if (t == limit || t == -limit) {
      taps[i] = sinc(1.0 / (2.0 * beta)) * dbMPi / (4.0 * ts);
    } else {
      taps[i] = sinc(t / ts) * dbMPi / (4.0 * ts);
    }
  }
  return Taps.real(taps);
}

/// raised_cosine.h:30
Taps raisedCosineSr(int count, double beta, double symbolrate, double samplerate) =>
    raisedCosine(count, beta, samplerate / symbolrate);
