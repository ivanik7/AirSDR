// SPDX-License-Identifier: GPL-3.0-or-later
//
// Waterfall / spectrum data model (UI isolate).
//
// Port of the data side of sdrpp/core/src/gui/widgets/waterfall.cpp (SDR++ @8c9f5ee):
//   * getFFTBuffer + pushFFT (lines 876-942)   → [WaterfallModel.pushRow]
//   * updateWaterfallFb (lines 600-631)        → [WaterfallModel] full update
//   * smoothing / hold (pushFFT:914-941, display.cpp:41-45)
//   * updatePalletteFromArray                 → [WaterfallModel.setColorMap]
//
// Differences from SDR++ (docs/03 §2.3, §4.3 variant A):
//   * Rows arrive already MAX-decimated to the screen width by the DSP
//     (RadioController.fftRows) together with the absolute frequency span they
//     cover, instead of full-resolution FFTs. The history ring stores rows as
//     received; a full update re-projects them onto the current view with
//     [remapRow] (SDR++ re-runs doZoom on raw rows). Consequence: after zooming
//     IN, older rows are shown at their original (coarser) resolution; after
//     zooming OUT, parts of older rows outside their span are black.
//   * History is anchored to absolute frequency, so retuning the LO shifts old
//     rows (SDR++ keeps them at the same bin positions).
//   * The RGBA frame buffer is a ring (head index, no memmove); the painter
//     unwraps it with two drawImageRect calls.
//   * Full updates and image uploads are coalesced to at most once per frame
//     (SchedulerBinding.scheduleFrameCallback).
//   * The ui.Image is created with decodeImageFromPixelsSync (Impeller only);
//     if that throws (Skia / flutter_test) we fall back to the async
//     decodeImageFromPixels and keep the previous image until it is ready.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'colormaps.dart';
import 'waterfall_math.dart';

class WaterfallModel extends ChangeNotifier {
  WaterfallModel({int width = 256, int height = 256, ColorMapDef? colorMap, this.autoSchedule = true}) {
    _colorMap = colorMap ?? colorMapByName('classic');
    _palette = buildPalette(_colorMap.colors);
    _alloc(math.max(1, width), math.max(1, height));
  }

  /// When false, [flush] must be called manually (unit tests without a binding).
  final bool autoSchedule;

  // ---- Geometry / buffers -------------------------------------------------

  /// Columns (SDR++ `dataWidth`).
  int get width => _width;

  /// History rows (SDR++ `waterfallHeight`).
  int get height => _height;
  int _width = 0;
  int _height = 0;

  /// Received rows, [height] × [width] dB (NaN = no data). SDR++ `rawFFTs`.
  late Float32List _raw;
  late Float64List _rawLow;
  late Float64List _rawHigh;

  /// RGBA frame buffer ring, packed 0xAABBGGRR (bytes R,G,B,A on LE). SDR++ `waterfallFb`.
  late Uint32List rgba;

  /// Newest row index (SDR++ `currentFFTLine`, moves DOWN).
  int get head => _head;
  int _head = 0;

  /// Number of filled rows (SDR++ `fftLines`).
  int get lines => _lines;
  int _lines = 0;

  /// Latest row projected on the current view (SDR++ `latestFFT`), smoothed if enabled.
  late Float32List latestFFT;

  /// Peak hold (SDR++ `latestFFTHold`).
  late Float32List latestFFTHold;
  late Float32List _smoothingBuf;
  late Float32List _tmp;

  void _alloc(int w, int h) {
    _width = w;
    _height = h;
    _raw = Float32List(w * h)..fillRange(0, w * h, double.nan);
    _rawLow = Float64List(h);
    _rawHigh = Float64List(h);
    rgba = Uint32List(w * h)..fillRange(0, w * h, kOpaqueBlack);
    latestFFT = Float32List(w)..fillRange(0, w, double.nan);
    latestFFTHold = Float32List(w)..fillRange(0, w, -1000);
    _smoothingBuf = Float32List(w)..fillRange(0, w, double.nan);
    _tmp = Float32List(w);
    _head = 0;
    _lines = 0;
  }

  /// Resizes the buffers, keeping the newest min(lines, h) rows (re-sampled to [w]).
  void resize(int w, int h) {
    w = math.max(1, w);
    h = math.max(1, h);
    if (w == _width && h == _height) return;
    final oldRaw = _raw, oldLow = _rawLow, oldHigh = _rawHigh;
    final oldW = _width, oldH = _height, oldHead = _head;
    final keep = math.min(_lines, h);
    _alloc(w, h);
    final src = Float32List(oldW);
    final dst = Float32List(w);
    for (var i = 0; i < keep; i++) {
      final o = (oldHead + i) % oldH;
      src.setRange(0, oldW, oldRaw, o * oldW);
      remapRow(src, oldLow[o], oldHigh[o], dst, oldLow[o], oldHigh[o]);
      _raw.setRange(i * w, (i + 1) * w, dst);
      _rawLow[i] = oldLow[o];
      _rawHigh[i] = oldHigh[o];
    }
    _lines = keep;
    _head = 0;
    _fullUpdate = true;
    _schedule();
  }

