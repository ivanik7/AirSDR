// Recording fake UsbDeviceHandle that simulates an RTL2832U + tuner.
//
// Dart twin of tool/oracle/rtlsdr/fake_libusb.c: the device model (register
// memories, I2C tuner answers, R82xx status bytes, EEPROM contents) and the
// trace line format are identical, so a scenario run through the Dart port
// must produce byte-identical traces to the C librtlsdr oracle.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:sdr_flutter/usb/usb_transport.dart';

enum FakeTuner { none, e4000, fc0012, fc0013, fc2580, r820t, r828d }

class FakeModel {
  FakeTuner tuner = FakeTuner.none;
  String manufact = 'Realtek';
  String product = 'RTL2838UHIDIR';
  String serial = '00000001';
  int pllLock = 1;
  int failFirstWrite = 0;

  /// Parses the "model key=value ..." scenario line (see oracle_main.c).
  static FakeModel parse(String args) {
    final m = FakeModel();
    for (final tok in args.split(RegExp(r'[ \t]+'))) {
      final eq = tok.indexOf('=');
      if (eq < 0) continue;
      final k = tok.substring(0, eq);
      final v = tok.substring(eq + 1);
      switch (k) {
        case 'tuner':
          m.tuner = switch (v) {
            'r820t' => FakeTuner.r820t,
            'r828d' => FakeTuner.r828d,
            'e4000' => FakeTuner.e4000,
            'fc0012' => FakeTuner.fc0012,
            'fc0013' => FakeTuner.fc0013,
            'fc2580' => FakeTuner.fc2580,
            _ => FakeTuner.none,
          };
        case 'manufact':
          m.manufact = v.replaceAll('_', ' ');
        case 'product':
          m.product = v.replaceAll('_', ' ');
        case 'serial':
          m.serial = v.replaceAll('_', ' ');
        case 'lock':
          m.pllLock = int.parse(v);
        case 'failfirst':
          m.failFirstWrite = int.parse(v);
      }
    }
    return m;
  }
}

int _bitrev(int byte) {
  const lut = [
    0x0, 0x8, 0x4, 0xc, 0x2, 0xa, 0x6, 0xe, //
    0x1, 0x9, 0x5, 0xd, 0x3, 0xb, 0x7, 0xf,
  ];
  return (lut[byte & 0xf] << 4) | lut[byte >> 4];
}

String _h2(int v) => (v & 0xff).toRadixString(16).padLeft(2, '0');
String _h4(int v) => (v & 0xffff).toRadixString(16).padLeft(4, '0');

class FakeRtlUsbDevice implements UsbDeviceHandle {
  final FakeModel model;
  final StringBuffer trace;

  final List<Uint8List> _blockMem =
      List.generate(8, (_) => Uint8List(0x10000));
  final List<Uint8List> _demodMem = List.generate(16, (_) => Uint8List(0x100));
  final Uint8List _i2cPtr = Uint8List(256);
  final List<Uint8List> _i2cRegs = List.generate(256, (_) => Uint8List(256));
  final Uint8List _eeprom = Uint8List(256);
  int _r82xxReads = 0;
  bool closed = false;

  /// Bulk stream behaviour for readAsync tests.
  FakeBulkInStream? lastStream;
  int bulkBlocksToEmit = 4;
  Object? bulkErrorAfterBlocks;

  FakeRtlUsbDevice(this.model, [StringBuffer? trace])
      : trace = trace ?? StringBuffer() {
    for (var i = 0; i < 256; i++) {
      _eeprom[i] = (i * 7 + 3) & 0xff;
    }
    switch (model.tuner) {
      case FakeTuner.e4000:
        _i2cRegs[0xc8][0x02] = 0x40;
      case FakeTuner.fc0013:
        _i2cRegs[0xc6][0x00] = 0xa3;
      case FakeTuner.fc0012:
        _i2cRegs[0xc6][0x00] = 0xa1;
      case FakeTuner.fc2580:
        _i2cRegs[0xac][0x01] = 0x56;
      default:
        break;
    }
  }

