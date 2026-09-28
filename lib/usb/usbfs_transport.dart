// UsbDeviceHandle over a usbfs file descriptor, using libc ioctl via dart:ffi.
//
// Dart port of the synchronous parts of libusb's Linux backend
// (libusb os/linux_usbfs.c, master a45bb16):
//   op_wrap_sys_device / initialize_device / initialize_handle  (:1127-1200, :1562-1629)
//   op_set_configuration (:1698), claim_interface (:1728), release_interface (:1748),
//   op_clear_halt (:1788), op_reset_device (:1809)
// plus libusb_control_transfer / libusb_bulk_transfer semantics (sync.c), done with
// the synchronous USBDEVFS_CONTROL / USBDEVFS_BULK ioctls instead of URBs.
// Streaming (rtlsdr_read_async equivalent) lives in usbfs_bulk_stream.dart.
//
// The fd is owned by Kotlin (UsbDeviceConnection, see UsbSdrPlugin.kt); this
// class never closes it (libusb: hpriv->fd_keep = 1).
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'usb_descriptors.dart';
import 'usb_transport.dart';
import 'usbfs_abi.dart';
import 'usbfs_bulk_stream.dart';
import 'usbfs_sys.dart';

/// Map an errno from a synchronous transfer ioctl (USBDEVFS_CONTROL/BULK,
/// i.e. kernel usb_control_msg/usb_bulk_msg) to a libusb error code.
/// Mirrors how libusb's sync.c reports LIBUSB_TRANSFER_* statuses.
int usbErrorFromTransferErrno(int errno) {
  switch (errno) {
    case Errno.etimedout:
      return UsbError.timeout;
    case Errno.epipe:
      return UsbError.pipe;
    case Errno.enodev:
    case Errno.eshutdown:
      return UsbError.noDevice;
    case Errno.eoverflow:
      return UsbError.overflow;
    case Errno.einval:
      return UsbError.invalidParam;
    case Errno.eacces:
    case Errno.eperm:
      return UsbError.access;
    case Errno.enomem:
      return UsbError.noMem;
    case Errno.ebusy:
      return UsbError.busy;
    case Errno.enoent:
      return UsbError.notFound;
    case Errno.eintr:
      return UsbError.interrupted;
    default:
      // EPROTO/EILSEQ/ETIME/ECOMM/ENOSR/EIO... -> LIBUSB_TRANSFER_ERROR -> IO
      return UsbError.io;
  }
}

class UsbfsDeviceHandle implements UsbDeviceHandle {
  /// usbfs fd from UsbDeviceConnection.getFileDescriptor() (not owned).
  final int fd;
  final UsbfsSys sys;

  /// USBDEVFS_GET_CAPABILITIES result (USBFS_CAP_*).
  final int caps;

  /// Whether GET_CAPABILITIES succeeded (false => [caps] is libusb's fallback).
  final bool capsQueried;

  /// Extra buffers in the bulk stream pool beyond the URBs in flight; this is
  /// how many blocks the consumer may hold before the reader starts dropping.
  /// null => numBuffers.
  final int? spareBulkSlots;

  @override
  late final UsbDeviceDescriptor deviceDescriptor;

  /// Raw descriptors read from the fd (device descriptor first, then configs),
  /// or the 18-byte GET_DESCRIPTOR(DEVICE) answer when the read failed.
  late final Uint8List rawDescriptors;

  final Set<int> _claimedInterfaces = {};
  final Set<UsbfsBulkInStream> _streams = {};
  bool _closed = false;

  // Scratch native memory for synchronous ioctls (reused, grown on demand).
  final Pointer<UsbdevfsCtrlTransfer> _ctrl;
  final Pointer<UsbdevfsBulkTransfer> _bulk;
  final Pointer<Uint32> _u32;
  Pointer<Uint8> _buf;
  int _bufCap;

  UsbfsDeviceHandle._(
    this.fd,
    this.sys,
    this.caps,
    this.capsQueried,
    this.spareBulkSlots,
  ) : _ctrl = calloc<UsbdevfsCtrlTransfer>(),
      _bulk = calloc<UsbdevfsBulkTransfer>(),
      _u32 = calloc<Uint32>(),
      _buf = calloc<Uint8>(4096),
      _bufCap = 4096;

