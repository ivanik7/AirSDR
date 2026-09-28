// Tests of lib/runtime/device_sources.dart: the 'usb' SourceRegistry entry, the generic
// gain/AGC/sample-rate mapping onto the RTL-SDR / HackRF module settings, error propagation
// and the DspEngine integration (state gain/agc/sourceSettings, fatal device loss).
//
// Devices are the register-level mocks of the source module tests (MockUsbDeviceHandle +
// the RTL2832U/R820T model, the HackRF vendor-request script).
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/drivers/rtlsdr/librtlsdr.dart';
import 'package:sdr_flutter/runtime/device_sources.dart';
import 'package:sdr_flutter/runtime/dsp_engine.dart';
import 'package:sdr_flutter/runtime/dsp_protocol.dart';
import 'package:sdr_flutter/runtime/source_registry.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/hackrf_source.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/rtl_sdr_source.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/usb_source.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/usb_source_factory.dart';
import 'package:sdr_flutter/usb/mock_transport.dart';
import 'package:sdr_flutter/usb/usb_transport.dart';

import '../drivers/rtlsdr/fake_rtl_usb.dart';
import '../sdrpp/modules/sources/source_test_utils.dart';

const _r820t = 'tuner=r820t manufact=Realtek product=RTL2838UHIDIR serial=00000001';

const Map<String, Object?> _rtlParams = <String, Object?>{
  'fd': 42,
  'vid': 0x0bda,
  'pid': 0x2838,
  'deviceName': '/dev/bus/usb/001/002',
  'serial': '00000001',
  'manufacturer': 'Realtek',
  'product': 'RTL2838UHIDIR',
};

const Map<String, Object?> _hackrfParams = <String, Object?>{
  'fd': 7,
  'vid': 0x1d50,
  'pid': 0x6089,
  'deviceName': '/dev/bus/usb/001/003',
  'serial': '0000000000000000457863c8234e1a5f',
};

class _Ctx {
  final core = FakeCore();
  final errors = <(String, bool)>[];
  final saved = <String, Map<String, Object?>>{};
  late final SourceContext ctx = SourceContext(
    core: core,
    reportError: (m, {bool fatal = false}) => errors.add((m, fatal)),
    configLoad: (k) => saved[k],
    configSave: (k, c) => saved[k] = c,
  );
}

