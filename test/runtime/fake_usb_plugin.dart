// SPDX-License-Identifier: GPL-3.0-or-later
// Mocked Android UsbSdrPlugin (the Kotlin side of lib/usb/android_usb.dart) on test channels,
// plus sample devices. Shared by the controller and widget tests of auto-connect / hot re-plug.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> fakeUsbDev(
  String name,
  int vid,
  int pid, [
  String? product,
]) => <String, Object?>{
  'deviceName': name,
  'vid': vid,
  'pid': pid,
  'manufacturer': 'M',
  'product': product,
};

final fakeRtl = fakeUsbDev('/dev/bus/usb/001/002', 0x0bda, 0x2838, 'Blog V4');
final fakeRtlReplugged = fakeUsbDev(
  '/dev/bus/usb/001/009',
  0x0bda,
  0x2838,
  'Blog V4',
); // new bus address
final fakeRtlOther = fakeUsbDev(
  '/dev/bus/usb/001/010',
  0x0ccd,
  0x00d3,
  'Cinergy',
); // another known_devices[] entry
final fakeSlowRtl = fakeUsbDev(
  '/dev/bus/usb/001/011',
  0x0bda,
  0x2838,
  'Slow tuner',
);
final fakeHackrf = fakeUsbDev(
  '/dev/bus/usb/001/003',
  0x1d50,
  0x6089,
  'HackRF One',
);
final fakeMouse = fakeUsbDev('/dev/bus/usb/001/004', 0x046d, 0xc077);
final fakeAirspy = fakeUsbDev(
  '/dev/bus/usb/001/005',
  0x1d50,
  0x60a1,
); // known, but no driver

/// Mocked UsbSdrPlugin (Kotlin) on test channels.
class FakeUsbPlugin {
  FakeUsbPlugin(this.methods, this.events);

  final MethodChannel methods;
  final EventChannel events;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final List<Map<String, Object?>> devices = <Map<String, Object?>>[];
  final Set<String> deny = <String>{};
  final List<String> opens = <String>[];
  final List<String> closes = <String>[];
  Completer<void>? permissionResponse;
  Map<String, Object?>? initial;
  final StreamController<Object?> _events =
      StreamController<Object?>.broadcast();

  void install() {
    messenger.setMockMethodCallHandler(methods, (call) async {
      final args = call.arguments is Map
          ? (call.arguments as Map).cast<String, Object?>()
          : const <String, Object?>{};
      switch (call.method) {
        case 'listDevices':
          return devices;
        case 'open':
          final name = args['deviceName'] as String;
          opens.add(name);
          await permissionResponse?.future;
          final d = devices.where((e) => e['deviceName'] == name).firstOrNull;
          if (d == null) {
            throw PlatformException(
              code: 'NOT_FOUND',
              message: 'no device $name',
            );
          }
          if (deny.contains(name)) {
            throw PlatformException(
              code: 'PERMISSION_DENIED',
              message: 'denied',
            );
          }
          return <String, Object?>{
            'fd': 999999,
            'vid': d['vid'],
            'pid': d['pid'],
          };
        case 'close':
          closes.add(args['deviceName'] as String);
          return null;
        case 'hasPermission':
          return !deny.contains(args['deviceName']);
        case 'initialDevice':
          return initial;
      }
      return null;
    });
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        // Block body: MockStreamHandler would encode a returned subscription as an error.
        onListen: (args, sink) {
          _events.stream.listen(sink.success);
        },
      ),
    );
  }

  void uninstall() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockStreamHandler(events, null);
    _events.close();
  }

  void attach(Map<String, Object?> d) {
    devices.add(d);
    _events.add(<String, Object?>{'event': 'attached', 'device': d});
  }

  void detach(Map<String, Object?> d) {
    devices.removeWhere((e) => e['deviceName'] == d['deviceName']);
    _events.add(<String, Object?>{'event': 'detached', 'device': d});
  }

  /// A non-SDR device event (only makes the provider re-list, like a USB hub/mouse).
  void otherEvent() =>
      _events.add(<String, Object?>{'event': 'attached', 'device': fakeMouse});
}
