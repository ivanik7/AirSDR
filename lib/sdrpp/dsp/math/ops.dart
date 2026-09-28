// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/math/{add.h, subtract.h, multiply.h, conjugate.h, delay.h} and
// core/src/dsp/convert/{complex_to_real.h, complex_to_stereo.h, mono_to_stereo.h,
// l_r_to_stereo.h, real_to_complex.h, stereo_to_mono.h} (@8c9f5ee), plus the remaining VOLK
// element-wise kernels of docs/02 §3.22.
//
// The C++ static `process()` functions become top-level functions. All operate on counts of
// *samples*; complex/stereo buffers are interleaved. In-place is allowed where the VOLK kernel
// allows it (all of these, except interleave where `out` aliases an input of a different
// stride).
import 'dart:math' as math;
import 'dart:typed_data';

import '../processor.dart';

// ---- math/add.h, subtract.h, multiply.h (float) -------------------------------------------

/// `math::Add<float>::process` (volk_32f_x2_add_32f). For complex/stereo pass 2·count.
@pragma('vm:unsafe:no-bounds-checks')
int addF(int count, Float32List a, Float32List b, Float32List out) {
  for (int i = 0; i < count; i++) {
    out[i] = a[i] + b[i];
  }
  return count;
}

/// `math::Subtract<float>::process` (volk_32f_x2_subtract_32f).
@pragma('vm:unsafe:no-bounds-checks')
int subtractF(int count, Float32List a, Float32List b, Float32List out) {
  for (int i = 0; i < count; i++) {
    out[i] = a[i] - b[i];
  }
  return count;
}

/// `math::Multiply<float>::process` (volk_32f_x2_multiply_32f).
@pragma('vm:unsafe:no-bounds-checks')
int multiplyF(int count, Float32List a, Float32List b, Float32List out) {
  for (int i = 0; i < count; i++) {
    out[i] = a[i] * b[i];
  }
  return count;
}

/// `math::Multiply<complex_t>::process` (volk_32fc_x2_multiply_32fc).
@pragma('vm:unsafe:no-bounds-checks')
int multiplyC(int count, Float32List a, Float32List b, Float32List out) {
  for (int i = 0; i < 2 * count; i += 2) {
    final ar = a[i], ai = a[i + 1], br = b[i], bi = b[i + 1];
    out[i] = ar * br - ai * bi;
    out[i + 1] = ar * bi + ai * br;
  }
  return count;
}

/// volk_32f_s32f_multiply_32f: out = a·s over [count] floats.
@pragma('vm:unsafe:no-bounds-checks')
int scaleF(int count, Float32List a, double s, Float32List out) {
  for (int i = 0; i < count; i++) {
    out[i] = a[i] * s;
  }
  return count;
}

/// volk_32fc_32f_multiply_32fc: complex × real (window application).
@pragma('vm:unsafe:no-bounds-checks')
int multiplyCR(int count, Float32List a, Float32List r, Float32List out) {
  for (int i = 0; i < count; i++) {
    final s = r[i];
    out[2 * i] = a[2 * i] * s;
    out[2 * i + 1] = a[2 * i + 1] * s;
  }
  return count;
}

/// math::Conjugate::process (volk_32fc_conjugate_32fc).
@pragma('vm:unsafe:no-bounds-checks')
int conjugate(int count, Float32List input, Float32List out) {
  for (int i = 0; i < 2 * count; i += 2) {
    out[i] = input[i];
    out[i + 1] = -input[i + 1];
  }
  return count;
}

/// volk_32fc_magnitude_32f: out[i] = |in[i]|.
@pragma('vm:unsafe:no-bounds-checks')
int magnitude(int count, Float32List input, Float32List out) {
  for (int i = 0; i < count; i++) {
    final re = input[2 * i], im = input[2 * i + 1];
    out[i] = math.sqrt(re * re + im * im);
  }
  return count;
}

