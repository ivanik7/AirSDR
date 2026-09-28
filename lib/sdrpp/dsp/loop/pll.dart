// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/loop/pll.h (@8c9f5ee, lines 1-102).
//
// out[i] = phasor(pcl.phase) — the VCO output, not the mixed input;
// pcl.advance(normalizePhase(arg(in[i]) − pcl.phase)).
//
// Note on argument order (docs/02 §3.14): the C++ constructor forwards
// (bandwidth, initFreq, initPhase, …) to init(bandwidth, initPhase, initFreq, …). Callers in
// the radio path use init() directly; this port exposes init()'s order.
import 'dart:math' as math;
import 'dart:typed_data';

import '../math/math.dart';
import '../processor.dart';
import 'phase_control_loop.dart';

class PLL extends ProcessorTT {
  /// `init(in, bandwidth, initPhase, initFreq, minFreq, maxFreq)`.
  PLL(double bandwidth, [double initPhase = 0.0, double initFreq = 0.0, double minFreq = -flMPi, double maxFreq = flMPi]) {
    _initPhase = initPhase;
    _initFreq = initFreq;
    final (alpha, beta) = PhaseControlLoop.criticallyDamped(bandwidth);
    pcl = PhaseControlLoop(alpha, beta, initPhase, -flMPi, flMPi, initFreq, minFreq, maxFreq);
  }

  @override
  SampleType get type => SampleType.complex;

  late PhaseControlLoop pcl;
  late double _initPhase;
  late double _initFreq;

  void setBandwidth(double bandwidth) {
    final (alpha, beta) = PhaseControlLoop.criticallyDamped(bandwidth);
    pcl.setCoefficients(alpha, beta);
  }

  void setInitialPhase(double initPhase) => _initPhase = initPhase;

  void setInitialFreq(double initFreq) => _initFreq = initFreq;

  void setFrequencyLimits(double minFreq, double maxFreq) => pcl.setFreqLimits(minFreq, maxFreq);

  @override
  void reset() {
    pcl.phase = _initPhase;
    pcl.freq = _initFreq;
  }

  /// In-place allowed.
  @override
  @pragma('vm:unsafe:no-bounds-checks')
  int process(int count, Float32List input, Float32List output) {
    final p = pcl;
    for (int i = 0; i < count; i++) {
      final re = input[2 * i], im = input[2 * i + 1];
      final ph = p.phase;
      output[2 * i] = math.cos(ph);
      output[2 * i + 1] = math.sin(ph);
      p.advance(normalizePhase(math.atan2(im, re) - ph));
    }
    return count;
  }
}