  // ---- View / levels / palette -------------------------------------------

  /// Displayed absolute frequency span `[lowerFreq, upperFreq)`.
  double get lowerFreq => _lowerFreq;
  double get upperFreq => _upperFreq;
  double _lowerFreq = 0;
  double _upperFreq = 1;

  /// Sets the displayed span (SDR++ lowerFreq/upperFreq); triggers a full update.
  void setView(double lowerFreq, double upperFreq) {
    if (lowerFreq == _lowerFreq && upperFreq == _upperFreq) return;
    _lowerFreq = lowerFreq;
    _upperFreq = upperFreq;
    _fullUpdate = true;
    _schedule();
  }

  /// dB range (SDR++ waterfallMin/Max = fftMin/Max). Defaults: core.cpp min/max.
  double get minDb => _minDb;
  double get maxDb => _maxDb;
  double _minDb = -120;
  double _maxDb = 0;

  void setLevels(double minDb, double maxDb) {
    if (minDb == _minDb && maxDb == _maxDb) return;
    _minDb = minDb;
    _maxDb = maxDb;
    _fullUpdate = true;
    _schedule();
  }

  ColorMapDef get colorMap => _colorMap;
  late ColorMapDef _colorMap;
  Uint32List get palette => _palette;
  late Uint32List _palette;

  void setColorMap(ColorMapDef map) {
    if (identical(map, _colorMap)) return;
    _colorMap = map;
    _palette = buildPalette(map.colors);
    _fullUpdate = true;
    _schedule();
  }

  // ---- Smoothing / hold (SDR++ display menu) ----------------------------

  bool fftSmoothing = false;
  double fftSmoothingAlpha = 0.5;
  double fftSmoothingBeta = 0.5;
  bool fftHold = false;
  double fftHoldSpeed = 0.3;

  /// `setFFTSmoothingSpeed` (display.cpp:41-45): α = min(speed/(fftRate·10), 1).
  void setSmoothingSpeed(double speed, double fftRate) {
    fftSmoothingAlpha = math.min(speed / (fftRate * 10.0), 1.0);
    fftSmoothingBeta = 1.0 - fftSmoothingAlpha;
  }

  /// `setFFTHoldSpeed`: holdSpeed = speed/(fftRate·10).
  void setHoldSpeed(double speed, double fftRate) {
    fftHoldSpeed = speed / (fftRate * 10.0);
  }

  // ---- Data in ------------------------------------------------------------

  /// `getFFTBuffer` + `pushFFT`: add one row covering `[lowFreq, highFreq)`.
  void pushRow(Float32List db, double lowFreq, double highFreq) {
    _head = (_head - 1 + _height) % _height;
    _lines = math.min(_lines + 1, _height);
    final off = _head * _width;
    if (db.length == _width) {
      _raw.setRange(off, off + _width, db);
    } else {
      remapRow(db, lowFreq, highFreq, _tmp, lowFreq, highFreq);
      _raw.setRange(off, off + _width, _tmp);
    }
    _rawLow[_head] = lowFreq;
    _rawHigh[_head] = highFreq;

    // Project on current view and colourise (unless a full update is pending anyway).
    final row = Float32List.sublistView(_raw, off, off + _width);
    remapRow(row, lowFreq, highFreq, latestFFT, _lowerFreq, _upperFreq);
    if (!_fullUpdate) _colorize(latestFFT, off);

    // Smoothing (pushFFT:914-920) — only the spectrum line, not the waterfall.
    if (fftSmoothing) {
      for (var i = 0; i < _width; i++) {
        final v = latestFFT[i];
        final s = _smoothingBuf[i];
        final n = s.isNaN ? v : v * fftSmoothingAlpha + s * fftSmoothingBeta;
        _smoothingBuf[i] = n;
        latestFFT[i] = n;
      }
    }
    // Hold (pushFFT:936-940)
    if (fftHold) {
      for (var i = 1; i < _width; i++) {
        final v = latestFFT[i];
        if (v.isNaN) continue;
        latestFFTHold[i] = math.max(v, latestFFTHold[i] - fftHoldSpeed);
      }
    }
    _imageDirty = true;
    _schedule();
  }

