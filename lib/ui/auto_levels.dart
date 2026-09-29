// SPDX-License-Identifier: GPL-3.0-or-later
//
// Automatic waterfall/spectrum contrast (no SDR++ equivalent: SDR++ only has
// the manual Max/Min sliders of main_window.cpp:633-663).
//
// Per FFT row:
//   noise = [AutoLevelTuning.noisePercentile] of the valid bins (robust against
//           the DC spike, band-edge roll-off and floored "zero" bins),
//   peak  = maximum of the valid bins.
// Rows are aggregated into [AutoLevelTuning.bucket]-long buckets (mean noise,
// max peak) kept in a ring of [AutoLevelTuning.window] / bucket entries, so the
// sliding window never stores whole rows. Over the window:
//   floor = min(bucket noise), peak = max(bucket peak)
//   min   = floor − marginBelow
//   max   = max(floor + minRange, peak + marginAbove)
// i.e. with no signal the top sits [minRange] above the noise floor, so
// amplified noise is not stretched over the whole palette.
//
// The displayed levels glide towards those targets (fast when widening the
// range, slow when narrowing it), so the picture does not breathe every frame.
// The statistics belong to one spectrum: a row covering a different frequency
// span (retune, zoom, sample rate) restarts the window, as does [reset] (gain,
// source). After a restart the first row snaps the levels, then a short
// relearn period uses the fast time constant both ways.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// All tuning constants of the automatic contrast, in one place.
abstract final class AutoLevelTuning {
  /// Sliding window length.
  static const window = Duration(seconds: 30);

  /// Aggregation bucket (ring entry) length.
  static const bucket = Duration(seconds: 1);

  /// Per-row noise estimate: this fraction of valid bins lies below it.
  static const noisePercentile = 0.2;

  /// Bins at or below this are floored zeros (iq_frontend clamps |x|² at
  /// 1e-20, i.e. −200 dB) and are ignored.
  static const invalidBelowDb = -190.0;

  /// Bottom of the palette below the noise floor.
  static const marginBelowDb = 5.0;

  /// Headroom above the strongest signal.
  static const marginAboveDb = 3.0;

  /// Minimum range above the noise floor (also the top with no signal).
  /// Must stay ≥ 10 − marginBelowDb (SdrUiState keeps max ≥ min + 10).
  static const minRangeDb = 25.0;

  /// Time constant when the range widens (a signal appears).
  static const fastTau = Duration(milliseconds: 250);

  /// Time constant when the range narrows (a signal left the window).
  static const slowTau = Duration(milliseconds: 1500);

  /// After a restart both directions use [fastTau] for this long.
  static const relearn = Duration(seconds: 2);

  /// Level changes smaller than this are not pushed to the waterfall.
  static const deadbandDb = 0.5;

  /// Rows whose span differs by more than this belong to another spectrum.
  static const spanToleranceHz = 1.0;
}

class _Bucket {
  _Bucket(this.start);
  Duration start;
  double noiseSum = 0;
  int count = 0;
  double peak = double.negativeInfinity;
  double get noise => noiseSum / count;
}

class AutoLevels {
  final List<_Bucket> _ring = <_Bucket>[];
  _Bucket? _current;
  double? _low, _high;
  Duration? _lastTime;
  Duration? _relearnUntil;
  Float32List _sortBuf = Float32List(0);

  /// Step assumed for the first row after a restart (FFT rate is ~20 rows/s).
  static const _nominalRowPeriod = Duration(milliseconds: 50);

  /// Smoothed levels (null until the first valid row).
  double? min, max;

  /// Unsmoothed window targets (null until the first valid row).
  double? targetMin, targetMax;

  /// Window statistics (null until the first valid row).
  double? floor, peak;

  static int get _capacity =>
      AutoLevelTuning.window.inMicroseconds ~/
      AutoLevelTuning.bucket.inMicroseconds;

