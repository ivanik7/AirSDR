// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/main.dart';

void main() {
  test('Native engine is default with explicit Dart fallback', () {
    expect(requestedEngine(environment: const {}), 'native');
    expect(requestedEngine(environment: const {'SDR_ENGINE': ''}), 'native');
    expect(
      requestedEngine(environment: const {'SDR_ENGINE': 'bogus'}),
      'native',
    );
    expect(requestedEngine(environment: const {'SDR_ENGINE': 'dart'}), 'dart');
    expect(
      requestedEngine(environment: const {'SDR_ENGINE': 'NATIVE'}),
      'native',
    );
  });
  test('Android native audio requires API 26 and ABI 3', () {
    expect(androidNativeAvailable(sdkInt: 24, abi: 3), isFalse);
    expect(androidNativeAvailable(sdkInt: 25, abi: 3), isFalse);
    expect(androidNativeAvailable(sdkInt: 26, abi: 2), isFalse);
    expect(androidNativeAvailable(sdkInt: 26, abi: 3), isTrue);
  });
}
