// UsbfsBulkInStream tests: real reader isolate + real URB structs in native
// memory, against FakeUsbfsKernel (shared native state across isolates).
import 'dart:async';
import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/usb/usb_transport.dart';
import 'package:sdr_flutter/usb/usbfs_abi.dart';
import 'package:sdr_flutter/usb/usbfs_transport.dart';

import 'fake_usbfs_kernel.dart';

void main() {
  late FakeUsbfsKernel k;
  late UsbfsDeviceHandle h;

  setUp(() {
    k = FakeUsbfsKernel(descriptors: deviceDescriptorBytes());
    k[K.reapDelayUs] = 200;
  });
  tearDown(() {
    h.close();
    k.dispose();
  });

  test(
    'delivers blocks in order, resubmits, cancel discards and reaps all',
    () async {
      h = UsbfsDeviceHandle.wrap(5, sys: k);
      final s = await h.openBulkIn(0x81, numBuffers: 4, bufferLength: 512);
      expect(k[K.submits], greaterThanOrEqualTo(4));

      var last = -1;
      var gaps = 0;
      var blocks = 0;
      final done = Completer<void>();
      final sub = s.blocks.listen((b) {
        expect(b.length, 512);
        final bytes = Pointer<Uint8>.fromAddress(b.address)
            .asTypedList(b.length);
        final seq = bytes[0] | bytes[1] << 8 | bytes[2] << 16 | bytes[3] << 24;
        expect(seq, greaterThan(last), reason: 'blocks must stay in order');
        gaps += seq - last - 1;
        last = seq;
        // Rest of the buffer is the kernel's byte pattern (continuous).
        for (var i = 5; i < 512; i++) {
          expect((bytes[i] - bytes[i - 1]) & 0xff, 1);
        }
        s.release(b);
        if (++blocks == 200 && !done.isCompleted) done.complete();
      });
      await done.future.timeout(const Duration(seconds: 20));
      await s.cancel();
      await sub.cancel();
      expect(k[K.discards], greaterThanOrEqualTo(1));
      expect(k.pending, 0, reason: 'all URBs reaped before free');
      // Every completion is either delivered or counted as dropped (drops after
      // the last delivered block are not visible as gaps).
      expect(gaps, lessThanOrEqualTo(s.droppedBuffers));
      expect(s.droppedBuffers - gaps, lessThanOrEqualTo(8));
    },
  );

  test('consumer keeping up at a realistic rate -> no drops', () async {
    k[K.reapDelayUs] = 5000; // 5 ms per URB (~RTL 256 KiB @ 2.4 Msps is 53 ms)
    h = UsbfsDeviceHandle.wrap(5, sys: k);
    final s = await h.openBulkIn(0x81, numBuffers: 4, bufferLength: 512);
    var n = 0;
    final done = Completer<void>();
    final sub = s.blocks.listen((b) {
      s.release(b);
      if (++n == 40 && !done.isCompleted) done.complete();
    });
    await done.future.timeout(const Duration(seconds: 20));
    await s.cancel();
    await sub.cancel();
    expect(s.droppedBuffers, 0);
  });

  test('consumer not releasing -> drops are counted, no starvation', () async {
    h = UsbfsDeviceHandle.wrap(5, sys: k, spareBulkSlots: 2);
    final s = await h.openBulkIn(0x81, numBuffers: 3, bufferLength: 256);
    final held = <UsbBlock>[];
    final sub = s.blocks.listen(held.add);
    // Wait until the reader keeps reaping after the pool is exhausted.
    final sw = Stopwatch()..start();
    while (s.droppedBuffers < 5 && sw.elapsed < const Duration(seconds: 10)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // numBuffers + spare = 5 slots; 3 are always in URBs => 2 can be handed out.
    expect(held.length, 2);
    expect(s.droppedBuffers, greaterThanOrEqualTo(5));
    // Releasing lets data flow again.
    for (final b in held.toList()) {
      s.release(b);
    }
    final before = held.length;
    while (held.length == before && sw.elapsed < const Duration(seconds: 10)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(held.length, greaterThan(before));
    await s.cancel();
    await sub.cancel();
    expect(k.pending, 0);
  });

  test('REAPURB ENODEV -> stream error noDevice and close', () async {
    k[K.enodevAfterReaps] = 10;
    h = UsbfsDeviceHandle.wrap(5, sys: k);
    final s = await h.openBulkIn(0x81, numBuffers: 4, bufferLength: 512);
    final errors = <Object>[];
    final closed = Completer<void>();
    s.blocks.listen(s.release, onError: errors.add, onDone: closed.complete);
    await closed.future.timeout(const Duration(seconds: 10));
    expect(errors, hasLength(1));
    expect((errors.single as UsbException).code, UsbError.noDevice);
    await s.cancel();
  });

  test('URB status -ESHUTDOWN -> noDevice', () async {
    k[K.urbStatusAfterReaps] = 3;
    k[K.urbStatusErrno] = Errno.eshutdown;
    h = UsbfsDeviceHandle.wrap(5, sys: k);
    final s = await h.openBulkIn(0x81, numBuffers: 2, bufferLength: 512);
    final errors = <Object>[];
    final closed = Completer<void>();
    s.blocks.listen(s.release, onError: errors.add, onDone: closed.complete);
    await closed.future.timeout(const Duration(seconds: 10));
    expect((errors.single as UsbException).code, UsbError.noDevice);
    await s.cancel();
    expect(k.pending, 0);
  });

  test(
    'URB status -EPIPE on all URBs -> pipe error after retiring all',
    () async {
      k[K.urbStatusAfterReaps] = 1;
      k[K.urbStatusErrno] = Errno.epipe;
      h = UsbfsDeviceHandle.wrap(5, sys: k);
      final s = await h.openBulkIn(0x81, numBuffers: 3, bufferLength: 512);
      final errors = <Object>[];
      final closed = Completer<void>();
      s.blocks.listen(s.release, onError: errors.add, onDone: closed.complete);
      await closed.future.timeout(const Duration(seconds: 10));
      expect((errors.single as UsbException).code, UsbError.pipe);
      await s.cancel();
    },
  );

  test('short URBs deliver actual_length', () async {
    k[K.shortLen] = 100;
    h = UsbfsDeviceHandle.wrap(5, sys: k);
    final s = await h.openBulkIn(0x81, numBuffers: 2, bufferLength: 512);
    final b = await s.blocks.first;
    expect(b.length, 100);
    await s.cancel();
  });

  test('OUT endpoint rejected', () async {
    h = UsbfsDeviceHandle.wrap(5, sys: k);
    await expectLater(
      h.openBulkIn(0x01, numBuffers: 2, bufferLength: 512),
      throwsA(
        isA<UsbException>().having(
          (e) => e.code,
          'code',
          UsbError.invalidParam,
        ),
      ),
    );
  });

  test(
    'bufferLength > 16 KiB without CAP_NO_PACKET_SIZE_LIM -> notSupported',
    () async {
      k.dispose();
      k = FakeUsbfsKernel(
        descriptors: deviceDescriptorBytes(),
        caps: Usbfs.capBulkContinuation,
      );
      h = UsbfsDeviceHandle.wrap(5, sys: k);
      await expectLater(
        h.openBulkIn(0x81, numBuffers: 2, bufferLength: 262144),
        throwsA(
          isA<UsbException>().having(
            (e) => e.code,
            'code',
            UsbError.notSupported,
          ),
        ),
      );
    },
  );

  test('cancel is idempotent and handle.close cancels streams', () async {
    h = UsbfsDeviceHandle.wrap(5, sys: k);
    final s = await h.openBulkIn(0x81, numBuffers: 4, bufferLength: 512);
    final f1 = s.cancel();
    final f2 = s.cancel();
    await Future.wait([f1, f2]).timeout(const Duration(seconds: 10));
    expect(k.pending, 0);
    final s2 = await h.openBulkIn(0x81, numBuffers: 4, bufferLength: 512);
    h.close();
    await s2.cancel().timeout(const Duration(seconds: 10));
    expect(k.pending, 0);
  });
}
