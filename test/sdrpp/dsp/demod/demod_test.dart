import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/sdrpp/dsp/demod/am.dart';
import 'package:sdr_flutter/sdrpp/dsp/demod/broadcast_fm.dart';
import 'package:sdr_flutter/sdrpp/dsp/demod/cw.dart';
import 'package:sdr_flutter/sdrpp/dsp/demod/fm.dart';
import 'package:sdr_flutter/sdrpp/dsp/demod/quadrature.dart';
import 'package:sdr_flutter/sdrpp/dsp/demod/ssb.dart';
import 'package:sdr_flutter/sdrpp/dsp/kernels/dot.dart';
import 'package:sdr_flutter/sdrpp/dsp/processor.dart';

import '../test_util.dart';

void main() {
  const fs = 250000.0;
  final fmIn = golden('in_fm_stereo'); // L = 1 kHz tone, R = 0, pilot 19 kHz, dev 75 kHz
  final nF = fmIn.length ~/ 2;

  group('Quadrature', () {
    test('golden', () {
      final out = runChunked(Quadrature.hz(75000, fs), fmIn, nF, [1000]);
      expectClose(out, golden('quadrature'), tol: 1e-5);
    });
    test('FM tone → sine of the right frequency and amplitude', () {
      const n = 25000;
      final x = Float32List(2 * n);
      double ph = 0;
      for (int i = 0; i < n; i++) {
        ph += 2 * math.pi * 30000 * math.sin(2 * math.pi * 2000 * i / fs) / fs;
        x[2 * i] = math.cos(ph);
        x[2 * i + 1] = math.sin(ph);
      }
      final out = Float32List(n);
      Quadrature.hz(75000, fs).process(n, x, out);
      expect(peakFrequency(out, fs, fMin: 500, fMax: 5000, step: 50), 2000);
      expect(toneAmplitude(out, 2000, fs), closeTo(30000 / 75000, 0.005));
    });
  });

  group('BroadcastFM', () {
    test('mono golden', () {
      final out = runChunked(BroadcastFM(75000, fs, stereo: false), fmIn, nF, [1000]);
      expectClose(out, golden('bfm_mono'), tol: 1e-5);
    });

    test('stereo: matches C++ golden after PLL lock, L ≫ R', () {
      final out = runChunked(BroadcastFM(75000, fs, stereo: true), fmIn, nF, [1000]);
      final g = golden('bfm_stereo');
      expect(out.length, g.length);
      // PLL uses double atan2/cos vs C++ atan2f/cosf: tiny loop-state differences.
      final tail = Float32List.sublistView(out, 20000);
      final gTail = Float32List.sublistView(g, 20000);
      expect(maxAbsDiff(tail, gTail), lessThan(5e-3));
      final l = toneAmplitude(out, 1000, fs, start: 10000, stride: 2, lane: 0);
      final r = toneAmplitude(out, 1000, fs, start: 10000, stride: 2, lane: 1);
      expect(l, closeTo(0.9, 0.01));
      expect(r, lessThan(0.01));
      expect(20 * math.log(l / r) / math.ln10, greaterThan(35), reason: 'separation dB');
    });

    test('stereo chunk invariance (scalar kernels, bit-exact)', () {
      DspKernels.useSimd = false;
      addTearDown(() => DspKernels.useSimd = true);
      final one = runChunked(BroadcastFM(75000, fs, stereo: true), fmIn, nF, [nF]);
      final ch = runChunked(BroadcastFM(75000, fs, stereo: true), fmIn, nF, randomChunks(4, 3000));
      expect(maxAbsDiff(ch, one), 0.0);
    });

    test('tap sizes and delays (docs/02 §3.14)', () {
      final b = BroadcastFM(75000, fs, stereo: false);
      expect(b.pilotFirTaps.size, 317);
      expect(b.audioFirTaps.size, 237);
      expect(b.lprDelay.delay, 159);
      b.setSamplerate(200000);
      expect(b.pilotFirTaps.size, (3.8 * 200000 / 3000).truncate() | 1);
    });

    test('RDS hook produces 5 kHz complex output', () {
      final b = BroadcastFM(75000, fs, stereo: false, rdsOut: true);
      final out = Float32List(2 * 5000);
      b.process(5000, Float32List.sublistView(fmIn, 0, 10000), out);
      expect(b.rdsOutCount, closeTo(100, 2));
    });
  });

  group('FM (NFM)', () {
    test('golden FM<stereo> 50 kHz bw 12.5k', () {
      final x = golden('in_nfm');
      final out = runChunked(FM(SampleType.stereo, 50000, 12500, true), x, x.length ~/ 2, [1000]);
      expectClose(out, golden('nfm'), tol: 1e-5);
      // 1 kHz tone, 2.5 kHz deviation over bw/2 = 6.25 kHz → 0.4
      expect(toneAmplitude(out, 1000, 50000, start: 2000, stride: 2), closeTo(0.4, 0.005));
    });
    test('setBandwidth rescales deviation', () {
      final x = golden('in_nfm');
      final fm = FM(SampleType.real, 50000, 12500, true);
      fm.setBandwidth(25000);
      final out = Float32List(x.length ~/ 2);
      fm.process(out.length, x, out);
      expect(toneAmplitude(out, 1000, 50000, start: 2000), closeTo(0.2, 0.005));
    });
  });

  group('AM', () {
    test('golden AUDIO and CARRIER AGC', () {
      final x = golden('in_am');
      final n = x.length ~/ 2;
      final a = runChunked(AM(SampleType.stereo, AGCMode.audio, 10000, 50 / 15000, 5 / 15000, 100 / 15000, 15000), x,
          n, [1000]);
      expectClose(a, golden('am_audio'), tol: 1e-4);
      final c = runChunked(
          AM(SampleType.stereo, AGCMode.carrier, 10000, 50 / 15000, 5 / 15000, 100 / 15000, 15000), x, n, [1000]);
      expectClose(c, golden('am_carrier'), tol: 1e-4);
    });
    test('(1 + m·sin) → 1 kHz sine', () {
      final x = golden('in_am');
      final n = x.length ~/ 2;
      final am = AM(SampleType.real, AGCMode.carrier, 10000, 50 / 15000, 5 / 15000, 100 / 15000, 15000);
      final out = Float32List(n);
      am.process(n, x, out);
      expect(peakFrequency(out, 15000, fMin: 200, fMax: 5000, step: 50, start: 5000), 1000);
      // The carrier AGC (attack ≫ decay) partially follows the envelope, compressing m = 0.5
      // (C++ golden: same value).
      expect(toneAmplitude(out, 1000, 15000, start: 5000), inInclusiveRange(0.3, 0.5));
    });
  });

  group('SSB / CW', () {
    test('golden USB / LSB / DSB', () {
      final x = golden('in_ssb');
      final n = x.length ~/ 2;
      for (final (m, name) in [(SSBMode.usb, 'usb'), (SSBMode.lsb, 'lsb'), (SSBMode.dsb, 'dsb')]) {
        final out = runChunked(SSB(SampleType.stereo, m, 2800, 24000, 50 / 24000, 5 / 24000), x, n, [1000]);
        expectClose(out, golden('ssb_$name'), tol: 1e-4, reason: name);
      }
    });

    // VFO reference: USB → VFO centre = carrier + bw/2 (REF_LOWER); LSB → carrier − bw/2.
    for (final (mode, toneBb) in [(SSBMode.usb, -1400.0 + 1000.0), (SSBMode.lsb, 1400.0 - 1000.0)]) {
      test('${mode.name.toUpperCase()}: carrier+1 kHz tone → 1 kHz audio', () {
        const sr = 24000.0;
        const n = 24000;
        final x = complexTone(n, toneBb, sr, amp: 0.05);
        final s = SSB(SampleType.stereo, mode, 2800, sr, 50 / sr, 5 / sr);
        final out = Float32List(2 * n);
        s.process(n, x, out);
        expect(peakFrequency(out, sr, fMin: 100, fMax: 3000, step: 10, start: 4000, stride: 2), 1000);
        // AGC (attack ≫ decay) settles near the peak: ~1.15 for a sine, same as C++ golden.
        expect(toneAmplitude(out, 1000, sr, start: 4000, stride: 2), closeTo(1.15, 0.05));
      });
    }

    test('CW golden + carrier → 800 Hz', () {
      final x = Float32List(2 * 6000);
      for (int i = 0; i < 6000; i++) {
        x[2 * i] = 0.1;
      }
      final out = runChunked(CW(SampleType.stereo, 800, 100 / 3000, 5 / 3000, 3000), x, 6000, [500]);
      expectClose(out, golden('cw'), tol: 1e-4);
      expect(peakFrequency(out, 3000, fMin: 100, fMax: 1400, step: 10, start: 1000, stride: 2), 800);
    });
  });
}
