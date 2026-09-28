// Mock UsbDeviceHandle for driver unit tests and trace-diff against the C
// libraries (tool/oracle/, docs/10-architecture.md §2).
//
//  * Every call is appended to [MockUsbDeviceHandle.trace] as a [UsbTraceEntry]
//    (control transfers record bmRequestType, bRequest, wValue, wIndex, wLength
//    and the data bytes — OUT payload, or the IN bytes returned to the driver).
//  * IN control transfers are answered by the [MockUsbDeviceHandle.onControlIn]
//    callback (scripted register file, canned replies ...); OUT transfers can be
//    observed/rejected by [MockUsbDeviceHandle.onControlOut].
//  * [MockBulkInStream] is a fake of the usbfs reader: tests push Dart data,
//    it is copied into malloc'd slot buffers (same UsbBlock contract as the
//    real stream, incl. drop counting when all slots are held).
//
// Trace line format ([UsbTraceEntry.toString], stable, meant for diffing with
// the C oracle's fake libusb):
//   C <bmRequestType> <bRequest> <wValue> <wIndex> <wLength> [<hex data>]
//   B <endpoint> <length> [<hex data>]        bulk transfer
//   CFG <n> | CLAIM <n> | RELEASE <n> | HALT <ep> | RESET | STR <index> | CLOSE
//   BULKIN <ep> <numBuffers> <bufferLength>
// Numbers are hex without 0x, zero padded (2 digits for u8, 4 for u16).
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'usb_transport.dart';

enum UsbTraceKind {
  control,
  bulk,
  setConfiguration,
  claimInterface,
  releaseInterface,
  clearHalt,
  reset,
  stringDescriptor,
  openBulkIn,
  close,
}

String _h2(int v) => (v & 0xff).toRadixString(16).padLeft(2, '0');
String _h4(int v) => (v & 0xffff).toRadixString(16).padLeft(4, '0');
String hexBytes(List<int> b) => b.map(_h2).join();

class UsbTraceEntry {
  final UsbTraceKind kind;

  /// control: bmRequestType; bulk/halt/bulkIn: endpoint; cfg/claim/release/str: number.
  final int a;

  /// control: bRequest; bulkIn: numBuffers.
  final int b;

  /// control: wValue; bulkIn: bufferLength.
  final int value;

  /// control: wIndex.
  final int index;

  /// control/bulk: requested length.
  final int length;

  /// OUT: bytes sent; IN: bytes returned to the driver (actual length).
  final Uint8List data;

  UsbTraceEntry(
    this.kind, {
    this.a = 0,
    this.b = 0,
    this.value = 0,
    this.index = 0,
    this.length = 0,
    Uint8List? data,
  }) : data = data ?? _empty;
  static final Uint8List _empty = Uint8List(0);

  bool get isIn => (a & UsbReqType.endpointIn) != 0;

  // Convenience accessors for control entries.
  int get requestType => a;
  int get request => b;

  @override
  String toString() {
    final d = data.isEmpty ? '' : ' ${hexBytes(data)}';
    switch (kind) {
      case UsbTraceKind.control:
        return 'C ${_h2(a)} ${_h2(b)} ${_h4(value)} ${_h4(index)} ${_h4(length)}$d';
      case UsbTraceKind.bulk:
        return 'B ${_h2(a)} $length$d';
      case UsbTraceKind.setConfiguration:
        return 'CFG $a';
      case UsbTraceKind.claimInterface:
        return 'CLAIM $a';
      case UsbTraceKind.releaseInterface:
        return 'RELEASE $a';
      case UsbTraceKind.clearHalt:
        return 'HALT ${_h2(a)}';
      case UsbTraceKind.reset:
        return 'RESET';
      case UsbTraceKind.stringDescriptor:
        return 'STR $a';
      case UsbTraceKind.openBulkIn:
        return 'BULKIN ${_h2(a)} $b $value';
      case UsbTraceKind.close:
        return 'CLOSE';
    }
  }

  @override
  bool operator ==(Object other) =>
      other is UsbTraceEntry && other.toString() == toString();
  @override
  int get hashCode => toString().hashCode;
}

/// A control transfer as seen by the handlers.
class UsbControlRequest {
  final int requestType;
  final int request;
  final int value;
  final int index;
  final int length;

  /// OUT payload (first [length] bytes of the driver's buffer); empty for IN.
  final Uint8List outData;
  const UsbControlRequest(
    this.requestType,
    this.request,
    this.value,
    this.index,
    this.length,
    this.outData,
  );
  bool get isIn => (requestType & UsbReqType.endpointIn) != 0;
}

/// Fill [response] (length == wLength) and return the number of bytes produced
/// (may be short). Throw [UsbException] to simulate a failure (e.g. pipe).
typedef ControlInHandler = int Function(
  UsbControlRequest req,
  Uint8List response,
);

