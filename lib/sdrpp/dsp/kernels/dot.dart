// SPDX-License-Identifier: GPL-3.0-or-later
// Dart replacements for the VOLK dot-product kernels used by SDR++ (docs/02 §3.22, §5.3):
//   volk_32f_x2_dot_prod_32f      -> dotRR   (real data  x real taps)
//   volk_32fc_32f_dot_prod_32fc   -> dotCR   (complex/stereo data x real taps)
//   volk_32fc_x2_dot_prod_32fc    -> dotCC   (complex data x complex taps)
// Each kernel has a scalar variant (double accumulators, bit-reproducible) and a Float32x4
// variant. The SIMD variants need taps pre-arranged per data alignment (see [TapsRR], [TapsCR],
// [TapsCC]) and the data buffer viewed as a [Float32x4List].
//
// Semantics are those of the C++ FIR: out = Σ_k buf[off+k] · taps[k] (correlation).
import 'dart:typed_data';

/// Global kernel switch. `true` (default) = Float32x4 kernels; `false` = scalar kernels.
/// Scalar kernels produce bit-identical results regardless of how the input is chunked;
/// SIMD kernels may differ in the last float ULPs because the summation order depends on the
/// buffer alignment of each output.
class DspKernels {
  static bool useSimd = true;
}

/// Number of padding floats every SIMD-read history buffer must have after its last valid
/// sample (the shifted tap tables read up to 3 floats past the end, rounded up to 16 bytes).
const int simdPadFloats = 8;

/// Rounds [n] floats up to a multiple of 4 plus [simdPadFloats].
int simdAllocLen(int n) => ((n + simdPadFloats + 3) >> 2) << 2;

// ---------------------------------------------------------------------------------------------
// Scalar kernels
// ---------------------------------------------------------------------------------------------

/// Σ a[aOff+k]·taps[k], k < n (volk_32f_x2_dot_prod_32f).
@pragma('vm:prefer-inline')
@pragma('vm:unsafe:no-bounds-checks')
double dotRR(Float32List a, int aOff, Float32List taps, int n) {
  double s0 = 0, s1 = 0, s2 = 0, s3 = 0;
  int k = 0;
  for (; k + 3 < n; k += 4) {
    s0 += a[aOff + k] * taps[k];
    s1 += a[aOff + k + 1] * taps[k + 1];
    s2 += a[aOff + k + 2] * taps[k + 2];
    s3 += a[aOff + k + 3] * taps[k + 3];
  }
  for (; k < n; k++) {
    s0 += a[aOff + k] * taps[k];
  }
  return (s0 + s1) + (s2 + s3);
}

/// Complex (interleaved) x real taps starting at complex index [cOff] (volk_32fc_32f_dot_prod_32fc).
/// Writes the complex result to out[2*oIdx], out[2*oIdx+1].
@pragma('vm:prefer-inline')
@pragma('vm:unsafe:no-bounds-checks')
void dotCR(Float32List buf, int cOff, Float32List taps, int n, Float32List out, int oIdx) {
  double re0 = 0, im0 = 0, re1 = 0, im1 = 0;
  int b = cOff * 2;
  int k = 0;
  for (; k + 1 < n; k += 2) {
    final t0 = taps[k];
    final t1 = taps[k + 1];
    re0 += buf[b] * t0;
    im0 += buf[b + 1] * t0;
    re1 += buf[b + 2] * t1;
    im1 += buf[b + 3] * t1;
    b += 4;
  }
  if (k < n) {
    final t = taps[k];
    re0 += buf[b] * t;
    im0 += buf[b + 1] * t;
  }
  out[2 * oIdx] = re0 + re1;
  out[2 * oIdx + 1] = im0 + im1;
}

/// Complex x complex taps (both interleaved) starting at complex index [cOff]
/// (volk_32fc_x2_dot_prod_32fc). [n] is the number of complex taps.
@pragma('vm:prefer-inline')
@pragma('vm:unsafe:no-bounds-checks')
void dotCC(Float32List buf, int cOff, Float32List taps, int n, Float32List out, int oIdx) {
  double re = 0, im = 0;
  int b = cOff * 2;
  int t = 0;
  for (int k = 0; k < n; k++) {
    final ar = buf[b], ai = buf[b + 1];
    final tr = taps[t], ti = taps[t + 1];
    re += ar * tr - ai * ti;
    im += ar * ti + ai * tr;
    b += 2;
    t += 2;
  }
  out[2 * oIdx] = re;
  out[2 * oIdx + 1] = im;
}

// ---------------------------------------------------------------------------------------------
// SIMD tap tables
// ---------------------------------------------------------------------------------------------

/// Real taps arranged for [dotRRSimd]: 4 tables, table `s` holds the taps shifted right by `s`
/// floats (zero padded), so a data offset `off` is served by table `off & 3` starting at
/// vector `off >> 2`.
class TapsRR {
  TapsRR(Float32List taps) : size = taps.length {
    tables = List<Float32x4List>.generate(4, (s) {
      final n4 = (size + s + 3) >> 2;
      final l = Float32List(n4 * 4);
      for (int i = 0; i < size; i++) {
        l[i + s] = taps[i];
      }
      return Float32x4List.view(l.buffer);
    }, growable: false);
  }

