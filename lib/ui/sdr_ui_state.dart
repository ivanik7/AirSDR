// SPDX-License-Identifier: GPL-3.0-or-later
//
// UI-side glue between RadioController and the waterfall/spectrum widgets.
//
// Port of the frame logic of sdrpp/core/src/gui/main_window.cpp (SDR++ @8c9f5ee):
//   * draw() flag handling (lines 260-340): VFO moved by mouse → CENTER-mode
//     retune; freqSelect.frequencyChanged → tuner::tune; waterfall.centerFreqMoved
//     → sourceManager.tune                            → [tapAt], [tuneTo], [panBy]
//   * scroll-wheel / arrow tuning (lines 553-609)     → [step]
//   * Zoom slider (lines 619-631)                     → [setZoomSlider]; pinch → [zoomAround]
//   * Max/Min sliders (lines 633-663)                 → [setLevels]
// and of core::setInputSampleRate (core.cpp:41-57)    → sample-rate change handling.
//
// SdrUiState owns the display state (FftViewport = LO + view, WaterfallVfo,
// WaterfallModel, tuning mode). The radio state lives in RadioController;
// this class keeps both in sync in both directions.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'colormaps.dart';
import 'radio_controller.dart';
import 'tuner.dart';
import 'viewport.dart';
import 'waterfall_model.dart';

class SdrUiState extends ChangeNotifier {
  SdrUiState(this.radio, {WaterfallModel? waterfall, this.tuningMode = TuningMode.normal})
      : waterfall = waterfall ?? WaterfallModel(),
        viewport = FftViewport(centerFreq: radio.centerFrequency, bandwidth: radio.sampleRate) {
    final p = radio.mode.params;
    vfo = WaterfallVfo(
      reference: p.reference,
      bandwidth: radio.bandwidth,
      offset: radio.vfoOffset,
      snapInterval: p.snapInterval,
      minBandwidth: p.minBandwidth,
      maxBandwidth: p.maxBandwidth,
      bandwidthLocked: p.bandwidthLocked,
    );
    _lastSampleRate = radio.sampleRate;
    _lastMode = radio.mode;
    this.waterfall.setLevels(fftMin, fftMax);
    radio.addListener(_onRadio);
    _rowsSub = radio.fftRows.listen(_onRow);
    _pushView();
  }

  final RadioController radio;
  final FftViewport viewport;
  late final WaterfallVfo vfo;
  final WaterfallModel waterfall;
  TuningMode tuningMode;

  late final StreamSubscription<FftRow> _rowsSub;
  late double _lastSampleRate;
  late DemodMode _lastMode;
  bool _lastRunning = false;

  /// SDR++ defaults (core.cpp:116-163): min −120, max 0.
  double fftMin = -120;
  double fftMax = 0;

  /// Data columns requested from the radio (pixels of the FFT row).
  int get columns => waterfall.width;

  // ---- Radio → UI ----------------------------------------------------------

  void _onRadio() {
    var viewChanged = false;
    if (radio.sampleRate != _lastSampleRate) {
      _lastSampleRate = radio.sampleRate;
      viewport.resetForSampleRate(radio.sampleRate);
      viewport.squeezeVfo(vfo);
      viewChanged = true;
    }
    if (radio.centerFrequency != viewport.centerFreq) {
      viewport.setCenterFrequency(radio.centerFrequency);
      viewChanged = true;
    }
    if (radio.mode != _lastMode) {
      _lastMode = radio.mode;
      final p = radio.mode.params;
      // RadioModule::selectDemod step 4 (docs/02 §4.2).
      vfo.minBandwidth = p.minBandwidth;
      vfo.maxBandwidth = p.maxBandwidth;
      vfo.bandwidthLocked = p.bandwidthLocked;
      vfo.snapInterval = p.snapInterval;
      vfo.setReference(p.reference);
    }
    if (radio.bandwidth != vfo.bandwidth) vfo.setBandwidth(radio.bandwidth);
    if (radio.vfoOffset != vfo.generalOffset) vfo.setOffset(radio.vfoOffset);
    if (radio.running != _lastRunning) {
      _lastRunning = radio.running;
      if (radio.running) waterfall.clear();
    }
    if (viewChanged) _pushView();
    notifyListeners();
  }

