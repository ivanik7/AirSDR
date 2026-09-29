// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../bands/bands.dart';
import '../radio_controller.dart';
import 'step_grid.dart';

/// The only tuning policy of the legacy-looking shell: ONE centered VFO.
///
/// The selected step is also the frequency grid (step_grid.dart): after every
/// finished retune the receive frequency is an integer multiple of the step
/// (nearest node, ties up), inside the device range. During a drag the VFO
/// moves along the grid; the LO is recentered on release.
///
/// Bands (bands.dart, task t_7b20878c):
///  * a frequency inside a band is snapped on the grid nodes inside that band
///    (the snap never pushes it out of the band);
///  * a user tune (keypad, drag release, preset, channel tap) that moves the
///    receiver from outside / another band into a band "enters" it once: the
///    band is determined by the raw value, the band's step is selected, the
///    frequency is snapped on the band's grid, and the band's mode is set —
///    a preset/channel keeps its own mode instead (the step is still the
///    band's);
///  * manual mode/step changes inside the band stay until the band is left;
///    leaving a band rolls nothing back;
///  * during a drag only the status follows; the band is applied once on
///    release together with the final retune;
///  * restoring state ([restore]: active channel at startup, channel
///    scanning) never applies band settings.
class CenteredReceiver {
  CenteredReceiver(this.radio);
  final RadioController radio;
  void Function()? onManualChange;
  String entry = '';
  static const steps = receiverSteps;
  static const stepStorageKey = 'receiver_step_hz_v1';
  static const defaultStepHz = 12500;
  int stepIndex = steps.indexOf(defaultStepHz);
  int get stepHz => steps[stepIndex];
  bool _stepChanged = false;
  bool _dragging = false;
  bool get dragging => _dragging;

  /// Frequency bands; null = no band logic (plain grid).
  BandsRepository? bands;

  /// Band the receiver is "inside" (its settings applied or restored).
  String? _bandId;

  /// Band at the shown frequency (live during a drag), for the status line.
  Band? get currentBand => bands?.bandAt(radio.tunedFrequency.round());

  /// Treats the current frequency's band as already entered, without
  /// applying its settings.
  void markCurrentBand() => _bandId = currentBand?.id;

  /// Raw (unsnapped) drag position; the VFO sits on its nearest grid node.
  int _dragRaw = 0;

  static const dragTunePeriod = Duration(milliseconds: 250);
  Timer? _dragTimer;

  int get _min {
    final m = (radio.selectedDevice?.minFrequency ?? 1).ceil();
    return m < 1 ? 1 : m;
  }

  int get _max => (radio.selectedDevice?.maxFrequency ?? 999999999999).floor();

  /// Nearest grid node; inside a band only the band's nodes are used.
  int _snap(num hz) {
    final v = hz.round();
    return _snapIn(v, bands?.bandAt(v));
  }

  int _snapIn(int hz, Band? band) {
    if (band != null) {
      final lo = band.startHz > _min ? band.startHz : _min;
      final hi = band.endHz < _max ? band.endHz : _max;
      if (lo <= hi) {
        return snapToStep(hz, stepHz, min: lo, max: hi, origin: band.startHz);
      }
    }
    return snapToStep(hz, stepHz, min: _min, max: _max);
  }

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
    onManualChange?.call();
    final i = steps.indexOf(hz);
    if (i < 0) throw ArgumentError.value(hz, 'step');
    _setStepIndex(i);
  }

  void cycleStep() {
    onManualChange?.call();
    _setStepIndex((stepIndex + 1) % steps.length);
  }

  void _selectStep(int i) {
    stepIndex = i;
    _stepChanged = true;
    _gridReady = true;
    _saveStep();
  }

  void _setStepIndex(int i) {
    _selectStep(i);
    if (_dragging) {
      _dragRaw = radio.tunedFrequency.round();
      dragBy(0, force: true);
    } else {
      resetOffset();
    }
  }

  void beginDrag() {
    onManualChange?.call();
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

  /// Release: one final retune + centering; a band entered by the drag is
  /// applied here, once.
  void endDrag() {
    if (!_dragging) return;
    _dragging = false;
    _dragTimer?.cancel();
    _dragTimer = null;
    _tuneEntering(radio.tunedFrequency.round());
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

  /// A user tune to [raw] Hz (see the class comment). [mode]: the mode of a
  /// preset/channel, which wins over the band's; null keeps the current mode
  /// unless a band is entered.
  void _tuneEntering(int raw, {DemodMode? mode}) {
    // A value just outside a band may land exactly on its inclusive edge
    // when rounded on the current grid. In that case it enters the band too.
    final band = bands?.bandAt(raw) ?? bands?.bandAt(_snapIn(raw, null));
    var newMode = mode;
    if (band != null && band.id != _bandId) {
      final i = steps.indexOf(band.stepHz);
      if (i >= 0 && i != stepIndex) _selectStep(i);
      newMode ??= band.mode;
    }
    final target = _snapIn(raw, band);
    _bandId = band?.id;
    // Retune first, then switch the mode: the mode notification then finds
    // the receiver centered and on the grid (no second LO retune).
    _tuneExact(target);
    if (newMode != null && newMode != radio.mode) {
      radio.setMode(newMode);
      resetOffset();
    }
  }

  void _checkRange(double hz) {
    final min = radio.selectedDevice?.minFrequency ?? 1;
    final max = radio.selectedDevice?.maxFrequency ?? 999999999999;
    if (!hz.isFinite || hz < min || hz > max || hz <= 0) {
      throw ArgumentError.value(hz, 'frequency');
    }
  }

  /// Tunes to [hz] rounded to the nearest grid node (entering its band).
  /// Throws [ArgumentError] for a frequency outside the device range.
  void tune(double hz) {
    onManualChange?.call();
    _checkRange(hz);
    _tuneEntering(hz.round());
  }

  /// ◀ ▶: the neighbour grid node, not "current + step" (118.180 → 118.200).
  void nudge(int direction) {
    onManualChange?.call();
    final band = currentBand;
    _tuneEntering(
      stepFrom(
        radio.tunedFrequency.round(),
        stepHz,
        direction,
        min: _min,
        max: _max,
        origin: band?.startHz ?? 0,
      ),
    );
  }

  /// Preset / channel tap: frequency + its own mode; the band's step applies
  /// when the band is entered. Throws [ArgumentError] out of device range.
  void apply(int hz, DemodMode mode) {
    onManualChange?.call();
    _checkRange(hz.toDouble());
    _tuneEntering(hz, mode: mode);
    resetOffset();
  }

  /// Restores a stored frequency/mode (active channel at startup, channel
  /// scanning) without applying band settings; the band counts as entered.
  /// Throws [ArgumentError] for a frequency outside the device range.
  void restore(int hz, DemodMode mode) {
    onManualChange?.call();
    _checkRange(hz.toDouble());
    _tuneExact(_snap(hz));
    radio.setMode(mode);
    resetOffset();
    markCurrentBand();
  }

  void changeMode(DemodMode mode) {
    onManualChange?.call();
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
