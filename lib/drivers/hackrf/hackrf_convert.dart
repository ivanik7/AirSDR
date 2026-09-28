// int8 interleaved I/Q (HackRF) -> Float32 interleaved conversion.
//
// Port of the conversion done in the SDR++ hackrf_source RX callback
// (~/prj/sdrpp/source_modules/hackrf_source/src/main.cpp:384-389):
//
//   volk_8i_s32f_convert_32f((float*)writeBuf, (int8_t*)transfer->buffer,
//                            128.0f, transfer->valid_length);
//   stream.swap(valid_length / 2);
//
// volk_8i_s32f_convert_32f (volk kernels/volk/volk_8i_s32f_convert_32f.h,
// generic): out[i] = (float)in[i] * (1.0f / scalar). With scalar == 128 the
// factor is an exact power of two, so every implementation below is
// bit-identical to volk.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

/// 256-entry LUT: unsigned byte value -> (int8)byte / 128.
final Float32List hackrfS8Lut = () {
  final lut = Float32List(256);
  for (var b = 0; b < 256; b++) {
    lut[b] = b.toSigned(8) / 128.0;
  }
  return lut;
}();

/// volk_8i_s32f_convert_32f(outputVector, inputVector, scalar, num_points).
@pragma('vm:prefer-inline')
@pragma('vm:unsafe:no-bounds-checks')
void volk8iS32fConvert32f(
  Float32List outputVector,
  Int8List inputVector,
  double scalar,
  int numPoints,
) {
  final iScalar = 1.0 / scalar;
  for (var number = 0; number < numPoints; number++) {
    outputVector[number] = inputVector[number] * iScalar;
  }
}

/// HackRF fast path: [validLength] bytes of int8 I/Q in [buffer] (e.g.
/// [HackrfTransfer.buffer], a view on native memory) -> [out] as interleaved
/// re,im floats scaled by 1/128. Returns the number of complex samples
/// (validLength / 2), i.e. the value SDR++ passes to stream.swap().
@pragma('vm:unsafe:no-bounds-checks')
int hackrfConvertS8ToF32(Uint8List buffer, int validLength, Float32List out) {
  if (validLength > buffer.length || validLength > out.length) {
    throw RangeError('validLength $validLength exceeds buffer/out length');
  }
  final lut = hackrfS8Lut;
  for (var i = 0; i < validLength; i++) {
    out[i] = lut[buffer[i]];
  }
  return validLength ~/ 2;
}
