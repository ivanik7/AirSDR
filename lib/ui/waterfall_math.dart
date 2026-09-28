// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pure helpers of the SDR++ waterfall widget.
//
// Port of sdrpp/core/src/gui/widgets/waterfall.cpp (SDR++ @8c9f5ee):
//   * freq_ranges / findBestRange   lines 29-47
//   * printAndScale                 lines 49-63
//   * doZoom                        lines 65-90
// plus [remapRow], a UI-side helper (not in SDR++) that re-projects an already
// decimated row onto a different frequency span (see WaterfallModel).

import 'dart:math' as math;
import 'dart:typed_data';

/// Grid steps (Hz / dB) — `freq_ranges[]`, waterfall.cpp:29-38.
const List<double> freqRanges = <double>[
  1.0, 2.0, 2.5, 5.0, //
  10.0, 20.0, 25.0, 50.0,
  100.0, 200.0, 250.0, 500.0,
  1000.0, 2000.0, 2500.0, 5000.0,
  10000.0, 20000.0, 25000.0, 50000.0,
  100000.0, 200000.0, 250000.0, 500000.0,
  1000000.0, 2000000.0, 2500000.0, 5000000.0,
  10000000.0, 20000000.0, 25000000.0, 50000000.0,
];

/// `findBestRange` (waterfall.cpp:40-47): smallest step giving fewer than
/// [maxSteps] grid lines over [bandwidth].
double findBestRange(double bandwidth, int maxSteps) {
  for (var i = 0; i < 32; i++) {
    if (bandwidth / freqRanges[i] < maxSteps.toDouble()) {
      return freqRanges[i];
    }
  }
  return 50000000.0;
}

/// C `printf("%.<precision>g", v)` (used by [printAndScale]).
String formatG(double v, [int precision = 6]) {
  if (v.isNaN) return 'nan';
  if (v.isInfinite) return v > 0 ? 'inf' : '-inf';
  if (v == 0) return (1 / v).isNegative ? '-0' : '0';
  final p = precision == 0 ? 1 : precision;
  final expStr = v.toStringAsExponential(p - 1);
  final ePos = expStr.indexOf('e');
  final x = int.parse(expStr.substring(ePos + 1));
  if (x < -4 || x >= p) {
    var mant = expStr.substring(0, ePos);
    if (mant.contains('.')) {
      mant = mant.replaceFirst(RegExp(r'0+$'), '');
      if (mant.endsWith('.')) mant = mant.substring(0, mant.length - 1);
    }
    final sign = x < 0 ? '-' : '+';
    final ax = x.abs();
    return '$mant' 'e$sign${ax < 10 ? '0$ax' : '$ax'}';
  }
  var s = v.toStringAsFixed(p - 1 - x);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  }
  return s;
}

/// `printAndScale` (waterfall.cpp:49-63): "%.6g" with K/M/G suffix.
/// For |freq| >= 1e12 SDR++ leaves the buffer untouched; we return ''.
String printAndScale(double freq) {
  final freqAbs = freq.abs();
  if (freqAbs < 1000) {
    return formatG(freq);
  } else if (freqAbs < 1000000) {
    return '${formatG(freq / 1000.0)}K';
  } else if (freqAbs < 1000000000) {
    return '${formatG(freq / 1000000.0)}M';
  } else if (freqAbs < 1000000000000) {
    return '${formatG(freq / 1000000000.0)}G';
  }
  return '';
}

final Float32List _f32 = Float32List(1);

/// Rounds to IEEE single precision (C `float` arithmetic in doZoom).
double _fround(double v) {
  _f32[0] = v;
  return _f32[0];
}

/// `doZoom` (waterfall.cpp:65-90) — 1:1 port, including the float (32-bit)
/// accumulation of `id`.
///
/// Resamples `in[offset .. offset+width)` (an [inSize]-bin dB row) to [outSize]
/// pixels by MAX-decimation (peaks are never lost); when there are fewer bins
/// than pixels (`factor < 1`) bins are repeated (nearest neighbour).
void doZoom(int offset, int width, int inSize, int outSize, Float32List inp, Float32List out) {
  // NOTE: REMOVE THAT SHIT, IT'S JUST A HACKY FIX
  if (offset < 0) {
    offset = 0;
  }
  if (width > 524288) {
    width = 524288;
  }

  final factor = _fround(width / outSize);
  final sFactor = factor.ceilToDouble();
  double uFactor;
  var id = offset.toDouble();
  double maxVal;
  int sId;
  for (var i = 0; i < outSize; i++) {
    maxVal = double.negativeInfinity;
    sId = id.toInt();
    uFactor = (sId + sFactor > inSize) ? sFactor - ((sId + sFactor) - inSize) : sFactor;
    for (var j = 0; j < uFactor; j++) {
      if (inp[sId + j] > maxVal) {
        maxVal = inp[sId + j];
      }
    }
    out[i] = maxVal;
    id = _fround(id + factor);
  }
}

/// `drawDataSize` / `drawDataStart` from `WaterFall::pushFFT` (waterfall.cpp:887-889):
/// the bin window of a full-band [rawFFTSize]-bin row that is visible for the
/// given view. Returns `(start, size)`.
(int, int) zoomWindow(int rawFFTSize, double wholeBandwidth, double viewBandwidth, double viewOffset) {
  final offsetRatio = viewOffset / (wholeBandwidth / 2.0);
  final drawDataSize = ((viewBandwidth / wholeBandwidth) * rawFFTSize).toInt();
  final drawDataStart = (((rawFFTSize / 2.0) * (offsetRatio + 1)) - (drawDataSize ~/ 2)).toInt();
  return (drawDataStart, drawDataSize);
}

/// Re-projects a decimated dB row [src] covering absolute frequencies
/// `[srcLow, srcHigh)` onto [dst] covering `[dstLow, dstHigh)`.
///
/// Not in SDR++ (which re-zooms its raw full-resolution rows in
/// `updateWaterfallFb`); rows here arrive already decimated by the DSP, so the
/// waterfall history is re-projected instead. Each output pixel takes the MAX
/// of the source pixels it overlaps (same policy as [doZoom]); pixels outside
/// the source span become NaN ("no data", painted black).
void remapRow(Float32List src, double srcLow, double srcHigh, Float32List dst, double dstLow, double dstHigh) {
  final n = src.length, m = dst.length;
  final srcSpan = srcHigh - srcLow;
  if (n == 0 || m == 0 || !(srcSpan > 0) || !(dstHigh > dstLow)) {
    for (var i = 0; i < m; i++) {
      dst[i] = double.nan;
    }
    return;
  }
  // Fast path: identical span and size.
  if (n == m && srcLow == dstLow && srcHigh == dstHigh) {
    dst.setAll(0, src);
    return;
  }
  final binsPerHz = n / srcSpan;
  final hzPerPx = (dstHigh - dstLow) / m;
  for (var i = 0; i < m; i++) {
    final f0 = dstLow + i * hzPerPx;
    final f1 = f0 + hzPerPx;
    final s0 = (f0 - srcLow) * binsPerHz;
    final s1 = (f1 - srcLow) * binsPerHz;
    if (s1 <= 0 || s0 >= n) {
      dst[i] = double.nan;
      continue;
    }
    var a = s0.floor();
    var b = s1.ceil();
    if (a < 0) a = 0;
    if (b > n) b = n;
    if (b <= a) b = math.min(a + 1, n);
    var maxVal = double.negativeInfinity;
    for (var j = a; j < b; j++) {
      final v = src[j];
      if (v > maxVal) maxVal = v;
    }
    dst[i] = maxVal;
  }
}
