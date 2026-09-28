// Linux usbfs ABI (ioctl numbers, structs, errno values) for the dart:ffi
// transport in usbfs_transport.dart.
//
// Sources:
//  * <linux/usbdevice_fs.h> (uapi) — struct usbdevfs_ctrltransfer / _bulktransfer /
//    _urb, USBDEVFS_* ioctl numbers, USBDEVFS_CAP_*, USBDEVFS_URB_*.
//  * libusb os/linux_usbfs.h (libusb master a45bb16, lines 29-160) — the same
//    definitions as used by libusb's usbfs backend (`struct usbfs_urb`,
//    IOCTL_USBFS_*, USBFS_CAP_*, MAX_BULK_BUFFER_LENGTH).
//  * <asm-generic/ioctl.h>, <asm-generic/errno*.h> — _IOC encoding and errno
//    numbers; identical on arm64 and x86_64 (the only ABIs we support).
//
// Measured on the host with gcc (tool/usbfs_abi_oracle.c, see test/usb/
// usbfs_abi_test.dart): CONTROL=0xc0185500 (24 B), BULK=0xc0185502 (24 B),
// SUBMITURB=0x8038550a (urb 56 B: status@4 buffer@16 buffer_length@24
// actual_length@28 usercontext@48), REAPURB=0x4008550c, REAPURBNDELAY=0x4008550d,
// DISCARDURB=0x550b, CLAIM=0x8004550f, RELEASE=0x80045510, RESET=0x5514,
// CLEAR_HALT=0x80045515, SETCONFIGURATION=0x80045505, GET_CAPABILITIES=0x8004551a.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ffi';

// ---------------------------------------------------------------------------
// <asm-generic/ioctl.h>
// ---------------------------------------------------------------------------

abstract final class Ioc {
  static const nrBits = 8;
  static const typeBits = 8;
  static const sizeBits = 14;
  static const nrShift = 0;
  static const typeShift = nrShift + nrBits; // 8
  static const sizeShift = typeShift + typeBits; // 16
  static const dirShift = sizeShift + sizeBits; // 30

  static const none = 0;
  static const write = 1;
  static const read = 2;

  /// _IOC(dir, type, nr, size)
  static int ioc(int dir, int type, int nr, int size) {
    if (size < 0 || size >= (1 << sizeBits)) {
      throw ArgumentError.value(size, 'size', 'does not fit _IOC_SIZEBITS');
    }
    return (dir << dirShift) |
        (type << typeShift) |
        (nr << nrShift) |
        (size << sizeShift);
  }

  static int io(int type, int nr) => ioc(none, type, nr, 0);
  static int ior(int type, int nr, int size) => ioc(read, type, nr, size);
  static int iow(int type, int nr, int size) => ioc(write, type, nr, size);
  static int iowr(int type, int nr, int size) =>
      ioc(read | write, type, nr, size);
}

// ---------------------------------------------------------------------------
// Structs (<linux/usbdevice_fs.h>). Layout is computed by dart:ffi for the
// running ABI; tests pin the 64-bit offsets against the C compiler.
// ---------------------------------------------------------------------------

/// struct usbdevfs_ctrltransfer (libusb: struct usbfs_ctrltransfer).
final class UsbdevfsCtrlTransfer extends Struct {
  @Uint8()
  external int bRequestType;
  @Uint8()
  external int bRequest;
  @Uint16()
  external int wValue;
  @Uint16()
  external int wIndex;
  @Uint16()
  external int wLength;

  /// in milliseconds
  @Uint32()
  external int timeout;

  /// pointer to data
  external Pointer<Void> data;
}

/// struct usbdevfs_bulktransfer.
final class UsbdevfsBulkTransfer extends Struct {
  @Uint32()
  external int ep;
  @Uint32()
  external int len;

  /// in milliseconds
  @Uint32()
  external int timeout;

  /// pointer to data
  external Pointer<Void> data;
}

