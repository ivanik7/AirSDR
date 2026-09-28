// UsbfsDeviceHandle tests against FakeUsbfsKernel (decodes the real ioctl
// numbers and structs).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/usb/usb_transport.dart';
import 'package:sdr_flutter/usb/usbfs_abi.dart';
import 'package:sdr_flutter/usb/usbfs_transport.dart';

import 'fake_usbfs_kernel.dart';

Uint8List _stringDesc(String s) {
  final b = Uint8List(2 + 2 * s.length);
  b[0] = b.length;
  b[1] = 3;
  for (var i = 0; i < s.length; i++) {
    b[2 + 2 * i] = s.codeUnitAt(i) & 0xff;
    b[3 + 2 * i] = s.codeUnitAt(i) >> 8;
  }
  return b;
}

void main() {
  late FakeUsbfsKernel k;
  tearDown(() => k.dispose());

  group('wrap', () {
    test('reads caps and device descriptor from the fd', () {
      k = FakeUsbfsKernel(descriptors: deviceDescriptorBytes(bcd: 0x0100));
      final h = UsbfsDeviceHandle.wrap(5, sys: k);
      expect(h.capsQueried, isTrue);
      expect(h.caps & Usbfs.capNoPacketSizeLim, isNonZero);
      expect(h.deviceDescriptor.vendorId, 0x0bda);
      expect(h.deviceDescriptor.productId, 0x2838);
      expect(h.deviceDescriptor.bcdDevice, 0x0100);
      expect(h.deviceDescriptor.iManufacturer, 1);
      expect(h.deviceDescriptor.iProduct, 2);
      expect(h.deviceDescriptor.iSerialNumber, 3);
      expect(k.log, ['GETCAP']);
      h.close();
    });

    test('GET_CAPABILITIES ENOTTY -> libusb fallback caps', () {
      k = FakeUsbfsKernel(
        descriptors: deviceDescriptorBytes(),
        capsErrno: Errno.enotty,
      );
      final h = UsbfsDeviceHandle.wrap(5, sys: k);
      expect(h.capsQueried, isFalse);
      expect(h.caps, Usbfs.capBulkContinuation);
      h.close();
    });

    test('GET_CAPABILITIES ENODEV -> noDevice', () {
      k = FakeUsbfsKernel(
        descriptors: deviceDescriptorBytes(),
        capsErrno: Errno.enodev,
      );
      expect(
        () => UsbfsDeviceHandle.wrap(5, sys: k),
        throwsA(
          isA<UsbException>().having((e) => e.code, 'code', UsbError.noDevice),
        ),
      );
    });

    test('descriptor read failure -> GET_DESCRIPTOR(DEVICE) on EP0', () {
      k = FakeUsbfsKernel(descriptors: null)
        ..controlIn = (t, r, v, i, len) {
          expect((t, r, v, i, len), (0x80, 6, 0x0100, 0, 18));
          return deviceDescriptorBytes(vid: 0x1d50, pid: 0x6089);
        };
      final h = UsbfsDeviceHandle.wrap(5, sys: k);
      expect(h.deviceDescriptor.vendorId, 0x1d50);
      expect(h.deviceDescriptor.productId, 0x6089);
      h.close();
    });
  });

  group('transfers', () {
    late UsbfsDeviceHandle h;
    setUp(() {
      k = FakeUsbfsKernel(descriptors: deviceDescriptorBytes());
      h = UsbfsDeviceHandle.wrap(5, sys: k);
      k.log.clear();
    });
    tearDown(() => h.close());

    test('control OUT sends wLength bytes and fields', () {
      final data = Uint8List.fromList([0xaa, 0xbb, 0xcc]);
      final n = h.controlTransfer(
        0x40,
        0x00,
        0x1234,
        0x0110,
        data,
        2,
        timeoutMs: 300,
      );
      expect(n, 2);
      expect(k.log, ['CTRL 40 0 1234 110 2 t=300 aabb']);
    });

    test('control IN copies back actual bytes only', () {
      k.controlIn = (t, r, v, i, len) => Uint8List.fromList([1, 2]);
      final data = Uint8List.fromList([9, 9, 9, 9]);
      final n = h.controlTransfer(0xc0, 0x00, 0x0034, 0x0600, data, 4);
      expect(n, 2);
      expect(data, [1, 2, 9, 9]);
      expect(k.log.single, 'CTRL c0 0 34 600 4 t=1000');
    });

    test('control zero length', () {
      expect(h.controlTransfer(0x40, 1, 0, 0, Uint8List(0), 0), 0);
    });

    test('errno mapping', () {
      for (final (errno, code) in [
        (Errno.epipe, UsbError.pipe),
        (Errno.etimedout, UsbError.timeout),
        (Errno.enodev, UsbError.noDevice),
        (Errno.eshutdown, UsbError.noDevice),
        (Errno.eoverflow, UsbError.overflow),
        (Errno.eproto, UsbError.io),
      ]) {
        k.failNextErrno = errno;
        expect(
          () => h.controlTransfer(0x40, 0, 0, 0, Uint8List(1), 1),
          throwsA(isA<UsbException>().having((e) => e.code, 'code', code)),
          reason: 'errno $errno',
        );
      }
    });

    test('bad lengths -> invalidParam', () {
      expect(
        () => h.controlTransfer(0x40, 0, 0, 0, Uint8List(1), 2),
        throwsA(
          isA<UsbException>().having(
            (e) => e.code,
            'code',
            UsbError.invalidParam,
          ),
        ),
      );
      expect(
        () => h.bulkTransfer(0x81, Uint8List(1), 2),
        throwsA(
          isA<UsbException>().having(
            (e) => e.code,
            'code',
            UsbError.invalidParam,
          ),
        ),
      );
    });

    test('bulk IN', () {
      k.bulkIn = (ep, len) => Uint8List.fromList(List.generate(len, (i) => i));
      final data = Uint8List(512);
      expect(h.bulkTransfer(0x81, data, 512), 512);
      expect(data[511], 511 & 0xff);
      expect(k.log.single, 'BULK 81 512 t=1000');
    });

    test('bulk split into 16 KiB without CAP_NO_PACKET_SIZE_LIM', () {
      k.dispose();
      k = FakeUsbfsKernel(
        descriptors: deviceDescriptorBytes(),
        caps: Usbfs.capBulkContinuation,
      );
      final h2 = UsbfsDeviceHandle.wrap(5, sys: k);
      k.log.clear();
      k.bulkIn = (ep, len) => Uint8List(len);
      expect(h2.bulkTransfer(0x81, Uint8List(40000), 40000), 40000);
      expect(k.log, [
        'BULK 81 16384 t=1000',
        'BULK 81 16384 t=1000',
        'BULK 81 7232 t=1000',
      ]);
      h2.close();
    });

    test('config / claim / release / clear_halt', () {
      h.setConfiguration(1);
      h.claimInterface(0);
      h.clearHalt(0x81);
      h.releaseInterface(0);
      expect(k.log, ['CFG 1', 'CLAIM 0', 'HALT 129', 'RELEASE 0']);
      k.failNextErrno = Errno.ebusy;
      expect(
        () => h.claimInterface(0),
        throwsA(
          isA<UsbException>().having((e) => e.code, 'code', UsbError.busy),
        ),
      );
      k.failNextErrno = Errno.einval;
      expect(
        () => h.setConfiguration(7),
        throwsA(
          isA<UsbException>().having((e) => e.code, 'code', UsbError.notFound),
        ),
      );
      k.failNextErrno = Errno.enoent;
      expect(
        () => h.clearHalt(0x82),
        throwsA(
          isA<UsbException>().having((e) => e.code, 'code', UsbError.notFound),
        ),
      );
    });

    test(
      'reset releases and re-claims claimed interfaces (op_reset_device)',
      () {
        h.claimInterface(0);
        k.log.clear();
        h.resetDevice();
        expect(k.log, ['RELEASE 0', 'RESET', 'CLAIM 0']);
      },
    );

    test('string descriptor ASCII (libusb_get_string_descriptor_ascii)', () {
      k.controlIn = (t, r, v, i, len) {
        expect(t, 0x80);
        expect(r, 6);
        if (v == 0x0300) return Uint8List.fromList([4, 3, 0x09, 0x04]);
        expect(i, 0x0409);
        if (v == 0x0301) return _stringDesc('Realtek');
        if (v == 0x0302) return _stringDesc('RTL\u00e9');
        throw Errno.epipe;
      };
      expect(h.getStringDescriptorAscii(1), 'Realtek');
      expect(h.getStringDescriptorAscii(2), 'RTL?');
      expect(h.getStringDescriptorAscii(3), isNull); // stall -> null
      expect(h.getStringDescriptorAscii(0), isNull);
    });

    test('closed handle -> noDevice', () {
      h.close();
      expect(
        () => h.controlTransfer(0x40, 0, 0, 0, Uint8List(0), 0),
        throwsA(
          isA<UsbException>().having((e) => e.code, 'code', UsbError.noDevice),
        ),
      );
    });
  });
}
