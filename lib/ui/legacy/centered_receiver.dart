// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../radio_controller.dart';
import 'step_grid.dart';

/// The only tuning policy of the legacy-looking shell: ONE centered VFO.
///
/// The selected step is also the frequency grid (step_grid.dart): after every
/// finished retune the receive frequency is an integer multiple of the step
/// (nearest node, ties up), inside the device range. During a drag the VFO
/// moves along the grid; the LO is recentered on release.
class CenteredReceiver {
  CenteredReceiver(this.radio);
  final RadioController radio;
  String entry = '';
  static const steps = <int>[5000, 6250, 12500, 25000, 100000];
  static const stepStorageKey = 'receiver_step_hz_v1';
  int stepIndex = 2;
  int get stepHz => steps[stepIndex];
  bool _stepChanged = false;
  bool _dragging = false;
  bool get dragging => _dragging;

  /// Raw (unsnapped) drag position; the VFO sits on its nearest grid node.
  int _dragRaw = 0;

  static const dragTunePeriod = Duration(milliseconds: 250);
  Timer? _dragTimer;

  int get _min {
    final m = (radio.selectedDevice?.minFrequency ?? 1).ceil();
    return m < 1 ? 1 : m;
  }

  int get _max => (radio.selectedDevice?.maxFrequency ?? 999999999999).floor();

  int _snap(num hz) => snapToStep(hz.round(), stepHz, min: _min, max: _max);

