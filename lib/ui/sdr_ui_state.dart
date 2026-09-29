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
//     plus an automatic mode (no SDR++ equivalent)    → [setAutoLevels], auto_levels.dart
// and of core::setInputSampleRate (core.cpp:41-57)    → sample-rate change handling.
//
// SdrUiState owns the display state (FftViewport = LO + view, WaterfallVfo,
// WaterfallModel, tuning mode). The radio state lives in RadioController;
// this class keeps both in sync in both directions.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auto_levels.dart';
import 'colormaps.dart';
import 'radio_controller.dart';
import 'tuner.dart';
import 'viewport.dart';
import 'waterfall_model.dart';

class SdrUiState extends ChangeNotifier {
  SdrUiState(
    this.radio, {
    WaterfallModel? waterfall,
    this.tuningMode = TuningMode.normal,
    this.centerDisplayOnVfo = false,
    Duration Function()? clock,
  }) : _clock = clock ?? _monotonicClock(),
       waterfall = waterfall ?? WaterfallModel(),
       viewport = FftViewport(
         centerFreq: radio.centerFrequency,
         bandwidth: radio.sampleRate,
       ),
       _centeredViewport = FftViewport(
         centerFreq: radio.tunedFrequency,
         bandwidth: radio.sampleRate,
       ) {
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
    _lastGain = radio.gain;
    _lastCenter = radio.centerFrequency;
    _lastAgc = radio.agc;
    _lastDeviceId = radio.selectedDevice?.id;
    this.waterfall.setLevels(fftMin, fftMax);
    radio.addListener(_onRadio);
    _rowsSub = radio.fftRows.listen(_onRow);
    _pushView();
  }

  final RadioController radio;
  final FftViewport viewport;

  /// Legacy display window centred on the selected frequency, independent of
  /// the physical LO. FFT rows still carry their absolute frequency spans.
  final bool centerDisplayOnVfo;
  final FftViewport _centeredViewport;
  FftViewport get displayViewport =>
      centerDisplayOnVfo ? _centeredViewport : viewport;
  WaterfallVfo get displayVfo => centerDisplayOnVfo
      ? (WaterfallVfo(reference: vfo.reference, bandwidth: vfo.bandwidth))
      : vfo;
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

  // ---- Automatic levels ------------------------------------------------------

  static const autoLevelsStorageKey = 'waterfall_auto_levels_v1';

  /// Automatic Max/Min (auto_levels.dart). While on, the Max/Min sliders show
  /// the automatic values and are disabled; switching it off keeps the current
  /// levels as the manual starting point.
  bool autoLevels = false;
  bool _autoLevelsChanged = false;
  final AutoLevels _auto = AutoLevels();
  final Duration Function() _clock;
  late double _lastGain;
  late double _lastCenter;
  late bool _lastAgc;
  String? _lastDeviceId;
  bool _disposed = false;

  static Duration Function() _monotonicClock() {
    final sw = Stopwatch()..start();
    return () => sw.elapsed;
  }

  /// Window statistics of the automatic mode (null until a valid row).
  double? get autoNoiseFloor => _auto.floor;
  double? get autoPeak => _auto.peak;

  /// Toggles automatic levels and persists the choice.
  void setAutoLevels(bool on) {
    _autoLevelsChanged = true;
    _setAuto(on);
    unawaited(
      SharedPreferences.getInstance()
          .then((p) => p.setBool(autoLevelsStorageKey, on))
          .then((_) {}, onError: (_) {}),
    );
  }

  void _setAuto(bool on) {
    if (autoLevels == on) return;
    autoLevels = on;
    // A fresh start: the first row snaps the levels.
    _auto
      ..reset()
      ..min = null
      ..max = null;
    if (!_disposed) notifyListeners();
  }

