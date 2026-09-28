// SPDX-License-Identifier: GPL-3.0-or-later
// Synthetic IQ source (no SDR++ counterpart). Generates complex baseband around a virtual
// centre frequency: Gaussian-ish noise + any number of carriers, each either unmodulated or
// modulated by audio tones (AM, NFM, WFM mono/stereo with 19 kHz pilot, USB, LSB, DSB, CW).
//
// * Deterministic: xorshift32 noise with a fixed seed; phases start at 0.
// * Allocation-free per block: phase accumulators (double, wrapped) + an 8192-entry sine LUT
//   with linear interpolation (spurs < −100 dBc).
// * Carriers are defined at absolute RF frequencies; [tune] moves the virtual centre, so the
//   signals move across the spectrum like a real receiver.
// * The WFM stereo MPX matches tool/oracle/dsp_oracle.cpp (in_fm_stereo):
//   mpx = 0.45(L+R) + 0.45(L−R)·sin(2θp) + 0.1·sin(θp), θp = 2π·19 kHz·t, dev 75 kHz.
import 'dart:math' as math;
import 'dart:typed_data';

import '../../signal_path/source_handler.dart';
import 'source_pump.dart';

enum SynthModulation { none, am, nfm, wfm, wfmStereo, usb, lsb, dsb, cw }

class SynthCarrier {
  SynthCarrier({
    required this.frequency,
    this.modulation = SynthModulation.none,
    this.amplitude = 0.1,
    this.toneHz = 1000,
    this.toneRightHz = 0,
    this.deviation = 0,
    this.modIndex = 0.5,
    this.toneLevel = 1.0,
  });

  /// Absolute RF carrier frequency (Hz). For USB/LSB/CW this is the suppressed-carrier
  /// (dial) frequency; the emitted tone is at frequency ± toneHz.
  double frequency;
  SynthModulation modulation;

  /// Peak amplitude of the complex carrier (full scale = 1).
  double amplitude;

  /// Modulating tone (left channel for WFM stereo).
  double toneHz;

  /// Right channel tone for WFM stereo; 0 = silent right channel.
  double toneRightHz;

  /// FM deviation in Hz; 0 = default (NFM 2.5 kHz, WFM 75 kHz).
  double deviation;

  /// AM modulation index.
  double modIndex;

  /// Tone level (0..1) for FM modulations.
  double toneLevel;

  // Oscillator state (cycles, in [0,1)).
  double _rfPhase = 0;
  double _tonePhase = 0;
  double _toneRPhase = 0;
  double _pilotPhase = 0;

  static SynthCarrier fromMap(Map<Object?, Object?> m) {
    double d(String k, double def) => (m[k] as num?)?.toDouble() ?? def;
    final modName = m['modulation'] as String? ?? 'none';
    final mod = SynthModulation.values.firstWhere((e) => e.name == modName, orElse: () => SynthModulation.none);
    return SynthCarrier(
      frequency: d('frequency', 0),
      modulation: mod,
      amplitude: d('amplitude', 0.1),
      toneHz: d('toneHz', 1000),
      toneRightHz: d('toneRightHz', 0),
      deviation: d('deviation', 0),
      modIndex: d('modIndex', 0.5),
      toneLevel: d('toneLevel', 1.0),
    );
  }

  Map<String, Object> toMap() => <String, Object>{
        'frequency': frequency,
        'modulation': modulation.name,
        'amplitude': amplitude,
        'toneHz': toneHz,
        'toneRightHz': toneRightHz,
        'deviation': deviation,
        'modIndex': modIndex,
        'toneLevel': toneLevel,
      };
}

class SynthSource extends SourceHandler {
  SynthSource(this.core,
      {double sampleRate = 2400000,
      double centerFreq = 100e6,
      this.noiseLevel = 0.01,
      List<SynthCarrier>? carriers,
      int seed = 0x1234567,
      PumpMode mode = PumpMode.realTime})
      : _sampleRate = sampleRate,
        _centerFreq = centerFreq,
        _seed = seed == 0 ? 1 : seed,
        carriers = carriers ?? defaultCarriers(centerFreq) {
    _rng = _seed;
    _pump = SourcePump(generate, sampleRate: sampleRate, mode: mode);
  }

