// SPDX-License-Identifier: GPL-3.0-or-later
//
// Host Dart FFI coverage for the parts of ABI 2 (native/include/sdrcore.h)
// that lib/native/sdr_core.dart does not wrap yet: sdr_v2_open_file,
// sdr_v2_open_usb, sdr_v2_configure, and sdr_v2_close. This file binds the
// C ABI directly with dart:ffi (same approach as
// test/usb/usbfs_sys_test.dart binding libc directly) instead of going
// through lib/native/sdr_core.dart, because that wrapper's public surface
// (SdrCoreV2Bindings) only exposes openSynthetic/start/stop/close/stats.
// Extending that wrapper is lib/ work owned by the native core task, not
// this test-only task; see docs/native-n1-tests.md for the boundary.
//
// Build the host .so first and point SDRCORE_HOST_LIBRARY at it:
//   native/tests/run_host_tests.sh <build_dir>
//   SDRCORE_HOST_LIBRARY=<build_dir>/libsdrcore.so flutter test test/native
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

// Mirrors SdrStats from native/include/sdrcore.h byte-for-byte.
final class _NativeStats extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int revision;
  @Uint32()
  external int state;
  @Uint32()
  external int source;
  @Int32()
  external int lastError;
  @Uint32()
  external int sampleRate;
  @Uint64()
  external int frequencyHz;
  @Int32()
  external int gainTenthsDb;
  @Uint32()
  external int reserved;
  @Uint64()
  external int inputSamples;
  @Uint64()
  external int processedSamples;
  @Uint64()
  external int droppedSamples;
  @Uint64()
  external int checksum;
}

final class _Handle extends Opaque {}

// ABI result/enum values from native/include/sdrcore.h.
const int _sdrOk = 0;
const int _sdrInvalidArgument = -1;
const int _sdrInvalidState = -2;

const int _sdrIdle = 0;
const int _sdrRunning = 2;
const int _sdrFile = 1;
const int _sdrRtlsdr = 3;
const int _sdrHackrf = 4;

class _Abi2 {
  _Abi2(String libraryPath) : _lib = DynamicLibrary.open(libraryPath) {
    version = _lib.lookupFunction<Uint32 Function(), int Function()>(
      'sdr_version',
    );
    create = _lib
        .lookupFunction<Pointer<_Handle> Function(), Pointer<_Handle> Function()>(
          'sdr_create',
        );
    destroy = _lib
        .lookupFunction<
          Void Function(Pointer<_Handle>),
          void Function(Pointer<_Handle>)
        >('sdr_destroy');
    openFile = _lib
        .lookupFunction<
          Int32 Function(Pointer<_Handle>, Int32, Uint32),
          int Function(Pointer<_Handle>, int, int)
        >('sdr_v2_open_file');
    openUsb = _lib
        .lookupFunction<
          Int32 Function(Pointer<_Handle>, Int32, Uint32),
          int Function(Pointer<_Handle>, int, int)
        >('sdr_v2_open_usb');
    configure = _lib
        .lookupFunction<
          Int32 Function(Pointer<_Handle>, Uint64, Uint32, Int32),
          int Function(Pointer<_Handle>, int, int, int)
        >('sdr_v2_configure');
    start = _lib
        .lookupFunction<
          Int32 Function(Pointer<_Handle>),
          int Function(Pointer<_Handle>)
        >('sdr_v2_start');
    stop = _lib
        .lookupFunction<
          Int32 Function(Pointer<_Handle>),
          int Function(Pointer<_Handle>)
        >('sdr_v2_stop');
    close = _lib
        .lookupFunction<
          Int32 Function(Pointer<_Handle>),
          int Function(Pointer<_Handle>)
        >('sdr_v2_close');
    stats = _lib
        .lookupFunction<
          Int32 Function(Pointer<_Handle>, Pointer<_NativeStats>),
          int Function(Pointer<_Handle>, Pointer<_NativeStats>)
        >('sdr_v2_stats');
  }

  final DynamicLibrary _lib;
  late final int Function() version;
  late final Pointer<_Handle> Function() create;
  late final void Function(Pointer<_Handle>) destroy;
  late final int Function(Pointer<_Handle>, int, int) openFile;
  late final int Function(Pointer<_Handle>, int, int) openUsb;
  late final int Function(Pointer<_Handle>, int, int, int) configure;
  late final int Function(Pointer<_Handle>) start;
  late final int Function(Pointer<_Handle>) stop;
  late final int Function(Pointer<_Handle>) close;
  late final int Function(Pointer<_Handle>, Pointer<_NativeStats>) stats;
}

_NativeStats _snapshot(_Abi2 abi, Pointer<_Handle> h, Pointer<_NativeStats> buf) {
  buf.ref.size = sizeOf<_NativeStats>();
  buf.ref.revision = 2;
  expect(abi.stats(h, buf), _sdrOk);
  return buf.ref;
}

