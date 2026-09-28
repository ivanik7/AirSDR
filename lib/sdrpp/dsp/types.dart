// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/types.h (@8c9f5ee, lines 1-131).
//
// C++ uses `complex_t {float re, im}` and `stereo_t {float l, r}` (8 bytes each, same layout as
// lv_32fc_t). The Dart port never materialises per-sample objects: every buffer is a
// `Float32List`, interleaved `[re0, im0, re1, im1, ...]` for complex and `[l0, r0, l1, r1, ...]`
// for stereo, exactly like the C++ memory layout (so stereo blocks reuse the complex kernels,
// as the C++ `(lv_32fc_t*)` casts do). See docs/02 §1.1.
import 'dart:math' as math;
import 'dart:typed_data';

import 'math/constants.dart';

/// Replaces the C++ template parameter `T` for templated blocks
/// (`float`, `complex_t`, `stereo_t`).
enum SampleType {
  /// `float`: one Float32 per sample.
  real,

  /// `complex_t`: interleaved re/im.
  complex,

  /// `stereo_t`: interleaved l/r (same layout as complex).
  stereo;

  /// Number of Float32 values per sample.
  int get stride => this == real ? 1 : 2;
}

/// Complex buffer view (interleaved re/im). Zero-cost wrapper for type documentation.
extension type const CBuf(Float32List raw) implements Float32List {
  /// Number of complex samples the buffer can hold.
  int get samples => raw.length >> 1;
}

/// Stereo buffer view (interleaved l/r).
extension type const SBuf(Float32List raw) implements Float32List {
  int get samples => raw.length >> 1;
}

/// Real buffer view.
extension type const RBuf(Float32List raw) implements Float32List {
  int get samples => raw.length;
}

/// Allocates a buffer of [count] samples of type [t] (C++ `buffer::alloc<T>`).
Float32List allocSamples(SampleType t, int count) => Float32List(count * t.stride);

/// complex_t::phase() = atan2f(im, re).
@pragma('vm:prefer-inline')
double complexPhase(double re, double im) => math.atan2(im, re);

/// complex_t::fastPhase(): piecewise-linear atan approximation.
double complexFastPhase(double re, double im) {
  final absIm = im.abs();
  double r, angle;
  if (re == 0.0 && im == 0.0) {
    return 0.0;
  }
  if (re >= 0.0) {
    r = (re - absIm) / (re + absIm);
    angle = (flMPi / 4.0) - (flMPi / 4.0) * r;
  } else {
    r = (re + absIm) / (absIm - re);
    angle = (3.0 * (flMPi / 4.0)) - (flMPi / 4.0) * r;
  }
  if (im < 0.0) {
    return -angle;
  }
  return angle;
}

/// complex_t::amplitude() = sqrt(re² + im²).
@pragma('vm:prefer-inline')
double complexAmplitude(double re, double im) => math.sqrt(re * re + im * im);

/// complex_t::fastAmplitude() = max + 0.4·min.
double complexFastAmplitude(double re, double im) {
  final reAbs = re.abs();
  final imAbs = im.abs();
  if (reAbs > imAbs) {
    return reAbs + 0.4 * imAbs;
  }
  return imAbs + 0.4 * reAbs;
}
