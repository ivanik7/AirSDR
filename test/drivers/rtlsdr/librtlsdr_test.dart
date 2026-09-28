// Unit tests for lib/drivers/rtlsdr/librtlsdr.dart beyond the C oracle traces:
// async streaming over openBulkIn, cancel, device loss, error paths.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ffi';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/drivers/rtlsdr/librtlsdr.dart';
import 'package:sdr_flutter/usb/usb_transport.dart';

import 'fake_rtl_usb.dart';

FakeRtlUsbDevice _usb({String product = 'RTL2838UHIDIR'}) =>
    FakeRtlUsbDevice(FakeModel()
      ..tuner = FakeTuner.r820t
      ..product = product);

class _ClaimFails extends FakeRtlUsbDevice {
  _ClaimFails() : super(FakeModel()..tuner = FakeTuner.r820t);
  @override
  void claimInterface(int interfaceNumber) =>
      throw UsbException(UsbError.busy, 'busy');
}

void main() {
  rtlsdrLog = (_) {};

  test('open probes R820T and reports its gain table', () {
    final res = RtlSdrDev.open(_usb());
    expect(res.r, 0);
    final dev = res.dev!;
    expect(dev.getTunerType(), RtlSdrTuner.r820t);
    expect(dev.getTunerGains().length, 29);
    expect(dev.manufact, 'Realtek');
    expect(dev.r82xxP.initDone, 1);
    expect(dev.getXtalFreq().tunerFreq, defRtlXtalFreq);
  });

  test('open fails and closes handle when claim_interface fails', () {
    final usb = _ClaimFails();
    final res = RtlSdrDev.open(usb);
    expect(res.r, UsbError.busy);
    expect(res.dev, isNull);
    expect(usb.closed, isTrue);
  });

  test('sample rate validation and exact rate', () {
    final dev = RtlSdrDev.open(_usb()).dev!;
    expect(dev.setSampleRate(225000), -Errno.einval);
    expect(dev.setSampleRate(500000), -Errno.einval);
    expect(dev.setSampleRate(3200001), -Errno.einval);
    expect(dev.setSampleRate(2400000), 0);
    expect(dev.getSampleRate(), 2400000);
    expect(dev.setSampleRate(1000000), 0);
    // real_rate = 1000000.026... truncated to uint32
    expect(dev.getSampleRate(), 1000000);
  });

  test('offset tuning is refused on R82xx, ppm is stored', () {
    final dev = RtlSdrDev.open(_usb()).dev!;
    expect(dev.setOffsetTuning(1), -2);
    expect(dev.setFreqCorrection(10), 0);
    expect(dev.setFreqCorrection(10), -2);
    expect(dev.getXtalFreq().rtlFreq, 28800288);
  });

  test('readSync maps to a bulk IN on 0x81', () {
    final usb = _usb();
    final dev = RtlSdrDev.open(usb).dev!;
    final buf = Uint8List(1024);
    final r = dev.readSync(buf, 1024);
    expect(r.r, 0);
    expect(r.nRead, 1024);
    expect(buf[1], 4);
    expect(usb.trace.toString(), contains('BULK ep=81 len=1024 to=0'));
  });

  test('readAsync delivers blocks, releases them, and stops on cancel',
      () async {
    final usb = _usb()..bulkBlocksToEmit = 5;
    final dev = RtlSdrDev.open(usb).dev!;
    dev.resetBuffer();
    final got = <int>[];
    final done = dev.readAsync((block) {
      final p = Pointer<Uint8>.fromAddress(block.address)
          .asTypedList(block.length);
      got.add(p[0]);
      if (got.length == 5) dev.cancelAsync();
    }, 0, 0);
    expect(dev.readAsync((_) {}, 0, 0), completion(-2)); // already running
    expect(await done, 0);
    expect(got, [0, 1, 2, 3, 4]);
    expect(usb.trace.toString(),
        contains('BULKIN ep=81 n=$defaultBufNumber len=$defaultBufLength'));
    expect(usb.lastStream!.released, 5);
    expect(usb.lastStream!.cancelled, isTrue);
    expect(dev.asyncStatus, RtlSdrAsyncStatus.inactive);
    expect(dev.cancelAsync(), -2);
    expect(await dev.close(), 0);
  });

  test('readAsync honours buf_num / buf_len (multiple of 512 only)', () async {
    final usb = _usb()..bulkBlocksToEmit = 1;
    final dev = RtlSdrDev.open(usb).dev!;
    final f = dev.readAsync((_) => dev.cancelAsync(), 4, 11776);
    expect(await f, 0);
    expect(usb.trace.toString(), contains('BULKIN ep=81 n=4 len=11776'));
    final f2 = dev.readAsync((_) => dev.cancelAsync(), 3, 1000);
    expect(await f2, 0);
    expect(usb.trace.toString(),
        contains('BULKIN ep=81 n=3 len=$defaultBufLength'));
  });

  test('readAsync returns -1 when the device disappears', () async {
    final usb = _usb()
      ..bulkBlocksToEmit = 2
      ..bulkErrorAfterBlocks = UsbException(UsbError.noDevice, 'gone');
    final dev = RtlSdrDev.open(usb).dev!;
    var n = 0;
    expect(await dev.readAsync((_) => n++, 0, 0), -1);
    expect(n, 2);
    expect(dev.devLost, 1);
    // close() on a lost device skips deinit (no control transfers)
    final before = usb.trace.length;
    await dev.close();
    expect(usb.trace.toString().substring(before).trim(),
        'RELEASE if=0 ret=0\nCLOSE');
  });

  test('close waits for a running readAsync to finish', () async {
    final usb = _usb()..bulkBlocksToEmit = 0;
    final dev = RtlSdrDev.open(usb).dev!;
    final f = dev.readAsync((_) {}, 0, 0);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    var closed = false;
    final c = dev.close().then((_) => closed = true);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(closed, isFalse);
    dev.cancelAsync();
    expect(await f, 0);
    await c;
    expect(closed, isTrue);
  });

  test('unported tuner (FC2580) is probed and reported as unsupported', () {
    final logs = <String>[];
    rtlsdrLog = logs.add;
    final dev =
        RtlSdrDev.open(FakeRtlUsbDevice(FakeModel()..tuner = FakeTuner.fc2580))
            .dev!;
    rtlsdrLog = (_) {};
    expect(dev.getTunerType(), RtlSdrTuner.fc2580);
    expect(logs.any((l) => l.contains('unsupported tuner')), isTrue);
    expect(dev.setCenterFreq(100000000), -1); // no set_freq in iface
    expect(dev.getCenterFreq(), 0);
  });

  test('E4000 / FC0012 / FC0013 have a tuner driver', () {
    for (final t in [FakeTuner.e4000, FakeTuner.fc0012, FakeTuner.fc0013]) {
      final dev = RtlSdrDev.open(FakeRtlUsbDevice(FakeModel()..tuner = t)).dev!;
      expect(dev.tuner!.setFreq, isNotNull, reason: '$t');
      expect(dev.setCenterFreq(433920000), 0, reason: '$t');
      expect(dev.getCenterFreq(), 433920000, reason: '$t');
    }
  });
}
