// SPDX-License-Identifier: GPL-3.0-or-later
//
// Standalone USB SDR device metadata for the native (ABI v3) controller:
// VID/PID -> driver kind, display names, sample-rate tables, gain ranges and
// tunable frequency ranges. This file intentionally does not import
// lib/drivers, lib/usb or lib/sdrpp (the Dart receive engine lib/native must
// not depend on); the constants below are copied verbatim from the
// equivalent original tables so no value is invented:
//   RTL-SDR known_devices[] / gain range -> lib/drivers/rtlsdr/librtlsdr.dart,
//     lib/sdrpp/modules/sources/rtl_sdr_source.dart, usb_source_factory.dart.
//   HackRF VID/PID / gain range          -> lib/drivers/hackrf/hackrf.dart,
//     lib/sdrpp/modules/sources/hackrf_source.dart, usb_source_factory.dart.
//
// Native (ABI v3) has no device-specific settings (no tuner AGC, no RTL2832
// digital AGC, no HackRF LNA/VGA split): callers must always report
// `hasAgc: false` regardless of [UsbSdrKind] and never surface the Dart
// driver's AGC switch as if the native source accepted it.

import '../ui/radio_controller.dart' show GainRange;

/// Driver kind selected by VID:PID. Airspy is deliberately not modelled here:
/// no native driver exists for it and the original `UsbSdrKind.unknown`
/// branch already covers "not one of our supported SDRs".
enum UsbSdrKind { rtlSdr, hackrf, unknown }

// ---- RTL-SDR --------------------------------------------------------------

/// One entry of librtlsdr's `known_devices[]` (rtlsdr_dongle_t): used only as
/// a display-name fallback when the USB manufacturer/product strings are
/// empty (lib/drivers/rtlsdr/librtlsdr.dart `knownDevices`).
class RtlSdrKnownDevice {
  const RtlSdrKnownDevice(this.vid, this.pid, this.name);
  final int vid;
  final int pid;
  final String name;
}

