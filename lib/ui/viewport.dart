// SPDX-License-Identifier: GPL-3.0-or-later
//
// VFO geometry and FFT view (zoom / pan) state.
//
// Port of sdrpp/core/src/gui/widgets/waterfall.{h,cpp} (SDR++ @8c9f5ee):
//   * WaterfallVFO::setOffset / setCenterOffset / setBandwidth / setReference
//     (waterfall.cpp:1219-1300) → [WaterfallVfo]
//   * WaterfallVFO::updateDrawingVars (waterfall.cpp:1302-1354) → [WaterfallVfo.pixels]
//   * WaterFall::setCenterFrequency / setBandwidth / setViewBandwidth /
//     setViewOffset (waterfall.cpp:989-1063) → [FftViewport]
//   * freqScaleSelect drag with LO carry (waterfall.cpp:372-409) → [FftViewport.dragView]
//   * click → VFO offset with snap (waterfall.cpp:465-475) → [FftViewport.xToSnappedOffset]
//   * Zoom slider mapping (main_window.cpp:619-631) → [zoomSliderToViewBandwidth]
//
// Coordinates here are in "data pixels" of an area [dataWidth] wide, like
// SDR++'s `dataWidth` (x = 0 at fftAreaMin.x). Callers pass logical pixels.

import 'dart:math' as math;

import 'radio_controller.dart' show VfoReference;

/// Port of `ImGui::WaterfallVFO` (geometry only; the DSP side lives in the controller).
class WaterfallVfo {
  WaterfallVfo({
    this.reference = VfoReference.center,
    this.bandwidth = 200000,
    double offset = 0,
    this.snapInterval = 5000,
    this.minBandwidth = 0,
    this.maxBandwidth = double.infinity,
    this.bandwidthLocked = false,
  }) {
    setOffset(offset);
  }

  VfoReference reference;
  double bandwidth;
  double snapInterval;
  double minBandwidth;
  double maxBandwidth;
  bool bandwidthLocked;

  /// Reference point (red line; displayed frequency = centerFreq + generalOffset).
  double generalOffset = 0;
  double centerOffset = 0;
  double lowerOffset = 0;
  double upperOffset = 0;

  /// waterfall.cpp:1219-1240
  void setOffset(double offset) {
    generalOffset = offset;
    switch (reference) {
      case VfoReference.center:
        centerOffset = offset;
        lowerOffset = offset - (bandwidth / 2.0);
        upperOffset = offset + (bandwidth / 2.0);
      case VfoReference.lower:
        lowerOffset = offset;
        centerOffset = offset + (bandwidth / 2.0);
        upperOffset = offset + bandwidth;
      case VfoReference.upper:
        upperOffset = offset;
        centerOffset = offset - (bandwidth / 2.0);
        lowerOffset = offset - bandwidth;
    }
  }

  /// waterfall.cpp:1242-1260
  void setCenterOffset(double offset) {
    switch (reference) {
      case VfoReference.center:
        generalOffset = offset;
      case VfoReference.lower:
        generalOffset = offset - (bandwidth / 2.0);
      case VfoReference.upper:
        generalOffset = offset + (bandwidth / 2.0);
    }
    centerOffset = offset;
    lowerOffset = offset - (bandwidth / 2.0);
    upperOffset = offset + (bandwidth / 2.0);
  }

  /// waterfall.cpp:1262-1283
  void setBandwidth(double bw) {
    if (bandwidth == bw || bw < 0) {
      return;
    }
    bandwidth = bw;
    switch (reference) {
      case VfoReference.center:
        lowerOffset = centerOffset - (bandwidth / 2.0);
        upperOffset = centerOffset + (bandwidth / 2.0);
      case VfoReference.lower:
        centerOffset = lowerOffset + (bandwidth / 2.0);
        upperOffset = lowerOffset + bandwidth;
      case VfoReference.upper:
        centerOffset = upperOffset - (bandwidth / 2.0);
        lowerOffset = upperOffset - bandwidth;
    }
  }

  /// waterfall.cpp:1285-1291
  void setReference(VfoReference ref) {
    if (reference == ref) {
      return;
    }
    reference = ref;
    setOffset(generalOffset);
  }