  /// A demo band: WFM stereo at centre+200 kHz, NFM at −300 kHz, AM at −600 kHz,
  /// USB at +500 kHz, CW at +700 kHz.
  static List<SynthCarrier> defaultCarriers(double center) => <SynthCarrier>[
        SynthCarrier(
            frequency: center + 200e3, modulation: SynthModulation.wfmStereo, amplitude: 0.3, toneHz: 1000, toneRightHz: 400),
        SynthCarrier(frequency: center - 300e3, modulation: SynthModulation.nfm, amplitude: 0.1, toneHz: 1000),
        SynthCarrier(frequency: center - 600e3, modulation: SynthModulation.am, amplitude: 0.1, toneHz: 700),
        SynthCarrier(frequency: center + 500e3, modulation: SynthModulation.usb, amplitude: 0.05, toneHz: 1500),
        SynthCarrier(frequency: center + 700e3, modulation: SynthModulation.cw, amplitude: 0.05),
      ];

  final SourceCore core;
  late final SourcePump _pump;
  double _sampleRate;
  double _centerFreq;
  final int _seed;
  int _rng = 1;

  /// RMS of the complex noise (per component ≈ noiseLevel/√2).
  double noiseLevel;
  final List<SynthCarrier> carriers;
  bool running = false;

  SourcePump get pump => _pump;
  double get sampleRate => _sampleRate;
  double get centerFreq => _centerFreq;

  // ---- Sine LUT ----
  static const int _lutBits = 13;
  static const int _lutSize = 1 << _lutBits;
  static final Float32List _sin = () {
    final t = Float32List(_lutSize + 1);
    for (int i = 0; i <= _lutSize; i++) {
      t[i] = math.sin(2 * math.pi * i / _lutSize);
    }
    return t;
  }();

  /// sin(2π·p) for p in [0,1).
  @pragma('vm:prefer-inline')
  @pragma('vm:unsafe:no-bounds-checks')
  static double _sinC(double p) {
    final x = p * _lutSize;
    final i = x.toInt();
    final f = x - i;
    final a = _sin[i];
    return a + (_sin[i + 1] - a) * f;
  }

  @pragma('vm:prefer-inline')
  static double _cosC(double p) {
    double q = p + 0.25;
    if (q >= 1.0) q -= 1.0;
    return _sinC(q);
  }

  @pragma('vm:prefer-inline')
  static double _wrap(double p) {
    if (p >= 1.0 || p < 0.0) p -= p.floorToDouble();
    return p;
  }

  void setSampleRate(double sr) {
    _sampleRate = sr;
    _pump.setSampleRate(sr);
    if (running || _selected) core.setInputSampleRate(sr);
  }

  bool _selected = false;

  @override
  void select() {
    _selected = true;
    core.setInputSampleRate(_sampleRate);
  }

  @override
  void deselect() {
    _selected = false;
  }

  @override
  Future<void> start(SourceSink sink) async {
    if (running) return;
    running = true;
    _pump.start(sink);
  }

  @override
  Future<void> stop() async {
    if (!running) return;
    _pump.stop();
    running = false;
  }

  @override
  void tune(double frequencyHz) {
    _centerFreq = frequencyHz;
  }

  @override
  List<SourceSetting> get settings => <SourceSetting>[
        ChoiceSetting('sampleRate', 'Sample rate', sampleRates.map((r) => '${r / 1e6} MSPS').toList(),
            math.max(0, sampleRates.indexOf(_sampleRate))),
        SliderSetting('noise', 'Noise level (dBFS)',
            min: -120, max: 0, step: 1, value: 20 * math.log(math.max(noiseLevel, 1e-6)) / math.ln10),
      ];

  static const List<double> sampleRates = <double>[250000, 1024000, 2048000, 2400000, 3200000, 8000000, 10000000];

  @override
  void applySetting(String id, Object value) {
    switch (id) {
      case 'sampleRate':
        final v = value is int && value < sampleRates.length ? sampleRates[value] : (value as num).toDouble();
        setSampleRate(v);
      case 'noise':
        noiseLevel = math.pow(10, (value as num).toDouble() / 20).toDouble();
    }
  }

  /// Uniform in [-1, 1) (xorshift32).
  @pragma('vm:prefer-inline')
  double _uni() {
    int x = _rng;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    _rng = x;
    return x * (2.0 / 4294967296.0) - 1.0;
  }

  /// Fills [count] complex samples into [out] (the [BlockFiller] of the pump; also usable
  /// directly to pre-generate test/benchmark signals).
  @pragma('vm:unsafe:no-bounds-checks')
  void generate(Float32List out, int count) {
    final n2 = 2 * count;
    // Noise: sum of 3 uniforms ≈ Gaussian, var = 3·(1/3) = 1 per component → scale.
    final ns = noiseLevel / math.sqrt2;
    if (ns > 0) {
      for (int i = 0; i < n2; i++) {
        out[i] = ns * (_uni() + _uni() + _uni());
      }
    } else {
      out.fillRange(0, n2, 0);
    }
    final fs = _sampleRate;
    for (final c in carriers) {
      _addCarrier(c, out, count, fs);
    }
  }

