// SPDX-License-Identifier: GPL-3.0-or-later
//
// Regression tests for lib/native/android_native_device_source.dart: USB
// discovery filtering, open -> fd/driver mapping (no shared ownership with
// the Dart usbfs transport), close, and attach/detach change notifications,
// all through mocked 'sdr/usb' platform channels (no real Kotlin plugin).

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/native/android_native_device_source.dart';
import 'package:sdr_flutter/native/android_usb_channel.dart';
import 'package:sdr_flutter/native/sdr_core.dart';

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
const _mouse = <String, Object?>{
  'deviceName': '/dev/bus/usb/001/004',
  'vid': 0x046d,
  'pid': 0xc077,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('test/native_usb');
  const events = EventChannel('test/native_usb/events');

  late List<MethodCall> calls;
  late List<Map<String, Object?>> devices;
  StreamController<Object?>? eventSink;

  setUp(() {
    calls = <MethodCall>[];
    devices = <Map<String, Object?>>[_rtl, _hackrf, _mouse];
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'listDevices':
          return devices;
        case 'open':
          final name = (call.arguments as Map)['deviceName'];
          if (name == _hackrf['deviceName']) {
            throw PlatformException(code: 'PERMISSION_DENIED', message: 'no');
          }
          return <String, Object?>{'fd': 777, 'vid': 0x0bda, 'pid': 0x2838};
        case 'close':
          return null;
      }
      return null;
    });
    eventSink = StreamController<Object?>.broadcast();
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (args, sink) {
          eventSink!.stream.listen(sink.success);
        },
      ),
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockStreamHandler(events, null);
    eventSink?.close();
  });

  AndroidNativeDeviceSource source() => AndroidNativeDeviceSource(
    channel: NativeAndroidUsbChannel(methods: methods, events: events),
  );

  test('lists only supported SDRs with native metadata (hasAgc always false)', () async {
    final s = source();
    final list = await s.list();
    expect(list.map((d) => d.info.id), [
      'usb:/dev/bus/usb/001/002',
      'usb:/dev/bus/usb/001/003',
    ]);
    expect(list[0].info.name, 'Realtek RTL2838UHIDIR (0bda:2838)');
    expect(list[0].info.hasAgc, isFalse);
    expect(list[0].source, SdrSourceId.rtlsdr);
    expect(list[1].info.name, 'HackRF One [457863c8234e1a5f]');
    expect(list[1].info.hasAgc, isFalse);
    expect(list[1].source, SdrSourceId.hackrf);
  });

  test('open() returns the Kotlin-owned fd, not a Dart-duplicated one', () async {
    final s = source();
    final list = await s.list();
    final opened = await s.open(list[0]);
    expect(opened.fd, 777);
    expect(opened.source, SdrSourceId.rtlsdr);
    expect(calls.where((c) => c.method == 'open').single.arguments, {
      'deviceName': '/dev/bus/usb/001/002',
    });
  });

  test('close() is idempotent and only closes a device this source opened', () async {
    final s = source();
    final list = await s.list();
    final opened = await s.open(list[0]);
    await s.close(opened);
    await s.close(opened); // idempotent: no second platform call
    expect(calls.where((c) => c.method == 'close').length, 1);
  });

  test('permission denied surfaces as a PlatformException-derived error', () async {
    final s = source();
    final list = await s.list();
    await expectLater(s.open(list[1]), throwsA(isA<Exception>()));
  });

  test('attach/detach events notify changes; unsupported devices are ignored', () async {
    final s = source();
    await s.list();
    final seen = <void>[];
    final sub = s.changes.listen(seen.add);
    await pumpEventQueue();
    eventSink!.add(<String, Object?>{'event': 'attached', 'device': _mouse});
    await pumpEventQueue();
    expect(seen, isEmpty); // mouse is not a supported SDR
    eventSink!.add(<String, Object?>{'event': 'attached', 'device': _hackrf});
    await pumpEventQueue();
    expect(seen.length, 1);
    eventSink!.add(<String, Object?>{'event': 'detached', 'device': _hackrf});
    await pumpEventQueue();
    expect(seen.length, 2);
    await sub.cancel();
  });

  test('without the platform plugin: no devices, no thrown errors', () async {
    final s = AndroidNativeDeviceSource(
      channel: NativeAndroidUsbChannel(
        methods: const MethodChannel('absent/native_usb'),
        events: const EventChannel('absent/native_usb/events'),
      ),
    );
    expect(await s.list(), isEmpty);
  });
}
