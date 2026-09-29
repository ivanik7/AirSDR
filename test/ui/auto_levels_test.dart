// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/ui/auto_levels.dart';

const _low = 99e6, _high = 101e6;
const _w = 512;
const _rowPeriod = Duration(milliseconds: 50); // 20 rows/s

/// Exponential (chi-square 2 dof) power noise around [floorDb], in dB —
/// the same statistics as a real |FFT|² bin of white noise.
Float32List noiseRow(math.Random rng, double floorDb, {int width = _w}) {
  final out = Float32List(width);
  for (var i = 0; i < width; i++) {
    final u = rng.nextDouble();
    final p = -math.log(1 - u * 0.999);
    out[i] = floorDb + 10 * math.log(p) / math.ln10;
  }
  return out;
}

Float32List withCarrier(Float32List row, double db, {int at = 100, int width = 3}) {
  for (var i = at; i < at + width; i++) {
    row[i] = db;
  }
  return row;
}

/// Feeds rows every [_rowPeriod] from [start] for [duration].
Duration feed(
  AutoLevels a,
  Duration start,
  Duration duration,
  Float32List Function() row, {
  double low = _low,
  double high = _high,
}) {
  var t = start;
  final end = start + duration;
  while (t < end) {
    a.addRow(row(), low, high, t);
    t += _rowPeriod;
  }
  return t;
}

