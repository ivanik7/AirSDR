// Fake usbfs "kernel" for host tests of UsbfsDeviceHandle / UsbfsBulkInStream.
//
// Implements UsbfsSys by decoding the real ioctl numbers and structs
// (so it also validates that the transport issues the right requests).
// URB state lives in native memory so the reader isolate (which receives a
// copy of this object) and the test isolate (which calls DISCARDURB via
// cancel()) see the same kernel.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ffi';
import 'dart:io' show sleep;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:sdr_flutter/usb/usbfs_abi.dart';
import 'package:sdr_flutter/usb/usbfs_sys.dart';

/// Shared native words.
abstract final class K {
  static const head = 0; // FIFO read index
  static const tail = 1; // FIFO write index
  static const discardAll = 2; // set by DISCARDURB
  static const reaps = 3; // completed (non-cancelled) reaps
  static const seq = 4; // byte pattern counter
  static const enodevAfterReaps = 5; // >0: REAPURB returns ENODEV after N reaps
  static const submits = 6;
  static const discards = 7;
  static const reapDelayUs = 8; // simulated USB time per URB
  static const urbStatusAfterReaps = 9; // >0: URB status error after N reaps
  static const urbStatusErrno = 10;
  static const shortLen = 11; // >0: actual_length for every URB
  static const words = 16;
  static const fifoSize = 1024;
}

class FakeUsbfsKernel extends UsbfsSys {
  final int ctlAddress; // Int64[K.words]
  final int fifoAddress; // Int64[fifoSize] URB addresses

  /// Descriptors returned by read() (null => read fails with EIO).
  final Uint8List? descriptors;

  /// errno for GET_CAPABILITIES (0 => success with [caps]).
  final int capsErrno;
  final int caps;

  // --- test-isolate-only state (synchronous ioctls) ---
  final List<String> log = [];

  /// Control IN responder: returns bytes (<= wLength) or throws an int errno.
  Uint8List Function(int reqType, int req, int value, int index, int length)?
  controlIn;

  /// errno to fail the next control/bulk/u32 ioctl with (0 => none).
  int failNextErrno = 0;

  /// Data returned by a bulk IN (USBDEVFS_BULK) call.
  Uint8List Function(int ep, int length)? bulkIn;

  FakeUsbfsKernel._(
    this.ctlAddress,
    this.fifoAddress,
    this.descriptors,
    this.capsErrno,
    this.caps,
  );

  factory FakeUsbfsKernel({
    Uint8List? descriptors,
    int capsErrno = 0,
    int caps = Usbfs.capBulkContinuation | Usbfs.capNoPacketSizeLim,
  }) {
    final ctl = calloc<Int64>(K.words);
    final fifo = calloc<Int64>(K.fifoSize);
    return FakeUsbfsKernel._(
      ctl.address,
      fifo.address,
      descriptors,
      capsErrno,
      caps,
    );
  }

  Pointer<Int64> get ctl => Pointer<Int64>.fromAddress(ctlAddress);
  Pointer<Int64> get fifo => Pointer<Int64>.fromAddress(fifoAddress);

  int operator [](int w) => ctl[w];
  void operator []=(int w, int v) => ctl[w] = v;

  int get pending => ctl[K.tail] - ctl[K.head];

  void dispose() {
    calloc.free(ctl);
    calloc.free(fifo);
  }

  @override
  int readDescriptors(int fd, Pointer<Uint8> buf, int length) {
    final d = descriptors;
    if (d == null) return -Errno.eio;
    final n = d.length < length ? d.length : length;
    buf.asTypedList(n).setRange(0, n, d);
    return n;
  }

  @override
  int ioctl(int fd, int request, Pointer<Void> arg) {
    if (request == Usbfs.getCapabilities) {
      log.add('GETCAP');
      if (capsErrno != 0) return -capsErrno;
      arg.cast<Uint32>().value = caps;
      return 0;
    }
    if (request == Usbfs.control) return _control(arg.cast());
    if (request == Usbfs.bulk) return _bulk(arg.cast());
    if (request == Usbfs.setConfiguration) return _u32('CFG', arg);
    if (request == Usbfs.claimInterface) return _u32('CLAIM', arg);
    if (request == Usbfs.releaseInterface) return _u32('RELEASE', arg);
    if (request == Usbfs.clearHalt) return _u32('HALT', arg);
    if (request == Usbfs.reset) {
      log.add('RESET');
      return _fail();
    }
    if (request == Usbfs.submitUrb) return _submit(arg.cast());
    if (request == Usbfs.reapUrb) return _reap(arg.cast());
    if (request == Usbfs.discardUrb) {
      ctl[K.discards]++;
      ctl[K.discardAll] = 1;
      return 0;
    }
    return -Errno.enotty;
  }

  int _fail() {
    final e = failNextErrno;
    failNextErrno = 0;
    return e == 0 ? 0 : -e;
  }

  int _u32(String name, Pointer<Void> arg) {
    log.add('$name ${arg.cast<Uint32>().value}');
    return _fail();
  }

