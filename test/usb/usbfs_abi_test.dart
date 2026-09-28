// Layout / ioctl number tests for lib/usb/usbfs_abi.dart.
// Pinned 64-bit values (arm64 == x86_64) + a live cross-check against the C
// compiler via tool/usbfs_abi_oracle.c when gcc and linux headers are present.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/usb/usbfs_abi.dart';

void main() {
  test('ABI is 64-bit on the test host', () {
    expect(usbfsAbiSupported, isTrue);
  });

  test('ioctl numbers match <linux/usbdevice_fs.h> (64-bit)', () {
    expect(Usbfs.control, 0xC0185500);
    expect(Usbfs.bulk, 0xC0185502);
    expect(Usbfs.setConfiguration, 0x80045505);
    expect(Usbfs.submitUrb, 0x8038550A);
    expect(Usbfs.discardUrb, 0x550B);
    expect(Usbfs.reapUrb, 0x4008550C);
    expect(Usbfs.reapUrbNdelay, 0x4008550D);
    expect(Usbfs.claimInterface, 0x8004550F);
    expect(Usbfs.releaseInterface, 0x80045510);
    expect(Usbfs.reset, 0x5514);
    expect(Usbfs.clearHalt, 0x80045515);
    expect(Usbfs.getCapabilities, 0x8004551A);
  });

  test('_IOC encoding', () {
    expect(Ioc.io(0x55, 20), 0x5514);
    expect(Ioc.iowr(0x55, 0, 24), 0xC0185500);
    expect(() => Ioc.ioc(0, 0x55, 0, 1 << 14), throwsArgumentError);
  });

  test('struct sizes (64-bit)', () {
    expect(sizeOf<UsbdevfsCtrlTransfer>(), 24);
    expect(sizeOf<UsbdevfsBulkTransfer>(), 24);
    expect(sizeOf<UsbdevfsUrb>(), 56);
  });

  test('field offsets by probing native memory', () {
    final m = _probeOffsets();
    expect(m, {
      'ctrl.bRequestType': 0,
      'ctrl.bRequest': 1,
      'ctrl.wValue': 2,
      'ctrl.wIndex': 4,
      'ctrl.wLength': 6,
      'ctrl.timeout': 8,
      'ctrl.data': 16,
      'bulk.ep': 0,
      'bulk.len': 4,
      'bulk.timeout': 8,
      'bulk.data': 16,
      'urb.type': 0,
      'urb.endpoint': 1,
      'urb.status': 4,
      'urb.flags': 8,
      'urb.buffer': 16,
      'urb.buffer_length': 24,
      'urb.actual_length': 28,
      'urb.start_frame': 32,
      'urb.number_of_packets': 36,
      'urb.error_count': 40,
      'urb.signr': 44,
      'urb.usercontext': 48,
    });
  });

  test('matches the C compiler (tool/usbfs_abi_oracle.c)', () async {
    final gcc = await Process.run('which', ['gcc']);
    if (gcc.exitCode != 0 ||
        !File('/usr/include/linux/usbdevice_fs.h').existsSync()) {
      markTestSkipped('gcc or linux headers not available');
      return;
    }
    final dir = await Directory.systemTemp.createTemp('usbfs_abi');
    try {
      final exe = '${dir.path}/oracle';
      final cc = await Process.run('gcc', [
        '-O0',
        '-o',
        exe,
        'tool/usbfs_abi_oracle.c',
      ]);
      expect(cc.exitCode, 0, reason: cc.stderr.toString());
      final run = await Process.run(exe, []);
      expect(run.exitCode, 0);
      final c = <String, int>{
        for (final l in (run.stdout as String).trim().split('\n'))
          l.split('=')[0]: int.parse(l.split('=')[1]),
      };
      final dart = <String, int>{
        'CONTROL': Usbfs.control,
        'BULK': Usbfs.bulk,
        'SETCONFIGURATION': Usbfs.setConfiguration,
        'SUBMITURB': Usbfs.submitUrb,
        'DISCARDURB': Usbfs.discardUrb,
        'REAPURB': Usbfs.reapUrb,
        'REAPURBNDELAY': Usbfs.reapUrbNdelay,
        'CLAIMINTERFACE': Usbfs.claimInterface,
        'RELEASEINTERFACE': Usbfs.releaseInterface,
        'RESET': Usbfs.reset,
        'CLEAR_HALT': Usbfs.clearHalt,
        'GET_CAPABILITIES': Usbfs.getCapabilities,
        'ctrl.size': sizeOf<UsbdevfsCtrlTransfer>(),
        'bulk.size': sizeOf<UsbdevfsBulkTransfer>(),
        'urb.size': sizeOf<UsbdevfsUrb>(),
        ..._probeOffsets(),
      };
      expect(dart, c);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}

/// Find each field's byte offset by writing a marker through the Dart struct
/// accessor into zeroed native memory and locating the first non-zero byte.
Map<String, int> _probeOffsets() {
  final out = <String, int>{};
  int find(Pointer<Uint8> mem, int size) {
    for (var i = 0; i < size; i++) {
      if (mem[i] != 0) return i;
    }
    return -1;
  }

  void probe<T extends Struct>(
    String name,
    int size,
    void Function(Pointer<T>) w,
  ) {
    final mem = calloc<Uint8>(size);
    try {
      w(mem.cast<T>());
      out[name] = find(mem, size);
    } finally {
      calloc.free(mem);
    }
  }

  final ptr = Pointer<Void>.fromAddress(0x7f);
  probe<UsbdevfsCtrlTransfer>(
    'ctrl.bRequestType',
    24,
    (p) => p.ref.bRequestType = 1,
  );
  probe<UsbdevfsCtrlTransfer>('ctrl.bRequest', 24, (p) => p.ref.bRequest = 1);
  probe<UsbdevfsCtrlTransfer>('ctrl.wValue', 24, (p) => p.ref.wValue = 1);
  probe<UsbdevfsCtrlTransfer>('ctrl.wIndex', 24, (p) => p.ref.wIndex = 1);
  probe<UsbdevfsCtrlTransfer>('ctrl.wLength', 24, (p) => p.ref.wLength = 1);
  probe<UsbdevfsCtrlTransfer>('ctrl.timeout', 24, (p) => p.ref.timeout = 1);
  probe<UsbdevfsCtrlTransfer>('ctrl.data', 24, (p) => p.ref.data = ptr);
  probe<UsbdevfsBulkTransfer>('bulk.ep', 24, (p) => p.ref.ep = 1);
  probe<UsbdevfsBulkTransfer>('bulk.len', 24, (p) => p.ref.len = 1);
  probe<UsbdevfsBulkTransfer>('bulk.timeout', 24, (p) => p.ref.timeout = 1);
  probe<UsbdevfsBulkTransfer>('bulk.data', 24, (p) => p.ref.data = ptr);
  probe<UsbdevfsUrb>('urb.type', 56, (p) => p.ref.type = 1);
  probe<UsbdevfsUrb>('urb.endpoint', 56, (p) => p.ref.endpoint = 1);
  probe<UsbdevfsUrb>('urb.status', 56, (p) => p.ref.status = 1);
  probe<UsbdevfsUrb>('urb.flags', 56, (p) => p.ref.flags = 1);
  probe<UsbdevfsUrb>('urb.buffer', 56, (p) => p.ref.buffer = ptr);
  probe<UsbdevfsUrb>('urb.buffer_length', 56, (p) => p.ref.bufferLength = 1);
  probe<UsbdevfsUrb>('urb.actual_length', 56, (p) => p.ref.actualLength = 1);
  probe<UsbdevfsUrb>('urb.start_frame', 56, (p) => p.ref.startFrame = 1);
  probe<UsbdevfsUrb>(
    'urb.number_of_packets',
    56,
    (p) => p.ref.numberOfPackets = 1,
  );
  probe<UsbdevfsUrb>('urb.error_count', 56, (p) => p.ref.errorCount = 1);
  probe<UsbdevfsUrb>('urb.signr', 56, (p) => p.ref.signr = 1);
  probe<UsbdevfsUrb>('urb.usercontext', 56, (p) => p.ref.usercontext = ptr);
  return out;
}
