// USB device -> SDR++ source module factory.
//
// Replaces SDR++'s per-module Android device lookup
// (core/backends/android/backend.cpp getDeviceFD(vid, pid, allowed) with the
// RTL_SDR_VIDPIDS / HACKRF_VIDPIDS / AIRSPY_VIDPIDS tables, :397-440): given
// the (vid, pid) of a device opened by the Android plugin, pick the driver
// and create the matching [SourceHandler] on the DSP isolate.
//
//   RTL-SDR : librtlsdr known_devices[] (librtlsdr.c:309-352)
//   HackRF  : 1d50:604b Jawbreaker, 1d50:6089 HackRF One, 1d50:cc15 rad1o
//   Airspy  : 1d50:60a1 R2/Mini, 03eb:800c HF+  -> not supported (no driver)
//
// SPDX-License-Identifier: GPL-3.0-or-later

import '../../../drivers/hackrf/hackrf.dart';
import '../../../drivers/rtlsdr/librtlsdr.dart';
import '../../../usb/usb_transport.dart';
import '../../signal_path/source_handler.dart';
import 'hackrf_source.dart';
import 'rtl_sdr_source.dart';
import 'usb_source.dart';

enum UsbSdrKind { rtlSdr, hackrf, airspy, airspyHf, unknown }

const int airspyUsbVid = 0x1d50; // AIRSPY_VIDPIDS
const int airspyUsbPid = 0x60a1;
const int airspyHfUsbVid = 0x03eb; // Airspy HF+ / Discovery
const int airspyHfUsbPid = 0x800c;

/// Driver selection by VID:PID.
UsbSdrKind usbSdrKind(int vid, int pid) {
  if (findKnownDevice(vid, pid) != null) return UsbSdrKind.rtlSdr;
  if (hackrfIsHackrfUsbId(vid, pid)) return UsbSdrKind.hackrf;
  if (vid == airspyUsbVid && pid == airspyUsbPid) return UsbSdrKind.airspy;
  if (vid == airspyHfUsbVid && pid == airspyHfUsbPid) {
    return UsbSdrKind.airspyHf;
  }
  return UsbSdrKind.unknown;
}

/// True for devices this app has a working source for.
bool isSupportedUsbSdr(int vid, int pid) => switch (usbSdrKind(vid, pid)) {
  UsbSdrKind.rtlSdr || UsbSdrKind.hackrf => true,
  _ => false,
};

/// SDR++ source name registered by the module for this device kind.
String? sourceNameFor(UsbSdrKind kind) => switch (kind) {
  UsbSdrKind.rtlSdr => 'RTL-SDR',
  UsbSdrKind.hackrf => 'HackRF',
  UsbSdrKind.airspy => 'Airspy',
  UsbSdrKind.airspyHf => 'Airspy HF+',
  UsbSdrKind.unknown => null,
};

/// Human readable device name for lists / notifications (UI isolate).
/// Prefers the USB product strings, falls back to the known_devices[] names.
String usbSdrDisplayName({
  required int vid,
  required int pid,
  String? manufacturer,
  String? product,
  String? serial,
}) {
  final kind = usbSdrKind(vid, pid);
  String base;
  switch (kind) {
    case UsbSdrKind.rtlSdr:
      final m = manufacturer?.trim() ?? '';
      final p = product?.trim() ?? '';
      if (m.isNotEmpty && p.isNotEmpty) {
        base = '$m $p';
      } else if (p.isNotEmpty) {
        base = p;
      } else {
        base = findKnownDevice(vid, pid)!.name;
      }
    case UsbSdrKind.hackrf:
      base = switch (pid) {
        hackrfOneUsbPid => 'HackRF One',
        hackrfJawbreakerUsbPid => 'HackRF Jawbreaker',
        rad1oUsbPid => 'rad1o',
        _ => 'HackRF',
      };
    case UsbSdrKind.airspy:
      base = 'Airspy R2/Mini';
    case UsbSdrKind.airspyHf:
      base = 'Airspy HF+';
    case UsbSdrKind.unknown:
      final p = product?.trim() ?? '';
      base = p.isNotEmpty ? p : 'USB device';
  }
  final sn = serial?.trim() ?? '';
  final vp =
      '${vid.toRadixString(16).padLeft(4, '0')}:${pid.toRadixString(16).padLeft(4, '0')}';
  if (sn.isEmpty) return '$base ($vp)';
  // HackRF serials are 32 hex digits; SDR++ shows the last 16.
  final shortSn = (kind == UsbSdrKind.hackrf && sn.length > 16)
      ? sn.substring(16)
      : sn;
  return '$base [$shortSn]';
}

/// [usbSdrDisplayName] for the params map sent to the DSP isolate.
String usbSdrDisplayNameFromParams(Map<Object?, Object?> params) {
  final p = UsbSourceParams.fromMap(params);
  return usbSdrDisplayName(
    vid: p.vid,
    pid: p.pid,
    manufacturer: p.manufacturer,
    product: p.product,
    serial: p.serial,
  );
}

class UnsupportedUsbSdrException extends UsbException {
  final UsbSdrKind kind;
  final int vid, pid;
  UnsupportedUsbSdrException(this.kind, this.vid, this.pid, String message)
    : super(UsbError.notSupported, message);
}

/// Create the source module for the device in [params]
/// (`{fd, vid, pid, deviceName, serial, manufacturer, product}`), on the DSP
/// isolate. Throws [UnsupportedUsbSdrException] for Airspy and unknown IDs.
UsbSourceModule createUsbSource(
  Map<Object?, Object?> params,
  SourceCore core, {
  UsbDeviceOpener? opener,
  Map<String, Object?>? savedConfig,
  void Function(Map<String, Object?> config)? onConfigChanged,
  SourceErrorCallback? onError,
}) {
  final p = UsbSourceParams.fromMap(params);
  final kind = usbSdrKind(p.vid, p.pid);
  switch (kind) {
    case UsbSdrKind.rtlSdr:
      return RtlSdrSourceModule(
        'RTL-SDR',
        core,
        p,
        opener: opener,
        savedConfig: savedConfig,
        onConfigChanged: onConfigChanged,
        onError: onError,
      );
    case UsbSdrKind.hackrf:
      return HackrfSourceModule(
        'HackRF',
        core,
        p,
        opener: opener,
        savedConfig: savedConfig,
        onConfigChanged: onConfigChanged,
        onError: onError,
      );
    case UsbSdrKind.airspy:
    case UsbSdrKind.airspyHf:
      throw UnsupportedUsbSdrException(
        kind,
        p.vid,
        p.pid,
        '${sourceNameFor(kind)} (${p.vidPid}) is not supported yet: '
        'no Dart driver for libairspy',
      );
    case UsbSdrKind.unknown:
      throw UnsupportedUsbSdrException(
        kind,
        p.vid,
        p.pid,
        'Unknown USB device ${p.vidPid}',
      );
  }
}
