// MockUsbDeviceHandle / MockBulkInStream tests.
import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/usb/mock_transport.dart';
import 'package:sdr_flutter/usb/usb_transport.dart';

void main() {
  group('control trace', () {
    test('records OUT and IN transfers with data', () {
      final regs = <int, int>{0x0034: 0x5a};
      final h = MockUsbDeviceHandle(
        onControlIn: (req, resp) {
          // rtlsdr_read_reg-like: IN, 1 byte from a register file
          resp[0] = regs[req.value] ?? 0;
          return 1;
        },
      );
      h.controlTransfer(
        0x40,
        0x00,
        0x2000,
        0x0110,
        Uint8List.fromList([0x01, 0x02]),
        2,
      );
      final buf = Uint8List(4);
      final n = h.controlTransfer(0xc0, 0x00, 0x0034, 0x0600, buf, 4);
      expect(n, 1);
      expect(buf[0], 0x5a);

      expect(h.controlTrace, hasLength(2));
      final w = h.trace[0];
      expect(
        (w.requestType, w.request, w.value, w.index, w.length),
        (0x40, 0x00, 0x2000, 0x0110, 2),
      );
      expect(w.data, [1, 2]);
      expect(h.trace[1].data, [0x5a]);
      expect(
        h.formatTrace(),
        'C 40 00 2000 0110 0002 0102\nC c0 00 0034 0600 0004 5a\n',
      );
    });

    test('IN without handler stalls (pipe)', () {
      final h = MockUsbDeviceHandle();
      expect(
        () => h.controlTransfer(0xc0, 0, 0, 0, Uint8List(1), 1),
        throwsA(
          isA<UsbException>().having((e) => e.code, 'code', UsbError.pipe),
        ),
      );
    });

    test('handler can throw to simulate errors', () {
      final h = MockUsbDeviceHandle(
        onControlOut: (req) => throw UsbException(UsbError.pipe, 'i2c nack'),
      );
      expect(
        () => h.controlTransfer(0x40, 0, 0, 0, Uint8List(1), 1),
        throwsA(isA<UsbException>()),
      );
      // still recorded (the C oracle records before the result too)
      expect(h.controlTrace, hasLength(1));
    });

    test('other operations are traced', () {
      final h = MockUsbDeviceHandle(
        strings: {1: 'Realtek', 2: 'RTL2838UHIDIR'},
      );
      h.setConfiguration(1);
      h.claimInterface(0);
      h.clearHalt(0x81);
      h.resetDevice();
      expect(h.getStringDescriptorAscii(1), 'Realtek');
      expect(h.getStringDescriptorAscii(0), isNull);
      expect(h.getStringDescriptorAscii(3), isNull);
      h.bulkTransfer(0x81, Uint8List(4), 4);
      h.releaseInterface(0);
      h.close();
      expect(h.formatTrace().trim().split('\n'), [
        'CFG 1',
        'CLAIM 0',
        'HALT 81',
        'RESET',
        'STR 1',
        'STR 3',
        'B 81 4',
        'RELEASE 0',
        'CLOSE',
      ]);
    });

    test('unplug -> noDevice everywhere', () async {
      final h = MockUsbDeviceHandle();
      final s = await h.openBulkIn(0x81, numBuffers: 2, bufferLength: 16);
      final err = Completer<Object>();
      s.blocks.listen((_) {}, onError: err.complete);
      h.unplug();
      expect(
        () => h.controlTransfer(0x40, 0, 0, 0, Uint8List(0), 0),
        throwsA(
          isA<UsbException>().having((e) => e.code, 'code', UsbError.noDevice),
        ),
      );
      expect(((await err.future) as UsbException).code, UsbError.noDevice);
      await s.cancel();
    });
  });

  group('MockBulkInStream', () {
    test(
      'data lands in native slots, release recycles, drops counted',
      () async {
        final h = MockUsbDeviceHandle(spareBulkSlots: 0);
        final s = await h.openBulkIn(
          0x81,
          numBuffers: 2,
          bufferLength: 4,
        ) as MockBulkInStream;
        expect(h.trace.last.toString(), 'BULKIN 81 2 4');
        final got = <UsbBlock>[];
        s.blocks.listen(got.add);
        expect(s.push([1, 2, 3, 4]), isTrue);
        expect(s.push([5, 6]), isTrue);
        expect(s.push([7]), isFalse); // both slots held
        expect(s.droppedBuffers, 1);
        await Future<void>.delayed(Duration.zero);
        expect(got, hasLength(2));
        expect(Pointer<Uint8>.fromAddress(got[0].address).asTypedList(4), [
          1,
          2,
          3,
          4,
        ]);
        expect(got[1].length, 2);
        s.release(got[0]);
        expect(s.push([8, 9, 10]), isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(got[2].slot, got[0].slot);
        expect(Pointer<Uint8>.fromAddress(got[2].address).asTypedList(3), [
          8,
          9,
          10,
        ]);
        await s.cancel();
        expect(s.push([1]), isFalse);
      },
    );

    test('pushAll chunks and end closes', () async {
      final h = MockUsbDeviceHandle();
      h.onBulkInOpened = (s) => scheduleMicrotask(() {
        s.pushAll(List.generate(10, (i) => i));
        s.end();
      });
      final s = await h.openBulkIn(0x81, numBuffers: 4, bufferLength: 4);
      final lens = <int>[];
      await for (final b in s.blocks) {
        lens.add(b.length);
        s.release(b);
      }
      expect(lens, [4, 4, 2]);
      await s.cancel();
    });
  });
}
