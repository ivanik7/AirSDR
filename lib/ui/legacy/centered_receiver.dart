// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import '../radio_controller.dart';

/// The only tuning policy of the legacy-looking shell: ONE centered VFO.
class CenteredReceiver {
  CenteredReceiver(this.radio);
  final RadioController radio;
  String entry = '';
  double stepHz = 12500;
  static const steps = [5000.0, 6250.0, 12500.0, 25000.0, 100000.0];
  int stepIndex = 2;
  bool _dragging = false;
  bool get dragging => _dragging;

  static const dragTunePeriod = Duration(milliseconds: 250);
  Timer? _dragTimer;

  void beginDrag() {
    if (_dragging) return;
    _dragging = true;
    _startDragTimer();
  }

  void _startDragTimer() {
    _dragTimer?.cancel();
    _dragTimer = Timer.periodic(dragTunePeriod, (_) {
      if (radio.tunedFrequency != radio.centerFrequency) resetOffset();
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
  void dragBy(double deltaHz) {
    if (!_dragging || !deltaHz.isFinite || deltaHz == 0) return;
    final target = (radio.tunedFrequency + deltaHz)
        .clamp(
          radio.selectedDevice?.minFrequency ?? 1,
          radio.selectedDevice?.maxFrequency ?? 999999999999,
        )
        .toDouble();
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
      if (next < (radio.selectedDevice?.minFrequency ?? 1) ||
          next > (radio.selectedDevice?.maxFrequency ?? 999999999999)) {
        break;
      }
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

  void resetOffset() =>
      radio.setTuning(centerFrequency: radio.tunedFrequency, vfoOffset: 0);
  void tune(double hz) {
    final min = radio.selectedDevice?.minFrequency ?? 1;
    final max = radio.selectedDevice?.maxFrequency ?? 999999999999;
    if (!hz.isFinite || hz < min || hz > max || hz <= 0) {
      throw ArgumentError.value(hz, 'frequency');
    }
    radio.setTuning(centerFrequency: hz, vfoOffset: 0);
  }

  void nudge(int direction) => tune(
    (radio.tunedFrequency + steps[stepIndex] * direction)
        .clamp(
          radio.selectedDevice?.minFrequency ?? 1,
          radio.selectedDevice?.maxFrequency ?? 999999999999,
        )
        .toDouble(),
  );
  void cycleStep() => stepIndex = (stepIndex + 1) % steps.length;
  void apply(int hz, DemodMode mode) {
    tune(hz.toDouble());
    changeMode(mode);
  }

  void changeMode(DemodMode mode) {
    radio.setMode(mode);
    radio.setTuning(centerFrequency: radio.tunedFrequency, vfoOffset: 0);
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
