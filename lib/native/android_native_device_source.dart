// SPDX-License-Identifier: GPL-3.0-or-later
//
// Standalone Android [NativeDeviceSource]: wires the native-only USB channel
// (android_usb_channel.dart) and device metadata (usb_device_catalog.dart)
// into the `NativeDeviceSource` interface used by `NativeRadioController`.
// Kotlin (UsbSdrPlugin.kt, 'sdr/usb') still owns the original
// UsbDeviceConnection/fd; this class only requests permission/open/close
// through the same MethodChannel and classifies/names the device for the
// native controller. ABI v3 duplicates the fd on open and closes only its
// duplicate (native_radio_controller.dart `NativeDeviceSource`).

import 'dart:async';

import 'package:flutter/services.dart' show MissingPluginException;

import '../ui/radio_controller.dart' show SdrDeviceInfo;
import 'android_usb_channel.dart';
import 'native_radio_controller.dart';
import 'sdr_core.dart';
import 'usb_device_catalog.dart';

/// Prefix of [NativeDevice.info.id] for Android USB devices; the rest is the
/// Kotlin-side deviceName (usbfs path).
const String nativeUsbDeviceIdPrefix = 'usb:';

/// Discovers, classifies and opens/closes Android USB SDR dongles for the
/// native controller, without depending on the Dart receive engine.
class AndroidNativeDeviceSource implements NativeDeviceSource {
  AndroidNativeDeviceSource({NativeAndroidUsbChannel? channel})
    : _channel = channel ?? NativeAndroidUsbChannel.instance;

  final NativeAndroidUsbChannel _channel;

  /// deviceName (usbfs path) -> last listed device, used by [open]/[close].
  final Map<String, NativeAndroidUsbDevice> _known = {};
  final Set<String> _openedDeviceNames = {};
  StreamController<void>? _changes;
  StreamSubscription<NativeAndroidUsbEvent>? _eventSub;

  static String _idOf(NativeAndroidUsbDevice d) =>
      '$nativeUsbDeviceIdPrefix${d.deviceName}';

  static NativeDevice _toNativeDevice(NativeAndroidUsbDevice d) {
    final kind = usbSdrKind(d.vendorId, d.productId);
    final (lo, hi) = usbSdrFrequencyRange(kind);
    return NativeDevice(
      SdrDeviceInfo(
        id: _idOf(d),
        name: usbSdrDisplayName(
          vid: d.vendorId,
          pid: d.productId,
          manufacturer: d.manufacturer,
          product: d.product,
          serial: d.serial,
        ),
        sampleRates: usbSdrSampleRates(kind),
        gain: usbSdrGainRange(kind),
        // ABI v3 has no device-specific AGC; never report the Dart driver's
        // tuner AGC as if the native source accepted it.
        hasAgc: false,
        minFrequency: lo,
        maxFrequency: hi,
      ),
      kind == UsbSdrKind.hackrf ? SdrSourceId.hackrf : SdrSourceId.rtlsdr,
    );
  }

  @override
  Future<List<NativeDevice>> list() async {
    List<NativeAndroidUsbDevice> devices;
    try {
      devices = await _channel.listDevices();
    } on MissingPluginException {
      // No platform channel (host/unit tests): no devices, no error.
      return const <NativeDevice>[];
    }
    _known
      ..clear()
      ..addEntries(<MapEntry<String, NativeAndroidUsbDevice>>[
        for (final d in devices)
          if (isSupportedUsbSdr(d.vendorId, d.productId))
            MapEntry<String, NativeAndroidUsbDevice>(d.deviceName, d),
      ]);
    return <NativeDevice>[for (final d in _known.values) _toNativeDevice(d)];
  }

  @override
  Future<NativeDevice> open(NativeDevice device) async {
    final deviceName = device.info.id.substring(nativeUsbDeviceIdPrefix.length);
    final result = await _channel.open(deviceName);
    _openedDeviceNames.add(deviceName);
    final kind = usbSdrKind(result.vendorId, result.productId);
    // Permission acquired by open() may make the serial visible for the first
    // time. Refresh identity before resolving a legacy per-dongle gain index.
    var info = device.info;
    try {
      final refreshed = await _channel.listDevices();
      for (final d in refreshed) {
        if (d.deviceName == deviceName && d.serial?.isNotEmpty == true) {
          info = _toNativeDevice(d).info;
          break;
        }
      }
    } catch (_) {
      // No verified serial: migration keeps its pending index for a later try.
    }
    return NativeDevice(
      info,
      kind == UsbSdrKind.hackrf ? SdrSourceId.hackrf : SdrSourceId.rtlsdr,
      fd: result.fd,
    );
  }

  @override
  Future<void> close(NativeDevice device) async {
    final deviceName = device.info.id.substring(nativeUsbDeviceIdPrefix.length);
    if (!_openedDeviceNames.remove(deviceName)) return;
    try {
      await _channel.close(deviceName);
    } catch (_) {
      // Already detached / channel gone.
    }
  }

  @override
  Stream<void> get changes {
    final c = _changes ??= StreamController<void>.broadcast(
      onListen: _listenEvents,
      onCancel: () {
        unawaited(_eventSub?.cancel());
        _eventSub = null;
      },
    );
    return c.stream;
  }

  void _listenEvents() {
    _eventSub ??= _channel.events.listen((e) {
      final supported = isSupportedUsbSdr(
        e.device.vendorId,
        e.device.productId,
      );
      if (!supported) return;
      if (e.type == NativeAndroidUsbEventType.detached) {
        _openedDeviceNames.remove(e.device.deviceName);
      }
      _changes?.add(null);
    }, onError: (Object _) {});
  }
}