  final int size;
  late final List<Float32x4List> tables;
}

/// Real taps arranged for complex data ([dotCRSimd]): each tap duplicated `[t0,t0,t1,t1]`.
/// `a` serves even complex offsets, `b` (shifted by one complex, zero padded) odd offsets.
class TapsCR {
  TapsCR(Float32List taps) : size = taps.length {
    a = _dup(taps, 0);
    b = _dup(taps, 1);
  }

  final int size;
  late final Float32x4List a;
  late final Float32x4List b;

  static Float32x4List _dup(Float32List taps, int shift) {
    final nC = taps.length + shift;
    final n4 = (nC + 1) >> 1;
    final l = Float32List(n4 * 4);
    for (int i = 0; i < taps.length; i++) {
      final j = i + shift;
      l[j * 2] = taps[i];
      l[j * 2 + 1] = taps[i];
    }
    return Float32x4List.view(l.buffer);
  }
}

/// Complex taps (interleaved) arranged for [dotCCSimd]: real parts duplicated (`r*`) and
/// imaginary parts duplicated (`i*`), each in an even (`A`) and odd (`B`) alignment.
class TapsCC {
  TapsCC(Float32List taps) : size = taps.length >> 1 {
    rA = _dup(taps, 0, 0);
    rB = _dup(taps, 0, 1);
    iA = _dup(taps, 1, 0);
    iB = _dup(taps, 1, 1);
  }

  final int size;
  late final Float32x4List rA, rB, iA, iB;

  Float32x4List _dup(Float32List taps, int part, int shift) {
    final nC = size + shift;
    final n4 = (nC + 1) >> 1;
    final l = Float32List(n4 * 4);
    for (int i = 0; i < size; i++) {
      final j = i + shift;
      final v = taps[2 * i + part];
      l[j * 2] = v;
      l[j * 2 + 1] = v;
    }
    return Float32x4List.view(l.buffer);
  }
}

// ---------------------------------------------------------------------------------------------
// SIMD kernels
// ---------------------------------------------------------------------------------------------

/// SIMD version of [dotRR]. [a4] is the Float32x4 view of the data (same backing store,
/// offset 0), [off] a float index.
@pragma('vm:prefer-inline')
@pragma('vm:unsafe:no-bounds-checks')
double dotRRSimd(Float32x4List a4, int off, TapsRR taps) {
  final s = off & 3;
  final t = taps.tables[s];
  final base = off >> 2;
  final n = t.length;
  var acc = Float32x4.zero();
  var acc2 = Float32x4.zero();
  int k = 0;
  for (; k + 1 < n; k += 2) {
    acc += a4[base + k] * t[k];
    acc2 += a4[base + k + 1] * t[k + 1];
  }
  if (k < n) {
    acc += a4[base + k] * t[k];
  }
  acc += acc2;
  return (acc.x + acc.y) + (acc.z + acc.w);
}

/// SIMD version of [dotCR]. [buf4] is the Float32x4 view of the interleaved complex data,
/// [cOff] a complex index.
@pragma('vm:prefer-inline')
@pragma('vm:unsafe:no-bounds-checks')
void dotCRSimd(Float32x4List buf4, int cOff, TapsCR taps, Float32List out, int oIdx) {
  final Float32x4List t;
  final int b;
  if ((cOff & 1) == 0) {
    t = taps.a;
    b = cOff >> 1;
  } else {
    t = taps.b;
    b = (cOff - 1) >> 1;
  }
  var acc = Float32x4.zero();
  var acc2 = Float32x4.zero();
  final n = t.length;
  int k = 0;
  for (; k + 1 < n; k += 2) {
    acc += buf4[b + k] * t[k];
    acc2 += buf4[b + k + 1] * t[k + 1];
  }
  if (k < n) {
    acc += buf4[b + k] * t[k];
  }
  acc += acc2;
  out[2 * oIdx] = acc.x + acc.z;
  out[2 * oIdx + 1] = acc.y + acc.w;
}

/// SIMD version of [dotCC].
@pragma('vm:prefer-inline')
@pragma('vm:unsafe:no-bounds-checks')
void dotCCSimd(Float32x4List buf4, int cOff, TapsCC taps, Float32List out, int oIdx) {
  final Float32x4List tr, ti;
  final int b;
  if ((cOff & 1) == 0) {
    tr = taps.rA;
    ti = taps.iA;
    b = cOff >> 1;
  } else {
    tr = taps.rB;
    ti = taps.iB;
    b = (cOff - 1) >> 1;
  }
  // accR lanes = (re·tr, im·tr, ...), accI lanes = (re·ti, im·ti, ...)
  var accR = Float32x4.zero();
  var accI = Float32x4.zero();
  final n = tr.length;
  for (int k = 0; k < n; k++) {
    final v = buf4[b + k];
    accR += v * tr[k];
    accI += v * ti[k];
  }
  // re = Σ re·tr − im·ti ; im = Σ im·tr + re·ti
  out[2 * oIdx] = (accR.x + accR.z) - (accI.y + accI.w);
  out[2 * oIdx + 1] = (accR.y + accR.w) + (accI.x + accI.z);
}
