// AndroidUsb channel wrapper tests (mocked platform channels) and a check that
// res/xml/device_filter.xml contains every librtlsdr known_devices[] entry.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/usb/android_usb.dart';
import 'package:sdr_flutter/usb/usb_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = AndroidUsb.defaultMethodChannel;

  tearDown(() => messenger.setMockMethodCallHandler(methods, null));

  test('listDevices / open / close', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'listDevices':
          return [
            {
              'deviceName': '/dev/bus/usb/001/002',
              'vid': 0x0bda,
              'pid': 0x2838,
              'manufacturer': 'Realtek',
              'product': 'RTL2838UHIDIR',
              'serial': null,
            },
          ];
        case 'open':
          return {'fd': 42, 'vid': 0x0bda, 'pid': 0x2838};
        case 'close':
          return null;
      }
      return null;
    });
    final usb = AndroidUsb();
    final devs = await usb.listDevices();
    expect(devs.single.deviceName, '/dev/bus/usb/001/002');
    expect(devs.single.vidPid, '0bda:2838');
    expect(devs.single.serial, isNull);
    final r = await usb.open(devs.single.deviceName);
    expect(r.fd, 42);
    await usb.close(devs.single.deviceName);
    expect(calls.map((c) => c.method), ['listDevices', 'open', 'close']);
    expect(calls[1].arguments, {'deviceName': '/dev/bus/usb/001/002'});
  });

  test('permission denied -> UsbException(access)', () async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      throw PlatformException(code: 'PERMISSION_DENIED', message: 'denied');
    });
    await expectLater(
      AndroidUsb().open('/dev/bus/usb/001/002'),
      throwsA(
        isA<UsbException>().having((e) => e.code, 'code', UsbError.access),
      ),
    );
  });

  test('events are decoded', () async {
    const events = AndroidUsb.defaultEventChannel;
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (args, sink) {
          sink.success({
            'event': 'attached',
            'device': {
              'deviceName': '/dev/bus/usb/001/003',
              'vid': 0x1d50,
              'pid': 0x6089,
            },
          });
          sink.success({'event': 'bogus'});
          sink.success({
            'event': 'detached',
            'device': {
              'deviceName': '/dev/bus/usb/001/003',
              'vid': 0x1d50,
              'pid': 0x6089,
            },
          });
          sink.endOfStream();
        },
      ),
    );
    final got = await AndroidUsb().events.toList();
    expect(got.map((e) => e.type), [
      AndroidUsbEventType.attached,
      AndroidUsbEventType.detached,
    ]);
    expect(got.first.device.vidPid, '1d50:6089');
  });

  test(
    'device_filter.xml covers librtlsdr known_devices[] + HackRF + Airspy',
    () {
      final xml = File('android/app/src/main/res/xml/device_filter.xml')
          .readAsStringSync();
      final filter = RegExp(r'vendor-id="(\d+)" product-id="(\d+)"')
          .allMatches(xml)
          .map((m) => (int.parse(m[1]!), int.parse(m[2]!)))
          .toSet();

      final src = File('~/prj/ref/rtl-sdr/src/librtlsdr.c');
      if (src.existsSync()) {
        final c = src.readAsStringSync();
        final start = c.indexOf('known_devices[] = {');
        final block = c.substring(start, c.indexOf('};', start));
        final known = RegExp(r'\{\s*0x([0-9a-fA-F]{4}),\s*0x([0-9a-fA-F]{4}),')
            .allMatches(block)
            .map(
              (m) => (int.parse(m[1]!, radix: 16), int.parse(m[2]!, radix: 16)),
            )
            .toSet();
        expect(known.length, 42);
        expect(
          filter.containsAll(known),
          isTrue,
          reason: 'missing: ${known.difference(filter)}',
        );
      }
      for (final id in [
        (0x1d50, 0x6089), // HackRF One
        (0x1d50, 0x604b), // Jawbreaker
        (0x1d50, 0xcc15), // rad1o
        (0x1d50, 0x60a1), // Airspy
        (0x03eb, 0x800c), // Airspy HF+
        (0x0bda, 0x2838),
      ]) {
        expect(filter, contains(id));
      }
      expect(filter.length, 47);
    },
  );
}
