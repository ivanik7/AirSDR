// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/main.dart';

void main() {
  test('The sole Android receiver requires API 26 and ABI 3', () {
    expect(androidNativeAvailable(sdkInt: 24, abi: 3), isFalse);
    expect(androidNativeAvailable(sdkInt: 25, abi: 3), isFalse);
    expect(androidNativeAvailable(sdkInt: 26, abi: 2), isFalse);
    expect(androidNativeAvailable(sdkInt: 26, abi: 3), isTrue);
  });
}
