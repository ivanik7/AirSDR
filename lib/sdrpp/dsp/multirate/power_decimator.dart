// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/multirate/power_decimator.h (@8c9f5ee, lines 1-129).
//
// Ratio must be a power of two ≤ 8192. Plan = decim::plans[log2(ratio) − 1]; each stage is a
// DecimatingFIR<T, float> with fixed pre-computed taps. process() runs stage 0 in → out, then
// every following stage out → out (in place).
import 'dart:typed_data';

import '../filter/fir.dart';
import '../processor.dart';
import '../taps/taps.dart';
import 'decim/plans.dart';

class PowerDecimator extends ProcessorTT {
  PowerDecimator(this.type, int ratio) {
    assert(checkRatio(ratio));
    _ratio = ratio;
    _reconfigure();
  }

  @override
  final SampleType type;
  late int _ratio;
  final List<DecimatingFIR> decimFirs = [];
  int stageCount = 0;

  int get ratio => _ratio;

  /// getMaxRatio() = 1 << plans_len.
  static int getMaxRatio() => 1 << plansLen;

  void setRatio(int ratio) {
    assert(checkRatio(ratio));
    _ratio = ratio;
    _reconfigure();
  }

  @override
  void reset() {
    for (final fir in decimFirs) {
      fir.reset();
    }
  }

  /// In-place allowed.
  @override
  int process(int count, Float32List input, Float32List output) {
    // If the ratio is 1, no need to decimate
    if (_ratio == 1) {
      if (!identical(input, output)) {
        output.setRange(0, count * type.stride, input);
      }
      return count;
    }
    // Process data through each stage
    Float32List data = input;
    for (int i = 0; i < stageCount; i++) {
      count = decimFirs[i].process(count, data, output);
      data = output;
    }
    return count;
  }

  void _reconfigure() {
    decimFirs.clear();
    stageCount = 0;
    if (_ratio > 1) {
      int planId = 0;
      while ((1 << (planId + 1)) < _ratio) {
        planId++;
      }
      final plan = plans[planId];
      stageCount = plan.stageCount;
      for (final st in plan.stages) {
        decimFirs.add(DecimatingFIR(type, Taps.real(st.taps), st.decimation));
      }
    }
  }

  /// Ratio must be a power of two, non-zero and ≤ max.
  static bool checkRatio(int ratio) => ((ratio & (ratio - 1)) == 0) && ratio != 0 && ratio <= getMaxRatio();
}