  /// Restores the persisted auto flag. A choice made before the load wins.
  Future<void> loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getBool(autoLevelsStorageKey);
      if (v != null && !_autoLevelsChanged && !_disposed) _setAuto(v);
    } catch (_) {
      // No storage (tests without the plugin): keep the default.
    }
  }

  void _applyAuto() {
    final lo = _auto.min, hi = _auto.max;
    if (lo == null || hi == null) return;
    const d = AutoLevelTuning.deadbandDb;
    if ((lo - fftMin).abs() < d && (hi - fftMax).abs() < d) return;
    _applyLevels(lo, hi);
    notifyListeners();
  }

  /// Data columns requested from the radio (pixels of the FFT row).
  int get columns => waterfall.width;

  // ---- Radio → UI ----------------------------------------------------------

  void _onRadio() {
    var viewChanged = false;
    if (radio.sampleRate != _lastSampleRate) {
      _lastSampleRate = radio.sampleRate;
      viewport.resetForSampleRate(radio.sampleRate);
      _centeredViewport.resetForSampleRate(radio.sampleRate);
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
    if (centerDisplayOnVfo &&
        _centeredViewport.centerFreq != radio.tunedFrequency) {
      _centeredViewport.setCenterFrequency(radio.tunedFrequency);
      viewChanged = true;
    }
    if (radio.running != _lastRunning) {
      _lastRunning = radio.running;
      if (radio.running) waterfall.clear();
      _auto.reset();
    }
    // Auto levels belong to one spectrum: a retune, another source or gain
    // restarts the window (span changes of the rows are caught in AutoLevels).
    final devId = radio.selectedDevice?.id;
    if (viewChanged ||
        radio.centerFrequency != _lastCenter ||
        radio.gain != _lastGain ||
        radio.agc != _lastAgc ||
        devId != _lastDeviceId) {
      _lastCenter = radio.centerFrequency;
      _lastGain = radio.gain;
      _lastAgc = radio.agc;
      _lastDeviceId = devId;
      _auto.reset();
    }
    if (viewChanged) _pushView();
    notifyListeners();
  }

  void _onRow(FftRow row) {
    waterfall.pushRow(row.db, row.lowFreq, row.highFreq);
    if (autoLevels &&
        _auto.addRow(row.db, row.lowFreq, row.highFreq, _clock())) {
      _applyAuto();
    }
  }

  // ---- UI → radio ----------------------------------------------------------

  void _pushView() {
    radio.setFftView(
      viewOffset: viewport.viewOffset,
      viewBandwidth: viewport.viewBandwidth,
    );
    waterfall.setView(displayViewport.lowerFreq, displayViewport.upperFreq);
  }

  void _pushTuning() {
    radio.setTuning(
      centerFrequency: viewport.centerFreq,
      vfoOffset: vfo.generalOffset,
    );
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
      tune(
        TuningMode.center,
        viewport,
        vfo,
        viewport.centerFreq + vfo.generalOffset,
      );
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
    viewport.setViewBandwidth(
      zoomSliderToViewBandwidth(t, viewport.wholeBandwidth),
    );
    viewport.setViewOffset(vfo.centerOffset);
    _pushView();
    notifyListeners();
  }

  double get zoomSlider => viewBandwidthToZoomSlider(
    viewport.viewBandwidth,
    viewport.wholeBandwidth,
  );

  /// Max/Min sliders (main_window.cpp:633-663): fftMax ≥ fftMin + 10.
  /// In [autoLevels] mode the next FFT row overrides these values (the UI
  /// disables the sliders then).
  void setLevels(double min, double max) {
    _applyLevels(min, max);
    notifyListeners();
  }

  void _applyLevels(double min, double max) {
    fftMin = math.min(min, max - 10);
    fftMax = math.max(max, fftMin + 10);
    waterfall.setLevels(fftMin, fftMax);
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
    _disposed = true;
    radio.removeListener(_onRadio);
    _rowsSub.cancel();
    waterfall.dispose();
    super.dispose();
  }
}
