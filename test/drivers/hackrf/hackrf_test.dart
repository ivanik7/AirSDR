// Unit tests for lib/drivers/hackrf/hackrf.dart beyond the C trace oracle:
// RX streaming over UsbDeviceHandle.openBulkIn, sample-rate fraction search,
// closed-device behaviour.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/drivers/hackrf/hackrf.dart';
import 'package:sdr_flutter/drivers/hackrf/hackrf_convert.dart';
import 'package:sdr_flutter/usb/usb_transport.dart';

import 'recording_usb_handle.dart';

Future<void> _pump() => Future<void>.delayed(Duration.zero);

void main() {
  setUp(() => lastLibusbError = 0);

  test(
    'openBulkIn uses endpoint 0x81, TRANSFER_COUNT x TRANSFER_BUFFER_SIZE',
    () async {
      final usb = RecordingUsbHandle();
      final (r, dev) = hackrfOpenSetup(usb);
      expect(r, hackrfSuccess);
      expect(dev!.bufferSize, 32768);
      expect(await dev.startRx((t) => 0), hackrfSuccess);
      final s = usb.streams.single;
      expect(s.endpoint, 0x81);
      expect(s.numBuffers, 4);
      expect(s.bufferLength, 262144);
      expect(dev.getTransferQueueDepth(), transferCount);
      expect(dev.getTransferBufferSize(), transferBufferSize);
      expect(await dev.close(), hackrfSuccess);
      expect(s.cancelled, isTrue);
      expect(usb.closed, isTrue);
    },
  );

  test(
    'RX callback receives int8 IQ; blocks released; convert fast path',
    () async {
      final usb = RecordingUsbHandle();
      final (_, dev) = hackrfOpenSetup(usb);
      final got = <List<double>>[];
      final ctx = Object();
      Object? seenCtx;
      final out = Float32List(transferBufferSize);
      expect(
        await dev!.startRx((t) {
          seenCtx = t.rxCtx;
          expect(t.bufferLength, transferBufferSize);
          final n = hackrfConvertS8ToF32(t.buffer, t.validLength, out);
          expect(n, t.validLength ~/ 2);
          got.add(out.sublist(0, t.validLength).toList());
          return 0;
        }, ctx),
        hackrfSuccess,
      );
      final s = usb.streams.single;
      s.emit([0x00, 0x7f, 0x80, 0xff]);
      s.emit([0x40, 0xc0]);
      await _pump();
      expect(identical(seenCtx, ctx), isTrue);
      expect(got, [
        [0.0, 127 / 128, -1.0, -1 / 128],
        [0.5, -0.5],
      ]);
      expect(s.released, [0, 1]); // both slots given back to the pool
      expect(dev.isStreaming(), hackrfTrue);
      expect(await dev.stopRx(), hackrfSuccess);
      expect(dev.isStreaming(), hackrfErrorStreamingStopped);
      await dev.close();
    },
  );

  test(
    'callback returning nonzero stops streaming (no more callbacks)',
    () async {
      final usb = RecordingUsbHandle();
      final (_, dev) = hackrfOpenSetup(usb);
      var calls = 0;
      await dev!.startRx((t) {
        calls++;
        return 1;
      });
      final s = usb.streams.single;
      s.emit([1, 2]);
      s.emit([3, 4]);
      await _pump();
      expect(calls, 1);
      expect(dev.isStreaming(), hackrfErrorStreamingStopped);
      expect(s.released.length, 2);
      // transfers are still "setup" until stop_rx, like in C
      expect(await dev.startRx((t) => 0), hackrfErrorBusy);
      expect(await dev.stopRx(), hackrfSuccess);
      await dev.close();
    },
  );

  test('transfer error stops streaming', () async {
    final usb = RecordingUsbHandle();
    final (_, dev) = hackrfOpenSetup(usb);
    await dev!.startRx((t) => 0);
    usb.streams.single.fail(UsbException(UsbError.noDevice, 'gone'));
    await _pump();
    expect(dev.isStreaming(), hackrfErrorStreamingStopped);
    await dev.close();
    expect(dev.isStreaming(), hackrfErrorStreamingThreadErr);
  });

  test('start/stop/start again reopens bulk stream', () async {
    final usb = RecordingUsbHandle();
    final (_, dev) = hackrfOpenSetup(usb);
    await dev!.startRx((t) => 0);
    expect(await dev.stopRx(), hackrfSuccess);
    expect(await dev.startRx((t) => 0), hackrfSuccess);
    expect(usb.streams.length, 2);
    expect(usb.streams[0].cancelled, isTrue);
    expect(usb.streams[1].cancelled, isFalse);
    await dev.close();
    expect(usb.streams[1].cancelled, isTrue);
  });

  test('calls after close return USB error, not crash', () async {
    final usb = RecordingUsbHandle();
    final (_, dev) = hackrfOpenSetup(usb);
    await dev!.close();
    expect(dev.setFreq(100000000), hackrfErrorLibusb);
    expect(
      hackrfErrorName(hackrfErrorLibusb),
      'No such device (it may have been disconnected)',
    );
    expect(dev.setLnaGain(8), hackrfErrorInvalidParam);
  });

  test('board rev read requires USB API 0x0106', () async {
    final (_, oldDev) = hackrfOpenSetup(RecordingUsbHandle(bcdDevice: 0x0104));
    expect(oldDev!.boardRevRead().$1, hackrfErrorUsbApiVersion);
    final (_, dev) = hackrfOpenSetup(RecordingUsbHandle());
    expect(dev!.boardRevRead(), (hackrfSuccess, 5));
    await oldDev.close();
    await dev.close();
  });

  test('set_sample_rate fraction search (IEEE754 via ByteData)', () {
    expect(hackrfSampleRateToFracrate(2e6), (2000000, 1));
    expect(hackrfSampleRateToFracrate(20e6), (20000000, 1));
    expect(hackrfSampleRateToFracrate(8e6 / 3), (8000000, 3));
    expect(hackrfSampleRateToFracrate(10e6 / 7), (10000000, 7));
    expect(hackrfSampleRateToFracrate(6e6 + 0.25), (24000001, 4));
  });

  test('hackrfIsHackrfUsbId', () {
    expect(hackrfIsHackrfUsbId(0x1d50, 0x6089), isTrue);
    expect(hackrfIsHackrfUsbId(0x1d50, 0x604b), isTrue);
    expect(hackrfIsHackrfUsbId(0x1d50, 0xcc15), isTrue);
    expect(hackrfIsHackrfUsbId(0x0bda, 0x2838), isFalse);
  });

  test('hackrfExit refuses while a device is open', () async {
    final (_, dev) = hackrfOpenSetup(RecordingUsbHandle());
    expect(hackrfExit(), hackrfErrorNotLastDevice);
    await dev!.close();
    expect(hackrfExit(), hackrfSuccess);
  });
}
