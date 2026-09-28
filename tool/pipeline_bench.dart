// Real-time factor of the whole receive chain on the host:
//   synth IQ (pre-generated) → IQFrontEnd (FFT 8192 @ 20 rows/s, VFO) → RadioModule (WFM
//   stereo, deemphasis, AF resampler to 48 kHz, volume) → null sink
//
// Build & run (AOT, representative of the Android release build):
//   dart compile exe tool/pipeline_bench.dart -o /tmp/pipeline_bench && /tmp/pipeline_bench
//
// Options: [seconds=10] [sampleRate=2400000] [mode=wfm|wfm-mono|nfm|am|usb]
import 'dart:io';
import 'dart:typed_data';

import 'package:sdr_flutter/sdrpp/core/core.dart';
import 'package:sdr_flutter/sdrpp/modules/radio/radio_module.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/source_pump.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/synth_source.dart';

void main(List<String> args) async {
  final seconds = args.isNotEmpty ? double.parse(args[0]) : 10.0;
  final sr = args.length > 1 ? double.parse(args[1]) : 2400000.0;
  final modeName = args.length > 2 ? args[2] : 'wfm';

  final core = Core();
  core.iqFrontEnd.setFFTSize(8192);
  core.iqFrontEnd.setFFTRate(20);
  final fftBuf = Float32List(8192);
  int rows = 0;
  core.iqFrontEnd.acquireFFTBuffer = (n) => fftBuf;
  core.iqFrontEnd.releaseFFTBuffer = (n) => rows++;

  final synth = SynthSource(core,
      sampleRate: sr, centerFreq: 100e6, noiseLevel: 0.01, mode: PumpMode.manual,
      carriers: SynthSource.defaultCarriers(100e6));
  core.sigpath.sourceManager.registerSource('Synth', synth);
  core.sigpath.sourceManager.selectSource('Synth');
  core.sigpath.sourceManager.tune(100e6);

  final f = RadioModuleFactory(core);
  core.moduleManager.loadModule(f);
  core.moduleManager.createInstance('Radio', 'radio');
  final radio = core.moduleManager.instances['Radio']!.instance as RadioModule;
  switch (modeName) {
    case 'wfm':
      radio.selectDemodByID(DemodID.wfm);
      radio.selectedDemod!.setOption('stereo', true);
      radio.vfo!.setOffset(200e3);
    case 'wfm-mono':
      radio.selectDemodByID(DemodID.wfm);
      radio.vfo!.setOffset(200e3);
    case 'nfm':
      radio.selectDemodByID(DemodID.nfm);
      radio.vfo!.setOffset(-300e3);
    case 'am':
      radio.selectDemodByID(DemodID.am);
      radio.vfo!.setOffset(-600e3);
    case 'usb':
      radio.selectDemodByID(DemodID.usb);
      radio.vfo!.setOffset(500e3);
  }

  // Pre-generate 1 s of IQ in pump-sized blocks, then replay it (source cost excluded).
  final block = synth.pump.blockSize;
  final nBlocks = (sr / block).ceil();
  final blocks = List<Float32List>.generate(nBlocks, (_) {
    final b = Float32List(2 * block);
    synth.generate(b, block);
    return b;
  });
  void sink(Float32List iq, int n) => core.iqFrontEnd.process(iq, n);

  // Warm-up (JIT/AOT caches, filter histories)
  for (int i = 0; i < nBlocks; i++) {
    sink(blocks[i], block);
  }
  final a0 = radio.audioFrames;
  rows = 0;

  final total = (seconds * sr / block).ceil();
  final sw = Stopwatch()..start();
  for (int i = 0; i < total; i++) {
    sink(blocks[i % nBlocks], block);
  }
  sw.stop();
  final signalS = total * block / sr;
  final wallS = sw.elapsedMicroseconds / 1e6;

  // Source generation cost separately.
  final g = Float32List(2 * block);
  final sw2 = Stopwatch()..start();
  final genBlocks = (2 * sr / block).ceil();
  for (int i = 0; i < genBlocks; i++) {
    synth.generate(g, block);
  }
  sw2.stop();

  stdout.writeln('mode=$modeName sr=${sr / 1e6} MSPS block=$block signal=${signalS.toStringAsFixed(1)} s');
  stdout.writeln('chain: wall=${wallS.toStringAsFixed(3)} s  RTF=${(signalS / wallS).toStringAsFixed(2)}x '
      'real time  (${(wallS / signalS * 100).toStringAsFixed(1)} % of one core)');
  stdout.writeln('audio frames=${radio.audioFrames - a0} (${((radio.audioFrames - a0) / signalS).toStringAsFixed(0)}/s), '
      'fft rows=$rows (${(rows / signalS).toStringAsFixed(1)}/s)');
  stdout.writeln('synth source generation: RTF=${(genBlocks * block / sr / (sw2.elapsedMicroseconds / 1e6)).toStringAsFixed(2)}x');
}
