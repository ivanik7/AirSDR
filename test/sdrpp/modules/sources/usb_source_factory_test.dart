// Tests for usb_source_factory.dart and the u8 converter.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/drivers/rtlsdr/librtlsdr.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/hackrf_source.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/rtl_sdr_convert.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/rtl_sdr_source.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/usb_source.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/usb_source_factory.dart';
import 'package:sdr_flutter/usb/usb_transport.dart';

import '../../../drivers/rtlsdr/fake_rtl_usb.dart';
import 'source_test_utils.dart';

void main() {
  rtlsdrLog = (_) {};
  SourceLog.sink = (l, m) {};

  group('usbSdrKind', () {
    test('every known_devices[] entry is an RTL-SDR', () {
      for (final d in knownDevices) {
        expect(usbSdrKind(d.vid, d.pid), UsbSdrKind.rtlSdr, reason: d.name);
        expect(isSupportedUsbSdr(d.vid, d.pid), isTrue);
      }
      expect(knownDevices.length, 42);
    });

    test('HackRF / Airspy / unknown', () {
      expect(usbSdrKind(0x1d50, 0x6089), UsbSdrKind.hackrf);
      expect(usbSdrKind(0x1d50, 0x604b), UsbSdrKind.hackrf);
      expect(usbSdrKind(0x1d50, 0xcc15), UsbSdrKind.hackrf);
      expect(usbSdrKind(0x1d50, 0x60a1), UsbSdrKind.airspy);
      expect(usbSdrKind(0x03eb, 0x800c), UsbSdrKind.airspyHf);
      expect(usbSdrKind(0x1234, 0x5678), UsbSdrKind.unknown);
      expect(isSupportedUsbSdr(0x1d50, 0x60a1), isFalse);
    });
  });

  group('display names', () {
    test('RTL', () {
      expect(
        usbSdrDisplayName(
          vid: 0x0bda,
          pid: 0x2838,
          manufacturer: 'RTLSDRBlog',
          product: 'Blog V4',
          serial: '00000001',
        ),
        'RTLSDRBlog Blog V4 [00000001]',
      );
      expect(
        usbSdrDisplayName(vid: 0x0bda, pid: 0x2832),
        'Generic RTL2832U (0bda:2832)',
      );
      expect(
        usbSdrDisplayName(vid: 0x1d19, pid: 0x1104, product: ' '),
        'MSI DigiVox Micro HD (1d19:1104)',
      );
    });

    test('HackRF / Airspy', () {
      expect(
        usbSdrDisplayName(
          vid: 0x1d50,
          pid: 0x6089,
          serial: '0000000000000000a06063c8234e925f',
        ),
        'HackRF One [a06063c8234e925f]',
      );
      expect(usbSdrDisplayName(vid: 0x1d50, pid: 0xcc15), 'rad1o (1d50:cc15)');
      expect(
        usbSdrDisplayNameFromParams({'vid': 0x1d50, 'pid': 0x60a1, 'fd': 3}),
        'Airspy R2/Mini (1d50:60a1)',
      );
    });
  });

  group('createUsbSource', () {
    test('RTL-SDR -> RtlSdrSourceModule', () {
      final model = FakeRtlUsbDevice(FakeModel()..tuner = FakeTuner.r820t);
      final core = FakeCore();
      final s = createUsbSource(
        {
          'fd': 5,
          'vid': 0x0bda,
          'pid': 0x2838,
          'manufacturer': 'Realtek',
          'product': 'RTL2838UHIDIR',
          'serial': '00000001',
        },
        core,
        opener: (_) => rtlMockHandle(model),
      );
      expect(s, isA<RtlSdrSourceModule>());
      expect(s.sourceName, 'RTL-SDR');
      s.select();
      expect(core.rates, [2400000]);
    });

    test('HackRF -> HackrfSourceModule', () {
      final s = createUsbSource(
        {'fd': 5, 'vid': 0x1d50, 'pid': 0x6089},
        FakeCore(),
        opener: (_) => hackrfMockHandle(),
      );
      expect(s, isA<HackrfSourceModule>());
      expect(s.sourceName, 'HackRF');
      expect(s.deviceNames, ['HackRF USB']);
    });

    test('Airspy and unknown -> UnsupportedUsbSdrException', () {
      for (final (vid, pid, kind) in [
        (0x1d50, 0x60a1, UsbSdrKind.airspy),
        (0x03eb, 0x800c, UsbSdrKind.airspyHf),
        (0x1111, 0x2222, UsbSdrKind.unknown),
      ]) {
        expect(
          () => createUsbSource(
            {'fd': 5, 'vid': vid, 'pid': pid},
            FakeCore(),
            opener: (_) => throw StateError('must not open'),
          ),
          throwsA(
            isA<UnsupportedUsbSdrException>()
                .having((e) => e.kind, 'kind', kind)
                .having((e) => e.code, 'code', UsbError.notSupported),
          ),
        );
      }
    });

    test('params map round trip', () {
      const p = UsbSourceParams(
        fd: 9,
        vid: 1,
        pid: 2,
        deviceName: '/dev/bus/usb/001/009',
        serial: 'S',
      );
      final q = UsbSourceParams.fromMap(p.toMap());
      expect(q.toMap(), p.toMap());
      expect(
        UsbSourceParams.fromMap({'vid': 1, 'pid': 2, 'serial': ''}).serial,
        isNull,
      );
    });
  });

  group('rtlsdr u8 -> f32', () {
    test('LUT is bit-identical to the C++ expression for all bytes', () {
      final buf = Uint8List.fromList(List.generate(256, (i) => i));
      final a = Float32List(256), b = Float32List(256);
      expect(rtlsdrConvertU8ToF32(buf, 256, a), 128);
      rtlsdrConvertU8ToF32Ref(buf, 256, b);
      for (var i = 0; i < 256; i++) {
        expect(a[i], b[i]);
      }
      // spot values: (0-127.4)/128, (127-127.4)/128, (255-127.4)/128
      expect(a[0], closeTo(-0.9953125, 1e-7));
      expect(a[127], closeTo(-0.003125, 1e-7));
      expect(a[255], closeTo(0.996875, 1e-7));
      // double math then one float rounding (not float math)
      final f = Float32List(1)..[0] = (128 - 127.4) / 128.0;
      expect(a[128], f[0]);
    });

    test('odd length ignores the trailing byte; range checks', () {
      final out = Float32List(4)..fillRange(0, 4, 9);
      expect(rtlsdrConvertU8ToF32(Uint8List(5), 5, out), 2);
      expect(out[3], rtlsdrU8Lut[0]);
      expect(
        () => rtlsdrConvertU8ToF32(Uint8List(4), 6, out),
        throwsRangeError,
      );
      expect(
        () => rtlsdrConvertU8ToF32(Uint8List(8), 8, Float32List(6)),
        throwsRangeError,
      );
    });
  });
}