  @override
  UsbDeviceDescriptor get deviceDescriptor => const UsbDeviceDescriptor(
        vendorId: 0x0bda,
        productId: 0x2838,
        iManufacturer: 1,
        iProduct: 2,
        iSerialNumber: 3,
      );

  bool _i2cPresent(int addr) {
    if (addr == 0xa0) return true;
    return switch (model.tuner) {
      FakeTuner.r820t => addr == 0x34,
      FakeTuner.r828d => addr == 0x74,
      FakeTuner.e4000 => addr == 0xc8,
      FakeTuner.fc0013 || FakeTuner.fc0012 => addr == 0xc6,
      FakeTuner.fc2580 => addr == 0xac,
      FakeTuner.none => false,
    };
  }

  bool _isR82xxAddr(int addr) =>
      (model.tuner == FakeTuner.r820t && addr == 0x34) ||
      (model.tuner == FakeTuner.r828d && addr == 0x74);

  int _modelI2c(bool isIn, int addr, Uint8List data, int len) {
    if (!_i2cPresent(addr)) return UsbError.pipe;

    if (!isIn) {
      if (len < 1) return 0;
      if (addr == 0xa0) {
        _i2cPtr[addr] = data[0];
        for (var i = 1; i < len; i++) {
          _eeprom[(data[0] + i - 1) & 0xff] = data[i];
        }
        return len;
      }
      _i2cPtr[addr] = data[0];
      for (var i = 1; i < len; i++) {
        _i2cRegs[addr][(data[0] + i - 1) & 0xff] = data[i];
      }
      return len;
    }

    if (addr == 0xa0) {
      for (var i = 0; i < len; i++) {
        data[i] = _eeprom[_i2cPtr[addr]];
        _i2cPtr[addr] = (_i2cPtr[addr] + 1) & 0xff;
      }
      return len;
    }

    if (_isR82xxAddr(addr)) {
      // R82xx always reads from reg 0; bytes 1.. are bit reversed
      final st = Uint8List(8);
      final n = _r82xxReads++;
      final lock = model.pllLock != 0 && (n % 7 != 6);
      st[0] = 0x96;
      st[1] = 0x00;
      st[2] = (lock ? 0x40 : 0x00) | 0x1c;
      st[3] = 0x21 + n;
      st[4] = ((n % 3) << 4) | ((n % 2) != 0 ? 0x08 : 0x0f);
      for (var i = 0; i < len; i++) {
        data[i] = (i == 0) ? 0x69 : _bitrev(st[i < 8 ? i : 7]);
      }
      return len;
    }

    for (var i = 0; i < len; i++) {
      data[i] = _i2cRegs[addr][(_i2cPtr[addr] + i) & 0xff];
    }
    return len;
  }

  int _modelCtrl(int rt, int val, int idx, Uint8List data, int len) {
    final isIn = (rt & 0x80) != 0;

    if ((rt & 0x60) != UsbReqType.typeVendor) return UsbError.pipe;

    if ((val & 0xff) == 0x20 && ((idx >> 8) == 0)) {
      final page = idx & 0x0f;
      final addr = val >> 8;
      for (var i = 0; i < len; i++) {
        if (isIn) {
          data[i] = _demodMem[page][(addr + i) & 0xff];
        } else {
          _demodMem[page][(addr + i) & 0xff] = data[i];
        }
      }
      return len;
    }

    final block = idx >> 8;
    if (block == 6) return _modelI2c(isIn, val & 0xff, data, len);
    if (block > 7) return UsbError.pipe;
    for (var i = 0; i < len; i++) {
      if (isIn) {
        data[i] = _blockMem[block][(val + i) & 0xffff];
      } else {
        _blockMem[block][(val + i) & 0xffff] = data[i];
      }
    }
    if (model.failFirstWrite != 0 && !isIn) {
      model.failFirstWrite = 0;
      return UsbError.io;
    }
    return len;
  }

  @override
  int controlTransfer(int requestType, int request, int value, int index,
      Uint8List data, int length,
      {int timeoutMs = 1000}) {
    final r = _modelCtrl(requestType, value, index, data, length);
    final sb = StringBuffer('CTRL rt=${_h2(requestType)} req=${_h2(request)} '
        'val=${_h4(value)} idx=${_h4(index)} len=$length to=$timeoutMs '
        'ret=$r data=');
    final n = (requestType & 0x80) != 0 ? (r > 0 ? r : 0) : length;
    for (var i = 0; i < n; i++) {
      sb.write(_h2(data[i]));
    }
    trace.writeln(sb);
    if (r < 0) throw UsbException(r, 'fake control transfer failed');
    return r;
  }