  void _onRow(FftRow row) {
    waterfall.pushRow(row.db, row.lowFreq, row.highFreq);
  }

  // ---- UI → radio ----------------------------------------------------------

  void _pushView() {
    radio.setFftView(viewOffset: viewport.viewOffset, viewBandwidth: viewport.viewBandwidth);
    waterfall.setView(viewport.lowerFreq, viewport.upperFreq);
  }

  void _pushTuning() {
    radio.setTuning(centerFrequency: viewport.centerFreq, vfoOffset: vfo.generalOffset);
    _pushView();
    notifyListeners();
  }

  /// Displayed ("tuned") frequency = LO + VFO reference offset.
  double get tunedFrequency => viewport.centerFreq + vfo.generalOffset;

  /// FrequencySelect / direct entry: `tuner::tune(tuningMode, vfo, freq)`.
  void tuneTo(double freq) {
    tune(tuningMode, viewport, vfo, freq);
    _pushTuning();
  }

  /// ◀ ▶ buttons: main_window.cpp:578-596 (wheel / arrows):
  /// `nfreq = round((center + generalOffset + interval·dir)/interval)·interval`.
  void step(int direction, {double multiplier = 1}) {
    final interval = vfo.snapInterval * multiplier;
    var nfreq = viewport.centerFreq + vfo.generalOffset + interval * direction;
    nfreq = (nfreq / interval).roundToDouble() * interval;
    tuneTo(nfreq);
  }

  /// Tap on spectrum/waterfall at [x] of a [dataWidth]-wide area
  /// (waterfall.cpp:465-475, then main_window.cpp:283-300 for CENTER mode).
  void tapAt(double x, double dataWidth) {
    final off = viewport.xToSnappedOffset(x, dataWidth, vfo.snapInterval);
    if (off == null) return;
    vfo.setOffset(off);
    if (tuningMode == TuningMode.center) {
      tune(TuningMode.center, viewport, vfo, viewport.centerFreq + vfo.generalOffset);
    }
    _pushTuning();
  }

  /// Horizontal drag of the view (freqScaleSelect, waterfall.cpp:372-409).
  /// Moving past the band edge retunes the LO.
  void panBy(double dx, double dataWidth) {
    final moved = viewport.dragView(dx, dataWidth);
    if (moved != 0) {
      // SDR++ keeps VFO offsets relative to the LO, so the VFO moves with it
      // (main_window.cpp:318-326 → sourceManager.tune).
      _pushTuning();
    } else {
      _pushView();
      notifyListeners();
    }
  }

  /// Pinch zoom around [focalX].
  void zoomAround(double scale, double focalX, double dataWidth) {
    viewport.zoomAround(scale, focalX, dataWidth);
    _pushView();
    notifyListeners();
  }

  /// Zoom slider 0..1 (main_window.cpp:619-631): quadratic, then centre the VFO.
  void setZoomSlider(double t) {
    viewport.setViewBandwidth(zoomSliderToViewBandwidth(t, viewport.wholeBandwidth));
    viewport.setViewOffset(vfo.centerOffset);
    _pushView();
    notifyListeners();
  }

  double get zoomSlider => viewBandwidthToZoomSlider(viewport.viewBandwidth, viewport.wholeBandwidth);

  /// Max/Min sliders (main_window.cpp:633-663): fftMax ≥ fftMin + 10.
  void setLevels(double min, double max) {
    fftMin = math.min(min, max - 10);
    fftMax = math.max(max, fftMin + 10);
    waterfall.setLevels(fftMin, fftMax);
    notifyListeners();
  }

  void setColorMap(ColorMapDef map) {
    waterfall.setColorMap(map);
    notifyListeners();
  }

  void setTuningMode(TuningMode mode) {
    tuningMode = mode;
    notifyListeners();
  }

  /// Layout: sets the FFT row width / history depth. Safe to call during build
  /// (no synchronous notification).
  void setLayout({required int columns, required int historyRows}) {
    if (columns != waterfall.width || historyRows != waterfall.height) {
      waterfall.resize(columns, historyRows);
    }
    radio.setFftWidth(columns);
  }

  @override
  void dispose() {
    radio.removeListener(_onRadio);
    _rowsSub.cancel();
    waterfall.dispose();
    super.dispose();
  }
}