  /// `updateDrawingVars` (waterfall.cpp:1302-1354): pixel positions (not clamped)
  /// of the passband edges and of the reference line.
  VfoPixels pixels(double viewBandwidth, double dataWidth, double viewOffset) {
    double px(double o) => ((((o - viewOffset) / (viewBandwidth / 2.0)) + 1.0) * (dataWidth / 2.0)).roundToDouble();
    final center = px(centerOffset);
    final left = px(lowerOffset);
    final right = px(upperOffset);
    final double line;
    switch (reference) {
      case VfoReference.lower:
        line = left;
      case VfoReference.center:
        line = center;
      case VfoReference.upper:
        line = right;
    }
    final lineVisible = line >= 0 && line < dataWidth;
    final l = left.clamp(0.0, dataWidth - 1);
    final r = right.clamp(0.0, dataWidth - 1);
    return VfoPixels(
      line: line,
      lineVisible: lineVisible,
      rectLeft: l,
      rectRight: r + 1,
      leftClamped: l != left,
      rightClamped: r != right,
    );
  }
}

/// Result of [WaterfallVfo.pixels].
class VfoPixels {
  const VfoPixels({
    required this.line,
    required this.lineVisible,
    required this.rectLeft,
    required this.rectRight,
    required this.leftClamped,
    required this.rightClamped,
  });

  /// x of the reference (red) line.
  final double line;
  final bool lineVisible;

  /// Filled passband rectangle `[rectLeft, rectRight)` (clamped to the area).
  final double rectLeft;
  final double rectRight;
  final bool leftClamped;
  final bool rightClamped;
}

/// FFT view state: LO, whole band, visible window.
class FftViewport {
  FftViewport({double centerFreq = 100e6, double bandwidth = 2.4e6})
      : wholeBandwidth = bandwidth,
        viewBandwidth = bandwidth {
    setCenterFrequency(centerFreq);
  }

  double _centerFreq = 0;

  /// Whole displayed band = effective sample rate (`wholeBandwidth`).
  double wholeBandwidth;

  /// Visible bandwidth (`viewBandwidth`).
  double viewBandwidth;

  /// Centre of the visible part relative to the LO (`viewOffset`).
  double viewOffset = 0;
  double lowerFreq = 0;
  double upperFreq = 0;

  double get centerFreq => _centerFreq;

  void _updateLimits() {
    lowerFreq = (_centerFreq + viewOffset) - (viewBandwidth / 2.0);
    upperFreq = (_centerFreq + viewOffset) + (viewBandwidth / 2.0);
  }

  /// waterfall.cpp:989-994
  void setCenterFrequency(double freq) {
    _centerFreq = freq;
    _updateLimits();
  }

  /// waterfall.cpp:1003-1016 (without the VFO squeeze — see [squeezeVfo]).
  void setBandwidth(double bandWidth) {
    final currentRatio = viewBandwidth / wholeBandwidth;
    wholeBandwidth = bandWidth;
    setViewBandwidth(bandWidth * currentRatio);
  }

  /// VFO part of `setBandwidth` (waterfall.cpp:1007-1014): pull the VFO inside the band.
  void squeezeVfo(WaterfallVfo vfo) {
    if (vfo.lowerOffset < -(wholeBandwidth / 2)) {
      vfo.setCenterOffset(-(wholeBandwidth / 2));
    }
    if (vfo.upperOffset > (wholeBandwidth / 2)) {
      vfo.setCenterOffset(wholeBandwidth / 2);
    }
  }

  /// waterfall.cpp:1022-1041
  void setViewBandwidth(double bandWidth) {
    if (bandWidth == viewBandwidth) {
      return;
    }
    if (viewOffset.abs() + (bandWidth / 2.0) > wholeBandwidth / 2.0) {
      if (viewOffset < 0) {
        viewOffset = (bandWidth / 2.0) - (wholeBandwidth / 2.0);
      } else {
        viewOffset = (wholeBandwidth / 2.0) - (bandWidth / 2.0);
      }
    }
    viewBandwidth = bandWidth;
    _updateLimits();
  }

  /// waterfall.cpp:1047-1063
  void setViewOffset(double offset) {
    if (offset == viewOffset) {
      return;
    }
    if (offset - (viewBandwidth / 2.0) < -(wholeBandwidth / 2.0)) {
      offset = (viewBandwidth / 2.0) - (wholeBandwidth / 2.0);
    }
    if (offset + (viewBandwidth / 2.0) > (wholeBandwidth / 2.0)) {
      offset = (wholeBandwidth / 2.0) - (viewBandwidth / 2.0);
    }
    viewOffset = offset;
    _updateLimits();
  }

  /// `core::setInputSampleRate` (core.cpp:41-57): new band, zoom reset.
  void resetForSampleRate(double effSr) {
    setBandwidth(effSr);
    setViewOffset(0);
    setViewBandwidth(effSr);
  }

