// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/demod/quadrature.h (@8c9f5ee, lines 1-75).
// FM discriminator: out[i] = normalizePhase(atan2(im, re) − prevPhase) · (1/hzToRads(dev, sr)).
// Full deviation maps to ±1.
import 'dart:math' as math;
import 'dart:typed_data';

import '../math/math.dart';
import '../processor.dart';

class Quadrature extends Processor {
  /// `init(in, deviation)` — [deviation] in radians/sample.
  Quadrature(double deviation) {
    setDeviation(deviation);
  }

  /// `init(in, deviation, samplerate)` — [deviation] in Hz.
  Quadrature.hz(double deviation, double samplerate) : this(hzToRads(deviation, samplerate));

  @override
  SampleType get inType => SampleType.complex;
  @override
  SampleType get outType => SampleType.real;

  double _invDeviation = 1;
  double phase = 0.0;

  void setDeviation(double deviation) {
    _invDeviation = 1.0 / deviation;
  }

  void setDeviationHz(double deviation, double samplerate) {
    _invDeviation = 1.0 / hzToRads(deviation, samplerate);
  }

  @override
  void reset() {
    phase = 0.0;
  }

  /// In-place allowed (output index i ≤ input index 2i).
  @override
  @pragma('vm:unsafe:no-bounds-checks')
  int process(int count, Float32List input, Float32List output) {
    double ph = phase;
    final inv = _invDeviation;
    for (int i = 0; i < count; i++) {
      final cphase = math.atan2(input[2 * i + 1], input[2 * i]);
      double d = cphase - ph;
      if (d > flMPi) {
        d -= 2.0 * flMPi;
      } else if (d <= -flMPi) {
        d += 2.0 * flMPi;
      }
      output[i] = d * inv;
      ph = cphase;
    }
    phase = ph;
    return count;
  }
}
