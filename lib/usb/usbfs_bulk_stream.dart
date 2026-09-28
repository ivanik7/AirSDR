// Continuous bulk-IN streaming over usbfs URBs in a dedicated reader isolate.
//
// Dart equivalent of librtlsdr rtlsdr_read_async() / _libusb_callback()
// (~/prj/ref/rtl-sdr/src/librtlsdr.c:1721-1746, 1860-1990) and of libhackrf's
// transfer thread, implemented directly on the usbfs URB ioctls the way libusb's
// Linux backend does it (libusb os/linux_usbfs.c master a45bb16:
// submit_bulk_transfer :2143, handle_bulk_completion :2576, discard_urbs :2093,
// reap_for_handle :2896).
//
// Model (docs/10-architecture.md §3):
//  * The consumer isolate (the one calling [UsbfsBulkInStream.open]) mallocs
//    N URBs and N + spare buffers ("slots") and owns that memory.
//  * The reader isolate submits N URBs (slots 0..N-1), then loops on the
//    blocking USBDEVFS_REAPURB. For every completed URB it takes a free slot,
//    re-points the URB to it and resubmits, and sends `(slot << 32) | length`
//    of the filled slot to the consumer. If no free slot is available the data
//    is dropped (the URB is resubmitted on the same buffer) and the drop is
//    counted in shared native memory — the USB queue never starves.
//  * The consumer returns slots with [release]; the reader receives them via
//    its ReceivePort between two reaps (it yields to its event loop after each
//    reap). Message order gives happens-before for the buffer contents.
//  * Cancel: the consumer sets the stop flag in shared memory, posts 'stop' and
//    issues USBDEVFS_DISCARDURB for every URB from its own thread (a blocking
//    REAPURB in the reader then returns). Discards are repeated every 50 ms
//    until the reader has exited, which closes the race with a resubmit that
//    happened concurrently with the first discard pass. The reader drains all
//    outstanding URBs and exits; only then native memory is freed.
//  * usbfs copies URB data into user memory at *reap* time (processcompl()),
//    so once the reader stopped reaping, the kernel never writes our buffers.
//
// Error semantics (as rtlsdr's _libusb_callback: only COMPLETED transfers are
// resubmitted): URB status ENODEV/ESHUTDOWN or REAPURB/SUBMITURB errno ENODEV
// => stream error UsbException(noDevice) and stop. Other URB errors retire that
// URB (not resubmitted); when all URBs are retired the stream fails with the
// last error (pipe/overflow/io). After an error the stream is closed; call
// [cancel] anyway to free native memory.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'usb_transport.dart';
import 'usbfs_abi.dart';
import 'usbfs_sys.dart';

/// Shared native control block (Int64 words).
abstract final class _Ctl {
  static const stop = 0; // written by consumer, read by reader
  static const dropped = 1; // written by reader, read by consumer
  static const delivered = 2; // written by reader (statistics)
  static const words = 4;
}

const _msgStop = 'stop';
const _msgStarted = 'started';
const _msgDone = 'done';
const _msgExit = 'exit';
const _msgErr = 'err';

/// Everything the reader isolate needs; all fields are sendable.
class _ReaderArgs {
  final UsbfsSys sys;
  final int fd;
  final int endpoint;
  final int numUrbs;
  final int numSlots;
  final int bufferLength;
  final int urbsAddress; // UsbdevfsUrb[numUrbs]
  final int slotsAddress; // Pointer<Uint8>[numSlots] (addresses)
  final int ctlAddress;
  final SendPort toConsumer;
  _ReaderArgs(
    this.sys,
    this.fd,
    this.endpoint,
    this.numUrbs,
    this.numSlots,
    this.bufferLength,
    this.urbsAddress,
    this.slotsAddress,
    this.ctlAddress,
    this.toConsumer,
  );
}

class UsbfsBulkInStream implements BulkInStream {
  final UsbfsSys _sys;
  final int _fd;
  final int numUrbs;
  final int numSlots;
  final int bufferLength;
  final Pointer<UsbdevfsUrb> _urbs;
  final Pointer<Pointer<Uint8>> _slots;
  final Pointer<Int64> _ctl;
  final void Function(UsbfsBulkInStream)? _onGone;

  final ReceivePort _fromReader = ReceivePort('usbfs-bulk-in');
  final StreamController<UsbBlock> _controller = StreamController<UsbBlock>();
  final Completer<void> _started = Completer<void>();
  final Completer<void> _exited = Completer<void>();
  final Set<int> _held = {};
  SendPort? _toReader;
  Future<void>? _cancelFuture;
  bool _freed = false;