  // ---- Pixel <-> frequency ----------------------------------------------

  /// `x = (f − lowerFreq) · dataWidth / viewBandwidth` (drawFFT horizontal scale).
  double freqToX(double freq, double dataWidth) => (freq - lowerFreq) * (dataWidth / viewBandwidth);

  /// Inverse of [freqToX].
  double xToFreq(double x, double dataWidth) => lowerFreq + x * (viewBandwidth / dataWidth);

  /// Offset (relative to LO) under x: waterfall.cpp:468.
  double xToOffset(double x, double dataWidth) =>
      (((x / (dataWidth / 2.0)) - 1.0) * (viewBandwidth / 2.0)) + viewOffset;

  /// Offset under x with the ABSOLUTE frequency snapped to [snap]
  /// (waterfall.cpp:468-471). Returns null when x is outside `[0, dataWidth)`.
  double? xToSnappedOffset(double x, double dataWidth, double snap) {
    if (x < 0 || x >= dataWidth) return null;
    var off = xToOffset(x, dataWidth);
    off += _centerFreq;
    off = ((off / snap).roundToDouble() * snap) - _centerFreq;
    return off;
  }

  /// Offset → pixel (`updateDrawingVars`, without rounding).
  double offsetToX(double offset, double dataWidth) =>
      (((offset - viewOffset) / (viewBandwidth / 2.0)) + 1.0) * (dataWidth / 2.0);

  // ---- Gestures ---------------------------------------------------------

  /// Frequency-scale drag (`freqScaleSelect`, waterfall.cpp:372-409):
  /// `viewOffset -= dx·viewBW/dataWidth`; beyond the band edge the LO moves
  /// instead. Returns the LO change (Hz, 0 if none). If [centerFrequencyLocked],
  /// the LO is not moved.
  double dragView(double dx, double dataWidth, {bool centerFrequencyLocked = false}) {
    final viewDelta = dx * (viewBandwidth / dataWidth);
    viewOffset -= viewDelta;
    var moved = 0.0;
    if (viewOffset + (viewBandwidth / 2.0) > wholeBandwidth / 2.0) {
      final freqOffset = (viewOffset + (viewBandwidth / 2.0)) - (wholeBandwidth / 2.0);
      viewOffset = (wholeBandwidth / 2.0) - (viewBandwidth / 2.0);
      if (!centerFrequencyLocked) {
        _centerFreq += freqOffset;
        moved += freqOffset;
      }
    }
    if (viewOffset - (viewBandwidth / 2.0) < -(wholeBandwidth / 2.0)) {
      final freqOffset = (viewOffset - (viewBandwidth / 2.0)) + (wholeBandwidth / 2.0);
      viewOffset = (viewBandwidth / 2.0) - (wholeBandwidth / 2.0);
      if (!centerFrequencyLocked) {
        _centerFreq += freqOffset;
        moved += freqOffset;
      }
    }
    _updateLimits();
    return moved;
  }

  /// Pinch zoom (replaces the SDR++ Zoom slider): new view bandwidth
  /// `viewBandwidth / scale`, clamped to `[minViewBandwidth, wholeBandwidth]`,
  /// keeping the frequency under [focalX] fixed.
  void zoomAround(double scale, double focalX, double dataWidth, {double minViewBandwidth = 1000}) {
    if (!(scale > 0)) return;
    final fo = xToOffset(focalX, dataWidth);
    final lo = math.min(minViewBandwidth, wholeBandwidth);
    final nbw = (viewBandwidth / scale).clamp(lo, wholeBandwidth).toDouble();
    setViewBandwidth(nbw);
    setViewOffset(fo - ((focalX / (dataWidth / 2.0)) - 1.0) * (nbw / 2.0));
  }
}

/// Zoom slider (main_window.cpp:619-631): `factor = t²`,
/// `viewBW = min(1000 + factor·(W − 1000), W)`.
double zoomSliderToViewBandwidth(double t, double wholeBandwidth) {
  final factor = t * t;
  final delta = wholeBandwidth - 1000.0;
  return math.min(1000.0 + (factor * delta), wholeBandwidth);
}

/// Inverse of [zoomSliderToViewBandwidth] (for showing the slider position).
double viewBandwidthToZoomSlider(double viewBandwidth, double wholeBandwidth) {
  final delta = wholeBandwidth - 1000.0;
  if (delta <= 0) return 1.0;
  final f = ((viewBandwidth - 1000.0) / delta).clamp(0.0, 1.0);
  return math.sqrt(f);
}
