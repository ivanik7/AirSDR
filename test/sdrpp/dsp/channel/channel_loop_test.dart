import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/sdrpp/dsp/channel/frequency_xlator.dart';
import 'package:sdr_flutter/sdrpp/dsp/channel/rx_vfo.dart';
import 'package:sdr_flutter/sdrpp/dsp/correction/dc_blocker.dart';
import 'package:sdr_flutter/sdrpp/dsp/kernels/dot.dart';
import 'package:sdr_flutter/sdrpp/dsp/loop/agc.dart';
import 'package:sdr_flutter/sdrpp/dsp/loop/phase_control_loop.dart';
import 'package:sdr_flutter/sdrpp/dsp/loop/pll.dart';
import 'package:sdr_flutter/sdrpp/dsp/math/math.dart';
import 'package:sdr_flutter/sdrpp/dsp/noise_reduction/noise_blanker.dart';
import 'package:sdr_flutter/sdrpp/dsp/noise_reduction/power_squelch.dart';
import 'package:sdr_flutter/sdrpp/dsp/processor.dart';

import '../test_util.dart';

void main() {
  final cin = golden('in_complex');
  final nC = cin.length ~/ 2;

  group('FrequencyXlator', () {
    test('shifts a tone by the offset; setOffset keeps phase continuous', () {
      const sr = 48000.0;
      const n = 4800;
      final x = complexTone(n, 1000, sr);
      final xl = FrequencyXlator.hz(-3000, sr);
      final out = Float32List(2 * n);
      xl.process(n, x, out);
      for (final i in [0, 100, 4799]) {
        final ph = 2 * math.pi * (1000 - 3000) * i / sr;
        expect(out[2 * i], closeTo(math.cos(ph), 1e-4));
        expect(out[2 * i + 1], closeTo(math.sin(ph), 1e-4));
      }
      // continuity after setOffset(0): next sample continues from the accumulated phase
      xl.setOffsetHz(0, sr);
      final y = Float32List.fromList([1, 0]);
      xl.process(1, y, y);
      final expPh = 2 * math.pi * (-3000) * n / sr;
      expect(y[0], closeTo(math.cos(expPh), 1e-4));
      expect(y[1], closeTo(math.sin(expPh), 1e-4));
      xl.reset();
      y
        ..[0] = 1
        ..[1] = 0;
      xl.process(1, y, y);
      expect(y[0], closeTo(1, 1e-7));
    });
  });

  group('RxVFO', () {
    test('golden 2.4M -> 250k, bw 150k, offset 100k', () {
      final v = RxVFO(2400000, 250000, 150000, 100000);
      expect(v.filterNeeded, isTrue);
      expect(v.ftaps.size, 126);
      final out = runChunked(v, cin, nC, [1200]);
      expectClose(out, golden('rxvfo_wfm'), tol: 2e-5);
    });

    test('tone at +offset+5 kHz ends up at 5 kHz; out-of-band tone rejected', () {
      const inSr = 2400000.0;
      const n = 240000;
      for (final (f, pass) in [(105000.0, true), (300000.0, false)]) {
        final v = RxVFO(inSr, 250000, 150000, 100000);
        final x = complexTone(n, f, inSr, amp: 0.3);
        final out = Float32List(2 * v.maxOutput(n));
        final m = v.process(n, x, out);
        expect(m, closeTo(25000, 2));
        final p = complexPower(out, m ~/ 4, m);
        if (pass) {
          // SDR++ chain gain at 5 kHz is ~-0.27 dB (decim + resampler + LPF ripple; golden-verified).
          expect(math.sqrt(p), closeTo(0.3, 0.012));
          final i = m ~/ 2;
          final dph = math.atan2(out[2 * i + 3], out[2 * i + 2]) - math.atan2(out[2 * i + 1], out[2 * i]);
          final fe = ((dph + 3 * math.pi) % (2 * math.pi) - math.pi) * 250000 / (2 * math.pi);
          expect(fe, closeTo(5000, 5));
        } else {
          expect(10 * math.log(p / 0.09) / math.ln10, lessThan(-60));
        }
      }
    });

    test('filterNeeded toggles; setters', () {
      final v = RxVFO(2400000, 250000, 250000, 0);
      expect(v.filterNeeded, isFalse);
      v.setBandwidth(100000);
      expect(v.filterNeeded, isTrue);
      v.setOutSamplerate(50000, 12500);
      expect(v.resamp.outSamplerate, 50000);
      expect(v.ftaps.size, estimateOk(50000, 12500));
      v.setInSamplerate(2048000);
      expect(v.resamp.inSamplerate, 2048000);
    });

    test('block-boundary invariance (scalar kernels, bit-exact)', () {
      DspKernels.useSimd = false;
      addTearDown(() => DspKernels.useSimd = true);
      final one = runChunked(RxVFO(2400000, 250000, 150000, 100000), cin, nC, [nC]);
      final ch = runChunked(RxVFO(2400000, 250000, 150000, 100000), cin, nC, randomChunks(9, 2000));
      expect(ch.length, one.length);
      expect(maxAbsDiff(ch, one), 0.0);
    });
  });

  group('DCBlocker', () {
    test('golden (float, rate 100/15000)', () {
      final out = runChunked(DCBlocker(SampleType.real, 100.0 / 15000.0), golden('in_dc'), 12000, [1000]);
      expectClose(out, golden('dcblock'), tol: 1e-6);
    });
    test('removes DC from complex', () {
      final d = DCBlocker.withSamplerate(SampleType.complex, 50, 48000);
      const n = 48000;
      final x = Float32List(2 * n);
      for (int i = 0; i < n; i++) {
        x[2 * i] = 0.7;
        x[2 * i + 1] = -0.2;
      }
      d.process(n, x, x);
      expect(x[2 * (n - 1)].abs(), lessThan(1e-3));
      expect(x[2 * (n - 1) + 1].abs(), lessThan(1e-3));
    });
  });

  group('AGC', () {
    test('golden (float, with look-ahead burst)', () {
      final a = AGC(SampleType.real, 1.0, 50.0 / 24000, 5.0 / 24000, 10e6, 10.0, double.infinity);
      expect(a.amp, 0.0, reason: 'initGain = ∞ → amp = 0');
      final out = runChunked(a, golden('in_agc'), 12000, [1000]);
      expectClose(out, golden('agc_real'), tol: 1e-5);
    });
    test('complex AGC converges to setPoint', () {
      final a = AGC(SampleType.complex, 1.0, 0.01, 0.001, 10e6, 10.0, double.infinity);
      final x = complexTone(20000, 100, 48000, amp: 0.01);
      a.process(20000, x, x);
      final m = math.sqrt(x[2 * 19999] * x[2 * 19999] + x[2 * 19999 + 1] * x[2 * 19999 + 1]);
      expect(m, closeTo(1.0, 0.01));
    });
  });

  group('PLL', () {
    test('criticallyDamped', () {
      final (a, b) = PhaseControlLoop.criticallyDamped(0.1);
      const z = 0.7071067811865476;
      const d = 1 + 2 * z * 0.1 + 0.01;
      expect(a, closeTo(4 * z * 0.1 / d, 1e-7));
      expect(b, closeTo(4 * 0.01 / d, 1e-7));
    });
    test('golden: pilot PLL on filtered 19 kHz pilot', () {
      const fs = 250000.0;
      final pll = PLL(25000.0 / fs, 0.0, hzToRads(19000.0, fs), hzToRads(18750.0, fs), hzToRads(19250.0, fs));
      final p = golden('pilot_filtered');
      final out = runChunked(pll, p, p.length ~/ 2, [1000]);
      final g = golden('pll_vco');
      // float atan2/cos of C++ vs double in Dart: small, bounded differences in the loop.
      expect(maxAbsDiff(out, g), lessThan(2e-3));
      // Locked: VCO phase tracks the pilot phase at the end
      final i = p.length ~/ 2 - 1;
      final perr = normalizePhase(math.atan2(p[2 * i + 1], p[2 * i]) - math.atan2(out[2 * i + 1], out[2 * i]));
      expect(perr.abs(), lessThan(0.1));
    });
    test('locks to an offset tone within limits', () {
      const fs = 48000.0;
      final pll = PLL(0.05, 0.0, hzToRads(1000, fs), hzToRads(900, fs), hzToRads(1100, fs));
      final x = complexTone(20000, 1050, fs, phase: 1.0);
      final out = Float32List(40000);
      pll.process(20000, x, out);
      expect(pll.pcl.freq, closeTo(hzToRads(1050, fs), 1e-4));
    });
  });

  group('noise reduction', () {
    test('NoiseBlanker golden', () {
      final out = runChunked(NoiseBlanker(500.0 / 24000.0, 5.0), cin, nC, [1000]);
      expectClose(out, golden('noiseblanker'), tol: 1e-5);
    });
    test('NoiseBlanker attenuates impulses', () {
      final nb = NoiseBlanker(500.0 / 24000.0, 2.0);
      final x = complexTone(4000, 300, 24000, amp: 0.1);
      x[2 * 3000] = 10;
      nb.process(4000, x, x);
      expect(x[2 * 3000], lessThan(1.0));
    });
    test('PowerSquelch passes / zeroes whole blocks by mean magnitude in dB', () {
      final sq = PowerSquelch(-20);
      final x = complexTone(100, 1, 100, amp: 0.1); // 10·log10(0.1) = -10 dB ≥ -20
      final o = Float32List(200);
      sq.process(100, x, o);
      expect(o, equals(x));
      sq.setLevel(-5);
      sq.process(100, x, o);
      expect(o, everyElement(0.0));
    });
  });
}

int estimateOk(double sr, double bw) => (3.8 * sr / (bw / 2 * 0.1)).truncate();
