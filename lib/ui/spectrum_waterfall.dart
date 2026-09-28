// SPDX-License-Identifier: GPL-3.0-or-later
//
// Spectrum (FFT line), frequency scale, waterfall and VFO overlay painters,
// plus the combined SpectrumWaterfallView with touch gestures.
//
// Port of the drawing / input parts of sdrpp/core/src/gui/widgets/waterfall.cpp
// (SDR++ @8c9f5ee):
//   * drawFFT (lines 119-206)         → [SpectrumPainter]
//   * drawWaterfall (lines 208-226)   → [WaterfallPainter]
//   * WaterfallVFO::draw (1356-1382)  → [paintVfo]
//   * processInputs (249-556)         → gestures in [SpectrumWaterfallView]
// Theme colours from sdrpp/root/res/themes/dark.json (PlotLines #66E5FF,
// FFTHoldColor #FFFF00, WaterfallBackground #000000).
//
// Layout (docs/03 §4.6): spectrum (fftHeight) / frequency scale (24 dp) /
// waterfall (rest). Unlike SDR++ there is no 50 px dB-label margin: dB labels
// are drawn inside the spectrum at the left edge so the data area spans the
// full width (x = 0 is the lowest visible frequency).
//
// Gestures (docs/03 §4.5):
//   * tap on spectrum or waterfall     → tune VFO to tap (snapped) — processInputs "move the VFO"
//   * drag on spectrum (1 finger)      → drag-to-tune (SDR++ NORMAL mode, IsMouseDown)
//   * drag near a VFO edge on spectrum → resize bandwidth (vfoBorderSelect)
//   * drag on scale / waterfall        → pan view; past the band edge the LO moves (freqScaleSelect)
//   * pinch anywhere                   → zoom around the focal point (replaces the Zoom slider)

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'radio_controller.dart' show VfoReference;
import 'sdr_ui_state.dart';
import 'viewport.dart';
import 'waterfall_math.dart';
import 'waterfall_model.dart';

const Color kPlotLines = Color(0xFF66E5FF);
const Color kPlotShadow = Color(0x3366E5FF); // PlotLines, alpha 0.2
const Color kFftHold = Color(0xFFFFFF00);
const Color kGrid = Color(0xFF323232); // IM_COL32(50, 50, 50, 255)
const Color kVfoRect = Color(0x32FFFFFF); // IM_COL32(255, 255, 255, 50)
const Color kVfoLineSelected = Color(0xFFFF0000);

/// Draws the VFO passband rectangle and reference line (WaterfallVFO::draw).
void paintVfo(Canvas canvas, Rect area, FftViewport vp, WaterfallVfo vfo, {Color rectColor = kVfoRect, double lineWidth = 1}) {
  final px = vfo.pixels(vp.viewBandwidth, area.width, vp.viewOffset);
  if (px.rectRight > px.rectLeft && px.rectRight > 0 && px.rectLeft < area.width) {
    canvas.drawRect(Rect.fromLTRB(area.left + px.rectLeft, area.top, area.left + px.rectRight, area.bottom), Paint()..color = rectColor);
  }
  if (px.lineVisible) {
    final x = area.left + px.line + 0.5;
    canvas.drawLine(Offset(x, area.top), Offset(x, area.bottom),
        Paint()
          ..color = kVfoLineSelected
          ..strokeWidth = lineWidth);
  }
}

TextPainter _text(String s, double size, Color color) {
  return TextPainter(
    text: TextSpan(text: s, style: TextStyle(color: color, fontSize: size)),
    textDirection: TextDirection.ltr,
  )..layout();
}

/// Frequency grid step for the current view (`range = findBestRange(viewBW, maxHSteps)`,
/// `maxHSteps = dataWidth/(textW("000.000")+10)`).
double gridStep(double viewBandwidth, double dataWidth, double labelWidth) {
  final maxHSteps = math.max(1, (dataWidth / (labelWidth + 10)).floor());
  return findBestRange(viewBandwidth, maxHSteps);
}

/// FFT line painter (`WaterFall::drawFFT`).
class SpectrumPainter extends CustomPainter {
  SpectrumPainter({required this.state, this.fontSize = 11}) : super(repaint: Listenable.merge([state, state.waterfall]));

  final SdrUiState state;
  final double fontSize;

