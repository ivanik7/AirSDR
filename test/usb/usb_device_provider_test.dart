// UsbDeviceProvider on mocked platform channels: filtering, names/rates, open → SourceSelection,
// close, attach events → changes + auto-select preference, initialDevice, graceful degradation
// without the plugin, 32-bit refusal; and SdrRadioController auto-selecting the attached device.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/runtime/device_sources.dart';
import 'package:sdr_flutter/runtime/dsp_engine.dart';
import 'package:sdr_flutter/runtime/sdr_radio_controller.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/rtl_sdr_source.dart';
import 'package:sdr_flutter/usb/android_usb.dart';
import 'package:sdr_flutter/usb/usb_device_provider.dart';
import 'package:sdr_flutter/usb/usb_transport.dart';

const _rtl = <String, Object?>{
  'deviceName': '/dev/bus/usb/001/002',
  'vid': 0x0bda,
  'pid': 0x2838,
  'manufacturer': 'Realtek',
  'product': 'RTL2838UHIDIR',
  'serial': null,
};
const _hackrf = <String, Object?>{
  'deviceName': '/dev/bus/usb/001/003',
  'vid': 0x1d50,
  'pid': 0x6089,
  'manufacturer': 'Great Scott Gadgets',
  'product': 'HackRF One',
  'serial': '0000000000000000457863c8234e1a5f',
};
const _mouse = <String, Object?>{'deviceName': '/dev/bus/usb/001/004', 'vid': 0x046d, 'pid': 0xc077};
const _airspy = <String, Object?>{'deviceName': '/dev/bus/usb/001/005', 'vid': 0x1d50, 'pid': 0x60a1};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('test/usb');
  const events = EventChannel('test/usb/events');

  late List<MethodCall> calls;
  late List<Map<String, Object?>> devices;
  Map<String, Object?>? initial;
  StreamController<Object?>? eventSink;

  setUp(() {
    calls = <MethodCall>[];
    devices = <Map<String, Object?>>[_rtl, _hackrf, _mouse, _airspy];
    initial = null;
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'listDevices':
          return devices.map((d) => d['deviceName'] == _rtl['deviceName'] && calls.any((c) => c.method == 'open')
              ? <String, Object?>{..._rtl, 'serial': '00000001'}
              : d).toList();
        case 'open':
          final name = (call.arguments as Map)['deviceName'];
          if (name == _hackrf['deviceName']) throw PlatformException(code: 'PERMISSION_DENIED', message: 'no');
          // A never-open fd number: on the host the usbfs transport fails with EBADF instead of
          // touching one of the test runner's descriptors.
          return <String, Object?>{'fd': 999999, 'vid': 0x0bda, 'pid': 0x2838};
        case 'close':
          return null;
        case 'initialDevice':
          return initial;
      }
      return null;
    });
    eventSink = StreamController<Object?>.broadcast();
    messenger.setMockStreamHandler(
        events,
        MockStreamHandler.inline(onListen: (args, sink) {
          eventSink!.stream.listen(sink.success);
        }));
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockStreamHandler(events, null);
    eventSink?.close();
  });

  UsbDeviceProvider provider({bool abi = true}) =>
      UsbDeviceProvider(usb: AndroidUsb(methods: methods, events: events), enabled: true, abiSupported: abi);

  test('lists only supported SDRs with names, rates and gain ranges', () async {
    final p = provider();
    final list = await p.listDevices();
    expect(list.map((d) => d.id), ['usb:/dev/bus/usb/001/002', 'usb:/dev/bus/usb/001/003']);
    expect(list[0].name, 'Realtek RTL2838UHIDIR (0bda:2838)');
    expect(list[0].sampleRates, rtlSdrSampleRates);
    expect(list[0].hasAgc, isTrue);
    expect(list[0].gain.max, 49.6);
    expect(list[1].name, 'HackRF One [457863c8234e1a5f]');
    expect(list[1].sampleRates.first, 2e6);
    expect(list[1].hasAgc, isFalse);
    expect(list[1].maxFrequency, 6e9);
    expect(list.every(p.owns), isTrue);
    expect(p.owns(SynthDeviceProvider.device), isFalse);
  });

  test('open -> SourceSelection(usb, {fd, vid, pid, deviceName, serial}); close', () async {
    final p = provider();
    final list = await p.listDevices();
    final sel = await p.open(list[0]);
    expect(sel.sourceId, usbSourceId);
    expect(sel.params['fd'], 999999);
    expect(sel.params['vid'], 0x0bda);
    expect(sel.params['pid'], 0x2838);
    expect(sel.params['deviceName'], '/dev/bus/usb/001/002');
    expect(sel.params['serial'], '00000001'); // re-read after permission
    await p.close(list[0]);
    await p.close(list[0]); // idempotent
    expect(calls.where((c) => c.method == 'close').length, 1);
  });

  test('permission denied -> UsbException(access)', () async {
    final p = provider();
    final list = await p.listDevices();
    await expectLater(
        p.open(list[1]), throwsA(isA<UsbException>().having((e) => e.code, 'code', UsbError.access)));
  });

  test('32-bit process: clear notSupported error, no open call', () async {
    final p = provider(abi: false);
    final list = await p.listDevices();
    await expectLater(
        p.open(list[0]),
        throwsA(isA<UsbException>()
            .having((e) => e.code, 'code', UsbError.notSupported)
            .having((e) => e.message, 'message', contains('64-bit'))));
    expect(calls.where((c) => c.method == 'open'), isEmpty);
  });

  test('attach event -> changes + preferredDevice; initialDevice', () async {
    initial = _hackrf;
    final p = provider();
    await p.listDevices();
    expect((await p.preferredDevice())?.id, 'usb:/dev/bus/usb/001/003');
    expect(await p.preferredDevice(), isNull); // initialDevice consumed once

    final changes = <void>[];
    final sub = p.changes.listen(changes.add);
    await pumpEventQueue();
    eventSink!.add(<String, Object?>{'event': 'attached', 'device': _mouse});
    eventSink!.add(<String, Object?>{'event': 'attached', 'device': _rtl});
    await pumpEventQueue();
    expect(changes.length, 1); // mouse ignored
    await p.listDevices();
    expect((await p.preferredDevice())?.id, 'usb:/dev/bus/usb/001/002');
    eventSink!.add(<String, Object?>{'event': 'detached', 'device': _rtl});
    await pumpEventQueue();
    expect(changes.length, 2);
    await sub.cancel();
  });

  test('without the platform plugin: no devices, no errors', () async {
    final p = UsbDeviceProvider(
        usb: AndroidUsb(methods: const MethodChannel('absent/usb'), events: const EventChannel('absent/ev')),
        enabled: true);
    expect(await p.listDevices(), isEmpty);
    final disabled = UsbDeviceProvider(); // host: Platform.isAndroid == false
    expect(disabled.enabled, isFalse);
    expect(await disabled.listDevices(), isEmpty);
    expect(await disabled.preferredDevice(), isNull);
    await expectLater(disabled.changes.isEmpty, completion(isTrue));
  });

  test('SdrRadioController auto-selects the device that launched the app', () async {
    initial = _rtl;
    final c = SdrRadioController(
      providers: <DeviceProvider>[provider(), SynthDeviceProvider()],
      options: const DspEngineOptions(audio: 'null'),
      registerSources: registerDeviceSources,
    );
    await c.ready;
    for (int i = 0; i < 50 && c.selectedDevice?.id != 'usb:/dev/bus/usb/001/002'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(c.devices.length, 3);
    expect(c.selectedDevice?.id, 'usb:/dev/bus/usb/001/002');
    // Opening fd 999999 on the host is not a usbfs device: the DSP isolate reports the error,
    // the controller stays usable.
    for (int i = 0; i < 100 && c.lastError == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(calls.where((x) => x.method == 'open'), isNotEmpty);
    expect(c.lastError, contains('RTL-SDR'));
    await c.selectDevice(SynthDeviceProvider.device);
    expect(calls.where((x) => x.method == 'close'), isNotEmpty);
    c.dispose();
  });
}
