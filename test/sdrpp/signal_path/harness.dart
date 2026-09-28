// Shared helpers for the signal-path tests.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sdr_flutter/sdrpp/core/config.dart';
import 'package:sdr_flutter/sdrpp/core/core.dart';
import 'package:sdr_flutter/sdrpp/dsp/dsp.dart';
import 'package:sdr_flutter/sdrpp/modules/radio/radio_module.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/source_pump.dart';
import 'package:sdr_flutter/sdrpp/modules/sources/synth_source.dart';

/// Result of a spectral peak search on a real signal.
class Peak {
  Peak(this.freq, this.magnitude, this.rms);
  final double freq;
  final double magnitude; // dB relative to a full-scale sine
  final double rms;
  @override
  String toString() => 'Peak(${freq.toStringAsFixed(1)} Hz, ${magnitude.toStringAsFixed(1)} dB, rms $rms)';
}

/// Peak frequency of [x] (real samples at [fs]) using a Hann-windowed FFT of size [n]
/// (last n samples) with parabolic interpolation.
Peak peakOf(List<double> x, double fs, {int n = 16384, double minHz = 20}) {
  if (x.length < n) throw StateError('need $n samples, have ${x.length}');
  final start = x.length - n;
  final inBuf = Float32List(2 * n);
  double sum2 = 0;
  for (int i = 0; i < n; i++) {
    final w = 0.5 - 0.5 * math.cos(2 * math.pi * i / n);
    final v = x[start + i];
    sum2 += v * v;
    inBuf[2 * i] = v * w;
  }
  final out = Float32List(2 * n);
  FftPlan.get(n).execute(inBuf, out);
  final mag = List<double>.generate(n ~/ 2, (k) => math.sqrt(out[2 * k] * out[2 * k] + out[2 * k + 1] * out[2 * k + 1]));
  final kMin = (minHz * n / fs).ceil();
  int best = kMin;
  for (int k = kMin; k < n ~/ 2 - 1; k++) {
    if (mag[k] > mag[best]) best = k;
  }
  double delta = 0;
  if (best > 0 && best < n ~/ 2 - 1) {
    final a = mag[best - 1], b = mag[best], c = mag[best + 1];
    final d = a - 2 * b + c;
    if (d != 0) delta = 0.5 * (a - c) / d;
  }
  // Hann coherent gain 0.5, sine amplitude A → |X| = A·n/4.
  final amp = mag[best] / (n / 4);
  return Peak((best + delta) * fs / n, 20 * math.log(amp + 1e-30) / math.ln10, math.sqrt(sum2 / n));
}

/// A complete receiver: Core + synth source (manual pump) + radio module "Radio".
class Rig {
  Rig({
    required List<SynthCarrier> carriers,
    double sampleRate = 2400000,
    double center = 100e6,
    double noise = 0.001,
    int fftSize = 8192,
    double fftRate = 20,
  }) {
    core = Core();
    core.iqFrontEnd.setFFTSize(fftSize);
    core.iqFrontEnd.setFFTRate(fftRate);
    synth = SynthSource(core,
        sampleRate: sampleRate, centerFreq: center, noiseLevel: noise, carriers: carriers, mode: PumpMode.manual);
    core.sigpath.sourceManager.registerSource('Synth', synth);
    core.sigpath.sourceManager.selectSource('Synth');
    core.sigpath.sourceManager.tune(center);
    factory = RadioModuleFactory(core, config: radioConfig);
    core.moduleManager.loadModule(factory);
    core.moduleManager.createInstance('Radio', 'radio');
    radio = core.moduleManager.instances['Radio']!.instance as RadioModule;
    radio.stream.bindStream(_capture);
  }

  late final Core core;
  late final SynthSource synth;
  late final RadioModuleFactory factory;
  late final RadioModule radio;
  final ConfigManager radioConfig = ConfigManager();

  final List<double> left = <double>[];
  final List<double> right = <double>[];

  void _capture(Float32List d, int n) {
    for (int i = 0; i < n; i++) {
      left.add(d[2 * i]);
      right.add(d[2 * i + 1]);
    }
  }

  Future<void> start() => core.sigpath.sourceManager.start();

  /// Runs [seconds] of signal through the whole chain.
  void run(double seconds) {
    final blocks = (seconds * synth.sampleRate / synth.pump.blockSize).ceil();
    synth.pump.pump(blocks);
  }

  void clear() {
    left.clear();
    right.clear();
  }
}
