import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/sdrpp/dsp/multirate/decim/plans.dart';
import 'package:sdr_flutter/sdrpp/dsp/multirate/polyphase_bank.dart';
import 'package:sdr_flutter/sdrpp/dsp/taps/taps.dart';
import 'package:sdr_flutter/sdrpp/dsp/window/windows.dart';

import '../test_util.dart';

void main() {
  group('windows (golden vs C++ window/*.h)', () {
    test('nuttall/blackman/BH/BN/hamming/hann, N=64, n in [-N+0.5, -0.5]', () {
      final g = golden('windows_64');
      const n = 64;
      final fns = [nuttall, blackman, blackmanHarris, blackmanNuttall, hamming, hann];
      for (int i = 0; i < n; i++) {
        final x = i - n + 0.5;
        for (int k = 0; k < fns.length; k++) {
          expect(fns[k](x, n.toDouble()), closeTo(g[i * 6 + k], 1e-7), reason: 'win $k i $i');
        }
      }
      expect(rectangular(3, 10), 1.0);
    });
  });

  group('taps (golden vs C++ taps/*.h)', () {
    void cmp(String name, Taps t, {double tol = 1e-7}) {
      final g = golden('taps_$name');
      final floats = t.isComplex ? 2 * t.size : t.size;
      expect(floats, g.length, reason: '$name tap count');
      expect(maxAbsDiff(t.taps, g), lessThanOrEqualTo(tol), reason: name);
    }

    test('estimateTapCount', () {
      expect(estimateTapCount(7500, 250000), 126);
      expect(estimateTapCount(4000, 250000), 237);
      expect(estimateTapCount(100, 48000), 1824);
    });
    test('lowPass WFM VFO 126', () => cmp('lp_vfo_wfm', lowPass(75000, 7500, 250000)));
    test('lowPass WFM audio 237', () => cmp('lp_audio_wfm', lowPass(15000, 4000, 250000)));
    test('lowPass NFM 304', () => cmp('lp_nfm', lowPass(6250, 625, 50000)));
    test('lowPass AM 114', () => cmp('lp_am', lowPass(5000, 500, 15000)));
    test('lowPass resampler proto 456', () => cmp('lp_resamp_wfm', lowPass(125000, 12500, 1500000)));
    test('lowPass large 4750', () => cmp('lp_resamp_af', lowPass(24000, 2400, 3000000)));
    test('lowPass odd', () => cmp('lp_odd', lowPass(1000, 300, 48000, true)));
    test('highPass 300 Hz 1824', () => cmp('hp_300', highPass(300, 100, 48000)));
    test('bandPass float', () => cmp('bp_float', bandPass(1000, 3000, 500, 48000)));
    test('bandPass complex pilot 317', () {
      final t = bandPassComplex(18750.0, 19250.0, 3000.0, 250000, true);
      expect(t.size, 317);
      cmp('bp_pilot', t, tol: 2e-7);
    });
    test('bandPass complex even', () => cmp('bp_complex', bandPassComplex(1000, 3000, 500, 48000), tol: 2e-7));
  });

  group('decim plans (generated)', () {
    test('stage table matches docs/02 §3.4', () {
      final expected = <int, List<List<int>>>{
        2: [
          [2, 69]
        ],
        4: [
          [2, 12],
          [2, 69]
        ],
        8: [
          [4, 27],
          [2, 69]
        ],
        16: [
          [8, 54],
          [2, 69]
        ],
        32: [
          [8, 44],
          [2, 12],
          [2, 69]
        ],
        64: [
          [8, 36],
          [4, 27],
          [2, 69]
        ],
        128: [
          [16, 72],
          [4, 27],
          [2, 69]
        ],
        256: [
          [32, 143],
          [4, 27],
          [2, 69]
        ],
        512: [
          [32, 129],
          [8, 54],
          [2, 69]
        ],
        1024: [
          [64, 257],
          [8, 54],
          [2, 69]
        ],
        2048: [
          [64, 329],
          [8, 44],
          [2, 12],
          [2, 69]
        ],
        4096: [
          [64, 400],
          [8, 36],
          [4, 27],
          [2, 69]
        ],
        8192: [
          [128, 726],
          [8, 36],
          [4, 27],
          [2, 69]
        ],
      };
      expect(plans.length, plansLen);
      int id = 0;
      for (final e in expected.entries) {
        final p = plans[id++];
        expect(p.stages.map((s) => [s.decimation, s.tapcount]).toList(), e.value, reason: 'ratio ${e.key}');
      }
    });
  });

  group('polyphase bank', () {
    test('golden 5 phases (reversed phase index)', () {
      final t = lowPass(125000, 12500, 1500000);
      for (int i = 0; i < t.size; i++) {
        t.taps[i] *= 5.0;
      }
      final pb = buildPolyphaseBank(5, t);
      expect(pb.tapsPerPhase, 92);
      expect(maxAbsDiff(pb.phases, golden('polybank_5')), 0.0);
    });
    test('small example', () {
      final pb = buildPolyphaseBank(3, Taps.real(Float32List.fromList([1, 2, 3, 4, 5, 6, 7])));
      expect(pb.tapsPerPhase, 3);
      // phases[(P-1) - (i % P)][i / P] = taps[i]
      expect(pb.phase(2).toList(), [1, 4, 7]);
      expect(pb.phase(1).toList(), [2, 5, 0]);
      expect(pb.phase(0).toList(), [3, 6, 0]);
    });
  });
}
