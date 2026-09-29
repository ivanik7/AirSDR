// SPDX-License-Identifier: GPL-3.0-or-later
// Generates `noiseReferenceTable` of lib/sdrpp/dsp/noise_reduction/auto_squelch.dart and prints
// the NFM quieting (dB) versus in-channel CNR, for choosing AutoSquelchTuning.noiseOpenDb.
//
//   dart run tool/auto_squelch_calibrate.dart
//
// Model of an empty channel: complex white Gaussian noise at the NFM IF rate (50 kHz) through
// the RxVFO channel filter (lowPass(bw/2, bw/2·0.1, sr), rx_vfo.h) → AutoSquelch noise detector.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sdr_flutter/sdrpp/dsp/dsp.dart';

Float32List channel(double bw, double sr, int n, double noiseRms, double carrier, int seed) {
  final rnd = math.Random(seed);
  double g() {
    double u1 = rnd.nextDouble();
    if (u1 < 1e-12) u1 = 1e-12;
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * rnd.nextDouble());
  }

  final x = Float32List(2 * n);
  final s = noiseRms / math.sqrt2;
  for (var i = 0; i < n; i++) {
    x[2 * i] = s * g() + carrier;
    x[2 * i + 1] = s * g();
  }
  if (bw < sr) {
    FIR(SampleType.complex, lowPass(bw / 2, bw / 2 * 0.1, sr)).process(n, x, x);
  }
  return x;
}

/// Mean |HPF(discriminator)| after the settling time, measured with the detector itself.
double meanNoise(double bw, double sr, {double cnrDb = double.negativeInfinity}) {
  const n = 200000;
  // Carrier amplitude for the requested CNR inside the channel bandwidth (noise rms 1 over
  // the full rate → in-channel noise power bw/sr).
  final carrier = cnrDb.isFinite ? math.sqrt(bw / sr * math.pow(10, cnrDb / 10)) : 0.0;
  final x = channel(bw, sr, n, 1.0, carrier, 7);
  final sq = AutoSquelch(detector: AutoSquelchDetector.noise, sampleRate: sr, bandwidth: bw);
  // Reuse the detector's filters: feed blocks, read metric; convert back to the level.
  const block = 500;
  var sum = 0.0;
  var cnt = 0;
  for (var i = 0; i + block <= n; i += block) {
    sq.analyze(block, Float32List.sublistView(x, 2 * i, 2 * (i + block)));
    if (i > 20000) {
      sum += sq.noiseLevel;
      cnt++;
    }
  }
  return sum / cnt;
}

void main() {
  const sr = 50000.0;
  final ratios = <double>[0.02, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.6, 0.8, 1.0];
  // ignore: avoid_print
  print('const List<(double, double)> noiseReferenceTable = <(double, double)>[');
  for (final r in ratios) {
    // ignore: avoid_print
    print('  ($r, ${meanNoise(r * sr, sr).toStringAsPrecision(5)}),');
  }
  // ignore: avoid_print
  print('];');
  for (final bw in <double>[1000, 2500, 5000, 12500, 25000, 50000]) {
    // Spread of the metric on an empty channel (false-open margin).
    final x = channel(bw, sr, 500000, 1.0, 0, 11);
    final sq = AutoSquelch(detector: AutoSquelchDetector.noise, sampleRate: sr, bandwidth: bw);
    var lo = 1e9, hi = -1e9;
    for (var i = 0; i + 500 <= 500000; i += 500) {
      sq.analyze(500, Float32List.sublistView(x, 2 * i, 2 * (i + 500)));
      if (i > 20000) {
        lo = math.min(lo, sq.metricDb!);
        hi = math.max(hi, sq.metricDb!);
      }
    }
    // ignore: avoid_print
    print('bw $bw empty channel: quieting min ${lo.toStringAsFixed(2)} max ${hi.toStringAsFixed(2)} dB, '
        'transitions ${sq.transitions}');
  }
  for (final bw in <double>[2500, 5000, 12500, 25000]) {
    for (var cnr = -6.0; cnr <= 20; cnr += 2) {
      final q = 20 * math.log(noiseReference(bw, sr) / meanNoise(bw, sr, cnrDb: cnr)) / math.ln10;
      // ignore: avoid_print
      print('bw $bw CNR $cnr dB → quieting ${q.toStringAsFixed(2)} dB');
    }
  }
}
