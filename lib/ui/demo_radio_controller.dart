// SPDX-License-Identifier: GPL-3.0-or-later
//
// DemoRadioController — a RadioController with no hardware and no DSP.
//
// Generates synthetic FFT rows (noise floor + fixed carriers + a slowly
// sweeping signal + a small DC spike) at [DemoRadioController.fftRate] rows/s
// so the UI can run standalone. Carriers sit at absolute frequencies, so
// retuning the LO moves them across the display like a real receiver.
// Nothing is demodulated; volume/squelch are stored only.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'radio_controller.dart';

class DemoRadioController extends RadioController {
  DemoRadioController({this.fftRate = 25, int seed = 1}) : _rng = math.Random(seed) {
    _device = _devices.first;
    _sampleRate = _device!.sampleRates[_device!.sampleRates.length ~/ 2];
    _gain = (_device!.gain.min + _device!.gain.max) / 2;
    _viewBandwidth = _sampleRate;
  }

  /// Rows per second while running.
  final int fftRate;
  final math.Random _rng;

  static const List<SdrDeviceInfo> _devices = <SdrDeviceInfo>[
    SdrDeviceInfo(
      id: 'demo:rtl',
      name: 'Demo RTL-SDR (synthetic)',
      sampleRates: <double>[250000, 1024000, 1536000, 1800000, 2048000, 2400000, 2560000, 3200000],
      gain: GainRange(min: 0, max: 49.6, step: 0.1),
      minFrequency: 24000000,
      maxFrequency: 1766000000,
    ),
    SdrDeviceInfo(
      id: 'demo:hackrf',
      name: 'Demo HackRF (synthetic)',
      sampleRates: <double>[2000000, 4000000, 8000000, 10000000, 20000000],
      gain: GainRange(min: 0, max: 62, step: 2),
      hasAgc: false,
      minFrequency: 1000000,
      maxFrequency: 6000000000,
    ),
  ];

  SdrDeviceInfo? _device;
  bool _running = false;
  String? _lastError;
  double _centerFrequency = 100000000;
  double _vfoOffset = 0;
  DemodMode _mode = DemodMode.wfm;
  final Map<DemodMode, double> _bandwidths = <DemodMode, double>{
    for (final m in DemodMode.values) m: m.params.defaultBandwidth,
  };
  late double _sampleRate;
  late double _gain;
  bool _agc = false;
  double _volume = 0.5;
  bool _squelchEnabled = false;
  double _squelchLevel = -50;

  int _fftWidth = 1024;
  double _viewOffset = 0;
  late double _viewBandwidth;

  final StreamController<FftRow> _rows = StreamController<FftRow>.broadcast();
  Timer? _timer;
  int _tick = 0;
  bool _disposed = false;

  /// Number of rows emitted since construction (for tests).
  int rowsEmitted = 0;

  @override
  List<SdrDeviceInfo> get devices => _devices;
  @override
  SdrDeviceInfo? get selectedDevice => _device;

  @override
  Future<void> selectDevice(SdrDeviceInfo device) async {
    if (_running || device == _device) return;
    _device = device;
    if (!device.sampleRates.contains(_sampleRate)) {
      _sampleRate = device.sampleRates[device.sampleRates.length ~/ 2];
      _viewBandwidth = _sampleRate;
      _viewOffset = 0;
    }
    _gain = _gain.clamp(device.gain.min, device.gain.max).toDouble();
    if (!device.hasAgc) _agc = false;
    notifyListeners();
  }

  @override
  Future<void> refreshDevices() async {}

  @override
  bool get running => _running;
  @override
  String? get lastError => _lastError;

  @override
  Future<void> start() async {
    if (_running || _disposed) return;
    if (_device == null) {
      _lastError = 'No device';
      notifyListeners();
      return;
    }
    _lastError = null;
    _running = true;
    _timer = Timer.periodic(Duration(microseconds: 1000000 ~/ fftRate), (_) => _emitRow());
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    _timer?.cancel();
    _timer = null;
    _running = false;
    notifyListeners();
  }

  @override
  double get centerFrequency => _centerFrequency;
  @override
  double get vfoOffset => _vfoOffset;

  @override
  void setTuning({required double centerFrequency, required double vfoOffset}) {
    if (centerFrequency == _centerFrequency && vfoOffset == _vfoOffset) return;
    _centerFrequency = centerFrequency;
    _vfoOffset = vfoOffset;
    notifyListeners();
  }

  @override
  DemodMode get mode => _mode;

  @override
  void setMode(DemodMode mode) {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
  }

  @override
  double get bandwidth => _bandwidths[_mode]!;

  @override
  void setBandwidth(double hz) {
    final bw = _mode.params.clampBandwidth(hz);
    if (bw == bandwidth) return;
    _bandwidths[_mode] = bw;
    notifyListeners();
  }

