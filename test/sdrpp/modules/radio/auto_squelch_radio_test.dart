// Auto squelch (app extension) through the whole receiver: synth source → IQFrontEnd → VFO →
// radio (processIF analyses the IF, gates the AF) → 48 kHz audio. Plus the manual SDR++
// power squelch regression and config persistence.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/sdrpp/dsp/dsp.dart' show AutoSquelchDetector;
import 'package:sdr_flutter/sdrpp/modules/radio/radio_module.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/synth_source.dart';

import '../../signal_path/harness.dart';

double rms(List<double> x) => x.isEmpty ? 0 : math.sqrt(x.fold<double>(0, (a, v) => a + v * v) / x.length);

void main() {
  const center = 100e6;

  test('NFM auto: empty channel silent at any noise level; a carrier opens with its 1 kHz tone', () async {
    for (final noise in <double>[0.0003, 0.003, 0.03]) {
      final rig = Rig(carriers: [], noise: noise);
      rig.radio.selectDemodByID(DemodID.nfm);
      rig.radio.setSquelchMode(SquelchMode.auto);
      expect(rig.radio.autoSquelch.detector, AutoSquelchDetector.noise);
      await rig.start();
      rig.run(1.0);
      expect(rig.radio.autoSquelch.open, isFalse, reason: 'noise $noise');
      expect(rms(rig.left), 0, reason: 'noise $noise: closed = exact silence');
      // A station 20 dB above the in-channel noise (12.5 kHz of 2.4 MHz).
      final inChannel = noise * math.sqrt(12500 / 2.4e6);
      rig.synth.carriers.add(SynthCarrier(
          frequency: center, modulation: SynthModulation.nfm, amplitude: inChannel * 10, deviation: 3000));
      rig.clear();
      rig.run(0.6);
      expect(rig.radio.autoSquelch.open, isTrue, reason: 'noise $noise');
      expect(peakOf(rig.left, 48000, n: 8192).freq, closeTo(1000, 6));
      // The station goes away → silence after the hang.
      rig.synth.carriers.clear();
      rig.run(0.6);
      expect(rig.radio.autoSquelch.open, isFalse);
      rig.clear();
      rig.run(0.3);
      expect(rms(rig.left), 0);
    }
  });

  test('AM auto: level squelch learns the floor, opens on a carrier', () async {
    final rig = Rig(carriers: [], noise: 0.003);
    rig.radio.selectDemodByID(DemodID.am);
    rig.radio.setSquelchMode(SquelchMode.auto);
    expect(rig.radio.autoSquelch.detector, AutoSquelchDetector.level);
    await rig.start();
    rig.run(2.0);
    expect(rig.radio.autoSquelch.open, isFalse);
    expect(rig.radio.autoSquelch.floorDb, isNotNull);
    rig.clear();
    rig.run(0.3);
    expect(rms(rig.left), 0);
    final inChannel = 0.003 * math.sqrt(10000 / 2.4e6);
    rig.synth.carriers.add(SynthCarrier(
        frequency: center, modulation: SynthModulation.am, amplitude: inChannel * 10, toneHz: 700, modIndex: 0.6));
    rig.clear();
    rig.run(1.0);
    expect(rig.radio.autoSquelch.open, isTrue);
    expect(peakOf(rig.left, 48000, n: 16384).freq, closeTo(700, 3));
  });

  test('auto is refused for WFM/RAW (no detector), kept per mode, saved with its offset', () {
    final rig = Rig(carriers: []);
    rig.radio.selectDemodByID(DemodID.nfm);
    expect(rig.radio.autoSquelchAllowed, isTrue);
    rig.radio.setSquelchMode(SquelchMode.auto);
    rig.radio.setAutoSquelchOffset(4);
    rig.radio.setAutoSquelchOffset(99); // clamped
    expect(rig.radio.autoSquelchOffset, RadioModule.maxAutoSquelchOffset);
    rig.radio.setAutoSquelchOffset(4);
    rig.radio.selectDemodByID(DemodID.wfm);
    expect(rig.radio.autoSquelchAllowed, isFalse);
    expect(rig.radio.squelchMode, SquelchMode.off);
    rig.radio.selectDemodByID(DemodID.raw);
    expect(rig.radio.autoSquelchAllowed, isFalse);
    rig.radio.selectDemodByID(DemodID.nfm);
    expect(rig.radio.squelchMode, SquelchMode.auto);
    expect(rig.radio.autoSquelchOffset, 4);
    expect(rig.radio.autoSquelch.offsetDb, 4);
    final conf = rig.radioConfig.conf['Radio'] as Map;
    expect((conf['FM'] as Map)['squelchMode'], 'auto');
    expect((conf['FM'] as Map)['squelchAutoOffset'], 4);
    // CW: SDR++ has no power squelch for CW, but the auto level squelch is available.
    rig.radio.selectDemodByID(DemodID.cw);
    expect(rig.radio.squelchAllowed, isFalse);
    expect(rig.radio.autoSquelchAllowed, isTrue);
  });

  test('manual power squelch unchanged: same audio as without the auto squelch code path', () async {
    // Regression: SquelchMode.power must still be the SDR++ block-wise PowerSquelch only.
    final rig = Rig(carriers: [], noise: 0.001);
    rig.radio.selectDemodByID(DemodID.nfm);
    rig.radio.setSquelchMode(SquelchMode.power);
    rig.radio.setSquelchLevel(-40);
    await rig.start();
    rig.run(0.5);
    expect(rms(rig.left), lessThan(1e-3));
    rig.synth.carriers.add(SynthCarrier(frequency: center, modulation: SynthModulation.nfm, amplitude: 0.3));
    rig.clear();
    rig.run(0.5);
    final withPower = List<double>.of(rig.left);
    expect(peakOf(withPower, 48000, n: 8192).freq, closeTo(1000, 6));
    expect(rig.radio.autoSquelch.transitions, 0, reason: 'auto squelch not run in power mode');

    // Same input with the squelch off gives the same samples once the power squelch passes.
    final ref = Rig(carriers: [], noise: 0.001);
    ref.radio.selectDemodByID(DemodID.nfm);
    await ref.start();
    ref.run(0.5);
    ref.synth.carriers.add(SynthCarrier(frequency: center, modulation: SynthModulation.nfm, amplitude: 0.3));
    ref.clear();
    ref.run(0.5);
    final tail = withPower.length - 4800;
    for (var i = tail; i < withPower.length; i++) {
      expect(withPower[i], ref.left[i], reason: 'sample $i');
    }
  });
}