/// Copied verbatim from `lib/drivers/rtlsdr/librtlsdr.dart` `knownDevices`.
const List<RtlSdrKnownDevice> rtlSdrKnownDevices = [
  RtlSdrKnownDevice(0x0bda, 0x2832, 'Generic RTL2832U'),
  RtlSdrKnownDevice(0x0bda, 0x2838, 'Generic RTL2832U OEM'),
  RtlSdrKnownDevice(0x0413, 0x6680, 'DigitalNow Quad DVB-T PCI-E card'),
  RtlSdrKnownDevice(0x0413, 0x6f0f, 'Leadtek WinFast DTV Dongle mini D'),
  RtlSdrKnownDevice(0x0458, 0x707f, 'Genius TVGo DVB-T03 USB dongle (Ver. B)'),
  RtlSdrKnownDevice(0x0ccd, 0x00a9, 'Terratec Cinergy T Stick Black (rev 1)'),
  RtlSdrKnownDevice(
    0x0ccd,
    0x00b3,
    'Terratec NOXON DAB/DAB+ USB dongle (rev 1)',
  ),
  RtlSdrKnownDevice(0x0ccd, 0x00b4, 'Terratec Deutschlandradio DAB Stick'),
  RtlSdrKnownDevice(0x0ccd, 0x00b5, 'Terratec NOXON DAB Stick - Radio Energy'),
  RtlSdrKnownDevice(0x0ccd, 0x00b7, 'Terratec Media Broadcast DAB Stick'),
  RtlSdrKnownDevice(0x0ccd, 0x00b8, 'Terratec BR DAB Stick'),
  RtlSdrKnownDevice(0x0ccd, 0x00b9, 'Terratec WDR DAB Stick'),
  RtlSdrKnownDevice(0x0ccd, 0x00c0, 'Terratec MuellerVerlag DAB Stick'),
  RtlSdrKnownDevice(0x0ccd, 0x00c6, 'Terratec Fraunhofer DAB Stick'),
  RtlSdrKnownDevice(0x0ccd, 0x00d3, 'Terratec Cinergy T Stick RC (Rev.3)'),
  RtlSdrKnownDevice(0x0ccd, 0x00d7, 'Terratec T Stick PLUS'),
  RtlSdrKnownDevice(
    0x0ccd,
    0x00e0,
    'Terratec NOXON DAB/DAB+ USB dongle (rev 2)',
  ),
  RtlSdrKnownDevice(0x1554, 0x5020, 'PixelView PV-DT235U(RN)'),
  RtlSdrKnownDevice(0x15f4, 0x0131, 'Astrometa DVB-T/DVB-T2'),
  RtlSdrKnownDevice(0x15f4, 0x0133, 'HanfTek DAB+FM+DVB-T'),
  RtlSdrKnownDevice(0x185b, 0x0620, 'Compro Videomate U620F'),
  RtlSdrKnownDevice(0x185b, 0x0650, 'Compro Videomate U650F'),
  RtlSdrKnownDevice(0x185b, 0x0680, 'Compro Videomate U680F'),
  RtlSdrKnownDevice(0x1b80, 0xd393, 'GIGABYTE GT-U7300'),
  RtlSdrKnownDevice(0x1b80, 0xd394, 'DIKOM USB-DVBT HD'),
  RtlSdrKnownDevice(0x1b80, 0xd395, 'Peak 102569AGPK'),
  RtlSdrKnownDevice(0x1b80, 0xd397, 'KWorld KW-UB450-T USB DVB-T Pico TV'),
  RtlSdrKnownDevice(0x1b80, 0xd398, 'Zaapa ZT-MINDVBZP'),
  RtlSdrKnownDevice(0x1b80, 0xd39d, 'SVEON STV20 DVB-T USB & FM'),
  RtlSdrKnownDevice(0x1b80, 0xd3a4, 'Twintech UT-40'),
  RtlSdrKnownDevice(0x1b80, 0xd3a8, 'ASUS U3100MINI_PLUS_V2'),
  RtlSdrKnownDevice(0x1b80, 0xd3af, 'SVEON STV27 DVB-T USB & FM'),
  RtlSdrKnownDevice(0x1b80, 0xd3b0, 'SVEON STV21 DVB-T USB & FM'),
  RtlSdrKnownDevice(
    0x1d19,
    0x1101,
    'Dexatek DK DVB-T Dongle (Logilink VG0002A)',
  ),
  RtlSdrKnownDevice(
    0x1d19,
    0x1102,
    'Dexatek DK DVB-T Dongle (MSI DigiVox mini II V3.0)',
  ),
  RtlSdrKnownDevice(
    0x1d19,
    0x1103,
    'Dexatek Technology Ltd. DK 5217 DVB-T Dongle',
  ),
  RtlSdrKnownDevice(0x1d19, 0x1104, 'MSI DigiVox Micro HD'),
  RtlSdrKnownDevice(0x1f4d, 0xa803, 'Sweex DVB-T USB'),
  RtlSdrKnownDevice(0x1f4d, 0xb803, 'GTek T803'),
  RtlSdrKnownDevice(0x1f4d, 0xc803, 'Lifeview LV5TDeluxe'),
  RtlSdrKnownDevice(0x1f4d, 0xd286, 'MyGica TD312'),
  RtlSdrKnownDevice(0x1f4d, 0xd803, 'PROlectrix DV107669'),
];

/// Copied verbatim from `lib/sdrpp/modules/sources/rtl_sdr_source.dart`
/// `rtlSdrSampleRates`.
const List<double> rtlSdrSampleRates = [
  250000,
  1024000,
  1536000,
  1792000,
  1920000,
  2048000,
  2160000,
  2400000,
  2560000,
  2880000,
  3200000,
];

/// Copied verbatim from `lib/sdrpp/modules/sources/usb_source_factory.dart`
/// `rtlSdrGainRange` (R820T/R828D table: 0‥49.6 dB).
const GainRange rtlSdrGainRange = GainRange(min: 0, max: 49.6, step: 0);

/// Copied verbatim from `lib/sdrpp/modules/sources/usb_source_factory.dart`
/// `usbSdrFrequencyRange(UsbSdrKind.rtlSdr)` (includes direct sampling/HF).
const (double, double) rtlSdrFrequencyRange = (0, 2200000000);

RtlSdrKnownDevice? _findRtlSdrKnownDevice(int vid, int pid) {
  for (final d in rtlSdrKnownDevices) {
    if (d.vid == vid && d.pid == pid) return d;
  }
  return null;
}

// ---- HackRF -----------------------------------------------------------

/// Copied verbatim from `lib/drivers/hackrf/hackrf.dart`.
const int hackrfUsbVid = 0x1d50;
const int hackrfJawbreakerUsbPid = 0x604b;
const int hackrfOneUsbPid = 0x6089;
const int rad1oUsbPid = 0xcc15;