/// Observe an OUT control transfer. Return the number of bytes accepted
/// (normally req.length) or throw [UsbException].
typedef ControlOutHandler = int Function(UsbControlRequest req);

/// Bulk transfer handler: for IN fill [data] and return count; for OUT return
/// the number of bytes accepted.
typedef BulkHandler = int Function(int endpoint, Uint8List data, int length);

class MockUsbDeviceHandle implements UsbDeviceHandle {
  @override
  final UsbDeviceDescriptor deviceDescriptor;

  /// String descriptors by index (getStringDescriptorAscii).
  final Map<int, String> strings;

  ControlInHandler? onControlIn;
  ControlOutHandler? onControlOut;
  BulkHandler? onBulk;

  /// Called for every opened stream (e.g. to start feeding data).
  void Function(MockBulkInStream stream)? onBulkInOpened;

  /// Spare slots in mock streams beyond numBuffers (null => numBuffers).
  int? spareBulkSlots;

  final List<UsbTraceEntry> trace = [];
  final List<MockBulkInStream> streams = [];

  bool _closed = false;
  bool _unplugged = false;
  bool get isClosed => _closed;

  MockUsbDeviceHandle({
    this.deviceDescriptor = const UsbDeviceDescriptor(
      vendorId: 0x0bda,
      productId: 0x2838,
    ),
    Map<int, String>? strings,
    this.onControlIn,
    this.onControlOut,
    this.onBulk,
    this.onBulkInOpened,
    this.spareBulkSlots,
  }) : strings = strings ?? {};

  /// Only control transfer entries.
  List<UsbTraceEntry> get controlTrace =>
      trace.where((e) => e.kind == UsbTraceKind.control).toList();

  /// Trace as text, one entry per line.
  String formatTrace() => trace.map((e) => '$e\n').join();

  void clearTrace() => trace.clear();

  /// Simulate hot-unplug: every further call throws noDevice and open streams
  /// fail with UsbException(noDevice).
  void unplug() {
    _unplugged = true;
    for (final s in streams) {
      s.addError(UsbException(UsbError.noDevice, 'device unplugged'));
    }
  }

  void _check() {
    if (_closed) throw UsbException(UsbError.noDevice, 'handle closed');
    if (_unplugged) throw UsbException(UsbError.noDevice, 'device unplugged');
  }

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
    _check();
    if (length < 0 || length > 0xffff || length > data.length) {
      throw UsbException(UsbError.invalidParam, 'control length $length');
    }
    final isIn = (requestType & UsbReqType.endpointIn) != 0;
    if (isIn) {
      final req = UsbControlRequest(
        requestType & 0xff,
        request & 0xff,
        value & 0xffff,
        index & 0xffff,
        length,
        Uint8List(0),
      );
      final resp = Uint8List(length);
      final h = onControlIn;
      if (h == null) {
        throw UsbException(
          UsbError.pipe,
          'no IN handler (C ${_h2(requestType)} ${_h2(request)} ${_h4(value)} ${_h4(index)})',
        );
      }
      final n = h(req, resp);
      if (n < 0 || n > length) {
        throw StateError('ControlInHandler returned $n for wLength $length');
      }
      data.setRange(0, n, resp);
      trace.add(
        UsbTraceEntry(
          UsbTraceKind.control,
          a: requestType & 0xff,
          b: request & 0xff,
          value: value & 0xffff,
          index: index & 0xffff,
          length: length,
          data: Uint8List.fromList(resp.sublist(0, n)),
        ),
      );
      return n;
    } else {
      final out = Uint8List.fromList(data.sublist(0, length));
      final req = UsbControlRequest(
        requestType & 0xff,
        request & 0xff,
        value & 0xffff,
        index & 0xffff,
        length,
        out,
      );
      trace.add(
        UsbTraceEntry(
          UsbTraceKind.control,
          a: requestType & 0xff,
          b: request & 0xff,
          value: value & 0xffff,
          index: index & 0xffff,
          length: length,
          data: out,
        ),
      );
      final h = onControlOut;
      return h == null ? length : h(req);
    }
  }

  @override
  int bulkTransfer(
    int endpoint,
    Uint8List data,
    int length, {
    int timeoutMs = 1000,
  }) {
    _check();
    if (length < 0 || length > data.length) {
      throw UsbException(UsbError.invalidParam, 'bulk length $length');
    }
    final isIn = (endpoint & UsbReqType.endpointIn) != 0;
    final h = onBulk;
    final Uint8List recorded;
    int n;
    if (isIn) {
      n = h == null ? 0 : h(endpoint, data, length);
      recorded = Uint8List.fromList(data.sublist(0, n));
    } else {
      recorded = Uint8List.fromList(data.sublist(0, length));
      n = h == null ? length : h(endpoint, data, length);
    }
    trace.add(
      UsbTraceEntry(
        UsbTraceKind.bulk,
        a: endpoint & 0xff,
        length: length,
        data: recorded,
      ),
    );
    return n;
  }

  @override
  void setConfiguration(int configuration) {
    _check();
    trace.add(UsbTraceEntry(UsbTraceKind.setConfiguration, a: configuration));
  }

  @override
  void claimInterface(int interfaceNumber) {
    _check();
    trace.add(UsbTraceEntry(UsbTraceKind.claimInterface, a: interfaceNumber));
  }

  @override
  void releaseInterface(int interfaceNumber) {
    _check();
    trace.add(UsbTraceEntry(UsbTraceKind.releaseInterface, a: interfaceNumber));
  }

  @override
  void clearHalt(int endpoint) {
    _check();
    trace.add(UsbTraceEntry(UsbTraceKind.clearHalt, a: endpoint & 0xff));
  }

  @override
  void resetDevice() {
    _check();
    trace.add(UsbTraceEntry(UsbTraceKind.reset));
  }

  /// Answers from [strings] without EP0 traffic; recorded as `STR <index>`.
  @override
  String? getStringDescriptorAscii(int index) {
    if (index == 0) return null;
    if (_closed || _unplugged) return null;
    trace.add(UsbTraceEntry(UsbTraceKind.stringDescriptor, a: index));
    return strings[index];
  }

  @override
  Future<BulkInStream> openBulkIn(
    int endpoint, {
    required int numBuffers,
    required int bufferLength,
  }) async {
    _check();
    if ((endpoint & UsbReqType.endpointIn) == 0 ||
        numBuffers <= 0 ||
        bufferLength <= 0) {
      throw UsbException(UsbError.invalidParam, 'openBulkIn');
    }
    trace.add(
      UsbTraceEntry(
        UsbTraceKind.openBulkIn,
        a: endpoint & 0xff,
        b: numBuffers,
        value: bufferLength,
      ),
    );
    final s = MockBulkInStream(
      numSlots: numBuffers + (spareBulkSlots ?? numBuffers),
      bufferLength: bufferLength,
    );
    streams.add(s);
    onBulkInOpened?.call(s);
    return s;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    trace.add(UsbTraceEntry(UsbTraceKind.close));
    for (final s in streams) {
      s.cancel();
    }
  }
}

