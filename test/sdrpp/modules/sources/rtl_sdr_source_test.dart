// Tests for lib/sdrpp/modules/sources/rtl_sdr_source.dart (port of SDR++
// rtl_sdr_source/src/main.cpp) over lib/usb/mock_transport.dart:
//  * USB control-transfer trace of constructor/select + start + tune + menu
//    actions + stop == golden trace of the real C librtlsdr running the same
//    librtlsdr call sequence (tool/oracle/sources/rtl_scenarios, build.sh);
//  * the SDR++ start prefix == the rtlsdr driver oracle scenario
//    r820t_sdrpp_start (tool/oracle/rtlsdr);
//  * fake bulk data -> sink: exact float values ((b-127.4)/128) and counts;
//  * tune retry loop, stop cancels the stream, unplug -> error + clean stop;
//  * settings, config persistence.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/drivers/rtlsdr/librtlsdr.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/rtl_sdr_source.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/usb_source.dart';
import 'package:sdr_flutter/usb/mock_transport.dart';
import 'package:sdr_flutter/usb/usb_transport.dart';

import '../../../drivers/rtlsdr/fake_rtl_usb.dart';
import 'source_test_utils.dart';

/// One RTL dongle model shared by every open (like the C fake libusb, whose
/// register memory survives rtlsdr_close/rtlsdr_open).
class RtlRig {
  final FakeRtlUsbDevice model;
  final List<MockUsbDeviceHandle> handles = [];
  final core = FakeCore();
  final errors = <(String, Object?, bool)>[];
  final configs = <Map<String, Object?>>[];
  late final RtlSdrSourceModule src;

  RtlRig(
    String modelLine, {
    Map<String, Object?>? savedConfig,
    int fd = 42,
    String? serial = '00000001',
    bool freshModelPerOpen = false,
  }) : model = FakeRtlUsbDevice(FakeModel.parse(modelLine)) {
    src = RtlSdrSourceModule.fromParams(
      {
        'fd': fd,
        'vid': 0x0bda,
        'pid': 0x2838,
        'deviceName': '/dev/bus/usb/001/002',
        'serial': serial,
        'manufacturer': model.model.manufact,
        'product': model.model.product,
      },
      core,
      opener: (p) {
        expect(p.fd, fd);
        final h = rtlMockHandle(
          freshModelPerOpen
              ? FakeRtlUsbDevice(FakeModel.parse(modelLine))
              : model,
        );
        handles.add(h);
        return h;
      },
      savedConfig: savedConfig,
      onConfigChanged: configs.add,
      onError: (m, e, {bool fatal = false}) => errors.add((m, e, fatal)),
    );
  }

  MockUsbDeviceHandle get last => handles.last;
  MockBulkInStream get stream => last.streams.last;

  List<String> get ctrlTrace => [
    for (final h in handles)
      for (final e in h.controlTrace) e.toString(),
  ];
}

const _r820t =
    'tuner=r820t manufact=Realtek product=RTL2838UHIDIR serial=00000001';

String _devKey = 'Realtek RTL2838UHIDIR [00000001]';

