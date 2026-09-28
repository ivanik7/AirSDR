// SPDX-License-Identifier: GPL-3.0-or-later
// Complex FFT (replaces FFTW `fftwf_plan_dft_1d(N, in, out, FFTW_FORWARD, FFTW_ESTIMATE)` used by
// SDR++ core/src/signal_path/iq_frontend.cpp:248-267 and noise_reduction/fm_if.h).
//
// Iterative radix-2² ("radix-4") decimation-in-time FFT over interleaved Float32 complex data:
//  1. bit-reversal permutation (precomputed swap table),
//  2. one radix-2 stage if log2(N) is odd,
//  3. radix-4 stages, each fusing two radix-2 stages with per-stage contiguous twiddles.
// Arithmetic is done in double, storage in Float32. Output is unnormalised, like FFTW.
// Plans are cached per (N, direction) via [FftPlan.get].
import 'dart:math' as math;
import 'dart:typed_data';

class FftPlan {
  FftPlan._(this.n, this.forward) {
    if (n < 1 || (n & (n - 1)) != 0) {
      throw ArgumentError('FFT size must be a power of two, got $n');
    }
    int bits = 0;
    while ((1 << bits) < n) {
      bits++;
    }
    _log2n = bits;
    _buildBitrev(bits);
    _buildTwiddles();
  }

  /// FFT length (complex samples).
  final int n;

  /// true: e^(−j…) (FFTW_FORWARD); false: e^(+j…) (FFTW_BACKWARD).
  final bool forward;

  late final int _log2n;

  /// Pairs (i, rev(i)) with i < rev(i), for in-place permutation.
  late final Int32List _swaps;

  /// rev(i) for all i, for out-of-place permutation.
  late final Int32List _rev;

  /// One table per radix-4 stage: for j < L, [w1.re, w1.im, w2.re, w2.im] where
  /// w1 = W_{4L}^j, w2 = W_{4L}^{2j}.
  late final List<Float64List> _stageTw;

  static final Map<int, FftPlan> _cache = {};

  /// Returns a cached plan for size [n].
  static FftPlan get(int n, {bool forward = true}) {
    final key = forward ? n : -n;
    return _cache.putIfAbsent(key, () => FftPlan._(n, forward));
  }

  /// Drops all cached plans.
  static void clearCache() => _cache.clear();

  void _buildBitrev(int bits) {
    _rev = Int32List(n);
    final swaps = <int>[];
    for (int i = 0; i < n; i++) {
      int r = 0, x = i;
      for (int b = 0; b < bits; b++) {
        r = (r << 1) | (x & 1);
        x >>= 1;
      }
      _rev[i] = r;
      if (i < r) {
        swaps
          ..add(i)
          ..add(r);
      }
    }
    _swaps = Int32List.fromList(swaps);
  }

  void _buildTwiddles() {
    final sign = forward ? -1.0 : 1.0;
    _stageTw = [];
    int l = (_log2n & 1) == 1 ? 2 : 1;
    while (l * 4 <= n) {
      final t = Float64List(l * 4);
      final m = 4 * l;
      for (int j = 0; j < l; j++) {
        final a1 = sign * 2.0 * math.pi * j / m;
        final a2 = sign * 2.0 * math.pi * 2 * j / m;
        t[4 * j] = math.cos(a1);
        t[4 * j + 1] = math.sin(a1);
        t[4 * j + 2] = math.cos(a2);
        t[4 * j + 3] = math.sin(a2);
      }
      _stageTw.add(t);
      l *= 4;
    }
  }

  /// Executes the transform. [input] and [output] hold [n] interleaved complex samples
  /// (length ≥ 2n). They may be the same list (in-place).
  @pragma('vm:unsafe:no-bounds-checks')
  void execute(Float32List input, Float32List output) {
    // Permutation
    if (identical(input, output)) {
      final s = _swaps;
      for (int k = 0; k < s.length; k += 2) {
        final a = 2 * s[k], b = 2 * s[k + 1];
        final tr = output[a], ti = output[a + 1];
        output[a] = output[b];
        output[a + 1] = output[b + 1];
        output[b] = tr;
        output[b + 1] = ti;
      }
    } else {
      final r = _rev;
      for (int i = 0; i < n; i++) {
        final d = 2 * r[i];
        output[d] = input[2 * i];
        output[d + 1] = input[2 * i + 1];
      }
    }
    if (n == 1) return;

    final o = output;
    // Radix-2 stage (length 2) when log2(n) is odd
    if ((_log2n & 1) == 1) {
      for (int i = 0; i < 2 * n; i += 4) {
        final ar = o[i], ai = o[i + 1], br = o[i + 2], bi = o[i + 3];
        o[i] = ar + br;
        o[i + 1] = ai + bi;
        o[i + 2] = ar - br;
        o[i + 3] = ai - bi;
      }
    }

    // Radix-4 stages: combine 4 blocks of length L into one of length 4L.
    // With w1 = W_4L^j, w2 = W_4L^2j (W = e^(∓j2π/…)):
    //   a = x0 + w2·x1, b = x0 − w2·x1, c = x2 + w2·x3, d = x2 − w2·x3
    //   y0 = a + w1·c, y2 = a − w1·c, y1 = b + (∓j)·w1·d, y3 = b − (∓j)·w1·d
    final fwd = forward;
    int l = (_log2n & 1) == 1 ? 2 : 1;
    for (final tw in _stageTw) {
      final m = 4 * l;
      for (int s = 0; s < n; s += m) {
        for (int j = 0; j < l; j++) {
          final w1r = tw[4 * j], w1i = tw[4 * j + 1];
          final w2r = tw[4 * j + 2], w2i = tw[4 * j + 3];
          final i0 = 2 * (s + j);
          final i1 = i0 + 2 * l;
          final i2 = i1 + 2 * l;
          final i3 = i2 + 2 * l;
          final x0r = o[i0], x0i = o[i0 + 1];
          final x1r0 = o[i1], x1i0 = o[i1 + 1];
          final x2r = o[i2], x2i = o[i2 + 1];
          final x3r0 = o[i3], x3i0 = o[i3 + 1];
          // w2·x1, w2·x3
          final x1r = x1r0 * w2r - x1i0 * w2i, x1i = x1r0 * w2i + x1i0 * w2r;
          final x3r = x3r0 * w2r - x3i0 * w2i, x3i = x3r0 * w2i + x3i0 * w2r;
          final ar = x0r + x1r, ai = x0i + x1i;
          final br = x0r - x1r, bi = x0i - x1i;
          final cr0 = x2r + x3r, ci0 = x2i + x3i;
          final dr0 = x2r - x3r, di0 = x2i - x3i;
          // w1·c, w1·d
          final cr = cr0 * w1r - ci0 * w1i, ci = cr0 * w1i + ci0 * w1r;
          final dr1 = dr0 * w1r - di0 * w1i, di1 = dr0 * w1i + di0 * w1r;
          // (∓j)·w1·d : forward multiplies by −j: (x + jy)(−j) = y − jx
          final double dr, di;
          if (fwd) {
            dr = di1;
            di = -dr1;
          } else {
            dr = -di1;
            di = dr1;
          }
          o[i0] = ar + cr;
          o[i0 + 1] = ai + ci;
          o[i2] = ar - cr;
          o[i2 + 1] = ai - ci;
          o[i1] = br + dr;
          o[i1 + 1] = bi + di;
          o[i3] = br - dr;
          o[i3 + 1] = bi - di;
        }
      }
      l = m;
    }
  }
}
