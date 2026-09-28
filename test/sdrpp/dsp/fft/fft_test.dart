import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/sdrpp/dsp/fft/fft.dart';

/// Naive O(N²) DFT (double) for reference.
Float64List dft(Float32List x, int n, bool forward) {
  final out = Float64List(2 * n);
  final s = forward ? -1.0 : 1.0;
  for (int k = 0; k < n; k++) {
    double re = 0, im = 0;
    for (int t = 0; t < n; t++) {
      final a = s * 2 * math.pi * ((k * t) % n) / n;
      final c = math.cos(a), si = math.sin(a);
      re += x[2 * t] * c - x[2 * t + 1] * si;
      im += x[2 * t] * si + x[2 * t + 1] * c;
    }
    out[2 * k] = re;
    out[2 * k + 1] = im;
  }
  return out;
}

void main() {
  final rnd = math.Random(11);

  for (final n in [1, 2, 4, 8, 16, 32, 64, 128, 256, 512]) {
    test('FFT n=$n matches naive DFT (fwd + inv)', () {
      final x = Float32List.fromList(List.generate(2 * n, (_) => rnd.nextDouble() * 2 - 1));
      for (final fwd in [true, false]) {
        final ref = dft(x, n, fwd);
        final out = Float32List(2 * n);
        FftPlan.get(n, forward: fwd).execute(x, out);
        double err = 0;
        for (int i = 0; i < 2 * n; i++) {
          err = math.max(err, (out[i] - ref[i]).abs());
        }
        expect(err, lessThan(1e-4 * math.max(1, math.sqrt(n))), reason: 'fwd=$fwd');
      }
    });
  }

  for (final n in [1024, 2048, 4096, 8192, 16384, 32768, 65536]) {
    test('FFT n=$n: tone bin, roundtrip, in-place == out-of-place', () {
      final plan = FftPlan.get(n);
      expect(identical(plan, FftPlan.get(n)), isTrue, reason: 'plan cache');
      // Tone at bin k plus noise
      final k = n ~/ 7;
      final x = Float32List(2 * n);
      for (int i = 0; i < n; i++) {
        final ph = 2 * math.pi * k * i / n;
        x[2 * i] = math.cos(ph) + 0.01 * (rnd.nextDouble() - 0.5);
        x[2 * i + 1] = math.sin(ph) + 0.01 * (rnd.nextDouble() - 0.5);
      }
      final out = Float32List(2 * n);
      plan.execute(x, out);
      int maxBin = 0;
      double maxMag = 0;
      for (int i = 0; i < n; i++) {
        final m = out[2 * i] * out[2 * i] + out[2 * i + 1] * out[2 * i + 1];
        if (m > maxMag) {
          maxMag = m;
          maxBin = i;
        }
      }
      expect(maxBin, k);
      expect(math.sqrt(maxMag) / n, closeTo(1.0, 1e-3));

      // Inverse / n == original
      final back = Float32List(2 * n);
      FftPlan.get(n, forward: false).execute(out, back);
      double err = 0;
      for (int i = 0; i < 2 * n; i++) {
        err = math.max(err, (back[i] / n - x[i]).abs());
      }
      expect(err, lessThan(1e-4));

      // In place
      final y = Float32List.fromList(x);
      plan.execute(y, y);
      double d = 0;
      for (int i = 0; i < 2 * n; i++) {
        d = math.max(d, (y[i] - out[i]).abs());
      }
      expect(d, 0.0);
    });
  }

  test('non power of two rejected', () {
    expect(() => FftPlan.get(1000), throwsArgumentError);
  });
}
