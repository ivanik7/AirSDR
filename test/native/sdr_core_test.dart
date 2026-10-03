import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/native/sdr_core.dart';

final class FakeBindings implements SdrCoreBindings {
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
}