  /// libusb_wrap_sys_device() equivalent: wrap an already-open usbfs fd.
  static UsbfsDeviceHandle wrap(
    int fd, {
    UsbfsSys sys = const LibcUsbfsSys(),
    int? spareBulkSlots,
  }) {
    if (!usbfsAbiSupported) {
      throw UsbException(
        UsbError.notSupported,
        'usbfs transport supports 64-bit ABIs only (arm64/x86_64)',
      );
    }
    if (fd < 0) throw UsbException(UsbError.invalidParam, 'bad fd $fd');

    // initialize_handle(): USBDEVFS_GET_CAPABILITIES
    final capsP = calloc<Uint32>();
    int caps;
    bool capsQueried;
    try {
      final r = sys.ioctl(fd, Usbfs.getCapabilities, capsP.cast());
      if (r < 0) {
        if (-r == Errno.enodev) {
          throw UsbException(UsbError.noDevice, 'getcap: no device');
        }
        // libusb: "getcap not available" (ENOTTY) or "getcap failed" -> fallback
        caps = Usbfs.capBulkContinuation;
        capsQueried = false;
      } else {
        caps = capsP.value;
        capsQueried = true;
      }
    } finally {
      calloc.free(capsP);
    }

    // initialize_device(): cache descriptors in memory (lseek 0 + read).
    Uint8List raw = Uint8List(0);
    UsbDeviceDescriptor? desc;
    const readLen = 4096;
    final p = calloc<Uint8>(readLen);
    try {
      final n = sys.readDescriptors(fd, p, readLen);
      if (n >= UsbStd.dtDeviceSize) {
        raw = Uint8List.fromList(p.asTypedList(n));
        try {
          desc = parseDeviceDescriptor(raw);
        } on UsbException {
          desc = null;
        }
      }
    } finally {
      calloc.free(p);
    }

    final h = UsbfsDeviceHandle._(fd, sys, caps, capsQueried, spareBulkSlots);
    if (desc == null) {
      // Fallback: GET_DESCRIPTOR(DEVICE) over EP0 (libusb_get_descriptor).
      try {
        final d = Uint8List(UsbStd.dtDeviceSize);
        final n = h.controlTransfer(
          UsbReqType.endpointIn,
          UsbStd.requestGetDescriptor,
          UsbStd.dtDevice << 8,
          0,
          d,
          d.length,
        );
        if (n != UsbStd.dtDeviceSize) {
          throw UsbException(UsbError.io, 'short device descriptor ($n)');
        }
        desc = parseDeviceDescriptor(d);
        raw = d;
      } catch (_) {
        h.close();
        rethrow;
      }
    }
    h.deviceDescriptor = desc;
    h.rawDescriptors = raw;
    return h;
  }

  void _checkOpen() {
    if (_closed) throw UsbException(UsbError.noDevice, 'handle closed');
  }

  Pointer<Uint8> _scratch(int length) {
    if (length > _bufCap) {
      calloc.free(_buf);
      _bufCap = length;
      _buf = calloc<Uint8>(length);
    }
    return _buf;
  }

  // -------------------------------------------------------------------------
  // Transfers
  // -------------------------------------------------------------------------

  @override
  int controlTransfer(
    int requestType,
    int request,
    int value,
    int index,
    Uint8List data,
    int length, {
    int timeoutMs = 1000,
  }) {
    _checkOpen();
    if (length < 0 || length > 0xffff || length > data.length) {
      throw UsbException(
        UsbError.invalidParam,
        'control length $length (buffer ${data.length})',
      );
    }
    final isIn = (requestType & UsbReqType.endpointIn) != 0;
    final buf = _scratch(length == 0 ? 1 : length);
    if (!isIn && length > 0) {
      buf.asTypedList(length).setRange(0, length, data);
    }
    final c = _ctrl.ref
      ..bRequestType = requestType & 0xff
      ..bRequest = request & 0xff
      ..wValue = value & 0xffff
      ..wIndex = index & 0xffff
      ..wLength = length
      ..timeout = timeoutMs < 0 ? 0 : timeoutMs
      ..data = length == 0 ? nullptr : buf.cast();
    assert(c.wLength == length);
    final r = sys.ioctl(fd, Usbfs.control, _ctrl.cast());
    if (r < 0) {
      throw UsbException(
        usbErrorFromTransferErrno(-r),
        'control 0x${requestType.toRadixString(16)}/0x${request.toRadixString(16)} '
        'wValue=0x${value.toRadixString(16)} wIndex=0x${index.toRadixString(16)}: errno ${-r}',
      );
    }
    if (isIn && r > 0) {
      data.setRange(0, r, buf.asTypedList(r));
    }
    return r;
  }