  @override
  void paint(Canvas canvas, Size size) {
    final area = Offset.zero & size;
    canvas.drawRect(area, Paint()..color = Colors.black);
    if (size.width < 2 || size.height < 2) return;
    final wf = state.waterfall;
    final vp = state.viewport;
    final fftMin = state.fftMin, fftMax = state.fftMax;
    final vertRange = fftMax - fftMin;
    final fftHeight = size.height;
    final scaleFactor = fftHeight / vertRange;
    final gridPaint = Paint()
      ..color = kGrid
      ..strokeWidth = 1;
    final textColor = Colors.white.withValues(alpha: 0.8);

    // Vertical (dB) scale
    final textH = fontSize * 1.3;
    final maxVSteps = math.max(1, (fftHeight / textH / 1.5).floor());
    final vRange = findBestRange(vertRange, maxVSteps);
    final startLine = (fftMax / vRange).floorToDouble() * vRange;
    for (var line = startLine; line > fftMin; line -= vRange) {
      final yPos = (fftHeight - ((line - fftMin) * scaleFactor)).roundToDouble() + 0.5;
      canvas.drawLine(Offset(0, yPos), Offset(size.width, yPos), gridPaint);
    }

    // Horizontal (frequency) grid
    final labelW = fontSize * 0.6 * 7;
    final range = gridStep(vp.viewBandwidth, size.width, labelW);
    final startFreq = (vp.lowerFreq / range).ceilToDouble() * range;
    final horizScale = size.width / vp.viewBandwidth;
    for (var freq = startFreq; freq < vp.upperFreq; freq += range) {
      final xPos = ((freq - vp.lowerFreq) * horizScale).roundToDouble() + 0.5;
      canvas.drawLine(Offset(xPos, 1), Offset(xPos, fftHeight), gridPaint);
    }

    // VFO passband + reference line (drawVFOs)
    paintVfo(canvas, area, vp, state.vfo);

    // Data
    final data = wf.latestFFT;
    final n = math.min(data.length, wf.width);
    if (n >= 2) {
      final xScale = size.width / n;
      final pts = Float32List(n * 2);
      final strip = Float32List(n * 4);
      double y(double v) {
        if (v.isNaN) return fftHeight;
        final p = fftHeight - ((v - fftMin) * scaleFactor);
        return p.clamp(1.0, fftHeight);
      }

      for (var i = 0; i < n; i++) {
        final x = (i + 0.5) * xScale;
        final yy = y(data[i]);
        pts[i * 2] = x;
        pts[i * 2 + 1] = yy;
        strip[i * 4] = x;
        strip[i * 4 + 1] = yy;
        strip[i * 4 + 2] = x;
        strip[i * 4 + 3] = fftHeight;
      }
      canvas.drawVertices(ui.Vertices.raw(ui.VertexMode.triangleStrip, strip), BlendMode.srcOver, Paint()..color = kPlotShadow);
      canvas.drawRawPoints(
          ui.PointMode.polygon,
          pts,
          Paint()
            ..color = kPlotLines
            ..strokeWidth = 1);

      if (wf.fftHold) {
        final hold = wf.latestFFTHold;
        for (var i = 0; i < n; i++) {
          pts[i * 2 + 1] = y(hold[i]);
        }
        canvas.drawRawPoints(
            ui.PointMode.polygon,
            pts,
            Paint()
              ..color = kFftHold
              ..strokeWidth = 1);
      }
    }

    // dB labels (inside, left)
    for (var line = startLine; line > fftMin; line -= vRange) {
      final yPos = fftHeight - ((line - fftMin) * scaleFactor);
      final tp = _text('${line.toInt()}', fontSize, textColor);
      if (yPos - tp.height / 2 < 0) continue;
      tp.paint(canvas, Offset(3, yPos - tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(SpectrumPainter oldDelegate) => oldDelegate.state != state || oldDelegate.fontSize != fontSize;
}

/// Frequency scale under the spectrum (ticks + printAndScale labels).
class FrequencyScalePainter extends CustomPainter {
  FrequencyScalePainter({required this.state, this.fontSize = 11}) : super(repaint: state);
  final SdrUiState state;
  final double fontSize;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0F0F0F));
    final vp = state.viewport;
    if (size.width < 2) return;
    final labelW = fontSize * 0.6 * 7;
    final range = gridStep(vp.viewBandwidth, size.width, labelW);
    final startFreq = (vp.lowerFreq / range).ceilToDouble() * range;
    final horizScale = size.width / vp.viewBandwidth;
    final tick = Paint()
      ..color = Colors.white
      ..strokeWidth = 1;
    canvas.drawLine(const Offset(0, 0.5), Offset(size.width, 0.5), tick);
    for (var freq = startFreq; freq < vp.upperFreq; freq += range) {
      final xPos = ((freq - vp.lowerFreq) * horizScale).roundToDouble() + 0.5;
      canvas.drawLine(Offset(xPos, 0), Offset(xPos, 5), tick);
      final tp = _text(printAndScale(freq), fontSize, Colors.white);
      tp.paint(canvas, Offset((xPos - tp.width / 2).roundToDouble(), 6));
    }
  }

  @override
  bool shouldRepaint(FrequencyScalePainter oldDelegate) => oldDelegate.state != state;
}

/// Waterfall painter (`WaterFall::drawWaterfall`): the ring-buffer image
/// unwrapped with two drawImageRect calls, plus the VFO overlay.
class WaterfallPainter extends CustomPainter {
  WaterfallPainter({required this.state}) : super(repaint: Listenable.merge([state, state.waterfall]));
  final SdrUiState state;

