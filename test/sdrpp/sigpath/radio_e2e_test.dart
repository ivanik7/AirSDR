// End-to-end: synth source → IQFrontEnd → VFO → radio (IF chain, demod, AF chain) → 48 kHz
// stereo audio captured on the SinkManager stream splitter.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/sdrpp/modules/radio/radio_module.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/synth_source.dart';

import 'harness.dart';

void main() {
  const center = 100e6;

  test('WFM stereo: L = 1 kHz, R = 400 Hz, 48 kHz output', () async {
    final rig = Rig(carriers: [
      SynthCarrier(frequency: center + 300e3, modulation: SynthModulation.wfmStereo, amplitude: 0.5, toneHz: 1000, toneRightHz: 400),
    ]);
    rig.radio.selectDemodByID(DemodID.wfm);
    (rig.radio.selectedDemod!).setOption('stereo', true);
    rig.radio.vfo!.setOffset(300e3);
    await rig.start();
    rig.run(1.0);
    expect(rig.left.length, closeTo(48000, 600));
    rig.clear();
    rig.run(0.5);
    final l = peakOf(rig.left, 48000, n: 16384);
    final r = peakOf(rig.right, 48000, n: 16384);
    // ignore: avoid_print
    print('WFM L $l / R $r');
    expect(l.freq, closeTo(1000, 3));
    expect(r.freq, closeTo(400, 3));
    expect(l.rms, greaterThan(0.05));
    expect(l.rms, lessThan(1.5));
  });

  test('WFM mono (default config): 1 kHz tone', () async {
    final rig = Rig(carriers: [
      SynthCarrier(frequency: center - 500e3, modulation: SynthModulation.wfm, amplitude: 0.5, toneHz: 1000),
    ]);
    expect(rig.radio.selectedDemodID, DemodID.wfm.id); // default selectedDemodId = 1
    rig.radio.vfo!.setOffset(-500e3);
    await rig.start();
    rig.run(0.8);
    final l = peakOf(rig.left, 48000, n: 16384);
    final r = peakOf(rig.right, 48000, n: 16384);
    expect(l.freq, closeTo(1000, 3));
    expect(r.freq, closeTo(1000, 3));
    expect(l.rms, greaterThan(0.1));
  });

  test('NFM: 1 kHz tone', () async {
    final rig = Rig(carriers: [
      SynthCarrier(frequency: center + 125e3, modulation: SynthModulation.nfm, amplitude: 0.2, toneHz: 1000, deviation: 3000),
    ]);
    rig.radio.selectDemodByID(DemodID.nfm);
    rig.radio.vfo!.setOffset(125e3);
    await rig.start();
    rig.run(0.8);
    final p = peakOf(rig.left, 48000, n: 16384);
    // ignore: avoid_print
    print('NFM $p');
    expect(p.freq, closeTo(1000, 3));
    expect(p.rms, greaterThan(0.05));
    expect(p.rms, lessThan(1.5));
  });

  test('AM: 700 Hz tone', () async {
    final rig = Rig(carriers: [
      SynthCarrier(frequency: center - 250e3, modulation: SynthModulation.am, amplitude: 0.2, toneHz: 700, modIndex: 0.6),
    ]);
    rig.radio.selectDemodByID(DemodID.am);
    rig.radio.vfo!.setOffset(-250e3);
    await rig.start();
    rig.run(1.0);
    final p = peakOf(rig.left, 48000, n: 16384);
    // ignore: avoid_print
    print('AM $p');
    expect(p.freq, closeTo(700, 3));
    expect(p.rms, greaterThan(0.02));
    expect(p.rms, lessThan(1.5));
  });

  test('USB: 1500 Hz tone; VFO reference is the lower edge', () async {
    final rig = Rig(carriers: [
      SynthCarrier(frequency: center + 50e3, modulation: SynthModulation.usb, amplitude: 0.05, toneHz: 1500),
    ]);
    rig.radio.selectDemodByID(DemodID.usb);
    rig.radio.vfo!.setOffset(50e3);
    // REF_LOWER: DSP centre = dial + bw/2.
    expect(rig.radio.vfo!.centerOffset, closeTo(50e3 + rig.radio.bandwidth / 2, 1e-6));
    await rig.start();
    rig.run(1.0);
    final p = peakOf(rig.left, 48000, n: 16384);
    // ignore: avoid_print
    print('USB $p');
    expect(p.freq, closeTo(1500, 3));
    expect(p.rms, greaterThan(0.02));
    expect(p.rms, lessThan(1.5));
  });

  test('LSB / DSB / CW / RAW produce audio at 48 kHz', () async {
    final rig = Rig(carriers: [
      SynthCarrier(frequency: center + 50e3, modulation: SynthModulation.lsb, amplitude: 0.05, toneHz: 1200),
    ]);
    rig.radio.selectDemodByID(DemodID.lsb);
    rig.radio.vfo!.setOffset(50e3);
    await rig.start();
    rig.run(1.0);
    expect(peakOf(rig.left, 48000).freq, closeTo(1200, 3));

    for (final id in [DemodID.dsb, DemodID.cw, DemodID.raw]) {
      rig.radio.selectDemodByID(id);
      rig.clear();
      rig.run(0.5);
      expect(rig.left.length, closeTo(24000, 400), reason: id.name);
      expect(rig.left.every((v) => v.isFinite), isTrue, reason: id.name);
    }
    // CW of an unmodulated carrier at the dial → 800 Hz tone
    rig.synth.carriers
      ..clear()
      ..add(SynthCarrier(frequency: center + 50e3, amplitude: 0.05));
    rig.radio.selectDemodByID(DemodID.cw);
    rig.clear();
    rig.run(1.0);
    expect(peakOf(rig.left, 48000).freq, closeTo(800, 3));
  });

  test('power squelch mutes noise, opens on a carrier', () async {
    final rig = Rig(carriers: [], noise: 0.001);
    rig.radio.selectDemodByID(DemodID.nfm);
    rig.radio.setSquelchMode(SquelchMode.power);
    rig.radio.setSquelchLevel(-40);
    await rig.start();
    rig.run(0.5);
    final rmsClosed = math.sqrt(rig.left.fold<double>(0, (a, v) => a + v * v) / rig.left.length);
    expect(rmsClosed, lessThan(1e-3));
    rig.synth.carriers.add(SynthCarrier(frequency: center, modulation: SynthModulation.nfm, amplitude: 0.3));
    rig.clear();
    rig.run(0.5);
    expect(peakOf(rig.left, 48000, n: 8192).freq, closeTo(1000, 6));
  });

  test('per-mode config persistence', () {
    final rig = Rig(carriers: []);
    rig.radio.selectDemodByID(DemodID.nfm);
    rig.radio.setBandwidth(9000);
    rig.radio.setSquelchMode(SquelchMode.power);
    rig.radio.setSquelchLevel(-55);
    rig.radio.selectDemodByID(DemodID.am);
    rig.radio.setBandwidth(6000);
    rig.radio.selectDemodByID(DemodID.nfm);
    expect(rig.radio.bandwidth, 9000);
    expect(rig.radio.squelchMode, SquelchMode.power);
    expect(rig.radio.squelchLevel, -55);
    final conf = rig.radioConfig.conf['Radio'] as Map;
    expect(conf['selectedDemodId'], DemodID.nfm.id);
    expect((conf['AM'] as Map)['bandwidth'], 6000);
    expect((conf['FM'] as Map)['squelchMode'], 'power');
    // WFM default bandwidth clamp & deemphasis default 50 µs
    rig.radio.selectDemodByID(DemodID.wfm);
    expect(rig.radio.bandwidth, 150000);
    expect(rig.radio.deempMode, DeemphasisMode.mode50us);
  });
}