  UsbfsBulkInStream._(
    this._sys,
    this._fd,
    this.numUrbs,
    this.numSlots,
    this.bufferLength,
    this._urbs,
    this._slots,
    this._ctl,
    this._onGone,
  );

  /// Allocate native memory, spawn the reader isolate and submit the URBs.
  /// Throws [UsbException] if the initial submission fails.
  static Future<UsbfsBulkInStream> open({
    required UsbfsSys sys,
    required int fd,
    required int endpoint,
    required int numBuffers,
    required int bufferLength,
    int? spareSlots,
    bool noPacketSizeLimit = true,
    bool bulkContinuation = true,
    void Function(UsbfsBulkInStream)? onGone,
  }) async {
    if (!usbfsAbiSupported) {
      throw UsbException(UsbError.notSupported, 'usbfs needs a 64-bit ABI');
    }
    if ((endpoint & UsbReqType.endpointIn) == 0) {
      throw UsbException(
        UsbError.invalidParam,
        'endpoint 0x${endpoint.toRadixString(16)} is not IN',
      );
    }
    if (numBuffers <= 0 || bufferLength <= 0) {
      throw UsbException(
        UsbError.invalidParam,
        'numBuffers=$numBuffers bufferLength=$bufferLength',
      );
    }
    if (!noPacketSizeLimit && bufferLength > Usbfs.maxBulkBufferLength) {
      // libusb would split each transfer into 16 KiB URBs with
      // BULK_CONTINUATION; kernels without USBFS_CAP_NO_PACKET_SIZE_LIM
      // (< 3.3) are not supported here.
      throw UsbException(
        UsbError.notSupported,
        'kernel lacks USBFS_CAP_NO_PACKET_SIZE_LIM; bufferLength $bufferLength > ${Usbfs.maxBulkBufferLength}',
      );
    }
    final spare = spareSlots ?? numBuffers;
    if (spare < 0) throw UsbException(UsbError.invalidParam, 'spareSlots');
    final numSlots = numBuffers + spare;

    final urbs = calloc<UsbdevfsUrb>(numBuffers);
    final slots = calloc<Pointer<Uint8>>(numSlots);
    final ctl = calloc<Int64>(_Ctl.words);
    for (var i = 0; i < numSlots; i++) {
      final p = malloc<Uint8>(bufferLength);
      if (p == nullptr) {
        for (var j = 0; j < i; j++) {
          malloc.free(slots[j]);
        }
        calloc.free(urbs);
        calloc.free(slots);
        calloc.free(ctl);
        throw UsbException(UsbError.noMem, 'malloc($bufferLength)');
      }
      slots[i] = p;
    }

    final s = UsbfsBulkInStream._(
      sys,
      fd,
      numBuffers,
      numSlots,
      bufferLength,
      urbs,
      slots,
      ctl,
      onGone,
    );
    s._fromReader.listen(s._onMessage);
    final args = _ReaderArgs(
      sys,
      fd,
      endpoint,
      numBuffers,
      numSlots,
      bufferLength,
      urbs.address,
      slots.address,
      ctl.address,
      s._fromReader.sendPort,
    );
    try {
      await Isolate.spawn<_ReaderArgs>(
        _readerMain,
        args,
        debugName: 'usbfs-reader',
        onExit: s._fromReader.sendPort,
        onError: s._fromReader.sendPort,
        errorsAreFatal: true,
      );
    } catch (e) {
      s._fromReader.close();
      s._free();
      throw UsbException(UsbError.other, 'reader isolate spawn failed: $e');
    }
    try {
      await s._started.future;
    } catch (_) {
      await s._exited.future;
      s._free();
      rethrow;
    }
    return s;
  }

  void _onMessage(Object? msg) {
    if (msg is int) {
      final slot = msg >> 32;
      final len = msg & 0xffffffff;
      _held.add(slot);
      _controller.add(UsbBlock(slot, _slots[slot].address, len));
    } else if (msg is SendPort) {
      _toReader = msg;
    } else if (msg == _msgStarted) {
      if (!_started.isCompleted) _started.complete();
    } else if (msg is List && msg.length == 3 && msg[0] == _msgErr) {
      final ex = UsbException(msg[1] as int, msg[2] as String);
      if (!_started.isCompleted) {
        _started.completeError(ex);
      } else if (!_controller.isClosed) {
        _controller.addError(ex);
      }
    } else if (msg == _msgDone) {
      if (!_controller.isClosed) _controller.close();
    } else if (msg is List && msg.length == 2) {
      // onError from Isolate.spawn: [error, stack]
      final ex = UsbException(
        UsbError.other,
        'reader isolate crashed: ${msg[0]}',
      );
      if (!_started.isCompleted) {
        _started.completeError(ex);
      } else if (!_controller.isClosed) {
        _controller.addError(ex);
      }
    } else if (msg == null || msg == _msgExit) {
      // onExit (response null)
      if (!_started.isCompleted) {
        _started.completeError(
          UsbException(UsbError.other, 'reader isolate exited early'),
        );
      }
      if (!_controller.isClosed) _controller.close();
      if (!_exited.isCompleted) _exited.complete();
      _fromReader.close();
    }
  }

