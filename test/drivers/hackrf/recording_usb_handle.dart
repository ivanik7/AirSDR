// Minimal recording fake of UsbDeviceHandle for the libhackrf port tests.
//
// Produces the same text trace as the C oracle's fake libusb
// (tool/oracle/hackrf/fake_libusb/fake_libusb.c) and answers IN control
// transfers from the same script. Keep both in sync.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:sdr_flutter/usb/usb_transport.dart';

String _hex2(int v) => v.toRadixString(16).padLeft(2, '0');
String _hex4(int v) => v.toRadixString(16).padLeft(4, '0');

class RecordingUsbHandle implements UsbDeviceHandle {
  final List<String> trace = [];

  int bcdDevice;
  int currentConfig;
  int productId;

  /// bRequest answered with LIBUSB_ERROR_PIPE (-1: none)
  int failReq;

  /// bRequest answered with half the bytes (-1: none)
  int shortReq;

  RecordingUsbHandle({
    this.bcdDevice = 0x0112,
    this.currentConfig = 0,
    this.productId = 0x6089,
    this.failReq = -1,
    this.shortReq = -1,
  });

  final List<FakeBulkInStream> streams = [];
  bool closed = false;

  void log(String line) => trace.add(line);

  @override
  UsbDeviceDescriptor get deviceDescriptor => UsbDeviceDescriptor(
    vendorId: 0x1d50,
    productId: productId,
    bcdDevice: bcdDevice,
    iManufacturer: 1,
    iProduct: 2,
    iSerialNumber: 3,
  );

  /// Scripted IN responses; must match fake_script_in() in fake_libusb.c.
  /// Returns bytes or a negative libusb error.
  Object _scriptIn(int rt, int req, int val, int idx) {
    if (rt == 0x80 && req == 0x08) return [currentConfig]; // GET_CONFIGURATION
    if (rt != 0xc0) return UsbError.pipe;
    switch (req) {
      case 14: // BOARD_ID_READ: HackRF One (OG)
        return [2];
      case 15: // VERSION_STRING_READ
        return 'fake-2026.01.0'.codeUnits;
      case 18: // BOARD_PARTID_SERIALNO_READ
        return [
          0x3c, 0xcb, 0x00, 0xa0, 0x46, 0x4f, 0x57, 0x00, //
          0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
          0x78, 0x56, 0x34, 0x12, 0xf0, 0xde, 0xbc, 0x9a, //
        ];
      case 19: // SET_LNA_GAIN: always accepted
        return [1];
      case 20: // SET_VGA_GAIN: 62 "rejected" (retval 0)
        return [idx == 62 ? 0 : 1];
      case 45: // BOARD_REV_READ
        return [5];
      case 61: // GET_BUFFER_SIZE: 32768 LE
        return [0x00, 0x80, 0x00, 0x00];
      default:
        return UsbError.pipe;
    }
  }

  void _traceCtrl(
    int rt,
    int req,
    int val,
    int idx,
    int len,
    int to,
    int ret,
    List<int> data,
  ) {
    final hex = StringBuffer();
    for (final b in data) {
      hex.write(_hex2(b & 0xff));
    }
    log(
      'CTRL ${_hex2(rt)} ${_hex2(req)} ${_hex4(val)} ${_hex4(idx)} '
      'len=$len to=$to ret=$ret data=$hex',
    );
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
    if (closed) throw UsbException(UsbError.noDevice, 'closed');
    if (request == failReq) {
      _traceCtrl(
        requestType,
        request,
        value,
        index,
        length,
        timeoutMs,
        UsbError.pipe,
        const [],
      );
      throw UsbException(UsbError.pipe, 'scripted failure');
    }
    if (requestType & UsbReqType.endpointIn != 0) {
      final r = _scriptIn(requestType, request, value, index);
      if (r is int) {
        _traceCtrl(
          requestType,
          request,
          value,
          index,
          length,
          timeoutMs,
          r,
          const [],
        );
        throw UsbException(r, 'scripted IN error');
      }
      final resp = r as List<int>;
      var ret = resp.length > length ? length : resp.length;
      if (ret > 0 && request == shortReq) ret ~/= 2;
      data.setRange(0, ret, resp);
      _traceCtrl(
        requestType,
        request,
        value,
        index,
        length,
        timeoutMs,
        ret,
        data.sublist(0, ret),
      );
      return ret;
    } else {
      var ret = length;
      if (request == shortReq) ret = length ~/ 2;
      _traceCtrl(
        requestType,
        request,
        value,
        index,
        length,
        timeoutMs,
        ret,
        data.sublist(0, length),
      );
      return ret;
    }
  }

