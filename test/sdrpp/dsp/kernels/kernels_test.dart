import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/sdrpp/dsp/kernels/dot.dart';
import 'package:sdr_flutter/sdrpp/dsp/kernels/rotator.dart';

void main() {
  final rnd = math.Random(7);
  Float32List rand(int n) => Float32List.fromList(List.generate(n, (_) => rnd.nextDouble() * 2 - 1));

  group('dot kernels', () {
    for (final nTaps in [1, 2, 3, 4, 5, 7, 12, 27, 69, 126, 317]) {
      test('SIMD == scalar, taps=$nTaps, all alignments', () {
        final taps = rand(nTaps);
        final ctaps = rand(2 * nTaps);
        final data = Float32List(simdAllocLen(2 * (nTaps + 16)));
        data.setRange(0, 2 * (nTaps + 16), rand(2 * (nTaps + 16)));
        final d4 = Float32x4List.view(data.buffer);
        final tRR = TapsRR(taps), tCR = TapsCR(taps), tCC = TapsCC(ctaps);
        final o1 = Float32List(2), o2 = Float32List(2);
        for (int off = 0; off < 8; off++) {
          // real
          double ref = 0;
          for (int k = 0; k < nTaps; k++) {
            ref += data[off + k] * taps[k];
          }
          expect(dotRR(data, off, taps, nTaps), closeTo(ref, 1e-9));
          expect(dotRRSimd(d4, off, tRR), closeTo(ref, 1e-4));
          // complex x real
          double re = 0, im = 0;
          for (int k = 0; k < nTaps; k++) {
            re += data[2 * (off + k)] * taps[k];
            im += data[2 * (off + k) + 1] * taps[k];
          }
          dotCR(data, off, taps, nTaps, o1, 0);
          dotCRSimd(d4, off, tCR, o2, 0);
          expect(o1[0], closeTo(re, 1e-5));
          expect(o1[1], closeTo(im, 1e-5));
          expect(o2[0], closeTo(re, 1e-4));
          expect(o2[1], closeTo(im, 1e-4));
          // complex x complex
          re = 0;
          im = 0;
          for (int k = 0; k < nTaps; k++) {
            final ar = data[2 * (off + k)], ai = data[2 * (off + k) + 1];
            final br = ctaps[2 * k], bi = ctaps[2 * k + 1];
            re += ar * br - ai * bi;
            im += ar * bi + ai * br;
          }
          dotCC(data, off, ctaps, nTaps, o1, 0);
          dotCCSimd(d4, off, tCC, o2, 0);
          expect(o1[0], closeTo(re, 1e-5));
          expect(o1[1], closeTo(im, 1e-5));
          expect(o2[0], closeTo(re, 1e-4));
          expect(o2[1], closeTo(im, 1e-4));
        }
      });
    }
  });

  group('rotator', () {
    test('matches e^(jωn) and stays unit-magnitude', () {
      const n = 100000;
      const omega = 0.1234;
      final input = Float32List(2 * n);
      for (int i = 0; i < n; i++) {
        input[2 * i] = 1;
      }
      final out = Float32List(2 * n);
      final r = Rotator()..setDelta(omega);
      r.rotate(n, input, out);
      double maxErr = 0;
      for (final i in [0, 1, 511, 512, 513, 50000, n - 1]) {
        final er = (out[2 * i] - math.cos(omega * i)).abs();
        final ei = (out[2 * i + 1] - math.sin(omega * i)).abs();
        maxErr = math.max(maxErr, math.max(er, ei));
      }
      expect(maxErr, lessThan(1e-4));
      final m = math.sqrt(r.phaseRe * r.phaseRe + r.phaseIm * r.phaseIm);
      expect(m, closeTo(1.0, 1e-9));
    });

    test('block-boundary invariance (bit-exact)', () {
      const n = 5000;
      final input = Float32List.fromList(List.generate(2 * n, (_) => rnd.nextDouble() - 0.5));
      final a = Float32List(2 * n), b = Float32List(2 * n);
      final r1 = Rotator()..setDelta(-0.77);
      r1.rotate(n, input, a);
      final r2 = Rotator()..setDelta(-0.77);
      int pos = 0;
      final cr = math.Random(3);
      while (pos < n) {
        final c = math.min(1 + cr.nextInt(700), n - pos);
        r2.rotate(c, input, b, inOff: pos, outOff: pos);
        pos += c;
      }
      expect(b, equals(a));
    });

    test('in place', () {
      final x = Float32List.fromList([1, 0, 0, 1, 1, 1]);
      final r = Rotator()..setDelta(math.pi / 2);
      r.rotate(3, x, x);
      // (1)(1) = 1 ; (j)(j) = -1 ; (1+j)(-1) = -1-j
      expect(x[0], closeTo(1, 1e-6));
      expect(x[1], closeTo(0, 1e-6));
      expect(x[2], closeTo(-1, 1e-6));
      expect(x[3], closeTo(0, 1e-6));
      expect(x[4], closeTo(-1, 1e-6));
      expect(x[5], closeTo(-1, 1e-6));
    });
  });
}