  /// Clears history and spectrum (e.g. on stop/start or device change).
  void clear() {
    _raw.fillRange(0, _raw.length, double.nan);
    rgba.fillRange(0, rgba.length, kOpaqueBlack);
    latestFFT.fillRange(0, _width, double.nan);
    latestFFTHold.fillRange(0, _width, -1000);
    _smoothingBuf.fillRange(0, _width, double.nan);
    _lines = 0;
    _imageDirty = true;
    _schedule();
  }

  /// Resets peak hold.
  void resetHold() => latestFFTHold.fillRange(0, _width, -1000);

  void _colorize(Float32List row, int off) {
    final pal = _palette;
    final mn = _minDb, mx = _maxDb;
    final range = mx - mn;
    final last = pal.length - 1;
    for (var j = 0; j < _width; j++) {
      final v = row[j];
      if (v.isNaN) {
        rgba[off + j] = kOpaqueBlack;
        continue;
      }
      final p = ((v < mn ? mn : (v > mx ? mx : v)) - mn) / range;
      rgba[off + j] = pal[(p * last).toInt()];
    }
  }

  /// `updateWaterfallFb` (waterfall.cpp:600-631) for the ring layout.
  void _updateWaterfallFb() {
    final count = math.min(_height, _lines);
    final src = Float32List(_width);
    for (var i = 0; i < count; i++) {
      final r = (_head + i) % _height;
      final off = r * _width;
      src.setRange(0, _width, _raw, off);
      remapRow(src, _rawLow[r], _rawHigh[r], _tmp, _lowerFreq, _upperFreq);
      _colorize(_tmp, off);
      if (i == 0 && !fftSmoothing) latestFFT.setAll(0, _tmp);
    }
    for (var i = count; i < _height; i++) {
      final r = (_head + i) % _height;
      rgba.fillRange(r * _width, (r + 1) * _width, kOpaqueBlack);
    }
    _imageDirty = true;
  }

  // ---- Image --------------------------------------------------------------

  bool _fullUpdate = false;
  bool _imageDirty = true;
  bool _scheduled = false;
  bool _asyncInFlight = false;
  bool _disposed = false;

  /// True once decodeImageFromPixelsSync has thrown (Skia backend).
  bool get usingAsyncFallback => _syncUnsupported;
  static bool _syncUnsupported = false;

  /// Current waterfall image ([width] × [height], ring layout: row [head] = newest).
  ui.Image? get image => _image;
  ui.Image? _image;

  /// Row index of the ring head that [image] was built with.
  int get imageHead => _imageHead;
  int _imageHead = 0;

  /// Frame counter for listeners (increments on every flush that changed something).
  int get generation => _generation;
  int _generation = 0;

  void _schedule() {
    if (!autoSchedule || _scheduled || _disposed) return;
    _scheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _scheduled = false;
      flush();
    });
  }

  /// Applies pending full updates, rebuilds the image and notifies listeners.
  /// Called automatically once per frame when [autoSchedule].
  void flush() {
    if (_disposed) return;
    if (_fullUpdate) {
      _fullUpdate = false;
      _updateWaterfallFb();
    }
    if (_imageDirty) {
      _imageDirty = false;
      _rebuildImage();
    }
    _generation++;
    notifyListeners();
  }

  /// Whether the next image should be built with the given function (tests).
  @visibleForTesting
  static void debugResetSyncSupport() => _syncUnsupported = false;

  void _rebuildImage() {
    final bytes = rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes);
    final head = _head;
    if (!_syncUnsupported) {
      try {
        final img = ui.decodeImageFromPixelsSync(bytes, _width, _height, ui.PixelFormat.rgba8888);
        _image?.dispose();
        _image = img;
        _imageHead = head;
        return;
      } catch (_) {
        _syncUnsupported = true;
      }
    }
    if (_asyncInFlight) {
      _imageDirty = true; // retry after the in-flight decode completes
      return;
    }
    _asyncInFlight = true;
    final w = _width, h = _height;
    // decodeImageFromPixels copies the pixels synchronously; copy anyway to be safe.
    final copy = Uint8List.fromList(bytes);
    ui.decodeImageFromPixels(copy, w, h, ui.PixelFormat.rgba8888, (img) {
      _asyncInFlight = false;
      if (_disposed) {
        img.dispose();
        return;
      }
      if (w != _width || h != _height) {
        img.dispose();
      } else {
        _image?.dispose();
        _image = img;
        _imageHead = head;
      }
      if (_imageDirty) _schedule();
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _image?.dispose();
    _image = null;
    super.dispose();
  }
}