void main() {
  // Median of the per-row 20th percentile of exponential noise in dB:
  // 10·log10(−ln 0.8) ≈ −6.5 dB below the mean power.
  final p20 = 10 * math.log(-math.log(0.8)) / math.ln10;

  group('AutoLevels', () {
    test('pure noise: min ≈ floor − margin, max = floor + min range', () {
      final rng = math.Random(1);
      final a = AutoLevels();
      feed(a, Duration.zero, const Duration(seconds: 10), () => noiseRow(rng, -90));
      expect(a.floor, closeTo(-90 + p20, 1.0));
      expect(a.targetMin, closeTo(a.floor! - AutoLevelTuning.marginBelowDb, 1e-9));
      expect(a.targetMax, closeTo(a.floor! + AutoLevelTuning.minRangeDb, 1e-9));
      expect(a.min, closeTo(a.targetMin!, 0.5));
      expect(a.max, closeTo(a.targetMax!, 0.5));
      // Noise peaks (≈ +8 dB over the mean at 512 bins) stay below the top.
      expect(a.peak! + AutoLevelTuning.marginAboveDb, lessThan(a.targetMax!));
    });

    test('strong carrier appears → max rises quickly to peak + margin', () {
      final rng = math.Random(2);
      final a = AutoLevels();
      var t = feed(a, Duration.zero, const Duration(seconds: 5), () => noiseRow(rng, -90));
      final quietMax = a.max!;
      t = feed(a, t, const Duration(seconds: 1), () => withCarrier(noiseRow(rng, -90), -30));
      expect(a.peak, -30);
      expect(a.targetMax, closeTo(-30 + AutoLevelTuning.marginAboveDb, 1e-9));
      expect(a.max, greaterThan(quietMax + 20));
      expect(a.max, closeTo(-30 + AutoLevelTuning.marginAboveDb, 1.0));
      // The floor does not move because of the carrier.
      expect(a.floor, closeTo(-90 + p20, 1.0));
    });

    test('signal gone → max stays within the window, then returns down', () {
      final rng = math.Random(3);
      final a = AutoLevels();
      var t = feed(a, Duration.zero, const Duration(seconds: 3),
          () => withCarrier(noiseRow(rng, -90), -30));
      final high = a.max!;
      // Still inside the window: the peak is remembered.
      t = feed(a, t, AutoLevelTuning.window - const Duration(seconds: 5),
          () => noiseRow(rng, -90));
      expect(a.peak, -30);
      expect(a.max, closeTo(high, 0.5));
      // The carrier left the window: back to floor + min range.
      t = feed(a, t, const Duration(seconds: 15), () => noiseRow(rng, -90));
      expect(a.peak, lessThan(-70));
      expect(a.max, closeTo(a.floor! + AutoLevelTuning.minRangeDb, 0.5));
    });

    test('narrowing is smoothed: max glides down, not in one frame', () {
      final rng = math.Random(4);
      final a = AutoLevels();
      var t = feed(a, Duration.zero, const Duration(seconds: 1),
          () => withCarrier(noiseRow(rng, -90), -30));
      // Up to the moment the carrier bucket leaves the window.
      Float32List quiet() => noiseRow(rng, -90);
      while (a.peak == -30) {
        a.addRow(quiet(), _low, _high, t);
        t += _rowPeriod;
      }
      final target = a.targetMax!;
      expect(target, lessThan(-50));
      // One frame after the target dropped by > 20 dB: still near the top.
      expect(a.max, greaterThan(-30));
      // A couple of slow time constants later: close to the new target.
      feed(a, t, AutoLevelTuning.slowTau * 5, quiet);
      expect(a.max, closeTo(target, 1.0));
    });

    test('another frequency span restarts the window', () {
      final rng = math.Random(5);
      final a = AutoLevels();
      var t = feed(a, Duration.zero, const Duration(seconds: 3),
          () => withCarrier(noiseRow(rng, -90), -30));
      expect(a.peak, -30);
      // Retuned: a quiet band, rows cover another span.
      t = feed(a, t, const Duration(seconds: 3), () => noiseRow(rng, -100),
          low: 144e6, high: 146e6);
      expect(a.peak, lessThan(-80));
      expect(a.floor, closeTo(-100 + p20, 1.0));
      // Relearned quickly (not the 30 s window, not the slow glide).
      expect(a.max, closeTo(a.floor! + AutoLevelTuning.minRangeDb, 0.5));
      expect(a.min, closeTo(a.floor! - AutoLevelTuning.marginBelowDb, 0.5));
    });

    test('reset() (gain / source change) forgets the window', () {
      final rng = math.Random(6);
      final a = AutoLevels();
      var t = feed(a, Duration.zero, const Duration(seconds: 3),
          () => withCarrier(noiseRow(rng, -90), -30));
      a.reset();
      expect(a.peak, isNull);
      t = feed(a, t, const Duration(seconds: 3), () => noiseRow(rng, -70));
      expect(a.peak, lessThan(-55));
      expect(a.floor, closeTo(-70 + p20, 1.0));
    });

    test('DC spike, zero bins and band-edge roll-off do not break the floor', () {
      final rng = math.Random(7);
      final clean = AutoLevels();
      final dirty = AutoLevels();
      var t = Duration.zero;
      for (var i = 0; i < 100; i++) {
        final row = noiseRow(rng, -90);
        clean.addRow(Float32List.fromList(row), _low, _high, t);
        // DC spike in the middle.
        for (var j = _w ~/ 2 - 2; j < _w ~/ 2 + 2; j++) {
          row[j] = -20;
        }
        // Floored "zero" bins (iq_frontend clamps at −200 dB) and NaN.
        for (var j = 0; j < 20; j++) {
          row[j] = -200;
        }
        row[30] = double.nan;
        row[31] = double.negativeInfinity;
        // Roll-off at the upper band edge: 5 % of bins 30 dB down.
        for (var j = _w - 26; j < _w; j++) {
          row[j] = -120 + rng.nextDouble();
        }
        dirty.addRow(row, _low, _high, t);
        t += _rowPeriod;
      }
      expect(dirty.floor, closeTo(clean.floor!, 1.5));
      expect(dirty.min, closeTo(clean.min!, 1.5));
      // Never a bare minimum over the bins.
      expect(dirty.floor, greaterThan(-100));
    });

    test('rows without valid bins are ignored', () {
      final a = AutoLevels();
      final zeros = Float32List(_w)..fillRange(0, _w, -200);
      expect(a.addRow(zeros, _low, _high, Duration.zero), isFalse);
      expect(a.min, isNull);
      expect(a.max, isNull);
    });

    test('window is kept as buckets, not rows', () {
      final rng = math.Random(8);
      final a = AutoLevels();
      // 2 minutes at 20 rows/s = 2400 rows; the window must still reflect
      // only the last 30 s (checked via a carrier 60 s ago).
      var t = feed(a, Duration.zero, const Duration(seconds: 1),
          () => withCarrier(noiseRow(rng, -90), -20));
      t = feed(a, t, const Duration(seconds: 119), () => noiseRow(rng, -90));
      expect(a.peak, lessThan(-70));
      expect(a.debugBucketCount,
          lessThanOrEqualTo(AutoLevelTuning.window.inSeconds ~/ AutoLevelTuning.bucket.inSeconds));
    });

    test('a pause longer than the window (app in background) expires old data', () {
      final rng = math.Random(9);
      final a = AutoLevels();
      var t = feed(a, Duration.zero, const Duration(seconds: 2),
          () => withCarrier(noiseRow(rng, -90), -20));
      t += const Duration(minutes: 5);
      feed(a, t, const Duration(seconds: 1), () => noiseRow(rng, -90));
      expect(a.peak, lessThan(-70));
    });
  });
}