/// struct usbdevfs_urb (libusb: struct usbfs_urb), without the trailing
/// iso_frame_desc[0] flexible array (unused for bulk).
final class UsbdevfsUrb extends Struct {
  @Uint8()
  external int type;
  @Uint8()
  external int endpoint;
  @Int32()
  external int status;
  @Uint32()
  external int flags;
  external Pointer<Void> buffer;
  @Int32()
  external int bufferLength;
  @Int32()
  external int actualLength;
  @Int32()
  external int startFrame;

  /// union { int number_of_packets; unsigned int stream_id; }
  @Int32()
  external int numberOfPackets;
  @Int32()
  external int errorCount;
  @Uint32()
  external int signr;
  external Pointer<Void> usercontext;
}

// ---------------------------------------------------------------------------
// Constants (libusb os/linux_usbfs.h)
// ---------------------------------------------------------------------------

abstract final class Usbfs {
  // URB flags
  static const urbShortNotOk = 0x01;
  static const urbIsoAsap = 0x02;
  static const urbBulkContinuation = 0x04;
  static const urbQueueBulk = 0x10;
  static const urbZeroPacket = 0x40;

  // URB types
  static const urbTypeIso = 0;
  static const urbTypeInterrupt = 1;
  static const urbTypeControl = 2;
  static const urbTypeBulk = 3;

  /// Max bulk URB size on kernels without USBFS_CAP_NO_PACKET_SIZE_LIM.
  static const maxBulkBufferLength = 16384;
  static const maxCtrlBufferLength = 4096;

  // Capabilities (USBDEVFS_GET_CAPABILITIES)
  static const capZeroPacket = 0x01;
  static const capBulkContinuation = 0x02;
  static const capNoPacketSizeLim = 0x04;
  static const capBulkScatterGather = 0x08;
  static const capReapAfterDisconnect = 0x10;

  static const _u = 0x55; // 'U'

  // ioctl numbers. The struct-sized ones depend on the ABI via sizeOf<>().
  static final int control = Ioc.iowr(_u, 0, sizeOf<UsbdevfsCtrlTransfer>());
  static final int bulk = Ioc.iowr(_u, 2, sizeOf<UsbdevfsBulkTransfer>());
  static final int setConfiguration = Ioc.ior(_u, 5, sizeOf<Uint32>());
  static final int submitUrb = Ioc.ior(_u, 10, sizeOf<UsbdevfsUrb>());
  static final int discardUrb = Ioc.io(_u, 11);
  static final int reapUrb = Ioc.iow(_u, 12, sizeOf<Pointer<Void>>());
  static final int reapUrbNdelay = Ioc.iow(_u, 13, sizeOf<Pointer<Void>>());
  static final int claimInterface = Ioc.ior(_u, 15, sizeOf<Uint32>());
  static final int releaseInterface = Ioc.ior(_u, 16, sizeOf<Uint32>());
  static final int reset = Ioc.io(_u, 20);
  static final int clearHalt = Ioc.ior(_u, 21, sizeOf<Uint32>());
  static final int getCapabilities = Ioc.ior(_u, 26, sizeOf<Uint32>());
}

// ---------------------------------------------------------------------------
// errno (asm-generic/errno-base.h + errno.h; same numbers on arm64 & x86_64)
// ---------------------------------------------------------------------------

abstract final class Errno {
  static const eperm = 1;
  static const enoent = 2;
  static const eintr = 4;
  static const eio = 5;
  static const eagain = 11;
  static const enomem = 12;
  static const eacces = 13;
  static const efault = 14;
  static const ebusy = 16;
  static const enodev = 19;
  static const einval = 22;
  static const enotty = 25;
  static const epipe = 32;
  static const enosys = 38;
  static const enodata = 61;
  static const etime = 62;
  static const enosr = 63;
  static const ecomm = 70;
  static const eproto = 71;
  static const eoverflow = 75;
  static const eilseq = 84;
  static const emsgsize = 90;
  static const econnreset = 104;
  static const eshutdown = 108;
  static const etimedout = 110;
  static const eremoteio = 121;
}

/// True when the usbfs ioctl transport can run on this ABI (64-bit only;
/// armv7 is not supported, see STATUS-usb.md).
bool get usbfsAbiSupported => sizeOf<Pointer<Void>>() == 8;
