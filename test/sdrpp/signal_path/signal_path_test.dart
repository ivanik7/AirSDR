// IQFrontEnd FFT path, SourceManager tuning, VFOManager references, config persistence,
// module manager, file source formats.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/runtime/dsp_engine.dart';
import 'package:sdr_flutter/sdrpp/core/config.dart';
import 'package:sdr_flutter/sdrpp/core/core.dart';
import 'package:sdr_flutter/sdrpp/core/event.dart';
import 'package:sdr_flutter/sdrpp/modules/radio/radio_module.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/file_source.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/source_pump.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/synth_source.dart';
import 'package:sdr_flutter/sdrpp/signal_path/iq_frontend.dart';
import 'package:sdr_flutter/sdrpp/signal_path/source_handler.dart';
import 'package:sdr_flutter/sdrpp/signal_path/source_manager.dart';
import 'package:sdr_flutter/sdrpp/signal_path/vfo_manager.dart';

import 'harness.dart';

class _FakeSource extends SourceHandler {
  final List<double> tuned = <double>[];
  int selects = 0, deselects = 0;
  SourceSink? sink;
  @override
  void select() => selects++;
  @override
  void deselect() => deselects++;
  @override
  Future<void> start(SourceSink s) async => sink = s;
  @override
  Future<void> stop() async => sink = null;
  @override
  void tune(double f) => tuned.add(f);
  @override
  List<SourceSetting> get settings => const [];
  @override
  void applySetting(String id, Object value) {}
}