  int _control(Pointer<UsbdevfsCtrlTransfer> p) {
    final c = p.ref;
    final isIn = (c.bRequestType & 0x80) != 0;
    final len = c.wLength;
    final data = c.data.cast<Uint8>();
    final hdr =
        'CTRL ${c.bRequestType.toRadixString(16)} ${c.bRequest.toRadixString(16)} '
        '${c.wValue.toRadixString(16)} ${c.wIndex.toRadixString(16)} $len t=${c.timeout}';
    if (!isIn) {
      final out = len == 0 ? '' : ' ${_hex(data.asTypedList(len))}';
      log.add('$hdr$out');
      final e = _fail();
      return e < 0 ? e : len;
    }
    log.add(hdr);
    final e = _fail();
    if (e < 0) return e;
    final h = controlIn;
    if (h == null) return -Errno.epipe;
    final Uint8List resp;
    try {
      resp = h(c.bRequestType, c.bRequest, c.wValue, c.wIndex, len);
    } on int catch (errno) {
      return -errno;
    }
    final n = resp.length < len ? resp.length : len;
    if (n > 0) data.asTypedList(n).setRange(0, n, resp);
    return n;
  }

  int _bulk(Pointer<UsbdevfsBulkTransfer> p) {
    final b = p.ref;
    final data = b.data.cast<Uint8>();
    final isIn = (b.ep & 0x80) != 0;
    log.add('BULK ${b.ep.toRadixString(16)} ${b.len} t=${b.timeout}');
    final e = _fail();
    if (e < 0) return e;
    if (!isIn) return b.len;
    final h = bulkIn;
    final resp = h == null ? Uint8List(0) : h(b.ep, b.len);
    final n = resp.length < b.len ? resp.length : b.len;
    if (n > 0) data.asTypedList(n).setRange(0, n, resp);
    return n;
  }

  int _submit(Pointer<UsbdevfsUrb> urb) {
    final u = urb.ref;
    if (u.type != Usbfs.urbTypeBulk || (u.endpoint & 0x80) == 0) {
      return -Errno.einval;
    }
    if (ctl[K.enodevAfterReaps] > 0 &&
        ctl[K.reaps] >= ctl[K.enodevAfterReaps]) {
      return -Errno.enodev;
    }
    if (pending >= K.fifoSize) return -Errno.enomem;
    fifo[ctl[K.tail] % K.fifoSize] = urb.address;
    ctl[K.tail]++;
    ctl[K.submits]++;
    return 0;
  }

  /// Blocking reap: pops the oldest URB. Discarded URBs complete with
  /// -ENOENT immediately; otherwise waits [K.reapDelayUs] and fills the buffer
  /// with an incrementing byte pattern (bytes 0..3 = completion number).
  int _reap(Pointer<Pointer<UsbdevfsUrb>> out) {
    if (pending == 0) {
      // A real REAPURB would block forever here; the transport must never
      // reap with nothing in flight.
      return -Errno.eagain;
    }
    final discarded = ctl[K.discardAll] != 0;
    if (!discarded &&
        ctl[K.enodevAfterReaps] > 0 &&
        ctl[K.reaps] >= ctl[K.enodevAfterReaps]) {
      return -Errno.enodev;
    }
    final addr = fifo[ctl[K.head] % K.fifoSize];
    ctl[K.head]++;
    final urb = Pointer<UsbdevfsUrb>.fromAddress(addr);
    final u = urb.ref;
    if (discarded) {
      u.status = -Errno.enoent;
      u.actualLength = 0;
    } else {
      final d = ctl[K.reapDelayUs];
      if (d > 0) sleep(Duration(microseconds: d));
      if (ctl[K.urbStatusAfterReaps] > 0 &&
          ctl[K.reaps] >= ctl[K.urbStatusAfterReaps]) {
        u.status = -ctl[K.urbStatusErrno];
        u.actualLength = 0;
      } else {
        final len = ctl[K.shortLen] > 0 ? ctl[K.shortLen] : u.bufferLength;
        final buf = u.buffer.cast<Uint8>().asTypedList(len);
        var s = ctl[K.seq];
        for (var i = 0; i < len; i++) {
          buf[i] = (s + i) & 0xff;
        }
        ctl[K.seq] = s + len;
        // First 4 bytes: little-endian sequence number of this completion
        // (lets tests check ordering and count gaps == drops).
        if (len >= 4) {
          final n = ctl[K.reaps];
          buf[0] = n & 0xff;
          buf[1] = (n >> 8) & 0xff;
          buf[2] = (n >> 16) & 0xff;
          buf[3] = (n >> 24) & 0xff;
        }
        u.status = 0;
        u.actualLength = len;
      }
      ctl[K.reaps]++;
    }
    out.value = urb;
    return 0;
  }
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// 18-byte device descriptor for tests.
Uint8List deviceDescriptorBytes({
  int vid = 0x0bda,
  int pid = 0x2838,
  int bcd = 0x0100,
  int iMan = 1,
  int iProd = 2,
  int iSer = 3,
}) => Uint8List.fromList([
  18, 1, 0x00, 0x02, 0, 0, 0, 64, //
  vid & 0xff, vid >> 8, pid & 0xff, pid >> 8, bcd & 0xff, bcd >> 8,
  iMan, iProd, iSer, 1,
]);