/// Copied verbatim from `lib/sdrpp/modules/sources/hackrf_source.dart`
/// `hackrfSampleRates` (descending, as in the native config list); the UI
/// table ([usbSdrSampleRates]) presents it ascending like the original
/// `usbSdrSampleRates(UsbSdrKind.hackrf)`.
const List<int> hackrfSampleRatesDescending = [
  20000000,
  16000000,
  10000000,
  8000000,
  5000000,
  4000000,
  2000000,
];

/// Copied verbatim from `lib/sdrpp/modules/sources/usb_source_factory.dart`
/// `hackrfGainRange` (LNA 0‥40 dB + VGA 0‥62 dB, amp off).
const GainRange hackrfGainRange = GainRange(min: 0, max: 102, step: 2);

/// Copied verbatim from `lib/sdrpp/modules/sources/usb_source_factory.dart`
/// `usbSdrFrequencyRange(UsbSdrKind.hackrf)`.
const (double, double) hackrfFrequencyRange = (1000000, 6000000000);

/// Copied verbatim from `lib/drivers/hackrf/hackrf.dart`
/// `hackrfIsHackrfUsbId`.
bool _isHackrfUsbId(int vid, int pid) =>
    vid == hackrfUsbVid &&
    (pid == hackrfOneUsbPid ||
        pid == hackrfJawbreakerUsbPid ||
        pid == rad1oUsbPid);

// ---- kind / display name / UI metadata ------------------------------------

/// Driver selection by VID:PID. Copied verbatim from
/// `lib/sdrpp/modules/sources/usb_source_factory.dart` `usbSdrKind`, minus
/// the (unsupported, native-irrelevant) Airspy branches.
UsbSdrKind usbSdrKind(int vid, int pid) {
  if (_findRtlSdrKnownDevice(vid, pid) != null) return UsbSdrKind.rtlSdr;
  if (_isHackrfUsbId(vid, pid)) return UsbSdrKind.hackrf;
  return UsbSdrKind.unknown;
}

/// True for devices the native engine has a driver for.
bool isSupportedUsbSdr(int vid, int pid) => switch (usbSdrKind(vid, pid)) {
  UsbSdrKind.rtlSdr || UsbSdrKind.hackrf => true,
  UsbSdrKind.unknown => false,
};

/// Human readable device name for lists/notifications. Copied verbatim from
/// `lib/sdrpp/modules/sources/usb_source_factory.dart` `usbSdrDisplayName`,
/// minus the unsupported Airspy branches (never reached: callers filter by
/// [isSupportedUsbSdr] first).
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
        base = _findRtlSdrKnownDevice(vid, pid)!.name;
      }
    case UsbSdrKind.hackrf:
      base = switch (pid) {
        hackrfOneUsbPid => 'HackRF One',
        hackrfJawbreakerUsbPid => 'HackRF Jawbreaker',
        rad1oUsbPid => 'rad1o',
        _ => 'HackRF',
      };
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

/// Sample rates (Hz) offered by the UI for a device kind, ascending.
/// Equivalent to `lib/sdrpp/modules/sources/usb_source_factory.dart`
/// `usbSdrSampleRates`.
List<double> usbSdrSampleRates(UsbSdrKind kind) => switch (kind) {
  UsbSdrKind.rtlSdr => rtlSdrSampleRates,
  UsbSdrKind.hackrf => <double>[
    for (final r in hackrfSampleRatesDescending.reversed) r.toDouble(),
  ],
  UsbSdrKind.unknown => const <double>[],
};

/// Gain control range (always `hasAgc: false` for native; ABI v3 has no
/// device-specific AGC). Equivalent to `usb_source_factory.dart`
/// `usbSdrGainRange`.
GainRange usbSdrGainRange(UsbSdrKind kind) => switch (kind) {
  UsbSdrKind.rtlSdr => rtlSdrGainRange,
  UsbSdrKind.hackrf => hackrfGainRange,
  UsbSdrKind.unknown => const GainRange(min: 0, max: 0),
};

/// Tunable range shown by the frequency selector. Equivalent to
/// `usb_source_factory.dart` `usbSdrFrequencyRange`.
(double, double) usbSdrFrequencyRange(UsbSdrKind kind) => switch (kind) {
  UsbSdrKind.rtlSdr => rtlSdrFrequencyRange,
  UsbSdrKind.hackrf => hackrfFrequencyRange,
  UsbSdrKind.unknown => (0, 999999999999),
};
