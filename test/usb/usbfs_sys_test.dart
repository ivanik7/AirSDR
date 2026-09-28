// Smoke test of the real libc bindings (LibcUsbfsSys): VarArgs ioctl, errno
// accessor, lseek+read. Runs on the Linux host without SDR hardware:
//  * ioctl(USBDEVFS_GET_CAPABILITIES) on /dev/null must fail with ENOTTY;
//  * if /dev/bus/usb/001/001 (root hub) is readable, reading descriptors
//    returns a valid device descriptor (what UsbfsDeviceHandle.wrap does).
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/usb/usb_descriptors.dart';
import 'package:sdr_flutter/usb/usbfs_abi.dart';
import 'package:sdr_flutter/usb/usbfs_sys.dart';

final _libc = DynamicLibrary.process();
final _open = _libc
    .lookupFunction<
      Int Function(Pointer<Utf8>, Int, VarArgs<(Int,)>),
      int Function(Pointer<Utf8>, int, int)
    >('open');
final _close = _libc.lookupFunction<Int Function(Int), int Function(int)>(
  'close',
);

int _openRo(String path) {
  final p = path.toNativeUtf8();
  try {
    return _open(p, 0 /* O_RDONLY */, 0);
  } finally {
    malloc.free(p);
  }
}

void main() {
  const sys = LibcUsbfsSys();

  test('ioctl on a non-usbfs fd -> -ENOTTY', () {
    final fd = _openRo('/dev/null');
    expect(fd, greaterThanOrEqualTo(0));
    final caps = calloc<Uint32>();
    try {
      expect(sys.ioctl(fd, Usbfs.getCapabilities, caps.cast()), -Errno.enotty);
    } finally {
      calloc.free(caps);
      _close(fd);
    }
  });

  test('ioctl on a bad fd -> -EBADF', () {
    expect(sys.ioctl(-1, Usbfs.getCapabilities, nullptr), -9);
  });

  test('read root hub descriptors via usbfs node', () {
    const path = '/dev/bus/usb/001/001';
    if (!File(path).existsSync()) {
      markTestSkipped('$path not present');
      return;
    }
    final fd = _openRo(path);
    if (fd < 0) {
      markTestSkipped('$path not readable');
      return;
    }
    final buf = calloc<Uint8>(4096);
    try {
      final n = sys.readDescriptors(fd, buf, 4096);
      expect(n, greaterThanOrEqualTo(18));
      final d = parseDeviceDescriptor(buf.asTypedList(n));
      expect(d.vendorId, 0x1d6b); // Linux Foundation root hub
      // GET_CAPABILITIES needs a writable fd on most kernels: accept 0 or -EPERM.
      final caps = calloc<Uint32>();
      final r = sys.ioctl(fd, Usbfs.getCapabilities, caps.cast());
      expect(
        r == 0 || r == -1 /* EPERM */ || r == -Errno.eacces,
        isTrue,
        reason: 'r=$r',
      );
      calloc.free(caps);
    } finally {
      calloc.free(buf);
      _close(fd);
    }
  });
}
