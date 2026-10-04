import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/native/sdr_core.dart';

class FakeBindings implements SdrCoreBindings {
  FakeBindings({this.abi = 2, this.failCreate = false});

  final int abi;
  final bool failCreate;
  int versionCalls = 0;
  int createCalls = 0;
  final destroyed = <int>[];

  @override
  int version() {
    versionCalls++;
    return abi;
  }

  @override
  Pointer<SdrHandle> create() {
    createCalls++;
    return failCreate ? nullptr : Pointer<SdrHandle>.fromAddress(createCalls);
  }

  @override
  void destroy(Pointer<SdrHandle> handle) => destroyed.add(handle.address);
}

final class FakeV2Bindings extends FakeBindings implements SdrCoreV2Bindings {
  final calls = <String>[];

  @override
  int openFile(Pointer<SdrHandle> handle, int fd, int rate) {
    calls.add('file:$fd:$rate');
    return 0;
  }

  @override
  int openSynthetic(Pointer<SdrHandle> handle, int rate) => 0;

  @override
  int openUsb(Pointer<SdrHandle> handle, int fd, int source) {
    calls.add('usb:$fd:$source');
    return -5;
  }

  @override
  int configure(Pointer<SdrHandle> handle, int hz, int rate, int gain) {
    calls.add('configure:$hz:$rate:$gain');
    return 0;
  }

  @override
  int start(Pointer<SdrHandle> handle) => 0;

  @override
  int stop(Pointer<SdrHandle> handle) => 0;

  @override
  int close(Pointer<SdrHandle> handle) => 0;

  @override
  SdrCoreStats stats(Pointer<SdrHandle> handle) =>
      const SdrCoreStats(1, 3, 0, 0, 0, 0, 2400000, 100000000, 125, 0);
}

void main() {
  test('checks ABI before allocating a handle', () {
    final bindings = FakeBindings(abi: 1);
    expect(() => SdrCore.withBindings(bindings), throwsUnsupportedError);
    expect(bindings.versionCalls, 1);
    expect(bindings.createCalls, 0);
  });

  test('rejects allocation failure without destroying NULL', () {
    final bindings = FakeBindings(failCreate: true);
    final core = SdrCore.withBindings(bindings);
    expect(() => core.create(), throwsStateError);
    expect(bindings.destroyed, isEmpty);
  });

  test('accepts ABI 3, a superset that keeps every ABI 2 symbol', () {
    final bindings = FakeBindings(abi: 3);
    final core = SdrCore.withBindings(bindings);
    expect(core.version, 3);
    core.create().dispose();
    expect(bindings.destroyed, [1]);
  });

  test('rejects a future ABI it was not built against', () {
    expect(
      () => SdrCore.withBindings(FakeBindings(abi: 4)),
      throwsUnsupportedError,
    );
  });

  test(
    'each owned handle is released exactly once, even after repeated dispose',
    () {
      final bindings = FakeBindings();
      final core = SdrCore.withBindings(bindings);
      expect(core.version, 2);
      final first = core.create();
      final second = core.create();
      expect(first.isDisposed, isFalse);
      first.dispose();
      first.dispose();
      expect(first.isDisposed, isTrue);
      expect(bindings.destroyed, [1]);
      second.dispose();
      expect(bindings.destroyed, [1, 2]);
      expect(bindings.versionCalls, 2);
    },
  );

  test('ABI 2 dispatches fd and configuration units and propagates errors', () {
    final bindings = FakeV2Bindings();
    final instance = SdrCore.withBindings(bindings).create();
    instance.openFile(9, 2400000);
    instance.configure(100000000, 2400000, 125);
    expect(instance.stats.frequencyHz, 100000000);
    expect(() => instance.openUsb(10, 3), throwsStateError);
    expect(bindings.calls, [
      'file:9:2400000',
      'configure:100000000:2400000:125',
      'usb:10:3',
    ]);
    instance.dispose();
    expect(() => instance.configure(100000000, 2400000, 125), throwsStateError);
  });
}