  @override
  double get sampleRate => _sampleRate;

  @override
  void setSampleRate(double hz) {
    if (hz == _sampleRate) return;
    _sampleRate = hz;
    notifyListeners();
  }

  @override
  double get gain => _gain;

  @override
  void setGain(double value) {
    final g = _device == null ? value : value.clamp(_device!.gain.min, _device!.gain.max).toDouble();
    if (g == _gain) return;
    _gain = g;
    notifyListeners();
  }

  @override
  bool get agc => _agc;

  @override
  void setAgc(bool enabled) {
    if (enabled == _agc) return;
    _agc = enabled;
    notifyListeners();
  }

  @override
  double get volume => _volume;

  @override
  void setVolume(double value) {
    if (value == _volume) return;
    _volume = value.clamp(0.0, 1.0);
    notifyListeners();
  }

  @override
  bool get squelchEnabled => _squelchEnabled;

  @override
  void setSquelchEnabled(bool enabled) {
    if (enabled == _squelchEnabled) return;
    _squelchEnabled = enabled;
    notifyListeners();
  }

  @override
  double get squelchLevel => _squelchLevel;

  @override
  void setSquelchLevel(double db) {
    if (db == _squelchLevel) return;
    _squelchLevel = db.clamp(-100.0, 0.0);
    notifyListeners();
  }

  @override
  Stream<FftRow> get fftRows => _rows.stream;

  @override
  void setFftWidth(int pixels) {
    _fftWidth = math.max(1, pixels);
  }

  @override
  void setFftView({required double viewOffset, required double viewBandwidth}) {
    _viewOffset = viewOffset;
    _viewBandwidth = viewBandwidth;
  }

  // ---- Synthetic signal model ---------------------------------------------

  /// Carriers at absolute frequencies: (freq Hz, peak dB, half-width Hz).
  static const List<(double, double, double)> _carriers = <(double, double, double)>[
    (99300000, -62, 45000), // broadcast FM
    (99700000, -70, 45000),
    (100100000, -55, 50000),
    (100450000, -72, 3000), // narrow FM
    (100525000, -65, 150), // CW-like
    (100800000, -66, 45000),
    (145500000, -60, 4000),
    (433920000, -55, 6000),
  ];

  /// Deterministic synthetic row for LO [center] covering `[low, high)`.
  /// Exposed for tests.
  Float32List synthRow(double center, double low, double high, int width, double t) {
    final out = Float32List(width);
    final hzPerPx = (high - low) / width;
    // Moving signal: sweeps ±40 % of the band around the LO, period 20 s.
    final sweepF = center + math.sin(t * 2 * math.pi / 20.0) * _sampleRate * 0.4;
    // Gain shifts everything a bit (feels alive when dragging the slider).
    final gainDb = (_device == null) ? 0.0 : (_gain - _device!.gain.max / 2) * 0.3;
    for (var i = 0; i < width; i++) {
      final f0 = low + i * hzPerPx;
      final f1 = f0 + hzPerPx;
      final f = (f0 + f1) / 2;
      // Noise floor: -95 dB with ~Rayleigh-ish jitter.
      final u = _rng.nextDouble();
      var p = math.pow(10, (-95 + gainDb) / 10) * -math.log(1 - u * 0.999);
      for (final (fc, db, hw) in _carriers) {
        final d = (f - fc) / hw;
        if (d.abs() < 4 || (fc >= f0 && fc < f1)) {
          final shape = (fc >= f0 && fc < f1) ? 1.0 : math.exp(-d * d);
          p += math.pow(10, (db + gainDb) / 10) * shape;
        }
      }
      final ds = (f - sweepF) / 3000;
      if (ds.abs() < 4 || (sweepF >= f0 && sweepF < f1)) {
        final shape = (sweepF >= f0 && sweepF < f1) ? 1.0 : math.exp(-ds * ds);
        p += math.pow(10, (-68 + gainDb) / 10) * shape;
      }
      // DC spike at the LO.
      if (center >= f0 && center < f1) p += math.pow(10, (-60 + gainDb) / 10);
      out[i] = (10 * math.log(p) / math.ln10);
    }
    return out;
  }

  void _emitRow() {
    if (!_running || _disposed) return;
    _tick++;
    final vbw = _viewBandwidth.clamp(1.0, _sampleRate).toDouble();
    final low = _centerFrequency + _viewOffset - vbw / 2;
    final high = low + vbw;
    final row = FftRow(
      db: synthRow(_centerFrequency, low, high, _fftWidth, _tick / fftRate),
      lowFreq: low,
      highFreq: high,
    );
    rowsEmitted++;
    _rows.add(row);
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _running = false;
    _rows.close();
    super.dispose();
  }
}
