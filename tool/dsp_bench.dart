// Micro-benchmarks for SDR++ -> Dart porting estimates.
import 'dart:math' as math;
import 'dart:typed_data';

const int blockC = 48000; // complex samples per block (~20 ms at 2.4 MSPS)

// Complex (interleaved) x real taps, decimating FIR, scalar.
@pragma('vm:prefer-inline')
int firDecimScalar(Float32List buf, int count, Float32List taps, int decim, Float32List out) {
  final n = taps.length;
  int o = 0;
  for (int off = 0; off < count; off += decim) {
    double re = 0, im = 0;
    int b = off * 2;
    for (int k = 0; k < n; k++) {
      final t = taps[k];
      re += buf[b] * t;
      im += buf[b + 1] * t;
      b += 2;
    }
    out[o++] = re;
    out[o++] = im;
  }
  return o >> 1;
}

@pragma('vm:unsafe:no-bounds-checks')
int firDecimScalarNoBC(Float32List buf, int count, Float32List taps, int decim, Float32List out) {
  final n = taps.length;
  int o = 0;
  for (int off = 0; off < count; off += decim) {
    double re = 0, im = 0;
    int b = off * 2;
    for (int k = 0; k < n; k++) {
      final t = taps[k];
      re += buf[b] * t;
      im += buf[b + 1] * t;
      b += 2;
    }
    out[o++] = re;
    out[o++] = im;
  }
  return o >> 1;
}

// SIMD: buffer viewed as Float32x4 (2 complex per lane-vector), taps duplicated [t0,t0,t1,t1].
// Two tap sets: tapsA for even complex start offset, tapsB (shifted by one complex, zero padded) for odd.
@pragma('vm:unsafe:no-bounds-checks')
int firDecimSimd(Float32x4List buf4, int count, Float32x4List tapsA, Float32x4List tapsB, int decim, Float32List out) {
  int o = 0;
  for (int off = 0; off < count; off += decim) {
    final Float32x4List t;
    int b;
    if ((off & 1) == 0) {
      t = tapsA;
      b = off >> 1;
    } else {
      t = tapsB;
      b = (off - 1) >> 1;
    }
    var acc = Float32x4.zero();
    var acc2 = Float32x4.zero();
    final n = t.length;
    int k = 0;
    for (; k + 1 < n; k += 2) {
      acc += buf4[b + k] * t[k];
      acc2 += buf4[b + k + 1] * t[k + 1];
    }
    for (; k < n; k++) {
      acc += buf4[b + k] * t[k];
    }
    acc += acc2;
    out[o++] = acc.x + acc.z;
    out[o++] = acc.y + acc.w;
  }
  return o >> 1;
}

Float32x4List dupTaps(Float32List taps, bool shifted) {
  final nC = taps.length + (shifted ? 1 : 0);
  final n4 = (nC + 1) >> 1;
  final l = Float32List(n4 * 4);
  for (int i = 0; i < taps.length; i++) {
    final j = shifted ? i + 1 : i;
    l[j * 2] = taps[i];
    l[j * 2 + 1] = taps[i];
  }
  return Float32x4List.view(l.buffer);
}

// Rotator (volk_32fc_s32fc_x2_rotator2_32fc equivalent)
@pragma('vm:unsafe:no-bounds-checks')
void rotate(Float32List inp, Float32List out, int count, Float64List state, double dRe, double dIm) {
  double pRe = state[0], pIm = state[1];
  for (int i = 0; i < count; i++) {
    final a = inp[2 * i], b = inp[2 * i + 1];
    out[2 * i] = a * pRe - b * pIm;
    out[2 * i + 1] = a * pIm + b * pRe;
    final nr = pRe * dRe - pIm * dIm;
    pIm = pRe * dIm + pIm * dRe;
    pRe = nr;
    if ((i & 511) == 0) {
      final m = math.sqrt(pRe * pRe + pIm * pIm);
      pRe /= m;
      pIm /= m;
    }
  }
  state[0] = pRe;
  state[1] = pIm;
}

// Quadrature demod with atan2 (as SDR++ Quadrature uses atan2f)
@pragma('vm:unsafe:no-bounds-checks')
double quad(Float32List inp, Float32List out, int count, double phase, double invDev) {
  for (int i = 0; i < count; i++) {
    final c = math.atan2(inp[2 * i + 1], inp[2 * i]);
    var d = c - phase;
    if (d > math.pi) {
      d -= 2 * math.pi;
    } else if (d <= -math.pi) {
      d += 2 * math.pi;
    }
    out[i] = d * invDev;
    phase = c;
  }
  return phase;
}