/// volk_32f_accumulator_s32f: Σ in[i].
@pragma('vm:unsafe:no-bounds-checks')
double accumulate(int count, Float32List input) {
  double s = 0;
  for (int i = 0; i < count; i++) {
    s += input[i];
  }
  return s;
}

/// volk_32f_index_max_32u: index of the maximum.
int indexMax(int count, Float32List input) {
  int idx = 0;
  double m = input[0];
  for (int i = 1; i < count; i++) {
    if (input[i] > m) {
      m = input[i];
      idx = i;
    }
  }
  return idx;
}

// ---- convert/* ----------------------------------------------------------------------------

/// convert::ComplexToReal::process (volk_32fc_deinterleave_real_32f). In-place allowed.
@pragma('vm:unsafe:no-bounds-checks')
int complexToReal(int count, Float32List input, Float32List out) {
  for (int i = 0; i < count; i++) {
    out[i] = input[2 * i];
  }
  return count;
}

/// convert::ComplexToStereo (memcpy I→L, Q→R).
int complexToStereo(int count, Float32List input, Float32List out) {
  if (!identical(input, out)) out.setRange(0, 2 * count, input);
  return count;
}

/// convert::MonoToStereo::process (volk_32f_x2_interleave_32fc(out, in, in)).
/// In-place allowed (iterates backwards).
@pragma('vm:unsafe:no-bounds-checks')
int monoToStereo(int count, Float32List input, Float32List out) {
  for (int i = count - 1; i >= 0; i--) {
    final v = input[i];
    out[2 * i] = v;
    out[2 * i + 1] = v;
  }
  return count;
}

/// convert::LRToStereo::process (volk_32f_x2_interleave_32fc(out, l, r)).
/// [out] must not alias [l] or [r].
@pragma('vm:unsafe:no-bounds-checks')
int lrToStereo(int count, Float32List l, Float32List r, Float32List out) {
  for (int i = 0; i < count; i++) {
    out[2 * i] = l[i];
    out[2 * i + 1] = r[i];
  }
  return count;
}

/// convert::RealToComplex::process (interleave with a zero buffer). In-place allowed.
@pragma('vm:unsafe:no-bounds-checks')
int realToComplex(int count, Float32List input, Float32List out) {
  for (int i = count - 1; i >= 0; i--) {
    out[2 * i] = input[i];
    out[2 * i + 1] = 0.0;
  }
  return count;
}

/// convert::StereoToMono::process: (l + r)/2. In-place allowed.
@pragma('vm:unsafe:no-bounds-checks')
int stereoToMono(int count, Float32List input, Float32List out) {
  for (int i = 0; i < count; i++) {
    out[i] = (input[2 * i] + input[2 * i + 1]) / 2.0;
  }
  return count;
}

// ---- math/delay.h -------------------------------------------------------------------------

/// `math::Delay<T>`: output delayed by `delay` samples (delay.h:6-81).
class Delay extends ProcessorTT {
  Delay(this.type, int delay) {
    _delay = delay;
    _buffer = Float32List((delay + 1024) * type.stride);
  }

  @override
  final SampleType type;
  late int _delay;
  late Float32List _buffer;

  int get delay => _delay;

  void setDelay(int delay) {
    _delay = delay;
    _buffer = growBuffer(_buffer, (_delay + 1024) * type.stride, 0);
    reset();
  }

  @override
  void reset() {
    _buffer.fillRange(0, _delay * type.stride, 0.0);
  }

  @override
  int process(int count, Float32List input, Float32List output) {
    final st = type.stride;
    _buffer = growBuffer(_buffer, (_delay + count) * st, _delay * st);
    // Copy data into delay buffer
    _buffer.setRange(_delay * st, (_delay + count) * st, input);
    // Copy data out of the delay buffer
    output.setRange(0, count * st, _buffer);
    // Move end of the delay buffer to the front
    _buffer.setRange(0, _delay * st, _buffer, count * st);
    return count;
  }
}
