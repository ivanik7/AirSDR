// Tests for lib/sdrpp/modules/sources/hackrf_source.dart (port of SDR++
// hackrf_source/src/main.cpp) over lib/usb/mock_transport.dart:
//  * USB control-transfer trace of start/tune/menu/stop == golden trace of the
//    real libhackrf driven by the same call sequence
//    (tool/oracle/sources/hackrf_source_oracle.c, build.sh);
//  * int8 bulk data -> sink with exact values (b/128) and counts;
//  * stop cancels the stream, restart; unplug -> error + clean stop;
//  * settings (stepped sliders), config persistence.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/drivers/hackrf/hackrf.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/hackrf_source.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/usb_source.dart';
import 'package:sdr_flutter/usb/mock_transport.dart';
import 'package:sdr_flutter/usb/usb_transport.dart';

import 'source_test_utils.dart';

const _serial = '0000000000000000a06063c8234e925f';
const _sn16 = 'a06063c8234e925f';

class HackrfRig {
  final List<MockUsbDeviceHandle> handles = [];
  final core = FakeCore();
  final errors = <(String, Object?, bool)>[];
  final configs = <Map<String, Object?>>[];
  late final HackrfSourceModule src;

  HackrfRig({
    Map<String, Object?>? savedConfig,
    int currentConfig = 0,
    String? serial = _serial,
  }) {
    src = HackrfSourceModule.fromParams(
      {
        'fd': 7,
        'vid': 0x1d50,
        'pid': 0x6089,
        'deviceName': '/dev/bus/usb/001/003',
        'serial': serial,
      },
      core,
      opener: (p) {
        final h = hackrfMockHandle(currentConfig: currentConfig);
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

void main() {
  SourceLog.sink = (l, m) {};

  group('USB trace == C libhackrf oracle', () {
    test('default config: start, tune, stop', () async {
      final rig = HackrfRig();
      final src = rig.src;
      expect(src.deviceNames, [_sn16]);
      expect(src.selectedSerial, _serial);
      expect(src.sampleRate, 2000000);
      expect(src.bwId, 16);
      src.select();
      expect(rig.core.rates, [2000000]);
      expect(rig.handles, isEmpty); // HackRF select does not open the device

      await src.start(SinkRecorder().call);
      expect(src.running, isTrue);
      src.tune(433.92e6);
      await src.stop();
      expect(src.running, isFalse);

      expectSameLines(
        rig.ctrlTrace,
        goldenCtrlAsMock(readGolden('hackrf_source_default')),
      );
      // non-control USB calls in the same order as the C oracle
      expect(
        rig.last.trace
            .where((e) => e.kind != UsbTraceKind.control)
            .map((e) => e.toString()),
        ['CFG 1', 'CLAIM 0', 'BULKIN 81 4 262144', 'RELEASE 0', 'CLOSE'],
      );
      expect(rig.stream.isCancelled, isTrue);
      expect(rig.errors, isEmpty);
    });

    test('saved config + menu actions while running', () async {
      final rig = HackrfRig(
        currentConfig: 1,
        savedConfig: {
          'device': _serial,
          'devices': {
            _serial: {
              'sampleRate': 20000000,
              'biasT': true,
              'amp': true,
              'lnaGain': 40,
              'vgaGain': 62,
              'bandwidth': 16,
            },
          },
        },
      );
      final src = rig.src;
      expect(src.srId, 0);
      expect(src.lna, 40);
      await src.start(SinkRecorder().call);
      src.tune(2.4e9);
      src.applySetting(HackrfSettingId.bandwidth, 5);
      src.applySetting(HackrfSettingId.lnaGain, 27.0); // -> 24 (step 8)
      src.applySetting(HackrfSettingId.vgaGain, 31); // -> 30 (step 2)
      src.applySetting(HackrfSettingId.biasT, false);
      src.applySetting(HackrfSettingId.amp, false);
      // disabled while running
      src.applySetting(HackrfSettingId.sampleRate, 6);
      expect(src.sampleRate, 20000000);
      src.tune(145.5e6);
      await src.stop();

      expectSameLines(
        rig.ctrlTrace,
        goldenCtrlAsMock(readGolden('hackrf_source_configured')),
      );
      expect((rig.configs.last['devices'] as Map)[_serial], {
        'sampleRate': 20000000,
        'biasT': false,
        'amp': false,
        'lnaGain': 24,
        'vgaGain': 30,
        'bandwidth': 5,
      });
    });
  });

  group('streaming', () {
    test('int8 bulk data -> sink with volk values and counts', () async {
      final rig = HackrfRig();
      final sink = SinkRecorder();
      await rig.src.start(sink.call);
      final s = rig.stream;
      expect(s.bufferLength, transferBufferSize);
      final data = List<int>.generate(
        transferBufferSize + 1000,
        (i) => (i * 13 + (i >> 5)) & 0xff,
      );
      s.pushAll(data);
      await pumpEventQueue();
      expect(sink.counts, [transferBufferSize ~/ 2, 500]);
      final all = Float32List.fromList([for (final b in sink.blocks) ...b]);
      expect(all.length, data.length);
      for (var i = 0; i < data.length; i++) {
        final want = data[i].toSigned(8) / 128.0;
        if (all[i] != want) fail('sample $i: ${all[i]} != $want');
      }
      expect(s.heldSlots, 0);
      await rig.src.stop();
      expect(s.isCancelled, isTrue);
      expect(s.push([1, 2]), isFalse);
    });

    test('stop cancels, restart opens again', () async {
      final rig = HackrfRig();
      final sink = SinkRecorder();
      await rig.src.start(sink.call);
      await rig.src.start(sink.call); // no-op while running
      expect(rig.handles.length, 1);
      await rig.src.stop();
      await rig.src.stop();
      expect(rig.handles.single.isClosed, isTrue);
      rig.src.applySetting(HackrfSettingId.sampleRate, 2); // 10 MHz
      expect(rig.core.rates, [10000000]);
      expect(rig.src.bandwidthIdToBw(16), 10000000); // auto
      await rig.src.start(sink.call);
      expect(rig.handles.length, 2);
      rig.stream.push(List<int>.filled(512, 0x80)); // -128
      await pumpEventQueue();
      expect(sink.counts, [256]);
      expect(sink.blocks.single.every((v) => v == -1.0), isTrue);
      await rig.src.stop();
    });

    test('device unplug -> error reported, source stops cleanly', () async {
      final rig = HackrfRig();
      final sink = SinkRecorder();
      await rig.src.start(sink.call);
      rig.stream.push(List<int>.filled(64, 1));
      await pumpEventQueue();
      rig.last.unplug();
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(rig.src.running, isFalse);
      expect(rig.errors, hasLength(1));
      expect(rig.errors.single.$3, isTrue);
      expect((rig.errors.single.$2 as UsbException).code, UsbError.noDevice);
      expect(rig.stream.isCancelled, isTrue);
      expect(rig.last.isClosed, isTrue);
      expect(rig.src.openDev, isNull);
      expect(sink.counts, [32]);
      await rig.src.stop();
    });

    test('open failure is reported, not running', () async {
      final errors = <String>[];
      final src = HackrfSourceModule(
        'HackRF',
        FakeCore(),
        const UsbSourceParams(fd: 7, vid: 0x1d50, pid: 0x6089),
        opener: (_) => hackrfMockHandle()..unplug(),
        onError: (m, e, {bool fatal = false}) => errors.add(m),
      );
      expect(src.deviceNames, ['HackRF USB']);
      expect(src.selectedSerial, 'fake_serial');
      await src.start(SinkRecorder().call);
      expect(src.running, isFalse);
      expect(errors.single, startsWith('Could not open HackRF'));
    });
  });

  group('settings / config', () {
    test('settings list mirrors the SDR++ menu', () {
      final rig = HackrfRig();
      final s = {for (final x in rig.src.settings) x.id: x};
      expect(s.keys, [
        'device',
        'sampleRate',
        'bandwidth',
        'lnaGain',
        'vgaGain',
        'biasT',
        'amp',
      ]);
      final bw = s['bandwidth']! as dynamic;
      expect(bw.options.length, 17);
      expect(bw.options.last, 'Auto');
      expect(bw.selected, 16);
      final lna = s['lnaGain']! as dynamic;
      expect([lna.min, lna.max, lna.step], [0, 40, 8]);
      final vga = s['vgaGain']! as dynamic;
      expect([vga.min, vga.max, vga.step], [0, 62, 2]);
      final sr = s['sampleRate']! as dynamic;
      expect(sr.options, hackrfSampleRatesTxt);
      expect(sr.selected, 6);
    });

    test('selectBySerial defaults, validation and bandwidth clamp', () {
      final rig = HackrfRig(
        savedConfig: {
          'device': _serial,
          'devices': {
            _serial: {'sampleRate': 3000000, 'bandwidth': 99, 'lnaGain': 16},
          },
        },
      );
      // invalid rate keeps the default: srId 0 but sampleRate 2 MHz (C++)
      expect(rig.src.sampleRate, 2000000);
      expect(rig.src.srId, 0);
      expect(rig.src.bwId, 16);
      expect(rig.src.lna, 16);
      rig.src.applySetting(HackrfSettingId.lnaGain, 100);
      expect(rig.src.lna, 40);
      rig.src.applySetting(HackrfSettingId.vgaGain, -5);
      expect(rig.src.vga, 0);
    });

    test('new serial gets default device config (not saved, as C++)', () {
      final rig = HackrfRig();
      expect(rig.configs, isEmpty);
      expect((rig.src.saveConfig()['devices'] as Map)[_serial], {
        'sampleRate': 2000000,
        'biasT': false,
        'amp': false,
        'lnaGain': 0,
        'vgaGain': 0,
        'bandwidth': 16,
      });
      rig.src.applySetting(HackrfSettingId.device, 0);
      expect(rig.configs.last['device'], _serial);
    });

    test('stepped slider quantisation', () {
      expect(sliderFloatWithSteps(39.9, 0, 40, 8), 32);
      expect(sliderFloatWithSteps(62, 0, 62, 2), 62);
      expect(sliderFloatWithSteps(63, 0, 62, 2), 62);
      expect(sliderFloatWithSteps(3, 0, 62, 2), 2);
    });
  });
}