/// Fake BulkInStream fed from Dart. Data is copied into malloc'd native slot
/// buffers so consumers see exactly the same [UsbBlock] contract as with the
/// usbfs reader.
class MockBulkInStream implements BulkInStream {
  final int numSlots;
  final int bufferLength;
  final List<Pointer<Uint8>> _slots;
  final Queue<int> _free = Queue<int>();
  final Set<int> _held = {};
  final StreamController<UsbBlock> _controller = StreamController<UsbBlock>();
  int _dropped = 0;
  int delivered = 0;
  bool _cancelled = false;

  MockBulkInStream({required this.numSlots, required this.bufferLength})
    : _slots = List<Pointer<Uint8>>.generate(
        numSlots,
        (_) => malloc<Uint8>(bufferLength),
      ) {
    for (var i = 0; i < numSlots; i++) {
      _free.add(i);
    }
  }

  bool get isCancelled => _cancelled;
  int get freeSlots => _free.length;
  int get heldSlots => _held.length;

  /// Deliver one device buffer (<= bufferLength bytes). Returns false if it
  /// was dropped because no slot was free (counted in [droppedBuffers]).
  bool push(List<int> data) {
    if (_cancelled || _controller.isClosed) return false;
    if (data.length > bufferLength) {
      throw ArgumentError(
        'push of ${data.length} > bufferLength $bufferLength',
      );
    }
    if (_free.isEmpty) {
      _dropped++;
      return false;
    }
    final slot = _free.removeFirst();
    _slots[slot].asTypedList(bufferLength).setRange(0, data.length, data);
    _held.add(slot);
    delivered++;
    _controller.add(UsbBlock(slot, _slots[slot].address, data.length));
    return true;
  }

  /// Push [data] split into bufferLength-sized chunks.
  void pushAll(List<int> data) {
    for (var o = 0; o < data.length; o += bufferLength) {
      final e = (o + bufferLength) < data.length
          ? o + bufferLength
          : data.length;
      push(data.sublist(o, e));
    }
  }

  void addError(UsbException e) {
    if (!_controller.isClosed) _controller.addError(e);
  }

  /// End of data (like the device stopping); stream closes.
  void end() {
    if (!_controller.isClosed) _controller.close();
  }

  @override
  Stream<UsbBlock> get blocks => _controller.stream;

  @override
  void release(UsbBlock block) {
    if (_cancelled) return;
    if (_held.remove(block.slot)) _free.add(block.slot);
  }

  @override
  int get droppedBuffers => _dropped;

  @override
  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    if (!_controller.isClosed) unawaited(_controller.close());
    for (final p in _slots) {
      malloc.free(p);
    }
    _held.clear();
    _free.clear();
  }
}
