// SPDX-License-Identifier: GPL-3.0-or-later
// Dart FFI surface of the optional additive decoder extension
// (native/include/sdrcore_decoder_v1.h). Must never fabricate availability:
// a library without the extension (older native core, or one that simply
// has not implemented it yet) must make FfiNativeDecoderApi.tryOpen return
// null, and the required v3 radio ABI must stay unaffected either way.
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/native/native_decoder_api.dart';
import 'package:sdr_flutter/native/native_radio_api.dart';

void main() {
  final libraryPath = Platform.environment['SDRCORE_HOST_LIBRARY'];
  final skipReason = (libraryPath == null || libraryPath.isEmpty)
      ? 'Set SDRCORE_HOST_LIBRARY to a real host libsdrcore.so build'
      : null;

  test('decoder Dart struct sizes match the compiled C ABI header', () {
    // SdrDecoderDescriptor: 4+4+32+4*6 = 64 bytes. SdrDecoderEvent:
    // 4+4+8+8+4+4+8 = 40 bytes. Both must round-trip in sync with any
    // native/include/sdrcore_decoder_v1.h struct edit.
    expect(FfiNativeDecoderApi.layoutSizes, [64, 40]);
  });

  test('required v3 radio symbols resolve from a real host library whether or '
      'not the optional decoder extension is present', () {
    if (skipReason != null) return;
    // Must not throw: v3 is unaffected by decoder (ab)sence.
    final api = FfiNativeRadioApi.open(libraryPath: libraryPath);
    expect(api, isNotNull);
  }, skip: skipReason);

  test('real host library exposes all embedded decoder backends', () {
    if (skipReason != null) return;
    final lib = DynamicLibrary.open(libraryPath!);
    // sdr_version must still be resolvable (v3 unaffected).
    final version = lib.lookupFunction<Uint32 Function(), int Function()>(
      'sdr_version',
    )();
    expect(version, 3);
    final decoder = FfiNativeDecoderApi.tryOpen(lib);
    expect(decoder, isNotNull);
    final descriptors = decoder!.descriptors();
    expect(descriptors.map((d) => d.id), [
      'sstv',
      'rtl_433',
      'adsb',
      'meshtastic',
    ]);
    expect(descriptors[1].available, isTrue);
    expect(descriptors[1].input, 3);
    expect(descriptors[1].exclusiveReceiver, isFalse);
    expect(descriptors[1].requiredRateHz, isNull);
    expect(descriptors[2].available, isTrue);
    expect(descriptors[2].input, 4);
    expect(descriptors[2].requiredRateHz, 2400000);
    expect(descriptors[3].available, isTrue);
    expect(descriptors[3].input, 3);
    expect(descriptors[3].exclusiveReceiver, isFalse);
    expect(descriptors[3].requiredRateHz, 1000000);
  }, skip: skipReason);

  test('tryOpen returns null against the current process (no sdr_decoder_* symbols)', () {
    final lib = DynamicLibrary.process();
    expect(FfiNativeDecoderApi.tryOpen(lib), isNull);
  });
}
