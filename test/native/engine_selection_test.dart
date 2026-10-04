// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/main.dart';

void main() {
  test('Dart engine is the default; native is opt-in only', () {
    expect(requestedEngine(environment: const {}), 'dart');
    expect(requestedEngine(environment: const {'SDR_ENGINE': ''}), 'dart');
    expect(requestedEngine(environment: const {'SDR_ENGINE': 'bogus'}), 'dart');
    expect(requestedEngine(environment: const {'SDR_ENGINE': 'dart'}), 'dart');
    expect(
      requestedEngine(environment: const {'SDR_ENGINE': 'NATIVE'}),
      'native',
    );
  });
}