void main() {
  rtlsdrLog = (_) {};
  SourceLog.sink = (_, _) {};

  test('registerDeviceSources registers the usb source', () {
    final r = SourceRegistry.withBuiltins();
    registerDeviceSources(r);
    expect(r.contains(usbSourceId), isTrue);
    expect(r.contains('synth'), isTrue);
  });

  group('RTL-SDR controls', () {
    late _Ctx c;
    late List<MockUsbDeviceHandle> handles;
    late SourceInstance inst;
    late RtlSdrSourceModule m;

    setUp(() {
      c = _Ctx();
      handles = <MockUsbDeviceHandle>[];
      final model = FakeRtlUsbDevice(FakeModel.parse(_r820t));
      inst = createUsbSourceInstance(_rtlParams, c.ctx, opener: (p) {
        expect(p.fd, 42);
        final h = rtlMockHandle(model);
        handles.add(h);
        return h;
      });
      m = (inst.handler as UsbSourceHandler).module as RtlSdrSourceModule;
    });

    test('instance, settings and controls type', () {
      expect(inst.controls, isA<RtlSdrControls>());
      expect(m.gainList.length, 29);
      expect(inst.handler.settings.map((s) => s.id),
          containsAll(<String>['sampleRate', 'gain', 'tunerAgc', 'rtlAgc', 'ppm', 'biasT', 'directSampling']));
      inst.handler.select();
      expect(c.core.rates.last, 2400000);
    });

    test('gain dB -> nearest tuner table entry; AGC -> tuner AGC', () {
      final ctl = inst.controls;
      ctl.setGain(inst.handler, 29.7);
      expect(m.gainList[m.gainId], 297);
      expect(ctl.gainOf(inst.handler), closeTo(29.7, 1e-9));
      ctl.setGain(inst.handler, 30.1); // between 29.7 and 32.8
      expect(ctl.gainOf(inst.handler), closeTo(29.7, 1e-9));
      ctl.setGain(inst.handler, 100);
      expect(ctl.gainOf(inst.handler), closeTo(49.6, 1e-9));
      ctl.setGain(inst.handler, -5);
      expect(ctl.gainOf(inst.handler), 0);

      ctl.setAgc(inst.handler, true);
      expect(m.tunerAgc, isTrue);
      expect(m.rtlAgc, isFalse);
      expect(ctl.agcOf(inst.handler), isTrue);
      // Slider moved while AGC is on: remembered, applied when AGC goes off.
      ctl.setGain(inst.handler, 40.2);
      expect(ctl.gainOf(inst.handler), closeTo(40.2, 1e-9));
      ctl.setAgc(inst.handler, false);
      expect(ctl.agcOf(inst.handler), isFalse);
      expect(ctl.gainOf(inst.handler), closeTo(40.2, 1e-9));

      // Persisted per module under the SDR++ module name.
      final dev = (c.saved['rtl_sdr']!['devices'] as Map)['Realtek RTL2838UHIDIR [00000001]'] as Map;
      expect(dev['tunerAgc'], false);
    });

    test('sample rate -> nearest table entry', () {
      inst.controls.setSampleRate(inst.handler, 1.0e6);
      expect(m.sampleRate, 1024000);
      expect(c.core.rates.last, 1024000);
      inst.controls.setSampleRate(inst.handler, 2.4e6);
      expect(m.sampleRate, 2400000);
      expect(usbSdrSampleRates(UsbSdrKind.rtlSdr), rtlSdrSampleRates);
    });

    test('start/stop through the handler; running gain changes reach the device; stats', () async {
      final sink = SinkRecorder();
      await inst.handler.start(sink.call);
      expect(m.running, isTrue);
      final h = handles.last;
      h.streams.last.push(List<int>.filled(2048, 128));
      await pumpEventQueue();
      expect(sink.totalSamples, 1024);
      final before = h.controlTrace.length;
      inst.controls.setGain(inst.handler, 19.7);
      expect(h.controlTrace.length, greaterThan(before)); // I2C writes to the tuner
      expect(inst.stats!()['droppedBuffers'], 0);
      await inst.handler.stop();
      expect(m.running, isFalse);
    });

    test('start failure is thrown (engine keeps play state consistent)', () async {
      final c2 = _Ctx();
      final bad = createUsbSourceInstance(_rtlParams, c2.ctx,
          opener: (_) => rtlMockHandle(FakeRtlUsbDevice(FakeModel.parse(_r820t)))..unplug());
      await expectLater(bad.handler.start(SinkRecorder().call), throwsA(isA<StateError>()));
      expect(c2.errors, isNotEmpty);
    });

    // The device that could not be opened (fd refused / gone before select) must be reported
    // as such on Start, not as SDR++'s generic "No device selected" that hid the cause.
    test('open failure at select is the start failure reason', () async {
      final c2 = _Ctx();
      final bad = createUsbSourceInstance(_rtlParams, c2.ctx,
          opener: (_) => throw UsbException(UsbError.noDevice, 'gone'));
      expect(c2.errors.single.$1, startsWith('Could not open RTL-SDR'));
      await expectLater(
        bad.handler.start(SinkRecorder().call),
        throwsA(isA<StateError>().having((e) => e.message, 'message', startsWith('Could not open RTL-SDR'))),
      );
      expect(c2.errors.length, 1, reason: 'no second, misleading "No device selected" error');
    });
  });

  group('HackRF controls', () {
    test('combined gain split LNA/VGA, amp untouched', () {
      expect(hackrfSplitGain(0), (0.0, 0.0));
      expect(hackrfSplitGain(102), (40.0, 62.0));
      expect(hackrfSplitGain(200), (40.0, 62.0));
      expect(hackrfSplitGain(50), (16.0, 34.0));
      for (double g = 0; g <= 102; g += 2) {
        final (lna, vga) = hackrfSplitGain(g);
        expect(lna % 8, 0);
        expect(vga % 2, 0);
        expect((lna + vga - g).abs(), lessThanOrEqualTo(4), reason: 'g=$g');
      }

      final c = _Ctx();
      final inst = createUsbSourceInstance(_hackrfParams, c.ctx, opener: (_) => hackrfMockHandle());
      final m = (inst.handler as UsbSourceHandler).module as HackrfSourceModule;
      expect(inst.controls, isA<HackrfControls>());
      inst.controls.setGain(inst.handler, 50);
      expect(m.lna, 16);
      expect(m.vga, 34);
      expect(m.amp, isFalse);
      expect(inst.controls.gainOf(inst.handler), 50);
      expect(inst.controls.agcOf(inst.handler), isFalse);
      inst.controls.setSampleRate(inst.handler, 8e6);
      expect(m.sampleRate, 8000000);
      expect(c.saved.containsKey('hackrf'), isTrue);
      expect(usbSdrSampleRates(UsbSdrKind.hackrf).first, 2e6);
      expect(usbSdrHasAgc(UsbSdrKind.hackrf), isFalse);
    });
  });

  test('unsupported device (Airspy) is refused', () {
    final c = _Ctx();
    expect(() => createUsbSourceInstance(<String, Object?>{'fd': 1, 'vid': 0x1d50, 'pid': 0x60a1}, c.ctx),
        throwsA(isA<UnsupportedUsbSdrException>()));
  });

  group('DspEngine integration', () {
    late List<Map<String, Object?>> events;
    late DspEngine engine;
    late List<MockUsbDeviceHandle> handles;

    setUp(() {
      events = <Map<String, Object?>>[];
      handles = <MockUsbDeviceHandle>[];
      final r = SourceRegistry.withBuiltins();
      r.register(usbSourceId, (p, ctx) => createUsbSourceInstance(p, ctx, opener: (_) {
            final h = rtlMockHandle(FakeRtlUsbDevice(FakeModel.parse(_r820t)));
            handles.add(h);
            return h;
          }));
      engine = DspEngine(events.add, options: const DspEngineOptions(audio: 'null'), registry: r);
    });

    tearDown(() => engine.shutdown());

    Map<String, Object?> lastState() => events.lastWhere((e) => e[DspMsg.evt] == DspEvt.state);

    test('state carries gain / agc / source settings; fatal loss stops the engine', () async {
      await engine.handle(<String, Object?>{DspMsg.cmd: DspCmd.selectSource, 'id': 'usb', 'params': _rtlParams});
      expect(lastState()['sampleRate'], 2400000);
      await engine.handle(<String, Object?>{DspMsg.cmd: DspCmd.setGain, 'value': 29.7});
      expect(lastState()['gain'], closeTo(29.7, 1e-9));
      expect(lastState()['agc'], isFalse);
      final ids = (lastState()['sourceSettings'] as List).map((s) => (s as Map)['id']).toList();
      expect(ids, contains('tunerAgc'));
      await engine.handle(<String, Object?>{DspMsg.cmd: DspCmd.sourceSetting, 'id': 'rtlAgc', 'value': true});
      final rtlAgc = (lastState()['sourceSettings'] as List).cast<Map<Object?, Object?>>().firstWhere((s) => s['id'] == 'rtlAgc');
      expect(rtlAgc['value'], isTrue);

      await engine.handle(<String, Object?>{DspMsg.cmd: DspCmd.start});
      expect(engine.running, isTrue);
      handles.last.streams.last.push(List<int>.filled(11776, 127));
      await pumpEventQueue();
      expect(engine.statsMap()['droppedBuffers'], 0);
      expect(engine.core.iqFrontEnd.samplesIn, greaterThan(0));

      handles.last.unplug();
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(engine.running, isFalse);
      final err = events.lastWhere((e) => e[DspMsg.evt] == DspEvt.error);
      expect(err['fatal'], isTrue);
      expect(lastState()['running'], isFalse);

      // Restart after re-plug works (a fresh handle is opened).
      await engine.handle(<String, Object?>{DspMsg.cmd: DspCmd.start});
      expect(engine.running, isTrue);
      await engine.handle(<String, Object?>{DspMsg.cmd: DspCmd.stop});
    });

    test('start failure is acked as an error, engine not running', () async {
      final r = SourceRegistry.withBuiltins();
      r.register(usbSourceId,
          (p, ctx) => createUsbSourceInstance(p, ctx, opener: (_) => throw UsbException(UsbError.io, 'boom')));
      final ev = <Map<String, Object?>>[];
      final e2 = DspEngine(ev.add, options: const DspEngineOptions(audio: 'null'), registry: r);
      await e2.handle(<String, Object?>{DspMsg.cmd: DspCmd.selectSource, 'id': 'usb', 'params': _rtlParams});
      await e2.handle(<String, Object?>{DspMsg.cmd: DspCmd.start, DspMsg.req: 1});
      final ack = ev.lastWhere((e) => e[DspMsg.evt] == DspEvt.ack);
      expect(ack['ok'], isFalse);
      expect(e2.running, isFalse);
      await e2.shutdown();
    });
  });
}
