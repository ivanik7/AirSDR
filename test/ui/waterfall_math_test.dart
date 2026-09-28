// Tests for lib/ui/waterfall_math.dart, lib/ui/colormaps.dart, lib/ui/hrfreq.dart.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/ui/colormaps.dart';
import 'package:sdr_flutter/ui/hrfreq.dart';
import 'package:sdr_flutter/ui/waterfall_math.dart';

void main() {
  group('doZoom', () {
    test('max-decimation, factor 2', () {
      final inp = Float32List.fromList([-10, -5, -20, -30, 0, -1, -7, -8]);
      final out = Float32List(4);
      doZoom(0, 8, 8, 4, inp, out);
      expect(out, [-5, -20, 0, -7]);
    });

    test('factor < 1 repeats bins (nearest)', () {
      final inp = Float32List.fromList([1, 2, 3, 4]);
      final out = Float32List(8);
      doZoom(0, 4, 4, 8, inp, out);
      expect(out, [1, 1, 2, 2, 3, 3, 4, 4]);
    });

    test('offset window and end clipping (uFactor)', () {
      final inp = Float32List.fromList([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
      final out = Float32List(3);
      doZoom(4, 6, 10, 3, inp, out); // bins 4..9, 2 per pixel
      expect(out, [5, 7, 9]);
      // Window runs past the end: last pixel only uses what exists.
      final out2 = Float32List(2);
      doZoom(7, 6, 10, 2, inp, out2); // factor 3: [7,8,9], [10..] clipped -> -inf loop 0 times
      expect(out2[0], 9);
      expect(out2[1], double.negativeInfinity);
    });

    test('negative offset clamps to 0', () {
      final inp = Float32List.fromList([3, 1, 2, 0]);
      final out = Float32List(2);
      doZoom(-5, 4, 4, 2, inp, out);
      expect(out, [3, 2]);
    });

    test('zoomWindow matches SDR++ pushFFT', () {
      // Whole view: all bins.
      expect(zoomWindow(8192, 2.4e6, 2.4e6, 0), (0, 8192));
      // Half view centred on the upper quarter.
      expect(zoomWindow(8192, 2.4e6, 1.2e6, 0.6e6), (4096, 4096));
    });
  });

  group('remapRow', () {
    test('identity', () {
      final src = Float32List.fromList([1, 2, 3, 4]);
      final dst = Float32List(4);
      remapRow(src, 0, 4, dst, 0, 4);
      expect(dst, [1, 2, 3, 4]);
    });

    test('zoom out: max of overlapped pixels, NaN outside', () {
      final src = Float32List.fromList([1, 5, 3, 4]);
      final dst = Float32List(4);
      remapRow(src, 0, 4, dst, -4, 4);
      expect(dst[0].isNaN && dst[1].isNaN, isTrue);
      expect(dst[2], 5);
      expect(dst[3], 4);
    });

    test('zoom in: nearest', () {
      final src = Float32List.fromList([1, 2]);
      final dst = Float32List(4);
      remapRow(src, 0, 2, dst, 0, 2);
      expect(dst, [1, 1, 2, 2]);
    });
  });

  group('grid / labels', () {
    test('findBestRange', () {
      expect(findBestRange(2.4e6, 10), 250000);
      expect(findBestRange(100, 10), 20);
      expect(findBestRange(1e12, 10), 50000000);
      expect(findBestRange(120, 10), 20); // 120/10 = 12 !< 10 → 20: 6 < 10
    });

    test('printAndScale (%.6g + K/M/G)', () {
      expect(printAndScale(500), '500');
      expect(printAndScale(12500), '12.5K');
      expect(printAndScale(100250000), '100.25M');
      expect(printAndScale(1234567890), '1.23457G');
      expect(printAndScale(-2500), '-2.5K');
      expect(printAndScale(0), '0');
    });

    test('formatG', () {
      expect(formatG(0.0001), '0.0001');
      expect(formatG(0.00001), '1e-05');
      expect(formatG(1234567), '1.23457e+06');
      expect(formatG(100.0), '100');
    });
  });

  group('colormaps', () {
    test('14 SDR++ maps, classic and turbo present', () {
      expect(sdrppColorMaps.length, 14);
      expect(colorMapByName('Classic').colors.first, 0x000020);
      expect(colorMapByName('turbo').colors.first, 0x30123B);
      expect(colorMapByName('nonexistent').id, 'classic');
    });

    test('palette endpoints and packing (0xAABBGGRR)', () {
      final c = colorMapByName('classic');
      final p = buildPalette(c.colors);
      expect(p.length, kPaletteResolution);
      expect(p[0], 0xFF200000); // #000020 → b=0x20
      // Last entry: lower=upper=last colour (#4A0000) → r=0x4A.
      expect(p[kPaletteResolution - 1], 0xFF00004A);
      // Byte order is R,G,B,A in memory (rgba8888).
      final bytes = Uint8List.view(Uint32List.fromList([p[0]]).buffer);
      expect(bytes, [0x00, 0x00, 0x20, 0xFF]);
    });

    test('interpolation matches updatePalletteFromArray', () {
      // Two colours, resolution 4: i/4*2 = 0, .5, 1, 1.5
      final p = buildPalette([0x000000, 0xFF0000], resolution: 4);
      expect(p[0] & 0xFF, 0);
      expect(p[1] & 0xFF, 127); // 255*0.5 truncated
      expect(p[2] & 0xFF, 255);
      expect(p[3] & 0xFF, 255); // upperId clamped
    });

    test('paletteLookup clamps and maps like pushFFT', () {
      final p = buildPalette(colorMapByName('turbo').colors);
      expect(paletteLookup(p, -200, -120, 0), p[0]);
      expect(paletteLookup(p, 10, -120, 0), p[p.length - 1]);
      expect(paletteLookup(p, -60, -120, 0), p[(0.5 * (p.length - 1)).toInt()]);
      expect(paletteLookup(p, double.nan, -120, 0), kOpaqueBlack);
      expect(packedToArgb(0xFF200000), 0xFF000020);
    });
  });

  group('hrfreq', () {
    test('toString', () {
      expect(hrfreqToString(145500000), '145.5MHz');
      expect(hrfreqToString(100000000), '100MHz');
      expect(hrfreqToString(12500), '12.5KHz');
      expect(hrfreqToString(500), '500Hz');
      expect(hrfreqToString(1296000000), '1.296GHz');
    });

    test('fromString', () {
      expect(hrfreqFromString('145.5M'), 145500000);
      expect(hrfreqFromString('freq: 7,074 kHz'), 7074000);
      expect(hrfreqFromString('100'), 100);
      expect(hrfreqFromString('x'), isNull);
    });
  });
}