  /// One USBDEVFS_BULK ioctl.
  int _bulkOnce(int endpoint, Pointer<Uint8> buf, int length, int timeoutMs) {
    _bulk.ref
      ..ep = endpoint & 0xff
      ..len = length
      ..timeout = timeoutMs < 0 ? 0 : timeoutMs
      ..data = buf.cast();
    final r = sys.ioctl(fd, Usbfs.bulk, _bulk.cast());
    if (r < 0) {
      throw UsbException(
        usbErrorFromTransferErrno(-r),
        'bulk ep 0x${endpoint.toRadixString(16)} len $length: errno ${-r}',
      );
    }
    return r;
  }

  @override
  int bulkTransfer(
    int endpoint,
    Uint8List data,
    int length, {
    int timeoutMs = 1000,
  }) {
    _checkOpen();
    if (length < 0 || length > data.length) {
      throw UsbException(
        UsbError.invalidParam,
        'bulk length $length (buffer ${data.length})',
      );
    }
    final isIn = (endpoint & UsbReqType.endpointIn) != 0;
    final buf = _scratch(length == 0 ? 1 : length);
    if (!isIn && length > 0) buf.asTypedList(length).setRange(0, length, data);

    // Old kernels limit a single usbfs bulk transfer to 16 KiB
    // (no USBFS_CAP_NO_PACKET_SIZE_LIM): split like libusb does for URBs.
    final chunk = (caps & Usbfs.capNoPacketSizeLim) != 0
        ? (length == 0 ? 1 : length)
        : Usbfs.maxBulkBufferLength;
    var done = 0;
    do {
      final n = (length - done) < chunk ? (length - done) : chunk;
      final r = _bulkOnce(
        endpoint,
        Pointer<Uint8>.fromAddress(buf.address + done),
        n,
        timeoutMs,
      );
      done += r;
      if (r < n) break; // short transfer => done
    } while (done < length);

    if (isIn && done > 0) data.setRange(0, done, buf.asTypedList(done));
    return done;
  }

  // -------------------------------------------------------------------------
  // Configuration / interfaces
  // -------------------------------------------------------------------------

  int _u32Ioctl(int request, int value) {
    _u32.value = value;
    return sys.ioctl(fd, request, _u32.cast());
  }

  /// op_set_configuration
  @override
  void setConfiguration(int configuration) {
    _checkOpen();
    final r = _u32Ioctl(Usbfs.setConfiguration, configuration);
    if (r < 0) {
      final e = -r;
      if (e == Errno.einval) {
        throw UsbException(
          UsbError.notFound,
          'set configuration $configuration',
        );
      } else if (e == Errno.ebusy) {
        throw UsbException(UsbError.busy, 'set configuration $configuration');
      } else if (e == Errno.enodev) {
        throw UsbException(UsbError.noDevice, 'set configuration');
      }
      throw UsbException(UsbError.other, 'set configuration failed, errno=$e');
    }
  }

  /// claim_interface
  @override
  void claimInterface(int interfaceNumber) {
    _checkOpen();
    final r = _u32Ioctl(Usbfs.claimInterface, interfaceNumber);
    if (r < 0) {
      final e = -r;
      if (e == Errno.enoent) {
        throw UsbException(
          UsbError.notFound,
          'claim interface $interfaceNumber',
        );
      } else if (e == Errno.ebusy) {
        throw UsbException(UsbError.busy, 'claim interface $interfaceNumber');
      } else if (e == Errno.enodev) {
        throw UsbException(UsbError.noDevice, 'claim interface');
      }
      throw UsbException(UsbError.other, 'claim interface failed, errno=$e');
    }
    _claimedInterfaces.add(interfaceNumber);
  }

