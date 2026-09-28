import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/sdrpp/dsp/filter/deemphasis.dart';
import 'package:sdr_flutter/sdrpp/dsp/filter/fir.dart';
import 'package:sdr_flutter/sdrpp/dsp/kernels/dot.dart';
import 'package:sdr_flutter/sdrpp/dsp/multirate/decim/taps.g.dart';
import 'package:sdr_flutter/sdrpp/dsp/multirate/polyphase_resampler.dart';
import 'package:sdr_flutter/sdrpp/dsp/multirate/power_decimator.dart';
import 'package:sdr_flutter/sdrpp/dsp/multirate/rational_resampler.dart';
import 'package:sdr_flutter/sdrpp/dsp/processor.dart';
import 'package:sdr_flutter/sdrpp/dsp/taps/taps.dart';

import '../test_util.dart';

void main() {
  final cin = golden('in_complex');
  final rin = golden('in_real');
  final nC = cin.length ~/ 2;
  final nR = rin.length;
  const fixed = [1000];

  for (final simd in [true, false]) {
    group(simd ? 'SIMD kernels' : 'scalar kernels', () {
      setUp(() => DspKernels.useSimd = simd);
      tearDown(() => DspKernels.useSimd = true);

      test('FIR<complex,float> golden', () {
        final out = runChunked(FIR(SampleType.complex, lowPass(75000, 7500, 250000)), cin, nC, fixed);
        expectClose(out, golden('fir_cr'));
      });
      test('FIR<float,float> golden', () {
        final out = runChunked(FIR(SampleType.real, lowPass(15000, 4000, 250000)), rin, nR, fixed);
        expectClose(out, golden('fir_rr'));
      });
      test('FIR<complex,complex> golden (pilot BPF)', () {
        final out = runChunked(
            FIR(SampleType.complex, bandPassComplex(18750.0, 19250.0, 3000.0, 250000, true)), cin, nC, fixed);
        expectClose(out, golden('fir_cc'));
      });
      test('FIR setTaps history continuity golden', () {
        final f = FIR(SampleType.complex, lowPass(75000, 7500, 250000));
        final out = Float32List(2 * 9000);
        f.process(3000, Float32List.sublistView(cin, 0, 6000), out);
        f.setTaps(lowPass(75000, 16000, 250000));
        final o2 = Float32List(6000);
        f.process(3000, Float32List.sublistView(cin, 6000, 12000), o2);
        out.setRange(6000, 12000, o2);
        f.setTaps(lowPass(75000, 4750, 250000));
        f.process(3000, Float32List.sublistView(cin, 12000, 18000), o2);
        out.setRange(12000, 18000, o2);
        expectClose(out, golden('fir_settaps'));
      });
      test('DecimatingFIR /4 golden (chunk 999)', () {
        final out = runChunked(DecimatingFIR(SampleType.complex, fromArray(fir_8_4_taps), 4), cin, nC, [999]);
        expectClose(out, golden('decimfir_4'));
      });
      for (final ratio in [2, 8, 32, 64, 256]) {
        test('PowerDecimator x$ratio golden', () {
          final out = runChunked(PowerDecimator(SampleType.complex, ratio), cin, nC, [1200]);
          expectClose(out, golden('powerdecim_$ratio'));
        });
      }
      test('PolyphaseResampler 5/6 golden', () {
        final t = lowPass(125000, 12500, 1500000);
        for (int i = 0; i < t.size; i++) {
          t.taps[i] *= 5.0;
        }
        final out = runChunked(PolyphaseResampler(SampleType.complex, 5, 6, t), cin, nC, fixed);
        expectClose(out, golden('poly_5_6'));
      });
      final rrs = {
        'rr_2400k_250k': [2400000.0, 250000.0],
        'rr_2400k_50k': [2400000.0, 50000.0],
        'rr_2400k_24k': [2400000.0, 24000.0],
        'rr_2048k_250k': [2048000.0, 250000.0],
        'rr_24k_48k': [24000.0, 48000.0],
        'rr_15k_48k': [15000.0, 48000.0],
        'rr_250k_48k': [250000.0, 48000.0],
      };
      rrs.forEach((name, r) {
        test('RationalResampler $name golden', () {
          final rs = RationalResampler(SampleType.complex, r[0], r[1]);
          final out = runChunked(rs, cin, nC, fixed, outFactor: r[1] / r[0] + 0.01);
          expectClose(out, golden(name), tol: 2e-5);
          expect(out.length, golden(name).length, reason: 'output count');
        });
      });
      test('RationalResampler<stereo> 250k->48k golden', () {
        final rs = RationalResampler(SampleType.stereo, 250000, 48000);
        final out = runChunked(rs, cin, nC, fixed, outFactor: 0.2);
        expectClose(out, golden('rr_stereo_250k_48k'), tol: 2e-5);
      });
    });
  }

  group('block-boundary invariance (scalar kernels: bit-exact)', () {
    setUp(() => DspKernels.useSimd = false);
    tearDown(() => DspKernels.useSimd = true);

    void inv(String name, Processor Function() mk, Float32List input, int n, {double outFactor = 1.0}) {
      test(name, () {
        final one = runChunked(mk(), input, n, [n], outFactor: outFactor);
        for (final seed in [1, 2, 3]) {
          final chunks = runChunked(mk(), input, n, randomChunks(seed, 1500), outFactor: outFactor);
          expect(chunks.length, one.length, reason: 'count seed $seed');
          expect(maxAbsDiff(chunks, one), 0.0, reason: 'seed $seed');
        }
      });
    }

    inv('FIR complex', () => FIR(SampleType.complex, lowPass(75000, 7500, 250000)), cin, nC);
    inv('FIR real', () => FIR(SampleType.real, lowPass(15000, 4000, 250000)), rin, nR);
    inv('FIR complex taps', () => FIR(SampleType.complex, bandPassComplex(18750, 19250, 3000, 250000, true)), cin, nC);
    inv('DecimatingFIR /4', () => DecimatingFIR(SampleType.complex, fromArray(fir_8_4_taps), 4), cin, nC);
    inv('PowerDecimator x64', () => PowerDecimator(SampleType.complex, 64), cin, nC);
    inv('RationalResampler 2.4M->250k', () => RationalResampler(SampleType.complex, 2400000, 250000), cin, nC);
    inv('RationalResampler 24k->48k', () => RationalResampler(SampleType.complex, 24000, 48000), cin, nC,
        outFactor: 2.01);
    inv('RationalResampler<stereo> 250k->48k', () => RationalResampler(SampleType.stereo, 250000, 48000), cin, nC,
        outFactor: 0.2);
    inv('Deemphasis stereo', () => Deemphasis(SampleType.stereo, 50e-6, 48000), cin, nC);
  });

  group('SIMD chunk invariance (within float tolerance)', () {
    test('RationalResampler 2.4M->250k random chunks', () {
      final one = runChunked(RationalResampler(SampleType.complex, 2400000, 250000), cin, nC, [nC]);
      final ch = runChunked(RationalResampler(SampleType.complex, 2400000, 250000), cin, nC, randomChunks(5, 1500));
      expect(ch.length, one.length);
      expectClose(ch, one, tol: 1e-5);
    });
  });

  group('tone tests', () {
    test('RationalResampler 2.4M->250k: 20 kHz tone passes, 150 kHz alias rejected', () {
      const inSr = 2400000.0, outSr = 250000.0;
      const n = 240000;
      for (final f in [20000.0, 150000.0]) {
        final x = complexTone(n, f, inSr, amp: 0.5);
        final rs = RationalResampler(SampleType.complex, inSr, outSr);
        final out = Float32List(2 * (rs.maxOutput(n) + 16));
        final m = rs.process(n, x, out);
        expect(m, closeTo(n * outSr / inSr, 2));
        final pw = complexPower(out, m ~/ 4, m);
        if (f == 20000.0) {
          expect(math.sqrt(pw), closeTo(0.5, 0.01), reason: 'passband amplitude');
          // frequency check: phase increment
          final i = m ~/ 2;
          final ph = math.atan2(out[2 * i + 3], out[2 * i + 2]) - math.atan2(out[2 * i + 1], out[2 * i]);
          final fEst = ((ph + 3 * math.pi) % (2 * math.pi) - math.pi) * outSr / (2 * math.pi);
          expect(fEst, closeTo(f, 5));
        } else {
          expect(10 * math.log(pw / 0.25) / math.ln10, lessThan(-60), reason: 'stopband');
        }
      }
    });

    test('Real FIR low-pass: stopband attenuation > 70 dB', () {
      const sr = 250000.0;
      final f = FIR(SampleType.real, lowPass(15000, 4000, sr));
      const n = 20000;
      final x = Float32List(n);
      for (int i = 0; i < n; i++) {
        x[i] = math.sin(2 * math.pi * 40000 * i / sr);
      }
      final out = Float32List(n);
      f.process(n, x, out);
      final a = toneAmplitude(out, 40000, sr, start: 1000);
      expect(20 * math.log(a) / math.ln10, lessThan(-70));
      final f2 = FIR(SampleType.real, lowPass(15000, 4000, sr));
      for (int i = 0; i < n; i++) {
        x[i] = math.sin(2 * math.pi * 5000 * i / sr);
      }
      f2.process(n, x, out);
      expect(toneAmplitude(out, 5000, sr, start: 1000), closeTo(1.0, 0.01));
    });

    test('Deemphasis golden + corner frequency', () {
      final d = Deemphasis(SampleType.stereo, 50e-6, 48000);
      final out = runChunked(d, cin, nC, [1000]);
      expectClose(out, golden('deemp_stereo'), tol: 1e-6);
    });
  });
}
