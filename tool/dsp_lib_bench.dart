// SPDX-License-Identifier: GPL-3.0-or-later
// Throughput bench for the lib/sdrpp/dsp port (FIR, FFT, RxVFO, full WFM/NFM chains).
// Build: dart compile exe tool/dsp_lib_bench.dart -o build/dsp_lib_bench && build/dsp_lib_bench
// ignore_for_file: avoid_print
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sdr_flutter/sdrpp/dsp/dsp.dart';

const int block = 16384; // complex samples per call (≈ SDR++ IQ block size order)

double bench(String name, double seconds, int samplesPerIter, void Function() body, {String unit = 'MS/s'}) {
  for (int i = 0; i < 3; i++) {
    body();
  }
  final sw = Stopwatch()..start();
  int iters = 0;
  while (sw.elapsedMicroseconds < seconds * 1e6) {
    body();
    iters++;
  }
  final rate = iters * samplesPerIter / (sw.elapsedMicroseconds / 1e6) / 1e6;
  print('${name.padRight(52)} ${rate.toStringAsFixed(2).padLeft(9)} $unit');
  return rate;
}

void main() {
  final rnd = math.Random(1);
  final cin = Float32List(2 * block);
  for (int i = 0; i < cin.length; i++) {
    cin[i] = rnd.nextDouble() * 2 - 1;
  }
  final rin = Float32List.sublistView(cin, 0, block);
  final cout = Float32List(2 * block + 64);
  final sout = Float32List(2 * block + 64);

  for (final simd in [true, false]) {
    DspKernels.useSimd = simd;
    final tag = simd ? 'simd' : 'scalar';
    print('--- kernels: $tag ---');
    for (final n in [64, 126, 237, 317]) {
      final fcr = FIR(SampleType.complex, lowPass(75000, 250000 * 3.8 / n, 250000));
      bench('FIR<complex,float> ${fcr.taps.size} taps', 1.0, block, () => fcr.process(block, cin, cout));
    }
    final frr = FIR(SampleType.real, lowPass(15000, 4000, 250000));
    bench('FIR<float,float> ${frr.taps.size} taps', 1.0, block, () => frr.process(block, rin, cout));
    final fcc = FIR(SampleType.complex, bandPassComplex(18750, 19250, 3000, 250000, true));
    bench('FIR<complex,complex> ${fcc.taps.size} taps (pilot)', 1.0, block, () => fcc.process(block, cin, cout));
    final pd = PowerDecimator(SampleType.complex, 8);
    bench('PowerDecimator x8 (input rate)', 1.0, block, () => pd.process(block, cin, cout));
    final rr = RationalResampler(SampleType.complex, 2400000, 250000);
    final rrOut = Float32List(2 * rr.maxOutput(block));
    bench('RationalResampler 2.4M->250k (input rate)', 1.0, block, () => rr.process(block, cin, rrOut));
    final vfo = RxVFO(2400000, 250000, 150000, 100000);
    final vOut = Float32List(2 * vfo.maxOutput(block));
    bench('RxVFO 2.4M->250k bw150k (input rate)', 1.0, block, () => vfo.process(block, cin, vOut));
    final vfoN = RxVFO(2400000, 50000, 12500, 100000);
    bench('RxVFO 2.4M->50k bw12.5k (input rate)', 1.0, block, () => vfoN.process(block, cin, vOut));
    final bfm = BroadcastFM(75000, 250000, stereo: true);
    bench('BroadcastFM stereo @250k', 1.0, block, () => bfm.process(block, cin, sout));
    final nfm = FM(SampleType.stereo, 50000, 12500, true);
    bench('FM<stereo> NFM @50k', 1.0, block, () => nfm.process(block, cin, sout));
    final am = AM(SampleType.stereo, AGCMode.carrier, 10000, 50 / 15000, 5 / 15000, 100 / 15000, 15000);
    bench('AM<stereo> @15k', 1.0, block, () => am.process(block, cin, sout));
    final ssb = SSB(SampleType.stereo, SSBMode.usb, 2800, 24000, 50 / 24000, 5 / 24000);
    bench('SSB<stereo> @24k', 1.0, block, () => ssb.process(block, cin, sout));
    final afr = RationalResampler(SampleType.stereo, 250000, 48000);
    bench('RationalResampler<stereo> 250k->48k', 1.0, block, () => afr.process(block, cin, sout));
  }
  DspKernels.useSimd = true;

  print('--- FFT (complex, forward) ---');
  for (final n in [1024, 4096, 8192, 16384, 65536]) {
    final plan = FftPlan.get(n);
    final x = Float32List(2 * n);
    for (int i = 0; i < x.length; i++) {
      x[i] = rnd.nextDouble();
    }
    final y = Float32List(2 * n);
    final r = bench('FFT $n', 1.0, 1, () => plan.execute(x, y), unit: 'M FFT/s');
    print('${''.padRight(52)} ${(1 / r).toStringAsFixed(1).padLeft(9)} µs/FFT');
  }
}