  @override
  Stream<UsbBlock> get blocks => _controller.stream;

  @override
  int get droppedBuffers => _freed ? _droppedAtFree : _ctl[_Ctl.dropped];
  int _droppedAtFree = 0;

  /// Number of blocks handed to the consumer so far.
  int get deliveredBuffers => _freed ? _deliveredAtFree : _ctl[_Ctl.delivered];
  int _deliveredAtFree = 0;

  /// Slots currently held by the consumer (not yet released).
  int get heldSlots => _held.length;

  @override
  void release(UsbBlock block) {
    if (!_held.remove(block.slot)) return; // double release / foreign block
    if (_exited.isCompleted) return;
    _toReader?.send(block.slot);
  }

  void _discardAll() {
    for (var i = 0; i < numUrbs; i++) {
      // EINVAL => not in flight (already reaped / not submitted): ignore.
      _sys.ioctl(_fd, Usbfs.discardUrb, (_urbs + i).cast());
    }
  }

  @override
  Future<void> cancel() => _cancelFuture ??= _cancel();

  Future<void> _cancel() async {
    if (!_exited.isCompleted) {
      _ctl[_Ctl.stop] = 1;
      _toReader?.send(_msgStop);
      _discardAll();
      final t = Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (!_exited.isCompleted) _discardAll();
      });
      await _exited.future;
      t.cancel();
    }
    if (!_controller.isClosed) unawaited(_controller.close());
    _free();
  }

  void _free() {
    if (_freed) return;
    _droppedAtFree = _ctl[_Ctl.dropped];
    _deliveredAtFree = _ctl[_Ctl.delivered];
    _freed = true;
    for (var i = 0; i < numSlots; i++) {
      malloc.free(_slots[i]);
    }
    calloc.free(_slots);
    calloc.free(_urbs);
    calloc.free(_ctl);
    _held.clear();
    _onGone?.call(this);
  }
}

// ---------------------------------------------------------------------------
// Reader isolate
// ---------------------------------------------------------------------------

Future<void> _readerMain(_ReaderArgs a) async {
  final r = _Reader(a);
  try {
    await r.run();
  } finally {
    r.dispose();
    a.toConsumer.send(_msgDone);
  }
}

class _Reader {
  final _ReaderArgs a;
  final ReceivePort port = ReceivePort('usbfs-reader-ctl');
  final Pointer<UsbdevfsUrb> urbs;
  final Pointer<Pointer<Uint8>> slots;
  final Pointer<Int64> ctl;
  final Pointer<Pointer<UsbdevfsUrb>> reaped = calloc<Pointer<UsbdevfsUrb>>();
  final Queue<int> free = Queue<int>();
  late final List<int> urbSlot;
  late final List<bool> inFlight;
  int nInFlight = 0;
  bool stopping = false;
  int lastError = UsbError.io;

  _Reader(this.a)
    : urbs = Pointer<UsbdevfsUrb>.fromAddress(a.urbsAddress),
      slots = Pointer<Pointer<Uint8>>.fromAddress(a.slotsAddress),
      ctl = Pointer<Int64>.fromAddress(a.ctlAddress) {
    urbSlot = List<int>.generate(a.numUrbs, (i) => i);
    inFlight = List<bool>.filled(a.numUrbs, false);
    for (var s = a.numUrbs; s < a.numSlots; s++) {
      free.add(s);
    }
    port.listen((msg) {
      if (msg is int) {
        free.add(msg);
      } else if (msg == _msgStop) {
        stopping = true;
      }
    });
  }

  void error(int code, String message) =>
      a.toConsumer.send([_msgErr, code, message]);

  /// Returns 0 or -errno.
  int submit(int i) {
    final u = (urbs + i).ref
      ..type = Usbfs.urbTypeBulk
      ..endpoint = a.endpoint
      ..status = 0
      ..flags = 0
      ..buffer = slots[urbSlot[i]].cast()
      ..bufferLength = a.bufferLength
      ..actualLength = 0
      ..startFrame = 0
      ..numberOfPackets = 0
      ..errorCount = 0
      ..signr = 0
      ..usercontext = Pointer<Void>.fromAddress(i);
    assert(u.bufferLength == a.bufferLength);
    int r;
    do {
      r = a.sys.ioctl(a.fd, Usbfs.submitUrb, (urbs + i).cast());
    } while (r == -Errno.eintr);
    if (r == 0) {
      inFlight[i] = true;
      nInFlight++;
    }
    return r < 0 ? r : 0;
  }

