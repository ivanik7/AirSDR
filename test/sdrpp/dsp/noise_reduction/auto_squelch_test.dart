// AutoSquelch (app extension, lib/sdrpp/dsp/noise_reduction/auto_squelch.dart) on synthetic
// IF: complex Gaussian noise through the RxVFO channel low-pass + optional FM/AM carrier.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/sdrpp/dsp/dsp.dart';

/// Synthetic IF source: noise (rms [noiseRms] over the full rate, then channel-filtered to
/// [bandwidth]) + a carrier of amplitude [carrier] (FM with a [toneHz] tone at [deviation],
/// or unmodulated / AM).
class IfSynth {
  IfSynth({
    required this.sampleRate,
    required this.bandwidth,
    this.noiseRms = 1.0,
    int seed = 1,
  }) : _rnd = math.Random(seed),
       _fir = FIR(SampleType.complex, lowPass(bandwidth / 2, bandwidth / 2 * 0.1, sampleRate)) {
    // Fill the channel filter's history: a real VFO filter is always warmed up, a cold one
    // would feed the floor tracker near-zero power for the first taps.
    block(sampleRate.round());
  }

  final double sampleRate;
  final double bandwidth;
  double noiseRms;
  double carrier = 0;
  double toneHz = 1000;
  double deviation = 3000;
  double amIndex = 0; // > 0: AM instead of FM
  final math.Random _rnd;
  final FIR _fir;
  double _t = 0;
  double _phase = 0;

  /// In-channel noise power (the RxVFO filter keeps bandwidth/sampleRate of it).
  double get channelNoisePower => noiseRms * noiseRms * bandwidth / sampleRate;

  /// Sets [carrier] for a carrier-to-noise ratio of [cnrDb] inside the channel.
  void setCnr(double cnrDb) => carrier = math.sqrt(channelNoisePower * math.pow(10, cnrDb / 10));

  double _g() {
    var u = _rnd.nextDouble();
    if (u < 1e-12) u = 1e-12;
    return math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * _rnd.nextDouble());
  }

  Float32List block(int n) {
    final x = Float32List(2 * n);
    final s = noiseRms / math.sqrt2;
    for (var i = 0; i < n; i++) {
      x[2 * i] = s * _g();
      x[2 * i + 1] = s * _g();
    }
    _fir.process(n, x, x);
    if (carrier > 0) {
      for (var i = 0; i < n; i++) {
        final m = math.sin(2 * math.pi * toneHz * _t);
        double a = carrier;
        if (amIndex > 0) {
          a *= 1 + amIndex * m;
        } else {
          _phase += 2 * math.pi * deviation * m / sampleRate;
        }
        x[2 * i] += a * math.cos(_phase);
        x[2 * i + 1] += a * math.sin(_phase);
        _t += 1 / sampleRate;
      }
    }
    return x;
  }
}

/// Runs [seconds] through [sq] in [blockMs] blocks; returns the open state per block.
List<bool> run(AutoSquelch sq, IfSynth s, double seconds, {double blockMs = 10}) {
  final n = (s.sampleRate * blockMs / 1000).round();
  final blocks = (seconds * 1000 / blockMs).round();
  return <bool>[for (var b = 0; b < blocks; b++) sq.analyze(n, s.block(n))];
}

