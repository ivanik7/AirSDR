// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/loop/phase_control_loop.h (@8c9f5ee, lines 1-104).
// Template parameter T = float in every radio use; state is kept in double here but rounded
// to float32 after each update to follow the C++ float arithmetic closely.
import 'dart:math' as math;
import 'dart:typed_data';

class PhaseControlLoop {
  PhaseControlLoop(double alpha, double beta, double phase, double minPhase, double maxPhase, double freq,
      double minFreq, double maxFreq,
      {this.clampPhaseEnabled = true}) {
    init(alpha, beta, phase, minPhase, maxPhase, freq, minFreq, maxFreq);
  }

  /// CLAMP_PHASE template parameter.
  final bool clampPhaseEnabled;

  double freq = 0;
  double phase = 0;
  double _alpha = 0;
  double _beta = 0;
  double _minPhase = 0;
  double _maxPhase = 0;
  double _minFreq = 0;
  double _maxFreq = 0;
  double phaseDelta = 0;

  static final Float32List _f = Float32List(1);
  static double _fl(double x) {
    _f[0] = x;
    return _f[0];
  }

  void init(double alpha, double beta, double phase, double minPhase, double maxPhase, double freq, double minFreq,
      double maxFreq) {
    assert(maxPhase > minPhase);
    assert(maxFreq > minFreq);
    _alpha = _fl(alpha);
    _beta = _fl(beta);
    this.phase = _fl(phase);
    _minPhase = _fl(minPhase);
    _maxPhase = _fl(maxPhase);
    this.freq = _fl(freq);
    _minFreq = _fl(minFreq);
    _maxFreq = _fl(maxFreq);
    phaseDelta = _fl(_maxPhase - _minPhase);
  }

  /// criticallyDamped(bandwidth, alpha, beta) — returns (alpha, beta).
  static (double, double) criticallyDamped(double bandwidth) {
    final dampningFactor = _fl(math.sqrt(2.0) / 2.0);
    final denominator = _fl(1.0 + 2.0 * dampningFactor * bandwidth + bandwidth * bandwidth);
    final alpha = _fl((4 * dampningFactor * bandwidth) / denominator);
    final beta = _fl((4 * bandwidth * bandwidth) / denominator);
    return (alpha, beta);
  }

  void setCoefficients(double alpha, double beta) {
    _alpha = _fl(alpha);
    _beta = _fl(beta);
  }

  void setPhaseLimits(double minPhase, double maxPhase) {
    assert(maxPhase > minPhase);
    _minPhase = _fl(minPhase);
    _maxPhase = _fl(maxPhase);
    phaseDelta = _fl(_maxPhase - _minPhase);
    clampPhase();
  }

  void setFreqLimits(double minFreq, double maxFreq) {
    assert(maxFreq > minFreq);
    _minFreq = _fl(minFreq);
    _maxFreq = _fl(maxFreq);
    clampFreq();
  }

  @pragma('vm:prefer-inline')
  void advance(double error) {
    // Increment and clamp frequency
    freq = _fl(freq + _beta * error);
    clampFreq();

    // Increment and clamp phase
    phase = _fl(phase + (freq + (_alpha * error)));
    if (clampPhaseEnabled) clampPhase();
  }

  @pragma('vm:prefer-inline')
  void advancePhase() {
    phase = _fl(phase + freq);
    if (clampPhaseEnabled) clampPhase();
  }

  @pragma('vm:prefer-inline')
  void clampFreq() {
    if (freq > _maxFreq) {
      freq = _maxFreq;
    } else if (freq < _minFreq) {
      freq = _minFreq;
    }
  }

  @pragma('vm:prefer-inline')
  void clampPhase() {
    while (phase > _maxPhase) {
      phase = _fl(phase - phaseDelta);
    }
    while (phase < _minPhase) {
      phase = _fl(phase + phaseDelta);
    }
  }
}