  /// release_interface
  @override
  void releaseInterface(int interfaceNumber) {
    _checkOpen();
    final r = _u32Ioctl(Usbfs.releaseInterface, interfaceNumber);
    _claimedInterfaces.remove(interfaceNumber);
    if (r < 0) {
      final e = -r;
      if (e == Errno.enodev) {
        throw UsbException(UsbError.noDevice, 'release interface');
      }
      throw UsbException(UsbError.other, 'release interface failed, errno=$e');
    }
  }

  /// op_clear_halt
  @override
  void clearHalt(int endpoint) {
    _checkOpen();
    final r = _u32Ioctl(Usbfs.clearHalt, endpoint & 0xff);
    if (r < 0) {
      final e = -r;
      if (e == Errno.enoent) {
        throw UsbException(
          UsbError.notFound,
          'clear halt 0x${endpoint.toRadixString(16)}',
        );
      } else if (e == Errno.enodev) {
        throw UsbException(UsbError.noDevice, 'clear halt');
      }
      throw UsbException(UsbError.other, 'clear halt failed, errno=$e');
    }
  }

  /// op_reset_device: release claimed interfaces, USBDEVFS_RESET, re-claim.
  @override
  void resetDevice() {
    _checkOpen();
    /* Doing a device reset will cause the usbfs driver to get unbound
     * from any interfaces it is bound to. By voluntarily unbinding
     * the usbfs driver ourself, we stop the kernel from rebinding
     * the interface after reset (which would end up with the interface
     * getting bound to the in kernel driver if any). */
    final claimed = _claimedInterfaces.toList()..sort();
    for (final i in claimed) {
      _u32Ioctl(Usbfs.releaseInterface, i);
    }

    final r = sys.ioctl(fd, Usbfs.reset, nullptr);
    if (r < 0) {
      final e = -r;
      if (e == Errno.enodev) {
        throw UsbException(UsbError.notFound, 'reset: device gone');
      }
      throw UsbException(UsbError.other, 'reset failed, errno=$e');
    }

    /* And re-claim any interfaces which were claimed before the reset */
    var failed = false;
    for (final i in claimed) {
      final rr = _u32Ioctl(Usbfs.claimInterface, i);
      if (rr < 0) {
        _claimedInterfaces.remove(i);
        failed = true;
      }
    }
    if (failed) {
      throw UsbException(
        UsbError.notFound,
        'failed to re-claim interface(s) after reset',
      );
    }
  }

  // -------------------------------------------------------------------------
  // Descriptors
  // -------------------------------------------------------------------------

  @override
  String? getStringDescriptorAscii(int index) =>
      getStringDescriptorAsciiOrNull(this, index);

  // -------------------------------------------------------------------------
  // Streaming
  // -------------------------------------------------------------------------

  @override
  Future<BulkInStream> openBulkIn(
    int endpoint, {
    required int numBuffers,
    required int bufferLength,
  }) async {
    _checkOpen();
    final s = await UsbfsBulkInStream.open(
      sys: sys,
      fd: fd,
      endpoint: endpoint,
      numBuffers: numBuffers,
      bufferLength: bufferLength,
      spareSlots: spareBulkSlots ?? numBuffers,
      noPacketSizeLimit: (caps & Usbfs.capNoPacketSizeLim) != 0,
      bulkContinuation: (caps & Usbfs.capBulkContinuation) != 0,
      onGone: (s) => _streams.remove(s),
    );
    _streams.add(s);
    return s;
  }

  /// Does not close the fd (owned by Kotlin). Cancels running streams
  /// (fire-and-forget; await [BulkInStream.cancel] before close to be sure).
  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final s in _streams.toList()) {
      s.cancel();
    }
    calloc.free(_ctrl);
    calloc.free(_bulk);
    calloc.free(_u32);
    calloc.free(_buf);
  }
}