  bool get stopRequested => stopping || ctl[_Ctl.stop] != 0;

  Future<void> run() async {
    a.toConsumer.send(port.sendPort);
    // Submit all URBs (rtlsdr_read_async: libusb_submit_transfer in a loop).
    for (var i = 0; i < a.numUrbs; i++) {
      final r = submit(i);
      if (r < 0) {
        final e = -r;
        error(
          e == Errno.enodev
              ? UsbError.noDevice
              : e == Errno.enomem
              ? UsbError.noMem
              : UsbError.io,
          'Failed to submit transfer $i (errno $e). Please increase your '
          'allowed usbfs buffer size (usbfs_memory_mb)',
        );
        drain();
        return;
      }
    }
    a.toConsumer.send(_msgStarted);

    while (true) {
      if (stopRequested) {
        drain();
        return;
      }
      if (nInFlight == 0) {
        error(lastError, 'all transfers failed');
        return;
      }
      final r = a.sys.ioctl(a.fd, Usbfs.reapUrb, reaped.cast());
      if (r < 0) {
        final e = -r;
        if (e == Errno.eintr || e == Errno.eagain) continue;
        if (e == Errno.enodev) {
          error(UsbError.noDevice, 'device lost (REAPURB ENODEV)');
        } else {
          error(UsbError.io, 'REAPURB failed, errno=$e');
        }
        drain();
        return;
      }
      if (!handle(reaped.value)) {
        drain();
        return;
      }
      // Let release/stop messages in.
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Returns false when the stream must stop (fatal error / cancelled).
  bool handle(Pointer<UsbdevfsUrb> p) {
    final i = p.ref.usercontext.address;
    if (i < 0 || i >= a.numUrbs || (urbs + i) != p) {
      error(
        UsbError.other,
        'reaped foreign URB 0x${p.address.toRadixString(16)}',
      );
      return false;
    }
    inFlight[i] = false;
    nInFlight--;
    final status = p.ref.status;
    final len = p.ref.actualLength;

    if (stopRequested) return false;

    switch (-status) {
      case 0:
      case Errno.eremoteio: /* short transfer */
        break;
      case Errno.enoent: /* cancelled */
      case Errno.econnreset:
        stopping = true;
        return false;
      case Errno.enodev:
      case Errno.eshutdown:
        error(UsbError.noDevice, 'device removed (urb status $status)');
        return false;
      case Errno.epipe:
        lastError = UsbError.pipe;
        return true; // retired (not resubmitted), like a STALL in rtlsdr
      case Errno.eoverflow:
        lastError = UsbError.overflow;
        return true;
      default:
        lastError = UsbError.io; // ETIME/EPROTO/EILSEQ/ECOMM/ENOSR/...
        return true;
    }

    // LIBUSB_TRANSFER_COMPLETED: hand the buffer over and resubmit.
    if (len > 0) {
      if (free.isNotEmpty) {
        final filled = urbSlot[i];
        urbSlot[i] = free.removeFirst();
        ctl[_Ctl.delivered] = ctl[_Ctl.delivered] + 1;
        a.toConsumer.send((filled << 32) | len);
      } else {
        ctl[_Ctl.dropped] = ctl[_Ctl.dropped] + 1;
      }
    }
    final r = submit(i);
    if (r < 0) {
      if (-r == Errno.enodev) {
        error(UsbError.noDevice, 'device lost (SUBMITURB ENODEV)');
        return false;
      }
      lastError = UsbError.io;
    }
    return true;
  }

  /// Discard everything still in flight and reap it (discard_urbs + reap loop).
  void drain() {
    for (var i = 0; i < a.numUrbs; i++) {
      if (inFlight[i]) a.sys.ioctl(a.fd, Usbfs.discardUrb, (urbs + i).cast());
    }
    while (nInFlight > 0) {
      final r = a.sys.ioctl(a.fd, Usbfs.reapUrb, reaped.cast());
      if (r < 0) {
        if (-r == Errno.eintr || -r == Errno.eagain) continue;
        break; // ENODEV etc.: the kernel already killed the URBs
      }
      final i = reaped.value.ref.usercontext.address;
      if (i >= 0 && i < a.numUrbs && inFlight[i]) {
        inFlight[i] = false;
        nInFlight--;
      }
    }
  }

  void dispose() {
    port.close();
    calloc.free(reaped);
  }
}