  /// Restores the persisted step (does not retune: the caller recenters once
  /// the radio's own persisted state is in). A step chosen before the load
  /// finishes wins.
  Future<void> loadStep() async {
    _gridReady = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final hz = prefs.getInt(stepStorageKey);
      final i = hz == null ? -1 : steps.indexOf(hz);
      if (!_stepChanged && i >= 0) stepIndex = i;
    } catch (_) {
      // No storage (tests without the plugin): keep the default step.
    } finally {
      _gridReady = true;
    }
  }

  /// False while the persisted step is loading: recentering then only zeroes
  /// the offset, so a frequency is not rounded twice (old grid, then new).
  bool _gridReady = true;

  void _saveStep() {
    final hz = stepHz;
    unawaited(
      SharedPreferences.getInstance()
          .then((p) => p.setInt(stepStorageKey, hz))
          .then((_) {}, onError: (_) {}),
    );
  }

  /// Selects one of [steps] and immediately moves the receiver onto its grid.
  void setStepHz(int hz) {
    final i = steps.indexOf(hz);
    if (i < 0) throw ArgumentError.value(hz, 'step');
    _setStepIndex(i);
  }

  void cycleStep() => _setStepIndex((stepIndex + 1) % steps.length);

  void _setStepIndex(int i) {
    stepIndex = i;
    _stepChanged = true;
    _gridReady = true;
    _saveStep();
    if (_dragging) {
      _dragRaw = radio.tunedFrequency.round();
      dragBy(0, force: true);
    } else {
      resetOffset();
    }
  }

  void beginDrag() {
    if (_dragging) return;
    _dragging = true;
    _dragRaw = radio.tunedFrequency.round();
    _startDragTimer();
  }

  void _startDragTimer() {
    _dragTimer?.cancel();
    _dragTimer = Timer.periodic(dragTunePeriod, (_) {
      if (radio.tunedFrequency != radio.centerFrequency) _recenter();
    });
  }

  void dispose() {
    _dragTimer?.cancel();
    _dragTimer = null;
    _dragging = false;
  }

  /// The IQ sample rate is the *physical* band, independent of FFT zoom.
  /// Leave half the demodulator bandwidth plus 5% of the IQ span at each edge.
  /// Each edge crossing moves the LO by half a physical band; the remaining
  /// offset continues to feed the DSP VFO until release.
  void dragBy(double deltaHz, {bool force = false}) {
    if (!_dragging || !deltaHz.isFinite || (deltaHz == 0 && !force)) return;
    final raw = _dragRaw + deltaHz.round();
    _dragRaw = raw < _min ? _min : (raw > _max ? _max : raw);
    final target = _snap(_dragRaw).toDouble();
    final span = radio.sampleRate;
    if (!span.isFinite || span <= 0) return;
    final step = span / 2;
    final limit = (step - radio.bandwidth / 2 - span * 0.05)
        // Half-step overlap prevents oscillation when the passband is wide.
        .clamp(step / 2, step)
        .toDouble();
    var center = radio.centerFrequency;
    while ((target - center).abs() > limit) {
      final next = center + (target > center ? step : -step);
      if (next < _min || next > _max) break;
      center = next;
    }
    final edgeShift = center != radio.centerFrequency;
    radio.setTuning(centerFrequency: center, vfoOffset: target - center);
    // An edge shift already tuned the LO; restart the throttle from it.
    if (edgeShift) _startDragTimer();
  }

  void endDrag() {
    if (!_dragging) return;
    _dragging = false;
    _dragTimer?.cancel();
    _dragTimer = null;
    resetOffset();
  }

  bool _recentering = false;
  double? _unsnappable;

  /// True when the resting receiver is not centered or not on the grid.
  /// False while a recenter is in progress (its own notifications) and for a
  /// frequency the backend refused to move (locked LO) — no retune loops.
  bool get needsRecenter {
    if (_recentering) return false;
    if (radio.vfoOffset != 0) return true;
    if (!_gridReady) return false;
    final hz = radio.tunedFrequency;
    if (hz == _unsnappable) return false;
    return _snap(hz) != hz;
  }

  /// LO = VFO: moves the tuned frequency onto the nearest grid node, offset 0.
  void resetOffset() => _tuneExact(
    _gridReady ? _snap(radio.tunedFrequency) : radio.tunedFrequency.round(),
  );

  /// During a drag only the LO follows the VFO (already on the grid).
  void _recenter() => _tuneExact(radio.tunedFrequency.round());

  void _tuneExact(int hz) {
    _recentering = true;
    try {
      radio.setTuning(centerFrequency: hz.toDouble(), vfoOffset: 0);
    } finally {
      _recentering = false;
    }
    _unsnappable = radio.tunedFrequency != hz ? radio.tunedFrequency : null;
  }

  /// Tunes to [hz] rounded to the nearest grid node. Throws [ArgumentError]
  /// for a frequency outside the device range.
  void tune(double hz) {
    final min = radio.selectedDevice?.minFrequency ?? 1;
    final max = radio.selectedDevice?.maxFrequency ?? 999999999999;
    if (!hz.isFinite || hz < min || hz > max || hz <= 0) {
      throw ArgumentError.value(hz, 'frequency');
    }
    _tuneExact(_snap(hz));
  }

  /// ◀ ▶: the neighbour grid node, not "current + step" (118.180 → 118.200).
  void nudge(int direction) => _tuneExact(
    stepFrom(
      radio.tunedFrequency.round(),
      stepHz,
      direction,
      min: _min,
      max: _max,
    ),
  );

  void apply(int hz, DemodMode mode) {
    tune(hz.toDouble());
    changeMode(mode);
  }

  void changeMode(DemodMode mode) {
    radio.setMode(mode);
    resetOffset();
  }

  Future<void> start() async {
    resetOffset();
    await radio.start();
  }

  bool pressKey(String key) {
    if (key == 'CLR') {
      entry = '';
      return true;
    }
    if (key == 'OK') {
      final mhz = double.tryParse(entry);
      if (mhz == null) return false;
      try {
        tune((mhz * 1000000).roundToDouble());
        entry = '';
        return true;
      } on ArgumentError {
        return false;
      }
    }
    if (!RegExp(r'^[0-9.]$').hasMatch(key) ||
        entry.length >= 11 ||
        (key == '.' && entry.contains('.'))) {
      return false;
    }
    entry += key;
    return true;
  }
}
