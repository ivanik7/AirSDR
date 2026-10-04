// SPDX-License-Identifier: GPL-3.0-or-later
//
// Standalone Android USB discovery/permission/fd channel for the native
// (ABI v3) controller. Talks to the same Kotlin plugin and MethodChannel
// contract provided by UsbSdrPlugin.kt:
// Kotlin enumerates devices, owns permission requests and the
// UsbDeviceConnection that owns the usbfs fd ("sdr/usb" open/close path).
// lib/native/ never reimplements that: it only talks to the existing
// channel/event names and must not import lib/usb, lib/runtime or
// lib/sdrpp.
//
//   MethodChannel 'sdr/usb':
//     listDevices() -> List<Map>{deviceName, vid, pid, manufacturer, product, serial}
//     open(deviceName) -> Map{fd, vid, pid}   (asks for permission if needed)
//     close(deviceName) -> null
//     initialDevice() -> Map? (device that launched the activity via USB_DEVICE_ATTACHED)
//   EventChannel 'sdr/usb/events':
//     Map{event: 'attached'|'detached', device: {deviceName, vid, pid, ...}}
//
// The fd handed back by "open" is owned by Kotlin's UsbDeviceConnection and
// must never be closed from Dart; `sdr_v2_open_usb` (shared ABI open hook)
// dup()s it and the native side closes only its own duplicate (see
// NativeDeviceSource in native_radio_controller.dart).

import 'dart:async';

import 'package:flutter/services.dart';

/// One USB device as reported by UsbManager.getDeviceList(), decoded from the
/// 'sdr/usb' channel maps. Independent of the retired Dart USB transport.
class NativeAndroidUsbDevice {
  const NativeAndroidUsbDevice({
    required this.deviceName,
    required this.vendorId,
    required this.productId,
    this.manufacturer,
    this.product,
    this.serial,
  });

  /// /dev/bus/usb/BBB/DDD — key for open/close.
  final String deviceName;
  final int vendorId;
  final int productId;
  final String? manufacturer;
  final String? product;

  /// null when the app has no permission yet (Android hides it) or none exists.
  final String? serial;

  factory NativeAndroidUsbDevice.fromMap(Map<Object?, Object?> m) =>
      NativeAndroidUsbDevice(
        deviceName: m['deviceName'] as String,
        vendorId: m['vid'] as int,
        productId: m['pid'] as int,
        manufacturer: m['manufacturer'] as String?,
        product: m['product'] as String?,
        serial: m['serial'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is NativeAndroidUsbDevice &&
      other.deviceName == deviceName &&
      other.vendorId == vendorId &&
      other.productId == productId;

  @override
  int get hashCode => Object.hash(deviceName, vendorId, productId);

  @override
  String toString() =>
      'NativeAndroidUsbDevice($deviceName '
      '${vendorId.toRadixString(16)}:${productId.toRadixString(16)} '
      '${manufacturer ?? ''} ${product ?? ''} ${serial ?? ''})';
}

/// Result of [NativeAndroidUsbChannel.open]: a usbfs fd owned by Kotlin.
class NativeAndroidUsbOpenResult {
  const NativeAndroidUsbOpenResult(this.fd, this.vendorId, this.productId);
  final int fd;
  final int vendorId;
  final int productId;

  factory NativeAndroidUsbOpenResult.fromMap(Map<Object?, Object?> m) =>
      NativeAndroidUsbOpenResult(
        m['fd'] as int,
        m['vid'] as int,
        m['pid'] as int,
      );
}

enum NativeAndroidUsbEventType { attached, detached }

class NativeAndroidUsbEvent {
  const NativeAndroidUsbEvent(this.type, this.device);
  final NativeAndroidUsbEventType type;
  final NativeAndroidUsbDevice device;

  static NativeAndroidUsbEvent? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final type = switch (raw['event']) {
      'attached' => NativeAndroidUsbEventType.attached,
      'detached' => NativeAndroidUsbEventType.detached,
      _ => null,
    };
    final dev = raw['device'];
    if (type == null || dev is! Map) return null;
    return NativeAndroidUsbEvent(type, NativeAndroidUsbDevice.fromMap(dev));
  }
}

/// Thrown by [NativeAndroidUsbChannel] on a failed open/permission request.
class NativeAndroidUsbException implements Exception {
  const NativeAndroidUsbException(this.code, this.message);

  /// PlatformException code from UsbSdrPlugin: 'PERMISSION_DENIED',
  /// 'NOT_FOUND', 'OPEN_FAILED', 'BUSY', 'BAD_ARGS', or 'OTHER'.
  final String code;
  final String message;

  @override
  String toString() => 'NativeAndroidUsbException($code): $message';
}

/// Dart control-plane client for the Android USB platform channels.
class NativeAndroidUsbChannel {
  NativeAndroidUsbChannel({MethodChannel? methods, EventChannel? events})
    : _methods = methods ?? defaultMethodChannel,
      _events = events ?? defaultEventChannel;

  static const MethodChannel defaultMethodChannel = MethodChannel('sdr/usb');
  static const EventChannel defaultEventChannel = EventChannel(
    'sdr/usb/events',
  );

  static final NativeAndroidUsbChannel instance = NativeAndroidUsbChannel();

  final MethodChannel _methods;
  final EventChannel _events;
  Stream<NativeAndroidUsbEvent>? _eventStream;

  Future<List<NativeAndroidUsbDevice>> listDevices() async {
    final r = await _methods.invokeListMethod<Object?>('listDevices');
    return [
      for (final m in r ?? const <Object?>[])
        if (m is Map) NativeAndroidUsbDevice.fromMap(m),
    ];
  }

  /// Opens [deviceName] (requesting permission from the user if needed) and
  /// returns its usbfs fd. Throws [NativeAndroidUsbException].
  Future<NativeAndroidUsbOpenResult> open(String deviceName) async {
    try {
      final r = await _methods.invokeMapMethod<Object?, Object?>('open', {
        'deviceName': deviceName,
      });
      if (r == null) {
        throw const NativeAndroidUsbException('OTHER', 'open() returned null');
      }
      return NativeAndroidUsbOpenResult.fromMap(r);
    } on PlatformException catch (e) {
      throw NativeAndroidUsbException(
        e.code,
        'open($deviceName): ${e.code} ${e.message ?? ''}',
      );
    }
  }

  /// Releases the UsbDeviceConnection (closes the fd). Stop native streaming
  /// and close the native handle's own fd duplicate first.
  Future<void> close(String deviceName) async {
    await _methods.invokeMethod<void>('close', {'deviceName': deviceName});
  }

  /// Device that launched the activity via USB_DEVICE_ATTACHED (permission is
  /// already granted in that case), or null.
  Future<NativeAndroidUsbDevice?> initialDevice() async {
    final r = await _methods.invokeMapMethod<Object?, Object?>('initialDevice');
    return r == null ? null : NativeAndroidUsbDevice.fromMap(r);
  }

  /// Attach/detach events (broadcast).
  Stream<NativeAndroidUsbEvent> get events => _eventStream ??= _events
      .receiveBroadcastStream()
      .map(NativeAndroidUsbEvent.fromMap)
      .where((e) => e != null)
      .cast<NativeAndroidUsbEvent>()
      .asBroadcastStream();
}