  @override
  int bulkTransfer(
    int endpoint,
    Uint8List data,
    int length, {
    int timeoutMs = 1000,
  }) {
    log('BULK ep=${_hex2(endpoint)} len=$length');
    return length;
  }

  @override
  void setConfiguration(int configuration) {
    log('SET_CONFIGURATION $configuration');
    currentConfig = configuration;
  }

  @override
  void claimInterface(int interfaceNumber) =>
      log('CLAIM_INTERFACE $interfaceNumber');

  @override
  void releaseInterface(int interfaceNumber) =>
      log('RELEASE_INTERFACE $interfaceNumber');

  @override
  void clearHalt(int endpoint) => log('CLEAR_HALT ${_hex2(endpoint)}');

  @override
  void resetDevice() => log('RESET');

  @override
  String? getStringDescriptorAscii(int index) =>
      index == 0 ? null : '0000000000000000000000001234567890abcdef';

  @override
  Future<BulkInStream> openBulkIn(
    int endpoint, {
    required int numBuffers,
    required int bufferLength,
  }) async {
    for (var i = 0; i < numBuffers; i++) {
      log('SUBMIT ep=${_hex2(endpoint)} len=$bufferLength');
    }
    final s = FakeBulkInStream(this, endpoint, numBuffers, bufferLength);
    streams.add(s);
    return s;
  }

  @override
  void close() {
    log('CLOSE');
    closed = true;
  }
}

/// Bulk stream whose blocks are pushed by the test via [emit].
class FakeBulkInStream implements BulkInStream {
  final RecordingUsbHandle owner;
  final int endpoint;
  final int numBuffers;
  final int bufferLength;
  final _controller = StreamController<UsbBlock>();
  final List<Pointer<Uint8>> _slots = [];
  final Set<int> _busy = {};
  final List<int> released = [];
  int _dropped = 0;
  bool cancelled = false;

  FakeBulkInStream(
    this.owner,
    this.endpoint,
    this.numBuffers,
    this.bufferLength,
  ) {
    for (var i = 0; i < numBuffers; i++) {
      _slots.add(calloc<Uint8>(bufferLength));
    }
  }

  /// Deliver [bytes] as one completed transfer. Returns false if dropped.
  bool emit(List<int> bytes) {
    if (cancelled) return false;
    for (var s = 0; s < numBuffers; s++) {
      if (!_busy.contains(s)) {
        _busy.add(s);
        final n = bytes.length > bufferLength ? bufferLength : bytes.length;
        _slots[s].asTypedList(bufferLength).setRange(0, n, bytes);
        _controller.add(UsbBlock(s, _slots[s].address, n));
        return true;
      }
    }
    _dropped++;
    return false;
  }

  void fail(Object error) => _controller.addError(error);

  @override
  Stream<UsbBlock> get blocks => _controller.stream;

  @override
  void release(UsbBlock block) {
    released.add(block.slot);
    _busy.remove(block.slot);
  }

  @override
  int get droppedBuffers => _dropped;

  @override
  Future<void> cancel() async {
    if (cancelled) return;
    cancelled = true;
    for (var i = 0; i < numBuffers; i++) {
      owner.log('CANCEL ep=${_hex2(endpoint)}');
    }
    // Not awaited: the consumer may already have cancelled its subscription.
    unawaited(_controller.close());
    for (final p in _slots) {
      calloc.free(p);
    }
  }
}
