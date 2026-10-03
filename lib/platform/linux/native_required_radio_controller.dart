// SPDX-License-Identifier: GPL-3.0-or-later
//
// NativeRequiredRadioController — the honest fallback for desktop Linux when
// libsdrcore.so (with the host USB layer, native/include/sdrcore_host.h)
// cannot be loaded. The Dart receive engine is not supported on Linux (L1
// scope), so instead of faking a receiver this controller lists no devices,
// never runs, and reports why in [lastError] with linkState `failed`.
// Tuning/mode/gain are kept in memory so the UI stays usable for layout work.
import 'dart:async';

import '../../ui/radio_controller.dart';

class NativeRequiredRadioController extends RadioController {
  NativeRequiredRadioController({required this.reason});

  /// Human-readable cause (e.g. the dlopen error); shown in Settings.
  final String reason;

  double _centerFrequency = 100000000;
  DemodMode _mode = DemodMode.wfm;
  double _bandwidth = DemodMode.wfm.params.defaultBandwidth;
  double _gain = 20;
  double _volume = 0.5;
  bool _squelchEnabled = false;
  double _squelchLevel = -50;
  final StreamController<FftRow> _rows = StreamController<FftRow>.broadcast();

  String get _message =>
      'Native core required: libsdrcore.so with the host USB layer is not '
      'available ($reason). The Dart receive engine is not supported on Linux.';

  @override
  List<SdrDeviceInfo> get devices => const <SdrDeviceInfo>[];
  @override
  SdrDeviceInfo? get selectedDevice => null;
  @override
  Future<void> selectDevice(SdrDeviceInfo device) async {}
  @override
  Future<void> refreshDevices() async {}

  @override
  bool get running => false;
  @override
  Future<void> start() async => notifyListeners();
  @override
  Future<void> stop() async {}
  @override
  String? get lastError => _message;
  @override
  DeviceLinkState get linkState => DeviceLinkState.failed;
  @override
  Map<String, Object?> get stats => <String, Object?>{
    'engine': 'unavailable (native core required)',
    'reason': reason,
  };

  @override
  double get centerFrequency => _centerFrequency;
  @override
  double get vfoOffset => 0;
  @override
  void setTuning({required double centerFrequency, required double vfoOffset}) {
    _centerFrequency = centerFrequency + vfoOffset;
    notifyListeners();
  }

  @override
  DemodMode get mode => _mode;
  @override
  void setMode(DemodMode mode) {
    _mode = mode;
    _bandwidth = mode.params.defaultBandwidth;
    notifyListeners();
  }

  @override
  double get bandwidth => _bandwidth;
  @override
  void setBandwidth(double hz) {
    _bandwidth = _mode.params.clampBandwidth(hz);
    notifyListeners();
  }

  @override
  double get sampleRate => 2400000;
  @override
  void setSampleRate(double hz) {}
  @override
  double get gain => _gain;
  @override
  void setGain(double value) {
    _gain = value;
    notifyListeners();
  }

  @override
  bool get agc => false;
  @override
  void setAgc(bool enabled) {}

  @override
  double get volume => _volume;
  @override
  void setVolume(double value) {
    _volume = value.clamp(0.0, 1.0).toDouble();
    notifyListeners();
  }

  @override
  bool get squelchEnabled => _squelchEnabled;
  @override
  void setSquelchEnabled(bool enabled) {
    _squelchEnabled = enabled;
    notifyListeners();
  }

  @override
  double get squelchLevel => _squelchLevel;
  @override
  void setSquelchLevel(double db) {
    _squelchLevel = db;
    notifyListeners();
  }

  @override
  Stream<FftRow> get fftRows => _rows.stream;
  @override
  void setFftWidth(int pixels) {}
  @override
  void setFftView({
    required double viewOffset,
    required double viewBandwidth,
  }) {}

  @override
  void dispose() {
    _rows.close();
    super.dispose();
  }
}