  @override
  void paint(Canvas canvas, Size size) {
    final area = Offset.zero & size;
    canvas.drawRect(area, Paint()..color = Colors.black);
    final WaterfallModel wf = state.waterfall;
    final img = wf.image;
    if (img != null) {
      final w = img.width.toDouble(), h = img.height.toDouble();
      final head = wf.imageHead.toDouble().clamp(0.0, h);
      final sy = size.height / h;
      final paint = Paint()..filterQuality = FilterQuality.low;
      // Newest rows [head, h) at the top…
      if (h - head > 0) {
        canvas.drawImageRect(img, Rect.fromLTWH(0, head, w, h - head), Rect.fromLTWH(0, 0, size.width, (h - head) * sy), paint);
      }
      // …then the older rows [0, head) below.
      if (head > 0) {
        canvas.drawImageRect(img, Rect.fromLTWH(0, 0, w, head), Rect.fromLTWH(0, (h - head) * sy, size.width, head * sy), paint);
      }
    }
    // SDR++ draws the VFO on the waterfall only on hover; touch has no hover,
    // so it is always drawn, more transparent.
    paintVfo(canvas, area, state.viewport, state.vfo, rectColor: const Color(0x1EFFFFFF));
  }

  @override
  bool shouldRepaint(WaterfallPainter oldDelegate) => oldDelegate.state != state;
}

enum _DragTarget { none, tune, pan, vfoEdge }

/// Spectrum + frequency scale + waterfall with SDR++-like touch input.
class SpectrumWaterfallView extends StatefulWidget {
  const SpectrumWaterfallView({
    super.key,
    required this.state,
    this.spectrumFraction = 0.35,
    this.scaleHeight = 24,
    this.resolutionScale = 1.0,
    this.maxColumns = 2048,
    this.maxHistoryRows = 512,
    this.edgeGrip = 12,
  });

  final SdrUiState state;

  /// Part of the height used by the spectrum (SDR++ fftHeight; resizable divider not ported).
  final double spectrumFraction;
  final double scaleHeight;

  /// Columns per logical pixel (× devicePixelRatio, capped at 2).
  final double resolutionScale;
  final int maxColumns;
  final int maxHistoryRows;

  /// Touch zone (logical px) around VFO edges for bandwidth drag (SDR++: 2·uiScale).
  final double edgeGrip;

  @override
  State<SpectrumWaterfallView> createState() => _SpectrumWaterfallViewState();
}

class _SpectrumWaterfallViewState extends State<SpectrumWaterfallView> {
  _DragTarget _target = _DragTarget.none;
  double _lastFocalX = 0;
  double _lastScale = 1;
  double _width = 1;
  double _spectrumHeight = 1;

  SdrUiState get _s => widget.state;

  _DragTarget _hitTest(Offset p) {
    if (p.dy <= _spectrumHeight) {
      final vfo = _s.vfo;
      final vp = _s.viewport;
      final px = vfo.pixels(vp.viewBandwidth, _width, vp.viewOffset);
      if (!vfo.bandwidthLocked && px.rectRight - px.rectLeft >= 10) {
        if (vfo.reference != VfoReference.lower && !px.leftClamped && (p.dx - px.rectLeft).abs() <= widget.edgeGrip) {
          return _DragTarget.vfoEdge;
        }
        if (vfo.reference != VfoReference.upper && !px.rightClamped && (p.dx - px.rectRight).abs() <= widget.edgeGrip) {
          return _DragTarget.vfoEdge;
        }
      }
      return _DragTarget.tune;
    }
    return _DragTarget.pan;
  }