void main() {
  final libraryPath = Platform.environment['SDRCORE_HOST_LIBRARY'];
  final skipReason = !Platform.isLinux
      ? 'Host libsdrcore.so is built for Linux (or Android separately)'
      : (libraryPath == null || libraryPath.isEmpty)
      ? 'Set SDRCORE_HOST_LIBRARY to the host CMake libsdrcore.so path'
      : null;

  group('sdrcore ABI 2 file/usb/configure surface via raw Dart FFI', () {
    late _Abi2 abi;

    setUp(() {
      if (skipReason != null) return;
      abi = _Abi2(libraryPath!);
      expect(abi.version(), 2);
    });

    test(
      'open_file duplicates the fd; caller may close the original '
      'immediately and the native stream keeps reading its own copy',
      () {
        final h = abi.create();
        final path =
            '/tmp/sdr_core_ffi_test_data_${DateTime.now().microsecondsSinceEpoch}.cu8';
        File(path).writeAsBytesSync(const [1, 2, 3, 4, 5, 6, 7, 8]);
        final fd = _openReadOnly(path);
        expect(fd, greaterThanOrEqualTo(0));

        expect(abi.openFile(h, fd, 1000), _sdrOk);
        _closeFd(fd); // Caller's original fd closed right after open_file.
        expect(abi.start(h), _sdrOk);

        final buf = calloc<_NativeStats>();
        try {
          _NativeStats s = _snapshot(abi, h, buf);
          for (var i = 0; i < 50 && s.inputSamples < 4; i++) {
            sleep(const Duration(milliseconds: 10));
            s = _snapshot(abi, h, buf);
          }
          expect(s.inputSamples, 4); // 8 bytes / 2 = 4 complex CU8 samples.
          expect(s.inputSamples, s.processedSamples + s.droppedSamples);
          expect(abi.stop(h), _sdrOk);
          expect(abi.close(h), _sdrOk);
        } finally {
          calloc.free(buf);
        }
        abi.destroy(h);
        File(path).deleteSync();
      },
      skip: skipReason,
    );

    test(
      'configure validates frequency ceiling and gain range from the header',
      () {
        final h = abi.create();
        expect(abi.openFile(h, _devZeroFd(), 2000000), _sdrOk);
        // Frequency ceiling: 7.25 GHz documented in sdrcore.h.
        expect(
          abi.configure(h, 7250000001, 2000000, 0),
          _sdrInvalidArgument,
        );
        expect(abi.configure(h, 7250000000, 2000000, 0), _sdrOk);
        // Gain range: tenths of a dB, header says +/-100.0 dB (+/-1000).
        expect(abi.configure(h, 1000000, 2000000, 1001), _sdrInvalidArgument);
        expect(
          abi.configure(h, 1000000, 2000000, -1001),
          _sdrInvalidArgument,
        );
        expect(abi.configure(h, 1000000, 2000000, 1000), _sdrOk);
        // Sample rate outside the accepted 1 kHz..20 MHz band.
        expect(abi.configure(h, 1000000, 999, 0), _sdrInvalidArgument);
        expect(abi.configure(h, 1000000, 20000001, 0), _sdrInvalidArgument);
        abi.close(h);
        abi.destroy(h);
      },
      skip: skipReason,
    );

    test(
      'open_usb rejects a non-USB fd for both driver enum values without '
      'mutating state',
      () {
        final h = abi.create();
        final fd = _devZeroFd();
        expect(abi.openUsb(h, fd, _sdrRtlsdr), isNot(_sdrOk));
        expect(abi.openUsb(h, fd, _sdrHackrf), isNot(_sdrOk));
        // Passing a source that is not a USB enum value is a plain
        // argument error, distinct from a driver open failure.
        expect(abi.openUsb(h, fd, _sdrFile), _sdrInvalidArgument);
        final buf = calloc<_NativeStats>();
        try {
          final s = _snapshot(abi, h, buf);
          expect(s.state, _sdrIdle); // Rejected calls never left IDLE.
        } finally {
          calloc.free(buf);
        }
        _closeFd(fd);
        abi.destroy(h);
      },
      skip: skipReason,
    );

    test(
      'close() is a one-shot operation: a second close() on an idle handle '
      'is rejected, and the handle remains usable afterward',
      () {
        final h = abi.create();
        final fd = _devZeroFd();
        expect(abi.openFile(h, fd, 1000), _sdrOk);
        expect(abi.close(h), _sdrOk);
        expect(abi.close(h), _sdrInvalidState);
        // Still usable: open again on the same handle after close().
        expect(abi.openFile(h, fd, 1000), _sdrOk);
        expect(abi.close(h), _sdrOk);
        _closeFd(fd);
        abi.destroy(h);
      },
      skip: skipReason,
    );

    test(
      'start() while already RUNNING is rejected without disturbing the '
      'running stream (serialized single-owner contract)',
      () {
        final h = abi.create();
        final fd = _devZeroFd();
        expect(abi.openFile(h, fd, 1000), _sdrOk);
        expect(abi.start(h), _sdrOk);
        expect(abi.start(h), _sdrInvalidState);
        final buf = calloc<_NativeStats>();
        try {
          expect(_snapshot(abi, h, buf).state, _sdrRunning);
        } finally {
          calloc.free(buf);
        }
        abi.stop(h);
        abi.close(h);
        _closeFd(fd);
        abi.destroy(h);
      },
      skip: skipReason,
    );
  });
}

// /dev/zero is a convenient infinite CU8-shaped byte source for ABI
// argument-validation tests that never need real content to check.
int _devZeroFd() => _openReadOnly('/dev/zero');

final DynamicLibrary _libc = DynamicLibrary.process();
final int Function(Pointer<Utf8>, int, int) _openSyscall = _libc
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Int32, VarArgs<(Int32,)>),
      int Function(Pointer<Utf8>, int, int)
    >('open');
final int Function(int) _closeSyscall = _libc
    .lookupFunction<Int32 Function(Int32), int Function(int)>('close');

int _openReadOnly(String path) {
  final p = path.toNativeUtf8();
  try {
    return _openSyscall(p, 0 /* O_RDONLY */, 0);
  } finally {
    malloc.free(p);
  }
}

void _closeFd(int fd) => _closeSyscall(fd);