void main() {
  group('IQFrontEnd FFT', () {
    test('reshape params and rate', () {
      expect(IQFrontEnd.genReshapeParams(2.4e6, 8192, 20), (120000 - 8192, 8192));
      expect(IQFrontEnd.genReshapeParams(48000, 8192, 20), (0, 2400));
    });

    test('carrier at +300 kHz lands on the right bin, dB normalised by N', () {
      final fe = IQFrontEnd(sampleRate: 2.4e6, fftSize: 8192, fftRate: 20);
      final rows = <Float32List>[];
      final buf = Float32List(8192);
      fe.acquireFFTBuffer = (n) => buf;
      fe.releaseFFTBuffer = (n) => rows.add(Float32List.fromList(buf));
      const a = 0.5;
      final n = 240000; // 0.1 s → 2 rows
      final iq = Float32List(2 * n);
      for (int i = 0; i < n; i++) {
        final ph = 2 * math.pi * 300e3 * i / 2.4e6;
        iq[2 * i] = a * math.cos(ph);
        iq[2 * i + 1] = a * math.sin(ph);
      }
      for (int off = 0; off < n; off += 12000) {
        fe.process(Float32List.sublistView(iq, 2 * off, 2 * (off + 12000)), 12000);
      }
      expect(rows.length, 2);
      final row = rows.last;
      int best = 0;
      for (int i = 1; i < row.length; i++) {
        if (row[i] > row[best]) best = i;
      }
      // (-1)^i window shifts DC to bin N/2: bin = N/2 + f/fs·N
      expect(best, 4096 + (300e3 / 2.4e6 * 8192).round());
      // Nuttall coherent gain 0.3636 → 20·log10(0.5·0.3636) ≈ −14.8 dB
      expect(row[best], closeTo(20 * math.log(a * 0.3636) / math.ln10, 0.5));
      expect(row.every((v) => v.isFinite), isTrue);
    });

    test('decimation halves the effective rate and calls core', () {
      final core = Core();
      final seen = <double>[];
      core.onInputSampleRateChanged.bind(seen.add);
      core.setInputSampleRate(2.4e6);
      core.iqFrontEnd.setDecimation(4);
      expect(core.iqFrontEnd.getEffectiveSamplerate(), 600000);
      expect(seen.last, 600000);
    });

    test('DspEngine.computeRow: view window + doZoom, pixel of a carrier', () {
      // Full band = 2.4 MHz / 8192 bins, a single hot bin at +300 kHz.
      final raw = Float32List(8192)..fillRange(0, 8192, -120);
      final bin = 4096 + 1024;
      raw[bin] = 0;
      final out = Float32List(1000);
      // View: 1 MHz wide centred at +250 kHz → pixel = (300k − (−250k)) / 1 MHz · 1000 = 550
      final (low, high) = DspEngine.computeRow(raw, 8192, 2.4e6, 250e3, 1e6, out);
      expect(high - low, closeTo(1e6, 2 * 2.4e6 / 8192));
      int best = 0;
      for (int i = 1; i < out.length; i++) {
        if (out[i] > out[best]) best = i;
      }
      final expected = ((300e3 - low) / (high - low) * 1000).floor();
      expect(best, inInclusiveRange(expected - 1, expected + 1));
      expect(best, inInclusiveRange(548, 552));
    });

    test('end-to-end FFT row from the synth source via the Rig', () async {
      final rig = Rig(carriers: [SynthCarrier(frequency: 100e6 - 600e3, amplitude: 0.3)]);
      final rows = <Float32List>[];
      final buf = Float32List(8192);
      rig.core.iqFrontEnd.acquireFFTBuffer = (n) => buf;
      rig.core.iqFrontEnd.releaseFFTBuffer = (n) => rows.add(Float32List.fromList(buf));
      await rig.start();
      rig.run(0.5);
      expect(rows.length, inInclusiveRange(9, 11)); // 20 rows/s
      final row = rows.last;
      int best = 0;
      for (int i = 1; i < row.length; i++) {
        if (row[i] > row[best]) best = i;
      }
      expect(best, 4096 - 2048);
    });
  });

  group('SourceManager', () {
    test('select / tune with offset / panadapter / nullSource', () async {
      final core = Core();
      final sm = core.sigpath.sourceManager;
      final a = _FakeSource(), b = _FakeSource();
      sm.registerSource('A', a);
      sm.registerSource('B', b);
      sm.registerSource('A', b); // duplicate ignored
      expect(sm.getSourceNames(), ['A', 'B']);
      sm.selectSource('A');
      expect(a.selects, 1);
      final retunes = <double>[];
      sm.onRetune.bind(retunes.add);
      sm.tune(100e6);
      expect(a.tuned.last, 100e6);
      sm.setTuningOffset(-125e6); // upconverter
      expect(a.tuned.last, 25e6); // |100e6 − 125e6|
      expect(retunes.last, -25e6);
      sm.setTuningMode(TuningMode.panadapter);
      sm.setPanadapterIF(10.7e6);
      expect(a.tuned.last, 10.7e6);
      sm.setTuningMode(TuningMode.normal);
      sm.setTuningOffset(0);

      await sm.start();
      final sinkA = a.sink!;
      sm.selectSource('B');
      expect(a.deselects, 1);
      final before = core.iqFrontEnd.samplesIn;
      sinkA(Float32List(200), 100); // stale source → dropped
      expect(core.iqFrontEnd.samplesIn, before);
      await sm.start();
      b.sink!(Float32List(200), 100);
      expect(core.iqFrontEnd.samplesIn, before + 100);
      sm.unregisterSource('B');
      expect(sm.selectedHandler, isNull);
    });
  });

  group('VFOManager', () {
    test('reference: lower/upper move the DSP centre, general offset stays', () {
      final core = Core();
      core.setInputSampleRate(2.4e6);
      final vm = core.sigpath.vfoManager;
      final v = vm.createVFO('x', VFOReference.lower, 1000, 2800, 24000, 500, 12000, false)!;
      expect(v.getOffset(), 1000);
      expect(v.centerOffset, 2400);
      v.setBandwidth(3000);
      expect(v.centerOffset, 2500);
      v.setReference(VFOReference.upper);
      expect(v.centerOffset, -500);
      expect(v.dspVFO.offset, -500);
      expect(vm.createVFO('x', VFOReference.center, 0, 1, 1, 1, 1, false), isNull);
      vm.deleteVFO(v);
      expect(vm.vfoExists('x'), isFalse);
      expect(core.iqFrontEnd.getVFO('x'), isNull);
    });
  });

  group('Config / modules / events', () {
    test('ConfigManager: load default, debounced autosave, reload', () async {
      final dir = Directory.systemTemp.createTempSync('sigpath_cfg');
      try {
        final path = '${dir.path}/sub/radio_config.json';
        final c = ConfigManager(autoSaveDelay: const Duration(milliseconds: 50));
        c.setPath(path);
        c.load(<String, dynamic>{'a': 1});
        expect(File(path).existsSync(), isTrue);
        final base = c.saveCount;
        c.enableAutoSave();
        for (int i = 0; i < 10; i++) {
          c.acquire();
          c.conf['a'] = i;
          c.release(true);
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(c.saveCount, base + 1); // one write for the burst
        final c2 = ConfigManager()..setPath(path);
        c2.load(<String, dynamic>{});
        expect(c2.conf['a'], 9);
        File(path).writeAsStringSync('{corrupt');
        c2.load(<String, dynamic>{'b': 2});
        expect(c2.conf, {'b': 2});
        c.disableAutoSave();
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('radio config survives a restart (file-backed)', () {
      final dir = Directory.systemTemp.createTempSync('sigpath_radio');
      try {
        final path = '${dir.path}/radio_config.json';
        var core = Core();
        var f = RadioModuleFactory(core, configPath: path);
        core.moduleManager.loadModule(f);
        core.moduleManager.createInstance('Radio', 'radio');
        var r = core.moduleManager.instances['Radio']!.instance as RadioModule;
        r.selectDemodByID(DemodID.usb);
        r.setBandwidth(2400);
        core.moduleManager.endAll();

        core = Core();
        f = RadioModuleFactory(core, configPath: path);
        core.moduleManager.loadModule(f);
        core.moduleManager.createInstance('Radio', 'radio');
        r = core.moduleManager.instances['Radio']!.instance as RadioModule;
        expect(r.selectedDemodID, DemodID.usb.id);
        expect(r.bandwidth, 2400);
        core.moduleManager.endAll();
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('ModuleManager instance limits and errors', () {
      final core = Core();
      final m = core.moduleManager;
      final f = RadioModuleFactory(core);
      expect(m.loadModule(f), same(f));
      expect(m.createInstance('R1', 'radio'), 0);
      expect(m.createInstance('R1', 'radio'), -1);
      expect(m.createInstance('R2', 'nope'), -1);
      expect(m.countModuleInstances('radio'), 1);
      expect(m.disableInstance('R1'), 0);
      expect(m.instanceEnabled('R1'), isFalse);
      expect(m.enableInstance('R1'), 0);
      expect(m.deleteInstance('R1'), 0);
      expect(core.sigpath.vfoManager.vfoExists('R1'), isFalse);
      expect(core.sigpath.sinkManager.getStreamNames(), isEmpty);
    });

    test('Event bind/unbind by identity', () {
      final e = Event<int>();
      final got = <int>[];
      final h = e.bind(got.add);
      e.emit(1);
      expect(e.unbindHandler(h), isTrue);
      e.emit(2);
      expect(got, [1]);
    });
  });

  group('FileSource', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('sigpath_file'));
    tearDown(() => dir.deleteSync(recursive: true));

    Float32List tone(int n, double f, double fs) {
      final x = Float32List(2 * n);
      for (int i = 0; i < n; i++) {
        x[2 * i] = 0.5 * math.cos(2 * math.pi * f * i / fs);
        x[2 * i + 1] = 0.5 * math.sin(2 * math.pi * f * i / fs);
      }
      return x;
    }

    Future<List<double>> readAll(FileSource src, int samples) async {
      final got = <double>[];
      await src.start((iq, n) {
        for (int i = 0; i < 2 * n; i++) {
          got.add(iq[i]);
        }
      });
      while (got.length < 2 * samples) {
        src.pump.pump();
      }
      await src.stop();
      return got;
    }

    test('raw formats convert and loop', () async {
      final x = tone(1000, 5000, 100000);
      final core = Core();
      final files = <IQFileFormat, List<int>>{
        IQFileFormat.cf32: x.buffer.asUint8List(),
        IQFileFormat.cs16: Int16List.fromList([for (final v in x) (v * 32767).round()]).buffer.asUint8List(),
        IQFileFormat.cs8: Int8List.fromList([for (final v in x) (v * 127).round()]).buffer.asUint8List(),
        IQFileFormat.cu8: Uint8List.fromList([for (final v in x) (v * 127.5 + 127.5).round()]),
      };
      for (final e in files.entries) {
        final p = '${dir.path}/rec_433920000Hz.${e.key.name}';
        File(p).writeAsBytesSync(e.value);
        final src = FileSource(core, path: p, sampleRate: 100000, mode: PumpMode.manual);
        expect(src.format, e.key);
        expect(src.centerFreq, 433920000);
        expect(src.sampleCount, 1000);
        final got = await readAll(src, 2500); // loops 2.5×
        for (final i in [0, 777, 1999, 2 * 1000 + 13, 2 * 2000 + 555]) {
          expect(got[i], closeTo(x[i % 2000], 0.02), reason: '${e.key} @ $i');
        }
        src.close();
      }
    });

    test('WAV float32 and int16 (SDR++ recorder layout)', () async {
      final x = tone(500, 1000, 48000);
      Uint8List wav(int fmt, int bits, List<int> data) {
        final b = BytesBuilder();
        final h = ByteData(44);
        void s(int o, String t) {
          for (int i = 0; i < 4; i++) {
            h.setUint8(o + i, t.codeUnitAt(i));
          }
        }

        s(0, 'RIFF');
        h.setUint32(4, 36 + data.length, Endian.little);
        s(8, 'WAVE');
        s(12, 'fmt ');
        h.setUint32(16, 16, Endian.little);
        h.setUint16(20, fmt, Endian.little);
        h.setUint16(22, 2, Endian.little);
        h.setUint32(24, 48000, Endian.little);
        h.setUint32(28, 48000 * 2 * bits ~/ 8, Endian.little);
        h.setUint16(32, 2 * bits ~/ 8, Endian.little);
        h.setUint16(34, bits, Endian.little);
        s(36, 'data');
        h.setUint32(40, data.length, Endian.little);
        b.add(h.buffer.asUint8List());
        b.add(data);
        return b.toBytes();
      }

      final core = Core();
      final pf = '${dir.path}/f.wav';
      File(pf).writeAsBytesSync(wav(3, 32, x.buffer.asUint8List()));
      final pi = '${dir.path}/i.wav';
      File(pi).writeAsBytesSync(
          wav(1, 16, Int16List.fromList([for (final v in x) (v * 32767).round()]).buffer.asUint8List()));
      for (final p in [pf, pi]) {
        final src = FileSource(core, path: p, mode: PumpMode.manual);
        expect(src.isWav, isTrue);
        expect(src.sampleRate, 48000);
        src.select();
        expect(core.iqFrontEnd.getEffectiveSamplerate(), 48000);
        final got = await readAll(src, 600);
        expect(got[2 * 510 + 1], closeTo(x[2 * 10 + 1], 1e-3));
        src.close();
      }
    });
  });
}
