// uint8 interleaved I/Q (RTL-SDR) -> Float32 interleaved conversion.
//
// Port of the conversion in the SDR++ rtl_sdr_source async handler
// (~/prj/sdrpp/source_modules/rtl_sdr_source/src/main.cpp:531-539):
//
//   int sampCount = len / 2;
//   for (int i = 0; i < sampCount; i++) {
//       _this->stream.writeBuf[i].re = ((float)buf[i * 2] - 127.4) / 128.0f;
//       _this->stream.writeBuf[i].im = ((float)buf[(i * 2) + 1] - 127.4) / 128.0f;
//   }
//   if (!_this->stream.swap(sampCount)) { return; }
//
// Note the C++ arithmetic: `127.4` is a double literal, so the expression is
// evaluated in double ((double)(float)b - 127.4) / 128.0 and rounded to float
// once on store. A Float32List store of the same Dart double expression is
// therefore bit-identical, and a 256-entry LUT built that way reproduces SDR++
// exactly (checked in test/sdrpp/modules/sources/rtl_sdr_convert_test.dart).
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

/// 256-entry LUT: byte -> ((double)b - 127.4) / 128.0 rounded to float32.
final Float32List rtlsdrU8Lut = () {
  final lut = Float32List(256);
  for (var b = 0; b < 256; b++) {
    lut[b] = (b.toDouble() - 127.4) / 128.0;
  }
  return lut;
}();

/// Reference implementation, a line-by-line transcription of the C++ loop
/// (no LUT). Used by tests and the benchmark.
void rtlsdrConvertU8ToF32Ref(Uint8List buf, int len, Float32List out) {
  final sampCount = len ~/ 2;
  for (var i = 0; i < sampCount; i++) {
    out[i * 2] = (buf[i * 2].toDouble() - 127.4) / 128.0;
    out[(i * 2) + 1] = (buf[(i * 2) + 1].toDouble() - 127.4) / 128.0;
  }
}

/// Fast path: [len] bytes of u8 I/Q in [buf] (usually a view on the native
/// USB buffer) -> [out] as interleaved re,im floats. Returns the number of
/// complex samples (len / 2), the value SDR++ passes to stream.swap().
/// An odd trailing byte is ignored, like the C++ loop.
@pragma('vm:unsafe:no-bounds-checks')
int rtlsdrConvertU8ToF32(Uint8List buf, int len, Float32List out) {
  final sampCount = len ~/ 2;
  final n = sampCount * 2;
  if (len > buf.length || n > out.length) {
    throw RangeError('len $len exceeds buffer/out length');
  }
  final lut = rtlsdrU8Lut;
  for (var i = 0; i < n; i++) {
    out[i] = lut[buf[i]];
  }
  return sampCount;
}
