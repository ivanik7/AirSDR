// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/noise_reduction/noise_blanker.h (@8c9f5ee, lines 1-79).
// amp = amp·(1−rate) + |x|·rate; excess = |x|/amp; if excess > level: gain = 1/excess.
import 'dart:math' as math;
import 'dart:typed_data';

import '../processor.dart';

class NoiseBlanker extends ProcessorTT {
  NoiseBlanker(double rate, double level) {
    setRate(rate);
    setLevel(level);
  }

  @override
  SampleType get type => SampleType.complex;

  final Float32List _f = Float32List(1);
  double _rate = 0;
  double _invRate = 1;
  double _level = 1;
  double amp = 1.0;

  double _fl(double x) {
    _f[0] = x;
    return _f[0];
  }

  void setRate(double rate) {
    _rate = _fl(rate);
    _invRate = _fl(1.0 - _rate);
  }

  void setLevel(double level) => _level = _fl(level);

  @override
  void reset() {
    amp = 1.0;
  }

  /// In-place allowed.
  @override
  @pragma('vm:unsafe:no-bounds-checks')
  int process(int count, Float32List input, Float32List output) {
    double a = amp;
    final f = _f;
    for (int i = 0; i < count; i++) {
      final re = input[2 * i], im = input[2 * i + 1];
      // Get signal amplitude
      f[0] = math.sqrt(re * re + im * im);
      final inAmp = f[0];
      // Update average amplitude
      double gain = 1.0;
      if (inAmp != 0.0) {
        f[0] = (a * _invRate) + (inAmp * _rate);
        a = f[0];
        f[0] = inAmp / a;
        final excess = f[0];
        if (excess > _level) {
          gain = 1.0 / excess;
        }
      }
      // Scale output by gain
      output[2 * i] = re * gain;
      output[2 * i + 1] = im * gain;
    }
    amp = a;
    return count;
  }
}