void main() {
  group('noise squelch (NFM, IF 50 kHz)', () {
    const sr = 50000.0;

    test('reference table matches a fresh simulation (empty channel ≈ 0 dB quieting)', () {
      for (final bw in <double>[5000, 12500, 25000]) {
        final s = IfSynth(sampleRate: sr, bandwidth: bw, seed: 99);
        final sq = AutoSquelch(detector: AutoSquelchDetector.noise, sampleRate: sr, bandwidth: bw);
        run(sq, s, 0.2);
        var sum = 0.0;
        var n = 0;
        for (var i = 0; i < 200; i++) {
          sq.analyze(500, s.block(500));
          sum += sq.metricDb!;
          n++;
        }
        expect(sum / n, closeTo(0, 1.0), reason: 'bw $bw');
      }
    });

    test('(a) noise only at −20/0/+20 dB and several bandwidths: stays closed', () {
      for (final bw in <double>[5000, 12500, 25000]) {
        for (final rms in <double>[0.01, 0.1, 1.0, 10.0]) {
          final s = IfSynth(sampleRate: sr, bandwidth: bw, noiseRms: rms, seed: 7);
          final sq = AutoSquelch(detector: AutoSquelchDetector.noise, sampleRate: sr, bandwidth: bw);
          final open = run(sq, s, 5);
          expect(open.contains(true), isFalse, reason: 'bw $bw rms $rms');
          expect(sq.transitions, 0);
        }
      }
    });

    test('(b) carrier with 1 kHz tone above threshold opens fast; closes after the hang', () {
      const bw = 12500.0;
      final s = IfSynth(sampleRate: sr, bandwidth: bw, noiseRms: 0.3, seed: 3);
      final sq = AutoSquelch(detector: AutoSquelchDetector.noise, sampleRate: sr, bandwidth: bw);
      expect(run(sq, s, 1).contains(true), isFalse);
      s.setCnr(15);
      final on = run(sq, s, 2, blockMs: 1);
      final openAt = on.indexOf(true);
      expect(openAt, greaterThanOrEqualTo(0));
      expect(openAt, lessThan(60), reason: 'opens within 60 ms (was $openAt ms)');
      expect(on.sublist(openAt).every((o) => o), isTrue, reason: 'no drop-outs at 15 dB CNR');
      s.carrier = 0;
      final off = run(sq, s, 1, blockMs: 1);
      final closeAt = off.indexOf(false);
      expect(closeAt, greaterThanOrEqualTo(AutoSquelchTuning.hangMs.round()));
      expect(closeAt, lessThan(AutoSquelchTuning.hangMs + 60), reason: 'closed at $closeAt ms');
      expect(off.sublist(closeAt).contains(true), isFalse);
      expect(sq.transitions, 2);
    });

    test('RF gain / carrier level does not matter at the same CNR', () {
      for (final rms in <double>[0.01, 1.0, 30.0]) {
        final s = IfSynth(sampleRate: sr, bandwidth: 12500, noiseRms: rms, seed: 5);
        final sq = AutoSquelch(detector: AutoSquelchDetector.noise, sampleRate: sr, bandwidth: 12500);
        s.setCnr(12);
        final o = run(sq, s, 1);
        expect(o.sublist(10).every((v) => v), isTrue, reason: 'rms $rms');
      }
    });

    test('(c) signal at the threshold: hysteresis + hang keep transitions few', () {
      const bw = 12500.0;
      // CNR ≈ 2.5 dB → quieting ≈ threshold (6 dB close, 8.5 dB open), see calibration.
      for (final cnr in <double>[2.0, 3.0, 4.0]) {
        final s = IfSynth(sampleRate: sr, bandwidth: bw, noiseRms: 0.5, seed: 11);
        final sq = AutoSquelch(detector: AutoSquelchDetector.noise, sampleRate: sr, bandwidth: bw);
        s.setCnr(cnr);
        run(sq, s, 10);
        // Each open lasts ≥ hang (250 ms) → < 40 opens in 10 s is the hard bound; a chattering
        // comparator without hysteresis/hang would switch hundreds of times.
        expect(sq.transitions, lessThanOrEqualTo(12), reason: 'CNR $cnr: ${sq.transitions}');
      }
    });

    test('(d) 1 kHz tone / voice-band audio alone does not open (no quieting)', () {
      const bw = 12500.0;
      final s = IfSynth(sampleRate: sr, bandwidth: bw, noiseRms: 1.0, seed: 13);
      final sq = AutoSquelch(detector: AutoSquelchDetector.noise, sampleRate: sr, bandwidth: bw);
      // A weak, heavily modulated carrier: the discriminator output is full of tone, but the
      // HF noise is not quieted.
      s
        ..deviation = 5000
        ..setCnr(-3);
      expect(run(sq, s, 5).contains(true), isFalse);
      // The tone itself does not reach the detector: at high CNR the modulated and the
      // unmodulated carrier give nearly the same quieting (the few dB left are the FM
      // sidebands clipped by the channel filter), both far above the threshold.
      final a = IfSynth(sampleRate: sr, bandwidth: bw, seed: 17)..setCnr(20);
      final b = IfSynth(sampleRate: sr, bandwidth: bw, seed: 17)
        ..deviation = 0
        ..setCnr(20);
      final qa = AutoSquelch(detector: AutoSquelchDetector.noise, sampleRate: sr, bandwidth: bw);
      final qb = AutoSquelch(detector: AutoSquelchDetector.noise, sampleRate: sr, bandwidth: bw);
      run(qa, a, 1);
      run(qb, b, 1);
      expect((qa.metricDb! - qb.metricDb!).abs(), lessThan(5), reason: '${qa.metricDb} vs ${qb.metricDb}');
      expect(qa.metricDb!, greaterThan(qa.thresholdDb! + 10));
    });

    test('offset shifts the threshold (+ = needs a stronger signal)', () {
      const bw = 12500.0;
      final s = IfSynth(sampleRate: sr, bandwidth: bw, noiseRms: 0.5, seed: 19)..setCnr(8);
      final sq = AutoSquelch(detector: AutoSquelchDetector.noise, sampleRate: sr, bandwidth: bw);
      expect(run(sq, s, 1).last, isTrue);
      sq.offsetDb = 15;
      expect(sq.thresholdDb, AutoSquelchTuning.noiseOpenDb + 15);
      expect(run(sq, s, 1).last, isFalse);
      sq.offsetDb = -5;
      expect(run(sq, s, 1).last, isTrue);
    });
  });

  group('level squelch (AM/SSB/CW)', () {
    test('(a) noise only at −20/0/+20 dB: learns the floor and stays closed', () {
      for (final (sr, bw) in <(double, double)>[(15000, 10000), (24000, 2800), (3000, 200)]) {
        for (final rms in <double>[0.01, 0.1, 1.0]) {
          final s = IfSynth(sampleRate: sr, bandwidth: bw, noiseRms: rms, seed: 23);
          final sq = AutoSquelch(detector: AutoSquelchDetector.level, sampleRate: sr, bandwidth: bw);
          final o = run(sq, s, 5);
          expect(o.contains(true), isFalse, reason: 'sr $sr bw $bw rms $rms');
          final floorExpected = 10 * math.log(s.channelNoisePower) / math.ln10;
          expect(sq.floorDb!, closeTo(floorExpected, 1.5), reason: 'sr $sr bw $bw rms $rms');
        }
      }
    });

    test('AM carrier 10 dB above the floor opens; closes after the hang when it stops', () {
      final s = IfSynth(sampleRate: 15000, bandwidth: 10000, noiseRms: 0.1, seed: 29);
      final sq = AutoSquelch(detector: AutoSquelchDetector.level, sampleRate: 15000, bandwidth: 10000);
      expect(run(sq, s, 1).contains(true), isFalse);
      s
        ..amIndex = 0.6
        ..setCnr(10);
      final on = run(sq, s, 2, blockMs: 1);
      final openAt = on.indexOf(true);
      expect(openAt, inInclusiveRange(0, 60));
      expect(on.sublist(openAt).every((o) => o), isTrue);
      s.carrier = 0;
      final off = run(sq, s, 1, blockMs: 1);
      final closeAt = off.indexOf(false);
      expect(closeAt, inInclusiveRange(AutoSquelchTuning.hangMs.round(), AutoSquelchTuning.hangMs.round() + 80));
      expect(sq.transitions, 2);
    });

    test('(c) signal at the threshold: few transitions', () {
      final s = IfSynth(sampleRate: 24000, bandwidth: 2800, noiseRms: 0.1, seed: 31);
      final sq = AutoSquelch(detector: AutoSquelchDetector.level, sampleRate: 24000, bandwidth: 2800);
      run(sq, s, 2);
      // Total power = noise + carrier; floor + margin ⇔ CNR ≈ 4.7 dB, open at ≈ 7.8 dB.
      for (final cnr in <double>[4.0, 5.5, 7.0]) {
        final before = sq.transitions;
        s.setCnr(cnr);
        run(sq, s, 5);
        expect(sq.transitions - before, lessThanOrEqualTo(8), reason: 'CNR $cnr');
      }
    });

    test('(d) the threshold follows the noise floor', () {
      final s = IfSynth(sampleRate: 24000, bandwidth: 2800, noiseRms: 1.0, seed: 37);
      final sq = AutoSquelch(detector: AutoSquelchDetector.level, sampleRate: 24000, bandwidth: 2800);
      run(sq, s, 3);
      final th1 = sq.thresholdDb!;
      // Floor drops by 20 dB: the squelch stays closed and the threshold follows within the
      // floor window (2 s).
      s.noiseRms = 0.1;
      expect(run(sq, s, 3).contains(true), isFalse);
      expect(sq.thresholdDb!, closeTo(th1 - 20, 1.5));
      // A carrier 10 dB above the new floor opens (it would not have with the old threshold).
      s.setCnr(10);
      expect(run(sq, s, 1).last, isTrue);
      s.carrier = 0;
      expect(run(sq, s, 1).last, isFalse);
      // Floor rises by 20 dB (band noise): it opens, then the level becomes the floor and it
      // closes — never stuck open.
      s.noiseRms = 1.0;
      final o = run(sq, s, 15);
      expect(o.last, isFalse);
      final lastOpen = o.lastIndexOf(true);
      expect(lastOpen * 10, lessThan(AutoSquelchTuning.floorFreezeMs + 3000));
      expect(sq.thresholdDb!, closeTo(th1, 1.5));
      // reset() (retune / gain change in the engine) relearns at once.
      s.noiseRms = 10.0;
      sq.reset();
      expect(run(sq, s, 1).contains(true), isFalse);
      expect(sq.thresholdDb!, closeTo(th1 + 20, 1.5));
    });

    test('closed while the floor is being learnt (after reset)', () {
      final s = IfSynth(sampleRate: 15000, bandwidth: 10000, noiseRms: 0.1, seed: 41)..setCnr(20);
      final sq = AutoSquelch(detector: AutoSquelchDetector.level, sampleRate: 15000, bandwidth: 10000);
      sq.analyze(150, s.block(150)); // 10 ms
      expect(sq.thresholdDb, isNull);
      expect(sq.open, isFalse);
    });

    test('cold channel filter (zeros, then rising noise) after a mode switch does not open', () {
      for (final (det, sr, bw) in <(AutoSquelchDetector, double, double)>[
        (AutoSquelchDetector.level, 3000, 200), // CW: ~0.4 s filter warm-up
        (AutoSquelchDetector.level, 24000, 2800),
        (AutoSquelchDetector.noise, 50000, 12500),
      ]) {
        final sq = AutoSquelch(detector: det, sampleRate: sr, bandwidth: bw);
        final fir = FIR(SampleType.complex, lowPass(bw / 2, bw / 2 * 0.1, sr));
        final rnd = math.Random(3);
        final n = (sr / 100).round();
        final opened = <bool>[];
        for (var b = 0; b < 500; b++) {
          final x = Float32List(2 * n);
          if (b >= 10) {
            for (var i = 0; i < 2 * n; i++) {
              x[i] = 0.01 * (rnd.nextDouble() - 0.5);
            }
          }
          fir.process(n, x, x);
          opened.add(sq.analyze(n, x));
        }
        expect(opened.contains(true), isFalse, reason: '$det sr $sr bw $bw');
      }
    });
  });

  group('gate', () {
    test('zero while closed, linear fade-in/out over fadeMs, no step', () {
      final sq = AutoSquelch(detector: AutoSquelchDetector.noise, sampleRate: 50000, bandwidth: 12500);
      const fs = 48000.0;
      Float32List ones(int n) => Float32List(2 * n)..fillRange(0, 2 * n, 1.0);
      final a = ones(480);
      sq.gate(480, a, fs);
      expect(a.every((v) => v == 0), isTrue);
      // Open it with a strong carrier.
      final s = IfSynth(sampleRate: 50000, bandwidth: 12500, noiseRms: 0.1, seed: 43)..setCnr(30);
      run(sq, s, 0.2);
      expect(sq.open, isTrue);
      final b = ones(480);
      sq.gate(480, b, fs);
      final fadeFrames = (AutoSquelchTuning.fadeMs * fs / 1000).round();
      for (var i = 1; i < 480; i++) {
        expect(b[2 * i] - b[2 * (i - 1)], lessThanOrEqualTo(1.0 / fadeFrames + 1e-6));
      }
      expect(b[2 * (fadeFrames + 1)], 1.0);
      expect(b[2 * 479], 1.0);
    });
  });
}
