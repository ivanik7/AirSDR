// Tests for lib/drivers/hackrf/hackrf_convert.dart.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/drivers/hackrf/hackrf_convert.dart';

void main() {
  test('LUT covers all 256 byte values, exact (x/128)', () {
    for (var b = 0; b < 256; b++) {
      final s = b >= 128 ? b - 256 : b;
      expect(hackrfS8Lut[b], s / 128.0, reason: 'byte $b');
    }
    expect(hackrfS8Lut[0x80], -1.0);
    expect(hackrfS8Lut[0x7f], 127 / 128);
  });

  test('fast path is bit-identical to volk_8i_s32f_convert_32f(…,128)', () {
    final rnd = Random(1234);
    final n = 262144;
    final raw = Uint8List(n);
    for (var i = 0; i < n; i++) {
      raw[i] = rnd.nextInt(256);
    }
    final ref = Float32List(n);
    volk8iS32fConvert32f(ref, Int8List.sublistView(raw), 128.0, n);
    final out = Float32List(n);
    expect(hackrfConvertS8ToF32(raw, n, out), n ~/ 2);
    expect(
      Uint32List.sublistView(out),
      orderedEquals(Uint32List.sublistView(ref)),
    );
  });

  test('partial valid_length leaves the tail untouched', () {
    final raw = Uint8List.fromList([0x40, 0xc0, 0x01, 0x02]);
    final out = Float32List(4)..fillRange(0, 4, 9.0);
    expect(hackrfConvertS8ToF32(raw, 2, out), 1);
    expect(out, [0.5, -0.5, 9.0, 9.0]);
  });

  test('rejects validLength beyond buffers', () {
    expect(
      () => hackrfConvertS8ToF32(Uint8List(2), 4, Float32List(4)),
      throwsRangeError,
    );
    expect(
      () => hackrfConvertS8ToF32(Uint8List(4), 4, Float32List(2)),
      throwsRangeError,
    );
  });
}
