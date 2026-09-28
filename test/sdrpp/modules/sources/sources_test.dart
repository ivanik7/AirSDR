import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/sdrpp/core/core.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/source_pump.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/synth_source.dart';

void main() {
  test('SourcePump block size = sr/200 and real-time pacing', () async {
    int pushed = 0;
    final p = SourcePump((b, n) {}, sampleRate: 1e6, mode: PumpMode.realTime);
    expect(p.blockSize, 5000);
    final sw = Stopwatch()..start();
    p.start((iq, n) => pushed += n);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    p.stop();
    final expected = sw.elapsedMicroseconds / 1e6 * 1e6;
    expect(pushed, inInclusiveRange((expected * 0.8).round(), (expected * 1.05).round()));
  });

  test('SynthSource is deterministic and reset() restarts the sequence', () {
    final core = Core();
    final a = SynthSource(core, sampleRate: 240000, mode: PumpMode.manual);
    final b = SynthSource(core, sampleRate: 240000, mode: PumpMode.manual);
    final x = Float32List(2000), y = Float32List(2000);
    a.generate(x, 1000);
    b.generate(y, 1000);
    expect(x, y);
    a.reset();
    final z = Float32List(2000);
    a.generate(z, 1000);
    expect(z, x);
  });

  test('SynthSource tune moves carriers; select sets the input rate', () {
    final core = Core();
    final s = SynthSource(core, sampleRate: 1e6, centerFreq: 100e6, noiseLevel: 0,
        carriers: [SynthCarrier(frequency: 100.1e6, amplitude: 1)], mode: PumpMode.manual);
    s.select();
    expect(core.iqFrontEnd.getEffectiveSamplerate(), 1e6);
    final x = Float32List(20);
    s.generate(x, 10);
    // +100 kHz at 1 MSPS: phase step 0.1 cycle
    expect(x[2], closeTo(0.809, 1e-3)); // cos(2π·0.1)
    s.tune(100.1e6);
    s.reset();
    s.generate(x, 10);
    expect(x[2], closeTo(1.0, 1e-3)); // now at DC
  });
}
