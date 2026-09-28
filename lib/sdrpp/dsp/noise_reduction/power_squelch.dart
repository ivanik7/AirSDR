// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/noise_reduction/power_squelch.h (@8c9f5ee, lines 1-68).
// mean = Σ|x|/n over the whole block; if 10·log10(mean) >= level pass, else zero the block.
// (Magnitude with 10·log10 and block granularity are SDR++ behaviour, kept as is.)
import 'dart:math' as math;
import 'dart:typed_data';

import '../math/ops.dart';
import '../processor.dart';

class PowerSquelch extends ProcessorTT {
  PowerSquelch(double level) {
    setLevel(level);
  }

  @override
  SampleType get type => SampleType.complex;

  double _level = -50.0;
  Float32List _normBuffer = Float32List(0);
  final Float32List _f = Float32List(1);

  double get level => _level;

  void setLevel(double level) {
    _f[0] = level;
    _level = _f[0];
  }

  /// In-place allowed.
  @override
  int process(int count, Float32List input, Float32List output) {
    if (_normBuffer.length < count) _normBuffer = Float32List(count + (count >> 1));
    // Compute the amplitude of each sample
    magnitude(count, input, _normBuffer);
    // Compute the mean amplitude
    _f[0] = accumulate(count, _normBuffer);
    _f[0] = _f[0] / count;
    final sum = _f[0];
    if (10.0 * math.log(sum) / math.ln10 >= _level) {
      if (!identical(input, output)) output.setRange(0, 2 * count, input);
    } else {
      output.fillRange(0, 2 * count, 0.0);
    }
    return count;
  }
}
