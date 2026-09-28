// System-call layer for the usbfs transport: libc ioctl / lseek / read via dart:ffi.
//
// This is the only place that touches libc. [UsbfsSys] is an interface so the
// transport (incl. the bulk reader isolate) can be exercised on the host with a
// fake kernel (test/usb/fake_usbfs_kernel.dart). Implementations must be
// sendable to another isolate of the same group (no open ports / native
// finalizers), because the reader isolate receives the instance via
// Isolate.spawn.
//
// Reference: libusb os/linux_usbfs.c (master a45bb16) — every ioctl there is
// `ioctl(fd, IOCTL_USBFS_*, arg)` followed by an errno check; descriptors are read
// with lseek(fd, 0, SEEK_SET) + read() in initialize_device() (:1127-1200).
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ffi';

/// Raw syscall interface. All methods return >= 0 on success or `-errno`.
abstract class UsbfsSys {
  const UsbfsSys();

  /// ioctl(fd, request, arg).
  int ioctl(int fd, int request, Pointer<Void> arg);

  /// lseek(fd, 0, SEEK_SET) + read(fd, buf, length): used to read the cached
  /// descriptors (device descriptor first) like libusb initialize_device().
  int readDescriptors(int fd, Pointer<Uint8> buf, int length);
}

// ---------------------------------------------------------------------------
// libc bindings
// ---------------------------------------------------------------------------

typedef _IoctlC = Int Function(Int, UnsignedLong, VarArgs<(Pointer<Void>,)>);
typedef _IoctlD = int Function(int, int, Pointer<Void>);
typedef _LseekC = Int64 Function(Int, Int64, Int);
typedef _LseekD = int Function(int, int, int);
typedef _ReadC = IntPtr Function(Int, Pointer<Void>, Size);
typedef _ReadD = int Function(int, Pointer<Void>, int);
typedef _ErrnoC = Pointer<Int> Function();
typedef _ErrnoD = Pointer<Int> Function();

final DynamicLibrary _libc = DynamicLibrary.process();

// Resolved lazily, per isolate (top-level finals are isolate-local).
final _IoctlD _ioctl = _libc.lookupFunction<_IoctlC, _IoctlD>('ioctl');
final _LseekD _lseek = _libc.lookupFunction<_LseekC, _LseekD>('lseek');
final _ReadD _read = _libc.lookupFunction<_ReadC, _ReadD>('read');

/// glibc/musl: __errno_location(); bionic (Android): __errno().
final _ErrnoD _errnoLocation = () {
  for (final name in const ['__errno_location', '__errno']) {
    if (_libc.providesSymbol(name)) {
      return _libc.lookupFunction<_ErrnoC, _ErrnoD>(name);
    }
  }
  throw UnsupportedError('libc errno accessor not found');
}();

const int _seekSet = 0;
const int _eintr = 4;

/// Real implementation over libc.
///
/// errno is read immediately after the call on the same thread. The calls are
/// non-leaf FFI calls (they may block, e.g. REAPURB), so the isolate thread does
/// a safepoint transition on return; the VM does not issue syscalls on that
/// path in practice, which is the same assumption every dart:ffi errno user
/// makes.
final class LibcUsbfsSys extends UsbfsSys {
  const LibcUsbfsSys();

  @override
  int ioctl(int fd, int request, Pointer<Void> arg) {
    final r = _ioctl(fd, request, arg);
    if (r < 0) return -_errnoLocation().value;
    return r;
  }

  @override
  int readDescriptors(int fd, Pointer<Uint8> buf, int length) {
    int r = _lseek(fd, 0, _seekSet);
    if (r < 0) return -_errnoLocation().value;
    var total = 0;
    while (total < length) {
      r = _read(
        fd,
        Pointer<Void>.fromAddress(buf.address + total),
        length - total,
      );
      if (r < 0) {
        final e = _errnoLocation().value;
        if (e == _eintr) continue;
        return -e;
      }
      if (r == 0) break;
      total += r;
    }
    return total;
  }
}