  @pragma('vm:unsafe:no-bounds-checks')
  void _addCarrier(SynthCarrier c, Float32List out, int count, double fs) {
    final off = c.frequency - _centerFreq;
    if (off.abs() > fs) return; // far outside the band (still keep phase continuity? no need)
    final a = c.amplitude;
    final rfInc = off / fs;
    final toneInc = c.toneHz / fs;
    double rf = c._rfPhase;
    double tp = c._tonePhase;
    switch (c.modulation) {
      case SynthModulation.none:
      case SynthModulation.cw:
        for (int i = 0; i < count; i++) {
          out[2 * i] += a * _cosC(rf);
          out[2 * i + 1] += a * _sinC(rf);
          rf = _wrap(rf + rfInc);
        }
      case SynthModulation.am:
        final m = c.modIndex;
        for (int i = 0; i < count; i++) {
          final env = a * (1.0 + m * _sinC(tp)) / (1.0 + m);
          out[2 * i] += env * _cosC(rf);
          out[2 * i + 1] += env * _sinC(rf);
          rf = _wrap(rf + rfInc);
          tp = _wrap(tp + toneInc);
        }
      case SynthModulation.dsb:
        for (int i = 0; i < count; i++) {
          final env = a * _sinC(tp);
          out[2 * i] += env * _cosC(rf);
          out[2 * i + 1] += env * _sinC(rf);
          rf = _wrap(rf + rfInc);
          tp = _wrap(tp + toneInc);
        }
      case SynthModulation.usb:
      case SynthModulation.lsb:
        // Single sideband of a pure tone = one complex exponential at carrier ± tone.
        final inc = (off + (c.modulation == SynthModulation.usb ? c.toneHz : -c.toneHz)) / fs;
        for (int i = 0; i < count; i++) {
          out[2 * i] += a * _cosC(rf);
          out[2 * i + 1] += a * _sinC(rf);
          rf = _wrap(rf + inc);
        }
      case SynthModulation.nfm:
        final dev = (c.deviation > 0 ? c.deviation : 2500.0) * c.toneLevel / fs;
        for (int i = 0; i < count; i++) {
          out[2 * i] += a * _cosC(rf);
          out[2 * i + 1] += a * _sinC(rf);
          rf = _wrap(rf + rfInc + dev * _sinC(tp));
          tp = _wrap(tp + toneInc);
        }
      case SynthModulation.wfm:
        final dev = (c.deviation > 0 ? c.deviation : 75000.0) * 0.9 * c.toneLevel / fs;
        for (int i = 0; i < count; i++) {
          out[2 * i] += a * _cosC(rf);
          out[2 * i + 1] += a * _sinC(rf);
          rf = _wrap(rf + rfInc + dev * _sinC(tp));
          tp = _wrap(tp + toneInc);
        }
      case SynthModulation.wfmStereo:
        final dev = (c.deviation > 0 ? c.deviation : 75000.0) / fs;
        final lvl = c.toneLevel;
        final rInc = c.toneRightHz / fs;
        final hasR = c.toneRightHz > 0;
        const pInc0 = 19000.0;
        final pInc = pInc0 / fs;
        double rp = c._toneRPhase;
        double pp = c._pilotPhase;
        for (int i = 0; i < count; i++) {
          final l = lvl * _sinC(tp);
          final r = hasR ? lvl * _sinC(rp) : 0.0;
          double p2 = 2 * pp;
          if (p2 >= 1.0) p2 -= 1.0;
          final mpx = 0.45 * (l + r) + 0.45 * (l - r) * _sinC(p2) + 0.1 * _sinC(pp);
          out[2 * i] += a * _cosC(rf);
          out[2 * i + 1] += a * _sinC(rf);
          rf = _wrap(rf + rfInc + dev * mpx);
          tp = _wrap(tp + toneInc);
          rp = _wrap(rp + rInc);
          pp = _wrap(pp + pInc);
        }
        c._toneRPhase = rp;
        c._pilotPhase = pp;
    }
    c._rfPhase = rf;
    c._tonePhase = tp;
  }

  /// Resets oscillators and noise to the initial (seeded) state.
  void reset() {
    _rng = _seed;
    for (final c in carriers) {
      c._rfPhase = 0;
      c._tonePhase = 0;
      c._toneRPhase = 0;
      c._pilotPhase = 0;
    }
  }
}