  void _onScaleStart(ScaleStartDetails d) {
    _lastFocalX = d.localFocalPoint.dx;
    _lastScale = 1;
    _target = d.pointerCount > 1 ? _DragTarget.none : _hitTest(d.localFocalPoint);
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final x = d.localFocalPoint.dx;
    if (d.pointerCount > 1) {
      // Pinch zoom + two-finger pan.
      final ratio = d.horizontalScale / _lastScale;
      _lastScale = d.horizontalScale;
      if (ratio.isFinite && ratio > 0 && ratio != 1) _s.zoomAround(ratio, x, _width);
      final dx = x - _lastFocalX;
      if (dx != 0) _s.panBy(dx, _width);
      _lastFocalX = x;
      _target = _DragTarget.none;
      return;
    }
    final dx = x - _lastFocalX;
    _lastFocalX = x;
    switch (_target) {
      case _DragTarget.pan:
        if (dx != 0) _s.panBy(dx, _width);
      case _DragTarget.tune:
        _s.tapAt(x, _width);
      case _DragTarget.vfoEdge:
        _resizeVfo(x);
      case _DragTarget.none:
        break;
    }
  }

  /// vfoBorderSelect (waterfall.cpp:361-372).
  void _resizeVfo(double x) {
    final vfo = _s.vfo;
    final vp = _s.viewport;
    final line = vfo.pixels(vp.viewBandwidth, _width, vp.viewOffset).line;
    var dist = vfo.reference == VfoReference.center ? (x - line).abs() : (x - line);
    if (vfo.reference == VfoReference.upper) dist = -dist;
    var hzDist = dist * (vp.viewBandwidth / _width);
    if (vfo.reference == VfoReference.center) hzDist *= 2.0;
    hzDist = hzDist.clamp(vfo.minBandwidth, vfo.maxBandwidth).toDouble();
    _s.radio.setBandwidth(hzDist.roundToDouble());
  }

  void _onScaleEnd(ScaleEndDetails d) {
    _target = _DragTarget.none;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth.isFinite ? c.maxWidth : 400.0;
      final h = c.maxHeight.isFinite ? c.maxHeight : 400.0;
      _width = math.max(1, w);
      final specH = math.max(40.0, (h - widget.scaleHeight) * widget.spectrumFraction);
      _spectrumHeight = specH;
      final wfH = math.max(1.0, h - specH - widget.scaleHeight);
      final dpr = math.min(MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0, 2.0) * widget.resolutionScale;
      final cols = (w * dpr).round().clamp(16, widget.maxColumns);
      final rows = (wfH * dpr / 2).round().clamp(16, widget.maxHistoryRows);
      _s.setLayout(columns: cols, historyRows: rows);
      return RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: <Type, GestureRecognizerFactory>{
          TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
            () => TapGestureRecognizer(),
            (t) => t.onTapUp = (d) => _s.tapAt(d.localPosition.dx, _width),
          ),
          ScaleGestureRecognizer: GestureRecognizerFactoryWithHandlers<ScaleGestureRecognizer>(
            () => ScaleGestureRecognizer(),
            (t) => t
              ..onStart = _onScaleStart
              ..onUpdate = _onScaleUpdate
              ..onEnd = _onScaleEnd,
          ),
        },
        child: Column(
          children: [
            SizedBox(
              height: specH,
              width: w,
              child: RepaintBoundary(
                child: CustomPaint(key: const ValueKey<String>('spectrum'), painter: SpectrumPainter(state: _s), isComplex: true, willChange: true),
              ),
            ),
            SizedBox(
              height: widget.scaleHeight,
              width: w,
              child: RepaintBoundary(child: CustomPaint(painter: FrequencyScalePainter(state: _s))),
            ),
            SizedBox(
              height: wfH,
              width: w,
              child: RepaintBoundary(
                child: CustomPaint(key: const ValueKey<String>('waterfall'), painter: WaterfallPainter(state: _s), isComplex: true, willChange: true),
              ),
            ),
          ],
        ),
      );
    });
  }
}