  @override
  int bulkTransfer(int endpoint, Uint8List data, int length,
      {int timeoutMs = 1000}) {
    for (var i = 0; i < length; i++) {
      data[i] = (i * 3 + 1) & 0xff;
    }
    trace.writeln('BULK ep=${_h2(endpoint)} len=$length to=$timeoutMs '
        'ret=0 act=$length');
    return length;
  }

  @override
  void setConfiguration(int configuration) =>
      trace.writeln('SETCONFIG cfg=$configuration ret=0');

  @override
  void claimInterface(int interfaceNumber) =>
      trace.writeln('CLAIM if=$interfaceNumber ret=0');

  @override
  void releaseInterface(int interfaceNumber) =>
      trace.writeln('RELEASE if=$interfaceNumber ret=0');

  @override
  void clearHalt(int endpoint) => trace.writeln('CLEARHALT ep=${_h2(endpoint)}');

  @override
  void resetDevice() => trace.writeln('RESET ret=0');

  @override
  String? getStringDescriptorAscii(int index) {
    if (index == 0) {
      trace.writeln('STR idx=0 ret=${UsbError.invalidParam} s=');
      return null;
    }
    var s = index == 1
        ? model.manufact
        : index == 2
            ? model.product
            : model.serial;
    if (s.length > 255) s = s.substring(0, 255);
    trace.writeln('STR idx=$index ret=${s.length} s=$s');
    return s;
  }

  @override
  Future<BulkInStream> openBulkIn(int endpoint,
      {required int numBuffers, required int bufferLength}) async {
    trace.writeln('BULKIN ep=${_h2(endpoint)} n=$numBuffers len=$bufferLength');
    final s = FakeBulkInStream(numBuffers, bufferLength, bulkBlocksToEmit,
        bulkErrorAfterBlocks);
    lastStream = s;
    s.start();
    return s;
  }

  @override
  void close() {
    closed = true;
    trace.writeln('CLOSE');
  }
}

/// Emits [toEmit] blocks (native memory, byte i = (seq + i) & 0xff), then
/// optionally an error, then idles until cancelled.
class FakeBulkInStream implements BulkInStream {
  final int numBuffers;
  final int bufferLength;
  final int toEmit;
  final Object? errorAfter;
  final _ctrl = StreamController<UsbBlock>();
  final List<Pointer<Uint8>> _bufs = [];
  final Set<int> _outstanding = {};
  int released = 0;
  int emitted = 0;
  bool cancelled = false;

  FakeBulkInStream(
      this.numBuffers, this.bufferLength, this.toEmit, this.errorAfter) {
    for (var i = 0; i < numBuffers; i++) {
      _bufs.add(calloc<Uint8>(bufferLength));
    }
  }

  void start() {
    scheduleMicrotask(_pump);
  }

  void _pump() {
    if (cancelled) return;
    if (emitted < toEmit) {
      final slot = emitted % numBuffers;
      final p = _bufs[slot];
      final view = p.asTypedList(bufferLength);
      for (var i = 0; i < bufferLength; i++) {
        view[i] = (emitted + i) & 0xff;
      }
      _outstanding.add(slot);
      emitted++;
      _ctrl.add(UsbBlock(slot, p.address, bufferLength));
      Timer.run(_pump);
    } else if (errorAfter != null) {
      _ctrl.addError(errorAfter!);
    }
  }

  @override
  Stream<UsbBlock> get blocks => _ctrl.stream;

  @override
  void release(UsbBlock block) {
    _outstanding.remove(block.slot);
    released++;
  }

  @override
  int get droppedBuffers => 0;

  @override
  Future<void> cancel() async {
    if (cancelled) return;
    cancelled = true;
    unawaited(_ctrl.close());
    for (final p in _bufs) {
      calloc.free(p);
    }
  }
}
