// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/loop/agc.h (@8c9f5ee, lines 1-150).
//
// Per sample (docs/02 §3.11):
//   inAmp = |x|
//   if inAmp != 0: amp = inAmp > amp ? amp·(1−attack) + inAmp·attack : amp·(1−decay) + inAmp·decay
//                  gain = min(setPoint/amp, maxGain)
//   else gain = 1
//   if inAmp·gain > maxOutputAmp: look ahead over the rest of the block for the max amplitude,
//      amp = max, gain = min(setPoint/amp, maxGain)
//   out = in·gain
// Radio demods use setPoint 1, maxGain 10e6, maxOut 10, initGain ∞ → amp starts at 0.
//
// Note: the look-ahead makes the output depend on the block boundaries (as in C++); this only
// happens on clipping transients.
import 'dart:math' as math;
import 'dart:typed_data';

import '../processor.dart';

class AGC extends ProcessorTT {
  /// [type]: real (`float`) or complex (`complex_t`).
  AGC(this.type, double setPoint, double attack, double decay, double maxGain, double maxOutputAmp,
      [double initGain = 1.0]) {
    if (type == SampleType.stereo) {
      throw ArgumentError('AGC<stereo_t> does not exist in SDR++');
    }
    _setPoint = _fl(setPoint);
    setAttack(attack);
    setDecay(decay);
    _maxGain = _fl(maxGain);
    _maxOutputAmp = _fl(maxOutputAmp);
    _initGain = _fl(initGain);
    amp = _fl(_setPoint / _initGain);
  }

  @override
  final SampleType type;

  static final Float32List _f = Float32List(1);
  static double _fl(double x) {
    _f[0] = x;
    return _f[0];
  }

  late double _setPoint;
  late double _attack;
  late double _invAttack;
  late double _decay;
  late double _invDecay;
  late double _maxGain;
  late double _maxOutputAmp;
  late double _initGain;

  /// Average amplitude (float in C++).
  double amp = 1.0;

  void setSetPoint(double setPoint) => _setPoint = _fl(setPoint);

  void setAttack(double attack) {
    _attack = _fl(attack);
    _invAttack = _fl(1.0 - _attack);
  }

  void setDecay(double decay) {
    _decay = _fl(decay);
    _invDecay = _fl(1.0 - _decay);
  }

  void setMaxGain(double maxGain) => _maxGain = _fl(maxGain);

  void setMaxOutputAmp(double maxOutputAmp) => _maxOutputAmp = _fl(maxOutputAmp);

  void setInitialGain(double initGain) => _initGain = _fl(initGain);

  @override
  void reset() {
    amp = _fl(_setPoint / _initGain);
  }

  @override
  @pragma('vm:unsafe:no-bounds-checks')
  int process(int count, Float32List input, Float32List output) {
    final cplx = type == SampleType.complex;
    double a = amp;
    final f = _f;
    for (int i = 0; i < count; i++) {
      // Get signal amplitude
      double inAmp;
      if (cplx) {
        final re = input[2 * i], im = input[2 * i + 1];
        f[0] = math.sqrt(re * re + im * im);
        inAmp = f[0];
      } else {
        inAmp = input[i].abs();
      }
      double gain;

      // Update average amplitude
      if (inAmp != 0.0) {
        f[0] = (inAmp > a) ? ((a * _invAttack) + (inAmp * _attack)) : ((a * _invDecay) + (inAmp * _decay));
        a = f[0];
        f[0] = _setPoint / a;
        gain = math.min(f[0], _maxGain);
      } else {
        gain = 1.0;
      }

      // If clipping is detected look ahead and correct
      f[0] = inAmp * gain;
      if (f[0] > _maxOutputAmp) {
        double maxAmp = 0;
        for (int j = i; j < count; j++) {
          double ja;
          if (cplx) {
            final re = input[2 * j], im = input[2 * j + 1];
            f[0] = math.sqrt(re * re + im * im);
            ja = f[0];
          } else {
            ja = input[j].abs();
          }
          if (ja > maxAmp) maxAmp = ja;
        }
        a = maxAmp;
        f[0] = _setPoint / a;
        gain = math.min(f[0], _maxGain);
      }

      // Scale output by gain
      if (cplx) {
        output[2 * i] = input[2 * i] * gain;
        output[2 * i + 1] = input[2 * i + 1] * gain;
      } else {
        output[i] = input[i] * gain;
      }
    }
    amp = a;
    return count;
  }
}
