// Throughput microbenchmark of the source sample converters.
//
//   source ~/prj/env.sh
//   dart compile exe tool/source_convert_bench.dart -o /tmp/scb && /tmp/scb
//
// Measures (AOT) the RTL-SDR u8 -> f32 LUT converter used by rtl_sdr_source,
// its non-LUT reference (the literal C++ expression), and the HackRF int8 ->
// f32 converter used by hackrf_source, on native-memory buffers of the sizes
// the modules actually get (RTL 2.4 MS/s: 11776 B, HackRF: 262144 B).
//
// SPDX-License-Identifier: GPL-3.0-or-later

// ignore_for_file: avoid_print

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:sdr_flutter/drivers/hackrf/hackrf_convert.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/rtl_sdr_convert.dart';

double _bench(String name, int len, void Function(Uint8List, Float32List) f) {
  final p = malloc<Uint8>(len);
  final buf = p.asTypedList(len);
  for (var i = 0; i < len; i++) {
    buf[i] = (i * 31 + 7) & 0xff;
  }
  final out = Float32List(len);
  // warm up
  for (var i = 0; i < 200; i++) {
    f(buf, out);
  }
  final sw = Stopwatch()..start();
  var bytes = 0;
  while (sw.elapsedMilliseconds < 1500) {
    for (var i = 0; i < 50; i++) {
      f(buf, out);
    }
    bytes += 50 * len;
  }
  final s = sw.elapsedMicroseconds / 1e6;
  malloc.free(p);
  final mbps = bytes / s / 1e6;
  final msps = mbps / 2;
  print(
    '${name.padRight(34)} ${mbps.toStringAsFixed(0).padLeft(6)} MB/s '
    '= ${msps.toStringAsFixed(0).padLeft(5)} MS/s complex',
  );
  return msps;
}

void main() {
  print('buffer sizes: RTL 11776 B (2.4 MS/s asyncCount), HackRF 262144 B');
  _bench('rtl u8 LUT (rtlsdrConvertU8ToF32)', 11776, (b, o) {
    rtlsdrConvertU8ToF32(b, b.length, o);
  });
  _bench('rtl u8 reference (C++ expression)', 11776, (b, o) {
    rtlsdrConvertU8ToF32Ref(b, b.length, o);
  });
  _bench('hackrf s8 LUT (hackrfConvertS8ToF32)', 262144, (b, o) {
    hackrfConvertS8ToF32(b, b.length, o);
  });
  print('needed: RTL 3.2 MS/s max (6.4 MB/s), HackRF 20 MS/s (40 MB/s)');
}
