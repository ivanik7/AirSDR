// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/filter/deephasis.h (@8c9f5ee, lines 1-104).
// One-pole IIR: alpha = dt/(tau + dt), dt = 1/sr; y[i] = alpha·x[i] + (1 − alpha)·y[i−1],
// per channel for stereo (docs/02 §3.20).
import 'dart:typed_data';

import '../processor.dart';

class Deemphasis extends ProcessorTT {
  /// [type]: real (`float`) or stereo (`stereo_t`).
  Deemphasis(this.type, double tau, double samplerate) {
    if (type == SampleType.complex) {
      throw ArgumentError('Deemphasis<complex_t> does not exist in SDR++');
    }
    _tau = tau;
    _samplerate = samplerate;
    _updateAlpha();
  }

  @override
  final SampleType type;
  late double _tau;
  late double _samplerate;
  double alpha = 0;
  double _lastL = 0;
  double _lastR = 0;

  final Float32List _f = Float32List(1);

  void setTau(double tau) {
    _tau = tau;
    _updateAlpha();
  }

  void setSamplerate(double samplerate) {
    _samplerate = samplerate;
    _updateAlpha();
  }

  @override
  void reset() {
    _lastL = 0;
    _lastR = 0;
  }

  @override
  @pragma('vm:unsafe:no-bounds-checks')
  int process(int count, Float32List input, Float32List output) {
    if (count <= 0) return count;
    final a = alpha;
    // C++: (1 - alpha) with float alpha
    _f[0] = 1 - a;
    final ia = _f[0];
    if (type == SampleType.real) {
      double last = _lastL;
      for (int i = 0; i < count; i++) {
        output[i] = (a * input[i]) + (ia * last);
        last = output[i];
      }
      _lastL = last;
    } else {
      double l = _lastL, r = _lastR;
      for (int i = 0; i < 2 * count; i += 2) {
        output[i] = (a * input[i]) + (ia * l);
        output[i + 1] = (a * input[i + 1]) + (ia * r);
        l = output[i];
        r = output[i + 1];
      }
      _lastL = l;
      _lastR = r;
    }
    return count;
  }

  void _updateAlpha() {
    // float dt = 1.0f / _samplerate; alpha = dt / (_tau + dt);  (stored as float)
    _f[0] = 1.0 / _samplerate;
    final dt = _f[0];
    _f[0] = dt / (_tau + dt);
    alpha = _f[0];
  }
}
