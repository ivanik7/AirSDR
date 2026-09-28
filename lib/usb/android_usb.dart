// Dart side of the Android USB platform channels implemented by
// android/app/src/main/kotlin/net/ivanik/sdr_flutter/UsbSdrPlugin.kt.
//
//   MethodChannel 'sdr/usb':
//     listDevices() -> List<Map>{deviceName, vid, pid, manufacturer, product, serial}
//     open(deviceName) -> Map{fd, vid, pid}   (asks for permission if needed)
//     close(deviceName) -> null
//     hasPermission(deviceName) -> bool
//     initialDevice() -> Map? (device that launched the activity via USB_DEVICE_ATTACHED)
//   EventChannel 'sdr/usb/events':
//     Map{event: 'attached'|'detached', device: {deviceName, vid, pid, ...}}
//
// Kotlin keeps the UsbDeviceConnection alive until close(deviceName) or detach;
// never close() the fd from Dart (docs/01 §5.4).
//
// Replaces SDR++ core/backends/android/backend.cpp getDeviceFD() (:282-324) with a
// multi-device API (docs/01 §3.4, §5.3).
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/services.dart';

import 'usb_transport.dart';

/// One USB device as reported by UsbManager.getDeviceList().
class AndroidUsbDevice {
  /// /dev/bus/usb/BBB/DDD — key for open/close.
  final String deviceName;
  final int vendorId;
  final int productId;
  final String? manufacturer;
  final String? product;

  /// null when the app has no permission yet (Android hides it) or none exists.
  final String? serial;

  const AndroidUsbDevice({
    required this.deviceName,
    required this.vendorId,
    required this.productId,
    this.manufacturer,
    this.product,
    this.serial,
  });

  factory AndroidUsbDevice.fromMap(Map<Object?, Object?> m) => AndroidUsbDevice(
    deviceName: m['deviceName'] as String,
    vendorId: m['vid'] as int,
    productId: m['pid'] as int,
    manufacturer: m['manufacturer'] as String?,
    product: m['product'] as String?,
    serial: m['serial'] as String?,
  );

  Map<String, Object?> toMap() => {
    'deviceName': deviceName,
    'vid': vendorId,
    'pid': productId,
    'manufacturer': manufacturer,
    'product': product,
    'serial': serial,
  };

  String get vidPid =>
      '${vendorId.toRadixString(16).padLeft(4, '0')}:${productId.toRadixString(16).padLeft(4, '0')}';

  @override
  String toString() =>
      'AndroidUsbDevice($deviceName $vidPid ${manufacturer ?? ''} ${product ?? ''} ${serial ?? ''})';

  @override
  bool operator ==(Object other) =>
      other is AndroidUsbDevice &&
      other.deviceName == deviceName &&
      other.vendorId == vendorId &&
      other.productId == productId;

  @override
  int get hashCode => Object.hash(deviceName, vendorId, productId);
}

/// Result of [AndroidUsb.open]: a usbfs fd owned by Kotlin.
class AndroidUsbOpenResult {
  final int fd;
  final int vendorId;
  final int productId;
  const AndroidUsbOpenResult(this.fd, this.vendorId, this.productId);
  factory AndroidUsbOpenResult.fromMap(Map<Object?, Object?> m) =>
      AndroidUsbOpenResult(m['fd'] as int, m['vid'] as int, m['pid'] as int);
}

enum AndroidUsbEventType { attached, detached }

class AndroidUsbEvent {
  final AndroidUsbEventType type;
  final AndroidUsbDevice device;
  const AndroidUsbEvent(this.type, this.device);

  static AndroidUsbEvent? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final type = switch (raw['event']) {
      'attached' => AndroidUsbEventType.attached,
      'detached' => AndroidUsbEventType.detached,
      _ => null,
    };
    final dev = raw['device'];
    if (type == null || dev is! Map) return null;
    return AndroidUsbEvent(type, AndroidUsbDevice.fromMap(dev));
  }

  @override
  String toString() => 'AndroidUsbEvent(${type.name}, $device)';
}

/// Map a PlatformException code from UsbSdrPlugin to a libusb error code.
int usbErrorFromPlatformCode(String code) => switch (code) {
  'PERMISSION_DENIED' => UsbError.access,
  'NOT_FOUND' => UsbError.notFound,
  'OPEN_FAILED' => UsbError.io,
  'BUSY' => UsbError.busy,
  'BAD_ARGS' => UsbError.invalidParam,
  _ => UsbError.other,
};

class AndroidUsb {
  static const MethodChannel defaultMethodChannel = MethodChannel('sdr/usb');
  static const EventChannel defaultEventChannel = EventChannel(
    'sdr/usb/events',
  );

  final MethodChannel _methods;
  final EventChannel _events;
  Stream<AndroidUsbEvent>? _eventStream;

  AndroidUsb({MethodChannel? methods, EventChannel? events})
    : _methods = methods ?? defaultMethodChannel,
      _events = events ?? defaultEventChannel;

  static final AndroidUsb instance = AndroidUsb();

  Future<List<AndroidUsbDevice>> listDevices() async {
    final r = await _methods.invokeListMethod<Object?>('listDevices');
    return [
      for (final m in r ?? const <Object?>[])
        if (m is Map) AndroidUsbDevice.fromMap(m),
    ];
  }

  /// Open [deviceName] (requesting permission from the user if needed) and
  /// return its usbfs fd. Throws [UsbException].
  Future<AndroidUsbOpenResult> open(String deviceName) async {
    try {
      final r = await _methods.invokeMapMethod<Object?, Object?>('open', {
        'deviceName': deviceName,
      });
      if (r == null) {
        throw UsbException(UsbError.other, 'open($deviceName) returned null');
      }
      return AndroidUsbOpenResult.fromMap(r);
    } on PlatformException catch (e) {
      throw UsbException(
        usbErrorFromPlatformCode(e.code),
        'open($deviceName): ${e.code} ${e.message ?? ''}',
      );
    }
  }

  Future<bool> hasPermission(String deviceName) async {
    final r = await _methods.invokeMethod<bool>('hasPermission', {
      'deviceName': deviceName,
    });
    return r ?? false;
  }

  /// Release the UsbDeviceConnection (closes the fd). Stop all streams and
  /// close the Dart handle first.
  Future<void> close(String deviceName) async {
    await _methods.invokeMethod<void>('close', {'deviceName': deviceName});
  }

  /// Device that launched the activity via USB_DEVICE_ATTACHED (permission is
  /// already granted in that case), or null.
  Future<AndroidUsbDevice?> initialDevice() async {
    final r = await _methods.invokeMapMethod<Object?, Object?>('initialDevice');
    return r == null ? null : AndroidUsbDevice.fromMap(r);
  }

  /// Attach/detach events (broadcast).
  Stream<AndroidUsbEvent> get events => _eventStream ??= _events
      .receiveBroadcastStream()
      .map(AndroidUsbEvent.fromMap)
      .where((e) => e != null)
      .cast<AndroidUsbEvent>()
      .asBroadcastStream();
}