// Radix-2 iterative complex FFT (interleaved), precomputed twiddles + bitrev
class Fft {
  final int n;
  late final Int32List rev;
  late final Float32List tw; // cos,sin interleaved n/2
  Fft(this.n) {
    rev = Int32List(n);
    int bits = 0;
    while ((1 << bits) < n) bits++;
    for (int i = 0; i < n; i++) {
      int r = 0, x = i;
      for (int b = 0; b < bits; b++) {
        r = (r << 1) | (x & 1);
        x >>= 1;
      }
      rev[i] = r;
    }
    tw = Float32List(n);
    for (int i = 0; i < n ~/ 2; i++) {
      tw[2 * i] = math.cos(-2 * math.pi * i / n);
      tw[2 * i + 1] = math.sin(-2 * math.pi * i / n);
    }
  }
  @pragma('vm:unsafe:no-bounds-checks')
  void run(Float32List inp, Float32List out) {
    for (int i = 0; i < n; i++) {
      final r = rev[i];
      out[2 * r] = inp[2 * i];
      out[2 * r + 1] = inp[2 * i + 1];
    }
    for (int size = 2; size <= n; size <<= 1) {
      final half = size >> 1;
      final step = n ~/ size;
      for (int start = 0; start < n; start += size) {
        int t = 0;
        for (int j = 0; j < half; j++) {
          final wr = tw[2 * t], wi = tw[2 * t + 1];
          final a = 2 * (start + j), b = 2 * (start + j + half);
          final br = out[b], bi = out[b + 1];
          final xr = br * wr - bi * wi, xi = br * wi + bi * wr;
          final ar = out[a], ai = out[a + 1];
          out[a] = ar + xr;
          out[a + 1] = ai + xi;
          out[b] = ar - xr;
          out[b + 1] = ai - xi;
          t += step;
        }
      }
    }
  }
}

Float32List lowPassTaps(double cutoff, double trans, double sr) {
  final count = (3.8 * sr / trans).floor();
  final omega = 2 * math.pi * cutoff / sr;
  final half = count / 2.0;
  final corr = omega / math.pi;
  final t = Float32List(count);
  const c = [0.355768, 0.487396, 0.144232, 0.012604];
  for (int i = 0; i < count; i++) {
    final x = i - half + 0.5;
    final s = x * omega == 0 ? 1.0 : math.sin(x * omega) / (x * omega);
    final n = x - half;
    double w = 0, sign = 1;
    for (int k = 0; k < 4; k++) {
      w += sign * c[k] * math.cos(k * 2 * math.pi * n / count);
      sign = -sign;
    }
    t[i] = s * w * corr;
  }
  return t;
}

void bench(String name, int macsPerCall, void Function() f, {int minMs = 1500}) {
  for (int i = 0; i < 3; i++) f();
  final sw = Stopwatch()..start();
  int calls = 0;
  while (sw.elapsedMilliseconds < minMs) {
    f();
    calls++;
  }
  final s = sw.elapsedMicroseconds / 1e6;
  final perCall = s / calls * 1e3;
  final rate = macsPerCall * calls / s / 1e6;
  print('${name.padRight(46)} ${perCall.toStringAsFixed(3)} ms/call  ${rate.toStringAsFixed(1)} M units/s');
}

void main() {
  final rnd = math.Random(1);
  final pad = 1024;
  final bufL = Float32List((blockC + pad) * 2);
  for (int i = 0; i < bufL.length; i++) bufL[i] = rnd.nextDouble() * 2 - 1;
  final buf4 = Float32x4List.view(bufL.buffer);
  final out = Float32List(blockC * 2 + 16);

  for (final cfg in [
    [27, 4],
    [69, 2],
    [126, 1],
    [257, 64],
    [456, 1],
  ]) {
    final n = cfg[0], d = cfg[1];
    final taps = Float32List(n);
    for (int i = 0; i < n; i++) taps[i] = rnd.nextDouble();
    final ta = dupTaps(taps, false), tb = dupTaps(taps, true);
    final outs = (blockC + d - 1) ~/ d;
    bench('FIR c*r scalar     taps=$n decim=$d (M cMAC/s)', outs * n, () => firDecimScalar(bufL, blockC, taps, d, out));
    bench('FIR c*r scalar noBC taps=$n decim=$d (M cMAC/s)', outs * n, () => firDecimScalarNoBC(bufL, blockC, taps, d, out));
    bench('FIR c*r SIMD x4    taps=$n decim=$d (M cMAC/s)', outs * n, () => firDecimSimd(buf4, blockC, ta, tb, d, out));
  }
  // correctness check SIMD vs scalar
  {
    final taps = lowPassTaps(75000, 7500, 250000);
    final ta = dupTaps(taps, false), tb = dupTaps(taps, true);
    final o1 = Float32List(blockC * 2), o2 = Float32List(blockC * 2);
    firDecimScalar(bufL, blockC, taps, 1, o1);
    firDecimSimd(buf4, blockC, ta, tb, 1, o2);
    double md = 0;
    for (int i = 0; i < o1.length; i++) md = math.max(md, (o1[i] - o2[i]).abs());
    print('SIMD vs scalar max abs diff: $md (taps=${taps.length})');
  }
  final st = Float64List.fromList([1, 0]);
  bench('rotator (M samples/s)', blockC, () => rotate(bufL, out, blockC, st, math.cos(0.1), math.sin(0.1)));
  double ph = 0;
  bench('quadrature atan2 (M samples/s)', blockC, () => ph = quad(bufL, out, blockC, ph, 1.0));
  for (final n in [8192, 65536]) {
    final f = Fft(n);
    final inp = Float32List(2 * n), o = Float32List(2 * n);
    for (int i = 0; i < inp.length; i++) inp[i] = rnd.nextDouble();
    bench('FFT radix2 n=$n (FFTs/s -> "M units" = FFT/s/1e6)', 1, () => f.run(inp, o));
  }
}
