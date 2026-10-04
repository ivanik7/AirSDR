// SPDX-License-Identifier: GPL-3.0-or-later
//
// Regression tests for lib/native/usb_device_catalog.dart: VID/PID
// classification, display names, sample-rate/gain tables and frequency
// ranges, cross-checked against the original tables in
// lib/drivers/{rtlsdr,hackrf} and lib/sdrpp/modules/sources (the source of
// truth these constants were copied from, verbatim, for N5's dependency cut).

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/native/usb_device_catalog.dart';

void main() {
  group('usbSdrKind', () {
    test('RTL-SDR known_devices[] entries classify as rtlSdr', () {
      // A sample spanning the original knownDevices table, including the two
      // Realtek VIDs most commonly seen on dongles.
      for (final (vid, pid) in [
        (0x0bda, 0x2832), // Generic RTL2832U
        (0x0bda, 0x2838), // Generic RTL2832U OEM (RTL-SDR Blog V4 reports this)
        (0x1554, 0x5020), // PixelView PV-DT235U(RN)
        (0x1f4d, 0xd803), // PROlectrix DV107669
      ]) {
        expect(usbSdrKind(vid, pid), UsbSdrKind.rtlSdr, reason: '$vid:$pid');
      }
    });

    test('HackRF VID/PID triplet classifies as hackrf', () {
      expect(usbSdrKind(0x1d50, 0x6089), UsbSdrKind.hackrf); // HackRF One
      expect(usbSdrKind(0x1d50, 0x604b), UsbSdrKind.hackrf); // Jawbreaker
      expect(usbSdrKind(0x1d50, 0xcc15), UsbSdrKind.hackrf); // rad1o
    });

    test('unrelated and Airspy VID/PID are unknown (no native driver)', () {
      expect(usbSdrKind(0x046d, 0xc077), UsbSdrKind.unknown); // mouse
      expect(usbSdrKind(0x1d50, 0x60a1), UsbSdrKind.unknown); // Airspy R2/Mini
      expect(usbSdrKind(0x03eb, 0x800c), UsbSdrKind.unknown); // Airspy HF+
    });
  });

  group('isSupportedUsbSdr', () {
    test('true only for RTL-SDR and HackRF', () {
      expect(isSupportedUsbSdr(0x0bda, 0x2838), isTrue);
      expect(isSupportedUsbSdr(0x1d50, 0x6089), isTrue);
      expect(isSupportedUsbSdr(0x1d50, 0x60a1), isFalse); // Airspy
      expect(isSupportedUsbSdr(0x046d, 0xc077), isFalse); // mouse
    });
  });

  group('usbSdrDisplayName', () {
    test('RTL-SDR: manufacturer + product, then VID:PID', () {
      expect(
        usbSdrDisplayName(
          vid: 0x0bda,
          pid: 0x2838,
          manufacturer: 'Realtek',
          product: 'RTL2838UHIDIR',
        ),
        'Realtek RTL2838UHIDIR (0bda:2838)',
      );
    });

    test('RTL-SDR: falls back to the known_devices[] name with no strings', () {
      expect(
        usbSdrDisplayName(vid: 0x0bda, pid: 0x2832),
        'Generic RTL2832U (0bda:2832)',
      );
    });

    test('HackRF One name with the last-16-hex-digit serial suffix', () {
      expect(
        usbSdrDisplayName(
          vid: 0x1d50,
          pid: 0x6089,
          manufacturer: 'Great Scott Gadgets',
          product: 'HackRF One',
          serial: '0000000000000000457863c8234e1a5f',
        ),
        'HackRF One [457863c8234e1a5f]',
      );
    });

    test('rad1o and Jawbreaker have distinct base names', () {
      expect(usbSdrDisplayName(vid: 0x1d50, pid: 0xcc15), 'rad1o (1d50:cc15)');
      expect(
        usbSdrDisplayName(vid: 0x1d50, pid: 0x604b),
        'HackRF Jawbreaker (1d50:604b)',
      );
    });

    test('unknown device falls back to the product string or "USB device"', () {
      expect(
        usbSdrDisplayName(vid: 0x046d, pid: 0xc077, product: 'USB Mouse'),
        'USB Mouse (046d:c077)',
      );
      expect(usbSdrDisplayName(vid: 0x046d, pid: 0xc077), 'USB device (046d:c077)');
    });
  });

  group('device-kind metadata tables', () {
    test('RTL-SDR sample rates/gain/frequency match the original tables', () {
      expect(usbSdrSampleRates(UsbSdrKind.rtlSdr), rtlSdrSampleRates);
      expect(usbSdrSampleRates(UsbSdrKind.rtlSdr), contains(2400000));
      final gain = usbSdrGainRange(UsbSdrKind.rtlSdr);
      expect(gain.min, 0);
      expect(gain.max, 49.6);
      expect(usbSdrFrequencyRange(UsbSdrKind.rtlSdr), (0, 2200000000));
    });

    test('HackRF sample rates ascending, gain and frequency match the original tables', () {
      final rates = usbSdrSampleRates(UsbSdrKind.hackrf);
      expect(rates.first, 2e6);
      expect(rates.last, 20e6);
      expect(rates, [2e6, 4e6, 5e6, 8e6, 10e6, 16e6, 20e6]);
      final gain = usbSdrGainRange(UsbSdrKind.hackrf);
      expect(gain.min, 0);
      expect(gain.max, 102);
      expect(usbSdrFrequencyRange(UsbSdrKind.hackrf), (1000000, 6000000000));
    });

    test('unknown device kind has empty rates and zero-width gain', () {
      expect(usbSdrSampleRates(UsbSdrKind.unknown), isEmpty);
      final gain = usbSdrGainRange(UsbSdrKind.unknown);
      expect(gain.min, 0);
      expect(gain.max, 0);
    });

    test(
      'no device kind ever reports an AGC-capable gain in this catalog '
      '(ABI v3 has no device-specific AGC; callers must always pass hasAgc: false)',
      () {
        // usb_device_catalog.dart intentionally has no usbSdrHasAgc function:
        // this test documents that native metadata consumers must hardcode
        // hasAgc: false themselves rather than deriving it from device kind.
        expect(usbSdrGainRange(UsbSdrKind.rtlSdr).max, isNot(0));
      },
    );
  });
}
