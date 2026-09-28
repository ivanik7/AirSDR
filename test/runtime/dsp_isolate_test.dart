// DSP isolate protocol smoke test + SdrRadioController against the real isolate.
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/runtime/dsp_engine.dart';
import 'package:sdr_flutter/runtime/dsp_isolate.dart';
import 'package:sdr_flutter/runtime/dsp_protocol.dart';
import 'package:sdr_flutter/runtime/sdr_radio_controller.dart';
import 'package:sdr_flutter/runtime/source_registry.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

import '../sdrpp/signal_path/harness.dart';

/// Hook run inside the DSP isolate: registers an alias of the synth (stands in for the
/// integrator's USB registration).
void registerTestSources(SourceRegistry r) {
  r.register('fake-usb', (params, ctx) {
    if (params['fd'] != 42) throw ArgumentError('fd');
    return SourceRegistry.createSynth(<Object?, Object?>{'sampleRate': 1024000, 'pump': 'realTime'}, ctx);
  });
}

void main() {
  test('DSP isolate: synth → FFT rows + audio frames', () async {
    final dsp = await DspIsolate.spawn(
        options: const DspEngineOptions(audio: 'null', fftSize: 8192, fftRate: 20),
        registerSources: registerTestSources);
    final rows = <Float32List>[];
    final lows = <double>[];
    final audio = <double>[];
    Map<Object?, Object?>? stats;
    Map<Object?, Object?>? state;
    final sub = dsp.events.listen((m) {
      switch (m[DspMsg.evt]) {
        case DspEvt.fft:
          rows.add((m['data'] as TransferableTypedData).materialize().asFloat32List());
          lows.add((m['low'] as num).toDouble());
        case DspEvt.audio:
          final d = (m['data'] as TransferableTypedData).materialize().asFloat32List();
          for (int i = 0; i < d.length; i += 2) {
            audio.add(d[i]);
          }
        case DspEvt.stats:
          stats = m;
        case DspEvt.state:
          state = m;
      }
    });

    await dsp.request({
      DspMsg.cmd: DspCmd.selectSource,
      'id': 'synth',
      'params': {
        'sampleRate': 2400000.0,
        'centerFreq': 100e6,
        'noiseLevel': 0.001,
        'carriers': [
          {'frequency': 100.3e6, 'modulation': 'nfm', 'amplitude': 0.2, 'toneHz': 1000.0},
        ],
        'pump': 'realTime',
      },
    });
    await dsp.request({DspMsg.cmd: DspCmd.setFft, 'width': 800, 'viewOffset': 0.0, 'viewBandwidth': 2400000.0});
    await dsp.request({DspMsg.cmd: DspCmd.setMode, 'mode': 0}); // NFM
    await dsp.request({DspMsg.cmd: DspCmd.tune, 'center': 100e6, 'offset': 300e3});
    await dsp.request({DspMsg.cmd: DspCmd.audioTap, 'enabled': true});
    await dsp.request({DspMsg.cmd: DspCmd.start});
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await dsp.request({DspMsg.cmd: DspCmd.stop});
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // ignore: avoid_print
    print('rows ${rows.length}, audio ${audio.length}, stats $stats');
    expect(rows.length, inInclusiveRange(20, 40)); // ~20 rows/s × 1.5 s
    expect(rows.first.length, 800);
    expect(lows.last, closeTo(100e6 - 1.2e6, 1e3));
    // carrier at +300 kHz → pixel 400 + 300k/2.4M·800 = 500
    final row = rows.last;
    int best = 0;
    for (int i = 1; i < row.length; i++) {
      if (row[i] > row[best]) best = i;
    }
    expect(best, inInclusiveRange(497, 503));
    expect(audio.length, inInclusiveRange(48000, 80000));
    expect(peakOf(audio, 48000, n: 16384).freq, closeTo(1000, 5));
    expect(stats!['audioOutput'], 'null');
    expect(state!['mode'], 0);
    expect(state!['running'], false);

    // Registered hook source + command errors are acked as failures.
    await dsp.request({DspMsg.cmd: DspCmd.selectSource, 'id': 'fake-usb', 'params': {'fd': 42}});
    await dsp.request({DspMsg.cmd: DspCmd.getState});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(state!['sourceId'], 'fake-usb');
    expect(state!['sampleRate'], 1024000);
    await expectLater(dsp.request({DspMsg.cmd: DspCmd.selectSource, 'id': 'nope'}), throwsA(isA<DspCommandException>()));

    await sub.cancel();
    await dsp.close();
    expect(dsp.isClosed, isTrue);
  });

  test('SdrRadioController drives the isolate', () async {
    final c = SdrRadioController(options: const DspEngineOptions(audio: 'null'));
    await c.ready;
    expect(c.lastError, isNull);
    expect(c.devices.single.id, 'synth:0');
    expect(c.selectedDevice, isNotNull);
    await c.selectDevice(c.devices.first);
    c.setFftWidth(512);
    c.setFftView(viewOffset: 0, viewBandwidth: 2.4e6);
    final rows = <FftRow>[];
    final sub = c.fftRows.listen(rows.add);
    c.setTuning(centerFrequency: 100e6, vfoOffset: 200e3);
    await c.start();
    expect(c.running, isTrue, reason: c.lastError);
    c.setMode(DemodMode.nfm);
    c.setBandwidth(10000);
    c.setVolume(0.5);
    c.setSquelchEnabled(true);
    c.setSquelchLevel(-60);
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    expect(rows.length, greaterThan(10));
    expect(rows.last.width, 512);
    expect(rows.last.lowFreq, closeTo(100e6 - 1.2e6, 1e3));
    expect(c.mode, DemodMode.nfm);
    expect(c.bandwidth, 10000);
    expect(c.squelchEnabled, isTrue);
    expect(c.squelchLevel, -60);
    expect((c.lastStats['audioFrames'] as num), greaterThan(0));
    await c.stop();
    expect(c.running, isFalse);
    await sub.cancel();
    c.dispose();
  });
}
