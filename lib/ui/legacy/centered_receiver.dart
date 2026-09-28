// SPDX-License-Identifier: GPL-3.0-or-later
import '../radio_controller.dart';

/// The only tuning policy of the legacy-looking shell: ONE centered VFO.
class CenteredReceiver {
  CenteredReceiver(this.radio);
  final RadioController radio;
  String entry = '';
  double stepHz = 12500;
  static const steps = [5000.0, 6250.0, 12500.0, 25000.0, 100000.0];
  int stepIndex = 2;

  void resetOffset() => radio.setTuning(centerFrequency: radio.tunedFrequency, vfoOffset: 0);
  void tune(double hz) {
    final min = radio.selectedDevice?.minFrequency ?? 1;
    final max = radio.selectedDevice?.maxFrequency ?? 999999999999;
    if (!hz.isFinite || hz < min || hz > max || hz <= 0) throw ArgumentError.value(hz, 'frequency');
    radio.setTuning(centerFrequency: hz, vfoOffset: 0);
  }
  void nudge(int direction) => tune((radio.tunedFrequency + steps[stepIndex] * direction).clamp(
    radio.selectedDevice?.minFrequency ?? 1, radio.selectedDevice?.maxFrequency ?? 999999999999).toDouble());
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
    if (!RegExp(r'^[0-9.]$').hasMatch(key) || entry.length >= 11 || (key == '.' && entry.contains('.'))) return false;
    entry += key;
    return true;
  }
}