  /// Closed buckets currently in the window (tests).
  @visibleForTesting
  int get debugBucketCount => _ring.length;

  /// Forgets the window (the displayed [min]/[max] stay until the next row).
  void reset() {
    _ring.clear();
    _current = null;
    _low = _high = null;
    floor = peak = targetMin = targetMax = null;
    _lastTime = null;
    _relearnUntil = null;
  }

  /// Adds one FFT row covering `[lowFreq, highFreq)` observed at [now]
  /// (monotonic). Returns false for rows without valid bins.
  bool addRow(Float32List db, double lowFreq, double highFreq, Duration now) {
    final tol = AutoLevelTuning.spanToleranceHz;
    if (_low != null &&
        ((lowFreq - _low!).abs() > tol || (highFreq - _high!).abs() > tol)) {
      reset();
    }
    final stats = rowStats(db);
    if (stats == null) return false;
    final restarted = _low == null;
    _low = lowFreq;
    _high = highFreq;

    var cur = _current;
    if (cur == null || now - cur.start >= AutoLevelTuning.bucket) {
      if (cur != null) _ring.add(cur);
      cur = _current = _Bucket(now);
    }
    // Expire by time (rows may pause, e.g. while the app is in background),
    // and by count as a hard bound on memory.
    while (_ring.isNotEmpty &&
        (now - _ring.first.start > AutoLevelTuning.window ||
            _ring.length >= _capacity)) {
      _ring.removeAt(0);
    }
    cur.noiseSum += stats.noise;
    cur.count++;
    cur.peak = math.max(cur.peak, stats.peak);

    var f = cur.noise, p = cur.peak;
    for (final b in _ring) {
      if (b.noise < f) f = b.noise;
      if (b.peak > p) p = b.peak;
    }
    floor = f;
    peak = p;
    final tMin = f - AutoLevelTuning.marginBelowDb;
    final tMax = math.max(
      f + AutoLevelTuning.minRangeDb,
      p + AutoLevelTuning.marginAboveDb,
    );
    targetMin = tMin;
    targetMax = tMax;

    if (restarted) _relearnUntil = now + AutoLevelTuning.relearn;
    final last = _lastTime;
    _lastTime = now;
    if (min == null || max == null) {
      // Nothing shown yet: jump straight to the levels.
      min = tMin;
      max = tMax;
      return true;
    }
    // After a restart (no previous row) glide from the old levels quickly.
    final dt = last == null ? _nominalRowPeriod : now - last;
    final relearning = _relearnUntil != null && now < _relearnUntil!;
    // Widening: min down / max up → fast. Narrowing → slow.
    min = _glide(min!, tMin, dt, fast: relearning || tMin < min!);
    max = _glide(max!, tMax, dt, fast: relearning || tMax > max!);
    return true;
  }

  static double _glide(double v, double target, Duration dt, {required bool fast}) {
    final tau = fast ? AutoLevelTuning.fastTau : AutoLevelTuning.slowTau;
    if (dt <= Duration.zero) return v;
    final a = 1 - math.exp(-dt.inMicroseconds / tau.inMicroseconds);
    return v + (target - v) * a;
  }

  /// Per-row noise ([AutoLevelTuning.noisePercentile]) and peak of the valid
  /// bins, or null if the row has none.
  ({double noise, double peak})? rowStats(Float32List db) {
    if (_sortBuf.length < db.length) _sortBuf = Float32List(db.length);
    var n = 0;
    var peak = double.negativeInfinity;
    for (var i = 0; i < db.length; i++) {
      final v = db[i];
      if (!v.isFinite || v <= AutoLevelTuning.invalidBelowDb) continue;
      _sortBuf[n++] = v;
      if (v > peak) peak = v;
    }
    if (n == 0) return null;
    final view = Float32List.sublistView(_sortBuf, 0, n)..sort();
    final k = ((n - 1) * AutoLevelTuning.noisePercentile).round();
    return (noise: view[k].toDouble(), peak: peak);
  }
}
