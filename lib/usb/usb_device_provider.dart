// SPDX-License-Identifier: GPL-3.0-or-later
// DeviceProvider for USB SDR dongles (RTL-SDR, HackRF) on top of the Android plugin
// (lib/usb/android_usb.dart ↔ android/.../UsbSdrPlugin.kt).
//
//  * listDevices: UsbManager device list filtered by [isSupportedUsbSdr]; names from
//    [usbSdrDisplayName]; sample rates / gain range per device kind (device_sources.dart).
//  * open: permission dialog (if needed) + fd → `SourceSelection('usb', {fd, vid, pid,
//    deviceName, serial, manufacturer, product})`, the params of createUsbSource.
//  * close: releases the Kotlin UsbDeviceConnection (closes the fd).
//  * changes: attach/detach events.
//  * preferredDevice: the device that launched the app via USB_DEVICE_ATTACHED, or the last
//    attached supported device → the controller auto-selects it.
//  * autoConnect: every supported device (same VID:PID registry as device_filter.xml and
//    registerDeviceSources: [isSupportedUsbSdr]) is connected and started by the controller
//    without manual selection / Start.
//
// Replaces SDR++ core/backends/android/backend.cpp getDeviceFD() + the per-module
// VID:PID tables (docs/01 §3.4).
//
// Degrades gracefully without the platform channel (host tests, non-Android): no devices, no
// events, no errors.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../runtime/device_sources.dart';
import '../runtime/sdr_radio_controller.dart';
import '../sdrpp/modules/sources/usb_source_factory.dart';
import '../ui/radio_controller.dart';
import 'android_usb.dart';
import 'usb_transport.dart';
import 'usbfs_abi.dart' show usbfsAbiSupported;

/// Prefix of [SdrDeviceInfo.id] for USB devices; the rest is the usbfs path.
const String usbDeviceIdPrefix = 'usb:';

class UsbDeviceProvider extends DeviceProvider {
  UsbDeviceProvider({AndroidUsb? usb, bool? enabled, bool? abiSupported})
    : _usb = usb ?? AndroidUsb.instance,
      enabled = enabled ?? Platform.isAndroid,
      abiSupported = abiSupported ?? usbfsAbiSupported;

  final AndroidUsb _usb;

  /// False when the platform channel does not exist (host / tests).
  final bool enabled;

  /// usbfs transport needs a 64-bit process (lib/usb/usbfs_abi.dart).
  final bool abiSupported;

  final Map<String, AndroidUsbDevice> _known = <String, AndroidUsbDevice>{};
  final Set<String> _opened = <String>{};
  StreamController<void>? _changes;
  StreamSubscription<AndroidUsbEvent>? _eventSub;
  String? _pendingPreferred;
  bool _initialChecked = false;

  static String idOf(AndroidUsbDevice d) => '$usbDeviceIdPrefix${d.deviceName}';

  /// UI description of a USB device.
  static SdrDeviceInfo infoOf(AndroidUsbDevice d) {
    final kind = usbSdrKind(d.vendorId, d.productId);
    final (fMin, fMax) = usbSdrFrequencyRange(kind);
    return SdrDeviceInfo(
      id: idOf(d),
      name: usbSdrDisplayName(
        vid: d.vendorId,
        pid: d.productId,
        manufacturer: d.manufacturer,
        product: d.product,
        serial: d.serial,
      ),
      sampleRates: usbSdrSampleRates(kind),
      gain: usbSdrGainRange(kind),
      hasAgc: usbSdrHasAgc(kind),
      minFrequency: fMin,
      maxFrequency: fMax,
    );
  }

  static bool _isMissing(Object e) => e is MissingPluginException;

  @override
  Future<List<SdrDeviceInfo>> listDevices() async {
    if (!enabled) return const <SdrDeviceInfo>[];
    List<AndroidUsbDevice> devs;
    try {
      devs = await _usb.listDevices();
    } catch (e) {
      if (_isMissing(e)) return const <SdrDeviceInfo>[];
      rethrow;
    }
    _known
      ..clear()
      ..addEntries(<MapEntry<String, AndroidUsbDevice>>[
        for (final d in devs)
          if (isSupportedUsbSdr(d.vendorId, d.productId))
            MapEntry<String, AndroidUsbDevice>(idOf(d), d),
      ]);
    return <SdrDeviceInfo>[for (final d in _known.values) infoOf(d)];
  }

  @override
  bool owns(SdrDeviceInfo device) => device.id.startsWith(usbDeviceIdPrefix);

  @override
  bool get autoConnect => enabled;

  @override
  Future<SourceSelection> open(SdrDeviceInfo device) async {
    if (!abiSupported) {
      throw UsbException(
        UsbError.notSupported,
        'USB SDR access needs a 64-bit (arm64-v8a) build; this process is 32-bit',
      );
    }
    final d = _known[device.id];
    if (d == null) {
      throw UsbException(UsbError.notFound, '${device.name} is not connected');
    }
    final r = await _usb.open(d.deviceName);
    _opened.add(d.deviceName);
    // listDevices may hide the serial until permission is granted: re-read it now.
    AndroidUsbDevice dev = d;
    if (d.serial == null) {
      try {
        dev = (await _usb.listDevices()).firstWhere(
          (e) => e.deviceName == d.deviceName,
          orElse: () => d,
        );
      } catch (_) {}
    }
    return SourceSelection(usbSourceId, <String, Object?>{
      ...dev.toMap(),
      'fd': r.fd,
      'vid': r.vendorId,
      'pid': r.productId,
    });
  }

  @override
  Future<void> close(SdrDeviceInfo device) async {
    final name = device.id.substring(usbDeviceIdPrefix.length);
    if (!_opened.remove(name)) return;
    try {
      await _usb.close(name);
    } catch (_) {
      // Already detached / channel gone.
    }
  }

  @override
  Stream<void> get changes {
    if (!enabled) return const Stream<void>.empty();
    final c = _changes ??= StreamController<void>.broadcast(
      onListen: _listenEvents,
      onCancel: () {
        _eventSub?.cancel();
        _eventSub = null;
      },
    );
    return c.stream;
  }

  void _listenEvents() {
    _eventSub ??= _usb.events.listen((e) {
      final supported = isSupportedUsbSdr(
        e.device.vendorId,
        e.device.productId,
      );
      if (!supported) return;
      if (e.type == AndroidUsbEventType.attached) {
        _pendingPreferred = idOf(e.device);
      } else {
        _opened.remove(e.device.deviceName);
        if (_pendingPreferred == idOf(e.device)) _pendingPreferred = null;
      }
      _changes?.add(null);
    }, onError: (Object _) {});
  }

  @override
  Future<SdrDeviceInfo?> preferredDevice() async {
    if (!enabled) return null;
    // The attach event may arrive after the caller's listDevices() (the refresh queued by
    // that very event runs later): keep it pending until the device is actually listed.
    String? id = _pendingPreferred;
    if (id != null && _known.containsKey(id)) _pendingPreferred = null;
    if (id == null && !_initialChecked) {
      _initialChecked = true;
      try {
        final d = await _usb.initialDevice();
        if (d != null && isSupportedUsbSdr(d.vendorId, d.productId)) {
          id = idOf(d);
        }
      } catch (_) {}
    }
    final d = id == null ? null : _known[id];
    return d == null ? null : infoOf(d);
  }
}