void main() {
  rtlsdrLog = (_) {};
  final logs = <String>[];
  SourceLog.sink = (l, m) => logs.add('${l.name}: $m');

  group('USB trace == C librtlsdr oracle', () {
    test('default config: select, start, tune, stop', () async {
      final rig = RtlRig(_r820t);
      final src = rig.src;
      expect(src.deviceNames, [_devKey]);
      expect(src.gainList.length, 29);
      expect(src.sampleRate, 2400000);

      src.select();
      expect(rig.core.rates, [2400000]);

      final sink = SinkRecorder();
      await src.start(sink.call);
      expect(src.running, isTrue);
      await pumpEventQueue();
      expect(rig.last.trace.where((e) => e.kind == UsbTraceKind.openBulkIn), [
        UsbTraceEntry(
          UsbTraceKind.openBulkIn,
          a: 0x81,
          b: 15,
          value: rtlSdrAsyncCount(2400000),
        ),
      ]);
      src.tune(433.92e6);
      await src.stop();
      expect(src.running, isFalse);
      expect(rig.stream.isCancelled, isTrue);
      expect(rig.last.isClosed, isTrue);

      expectSameLines(
        rig.ctrlTrace,
        goldenCtrlAsMock(readGolden('rtl_source_default')),
      );
      expect(rig.errors, isEmpty);
    });

    test('start prefix == driver oracle scenario r820t_sdrpp_start', () async {
      // The rtlsdr driver oracle scenario r820t_sdrpp_start encodes SDR++'s
      // start(): open, 2.4M, 100 MHz, ppm 0, bw 0, ds 0, bias 0, agc 0,
      // set_tuner_gain(...). The module (default config) must produce exactly
      // the same USB control transfers up to that first set_tuner_gain.
      // fresh tuner model per open, like the single open of the C scenario
      final rig = RtlRig(_r820t, freshModelPerOpen: true);
      await rig.src.start(SinkRecorder().call);
      await rig.src.stop();
      final golden = File('tool/oracle/rtlsdr/golden/r820t_sdrpp_start.trace')
          .readAsLinesSync();
      final firstGain = golden.indexWhere(
        (l) => l.startsWith('CALL set_tuner_gain 0'),
      );
      final pre = goldenCtrlAsMock(golden.sublist(0, firstGain));
      expect(pre.length, greaterThan(200));
      // handles[1] = the open() done by start() (handles[0]: constructor)
      final startCtrl = [
        for (final e in rig.handles[1].controlTrace) e.toString(),
      ];
      expectSameLines(startCtrl.sublist(0, pre.length), pre);
    });

    test('saved config + menu actions while running', () async {
      final rig = RtlRig(
        _r820t,
        savedConfig: {
          'device': _devKey,
          'devices': {
            _devKey: {
              'sampleRate': 1024000.0,
              'directSampling': 0,
              'ppm': 52,
              'biasT': true,
              'offsetTuning': true,
              'rtlAgc': true,
              'tunerAgc': false,
              'gain': 16,
            },
          },
        },
      );
      final src = rig.src;
      expect(src.sampleRate, 1024000);
      expect(src.srId, 1);
      expect(src.dbTxt, '29.7 dB');
      await src.start(SinkRecorder().call);
      await pumpEventQueue();
      expect(
        rig.last.trace.last,
        UsbTraceEntry(
          UsbTraceKind.openBulkIn,
          a: 0x81,
          b: 15,
          value: rtlSdrAsyncCount(1024000),
        ),
      );
      src.tune(145.5e6);
      src.applySetting(RtlSdrSettingId.directSampling, 2);
      src.applySetting(RtlSdrSettingId.directSampling, 0);
      src.applySetting(RtlSdrSettingId.ppm, -3);
      src.applySetting(RtlSdrSettingId.gain, 20);
      expect(src.dbTxt, '37.2 dB');
      src.applySetting(RtlSdrSettingId.tunerAgc, true);
      // gain slider disabled with tuner AGC: ignored, no USB traffic
      final n = rig.ctrlTrace.length;
      src.applySetting(RtlSdrSettingId.gain, 3);
      expect(rig.ctrlTrace.length, n);
      expect(src.gainId, 20);
      src.applySetting(RtlSdrSettingId.rtlAgc, false);
      src.applySetting(RtlSdrSettingId.biasT, false);
      src.applySetting(RtlSdrSettingId.offsetTuning, false);
      src.applySetting(RtlSdrSettingId.tunerAgc, false);
      // disabled while running: no effect
      src.applySetting(RtlSdrSettingId.sampleRate, 7);
      expect(src.sampleRate, 1024000);
      await src.stop();

      expectSameLines(
        rig.ctrlTrace,
        goldenCtrlAsMock(readGolden('rtl_source_configured')),
      );
      final dev = rig.configs.last['devices'] as Map;
      expect(dev[_devKey], {
        'sampleRate': 1024000.0,
        'directSampling': 0,
        'ppm': -3,
        'biasT': false,
        'offsetTuning': false,
        'rtlAgc': false,
        'tunerAgc': false,
        'gain': 20,
      });
    });

    test('RTL-SDR Blog V4 (R828D): HF + VHF tuning', () async {
      final rig = RtlRig(
        'tuner=r828d manufact=RTLSDRBlog product=Blog_V4 serial=00000001',
      );
      expect(rig.src.deviceNames, ['RTLSDRBlog Blog V4 [00000001]']);
      await rig.src.start(SinkRecorder().call);
      rig.src.tune(7.1e6);
      rig.src.tune(98e6);
      await rig.src.stop();
      expectSameLines(
        rig.ctrlTrace,
        goldenCtrlAsMock(readGolden('rtl_source_blog_v4')),
      );
    });
  });

  group('streaming', () {
    test('u8 bulk data -> sink with SDR++ values and counts', () async {
      final rig = RtlRig(_r820t);
      final sink = SinkRecorder();
      await rig.src.start(sink.call);
      await pumpEventQueue();
      final len = rtlSdrAsyncCount(2400000);
      expect(len, 11776);
      final s = rig.stream;
      final data = List<int>.generate(3 * len, (i) => (i * 7 + i ~/ 3) & 0xff);
      s.pushAll(data);
      await pumpEventQueue();
      expect(sink.counts, [len ~/ 2, len ~/ 2, len ~/ 2]);
      final all = Float32List.fromList([for (final b in sink.blocks) ...b]);
      expect(all.length, data.length);
      final f = Float32List(1);
      for (var i = 0; i < data.length; i++) {
        // C++: ((float)buf[i] - 127.4) / 128.0f, double math, one rounding
        f[0] = (data[i].toDouble() - 127.4) / 128.0;
        if (all[i] != f[0]) fail('sample $i: ${all[i]} != ${f[0]}');
      }
      expect(all[0], closeTo((0 - 127.4) / 128, 1e-7));
      // every slot was released back to the reader
      expect(s.heldSlots, 0);
      // short / odd block
      s.push(List<int>.filled(1001, 255));
      await pumpEventQueue();
      expect(sink.counts.last, 500);
      expect(sink.blocks.last.every((v) => v == sink.blocks.last[0]), isTrue);
      await rig.src.stop();
      expect(s.isCancelled, isTrue);
      // after stop nothing is delivered
      expect(s.push([1, 2]), isFalse);
      expect(sink.counts.length, 4);
    });

    test('stop cancels the stream, restart works, select sets rate', () async {
      final rig = RtlRig(_r820t);
      final sink = SinkRecorder();
      await rig.src.start(sink.call);
      await pumpEventQueue();
      final first = rig.stream;
      await rig.src.start(sink.call); // already running: no-op
      expect(rig.handles.length, 2);
      await rig.src.stop();
      await rig.src.stop(); // idempotent
      expect(first.isCancelled, isTrue);
      expect(rig.handles[1].isClosed, isTrue);
      expect(
        rig.handles[1].trace
            .map((e) => e.kind)
            .skipWhile((k) => k != UsbTraceKind.releaseInterface),
        [UsbTraceKind.releaseInterface, UsbTraceKind.close],
      );

      rig.src.applySetting(RtlSdrSettingId.sampleRate, 0);
      expect(rig.core.rates, [250000]);
      await rig.src.start(sink.call);
      await pumpEventQueue();
      expect(rig.handles.length, 3);
      expect(rig.stream.bufferLength, rtlSdrAsyncCount(250000));
      rig.stream.push(List<int>.filled(512, 128));
      await pumpEventQueue();
      expect(sink.counts, [256]);
      await rig.src.stop();
    });

    test('device unplug -> error reported, source stops cleanly', () async {
      final rig = RtlRig(_r820t);
      final sink = SinkRecorder();
      await rig.src.start(sink.call);
      await pumpEventQueue();
      rig.stream.push(List<int>.filled(1024, 0));
      await pumpEventQueue();
      rig.last.unplug();
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(rig.src.running, isFalse);
      expect(rig.errors.length, 1);
      expect(rig.errors.single.$3, isTrue); // fatal
      expect((rig.errors.single.$2 as UsbException).code, UsbError.noDevice);
      expect(rig.stream.isCancelled, isTrue);
      expect(rig.last.isClosed, isTrue);
      expect(rig.src.openDev, isNull);
      expect(sink.counts, [512]);
      // stop() after self-stop is harmless; tune while stopped only stores
      await rig.src.stop();
      rig.src.tune(90e6);
      expect(rig.src.freq, 90e6);
    });

    test('unplug before start -> open error, not running', () async {
      final core = FakeCore();
      final errors = <String>[];
      final model = FakeRtlUsbDevice(FakeModel.parse(_r820t));
      var n = 0;
      final src = RtlSdrSourceModule(
        'RTL-SDR',
        core,
        const UsbSourceParams(
          fd: 3,
          vid: 0x0bda,
          pid: 0x2838,
          manufacturer: 'Realtek',
          product: 'RTL2838UHIDIR',
          serial: '1',
        ),
        opener: (p) {
          final h = rtlMockHandle(model);
          if (n++ > 0) h.unplug();
          return h;
        },
        onError: (m, e, {bool fatal = false}) => errors.add(m),
      );
      await src.start(SinkRecorder().call);
      expect(src.running, isFalse);
      expect(errors, isNotEmpty);
    });
  });

  group('tune', () {
    test('retune retries set_center_freq until it sticks (max 10)', () async {
      // osmocom 2.0.3 r82xx_set_freq returns 0 without PLL lock; the SDR++
      // retry loop matters when set_freq fails (dev->freq = 0), e.g. an I2C
      // error. Fail the first 3 tuner I2C writes of the retune.
      final rig = RtlRig(_r820t);
      await rig.src.start(SinkRecorder().call);
      final h = rig.last;
      final pass = h.onControlOut!;
      var failures = 3;
      h.onControlOut = (req) {
        final tunerI2cWrite = req.index == 0x0610 && req.value == 0x0034;
        if (tunerI2cWrite && failures > 0) {
          failures--;
          throw UsbException(UsbError.pipe, 'i2c nak');
        }
        return pass(req);
      };
      logs.clear();
      rig.src.tune(144e6);
      expect(failures, 0);
      expect(rig.src.openDev!.getCenterFreq(), 144000000);
      expect(logs.where((l) => l.contains('took 3 attempts')), hasLength(1));

      // permanent failure: gives up after 10 attempts, freq stays 0
      failures = 1 << 30;
      logs.clear();
      rig.src.tune(145e6);
      expect(rig.src.openDev!.getCenterFreq(), 0);
      expect(logs.where((l) => l.contains('took 10 attempts')), hasLength(1));
      expect(rig.src.freq, 145e6);
      h.onControlOut = pass;
      await rig.src.stop();
      expect(rig.errors, isEmpty);
    });

    test('tune locks on first try; tune while stopped stores freq', () async {
      final rig = RtlRig(_r820t);
      rig.src.tune(88.5e6);
      expect(rig.handles.length, 1); // no USB traffic while stopped
      await rig.src.start(SinkRecorder().call);
      expect(rig.src.openDev!.getCenterFreq(), 88500000);
      logs.clear();
      rig.src.tune(101.1e6);
      expect(rig.src.openDev!.getCenterFreq(), 101100000);
      expect(logs.where((l) => l.contains('attempts')), isEmpty);
      await rig.src.stop();
    });
  });

  group('settings / config', () {
    test('settings list mirrors the SDR++ menu', () {
      final rig = RtlRig(_r820t);
      final s = {for (final x in rig.src.settings) x.id: x};
      expect(s.keys, [
        'device',
        'sampleRate',
        'directSampling',
        'ppm',
        'gain',
        'biasT',
        'offsetTuning',
        'rtlAgc',
        'tunerAgc',
      ]);
      final sr = s['sampleRate']! as dynamic;
      expect(sr.options, rtlSdrSampleRatesTxt);
      expect(sr.selected, 7); // 2.4 MHz default
      final g = s['gain']! as dynamic;
      expect(g.max, 28);
      expect((s['directSampling']! as dynamic).options, [
        'Disabled',
        'I branch',
        'Q branch',
      ]);
    });

    test('new device creates default config and saves it', () {
      final rig = RtlRig(_r820t);
      final c = rig.src.saveConfig();
      expect(c['device'], '');
      expect((c['devices'] as Map)[_devKey], {
        'sampleRate': 2400000.0,
        'directSampling': 0,
        'ppm': 0,
        'biasT': false,
        'offsetTuning': false,
        'rtlAgc': false,
        'tunerAgc': false,
        'gain': 0,
      });
      expect(rig.configs, isNotEmpty);
      rig.src.applySetting(RtlSdrSettingId.ppm, 5000000);
      expect(rig.src.ppm, 1000000); // clamped like std::clamp
      rig.src.applySetting(RtlSdrSettingId.device, 0);
      expect(rig.src.saveConfig()['device'], _devKey);
    });

    test('restoreConfig re-selects with the stored settings', () {
      final rig = RtlRig(_r820t);
      rig.src.restoreConfig({
        'device': _devKey,
        'devices': {
          _devKey: {'sampleRate': 3200000, 'gain': 99, 'tunerAgc': true},
        },
      });
      expect(rig.src.sampleRate, 3200000);
      expect(rig.src.gainId, 28); // clamped to gainList.size() - 1
      expect(rig.src.tunerAgc, isTrue);
      expect(rig.src.gainEnabled, isFalse);
    });

    test('no fd -> no device, start reports error', () async {
      final errors = <String>[];
      final src = RtlSdrSourceModule(
        'RTL-SDR',
        FakeCore(),
        null,
        opener: (_) => throw StateError('must not open'),
        onError: (m, e, {bool fatal = false}) => errors.add(m),
      );
      expect(src.deviceNames, isEmpty);
      await src.start(SinkRecorder().call);
      expect(src.running, isFalse);
      expect(errors, ['No device selected']);
    });

    test('unported tuner (E4000) is reported, start refuses', () async {
      final rig = RtlRig(
        'tuner=e4000 manufact=Realtek product=RTL2838UHIDIR serial=1',
      );
      expect(rig.errors.single.$1, contains('E4000'));
      await rig.src.start(SinkRecorder().call);
      expect(rig.src.running, isFalse);
      expect(rig.handles.last.isClosed, isTrue);
    });

    test('device names', () {
      expect(
        RtlSdrSourceModule.deviceNameFor(
          const UsbSourceParams(fd: 1, vid: 0x0bda, pid: 0x2832),
        ),
        'Generic RTL2832U [No Serial]',
      );
      expect(rtlSdrAsyncCount(250000), 1024);
      expect(rtlSdrAsyncCount(3200000), 31 * 512);
    });
  });
}
