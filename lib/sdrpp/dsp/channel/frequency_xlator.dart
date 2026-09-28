// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/channel/frequency_xlator.h (@8c9f5ee, lines 1-68).
//
// phaseDelta = e^(j·ω) with ω = hzToRads(offset, sr); phase = 1+0j.
// process = volk_32fc_s32fc_x2_rotator2_32fc (see kernels/rotator.dart).
// setOffset only changes phaseDelta (phase continuous); reset() sets phase = 1.
import 'dart:typed_data';

import '../kernels/rotator.dart';
import '../math/math.dart';
import '../processor.dart';

class FrequencyXlator extends ProcessorTT {
  /// `init(in, offset)` — [offset] in radians/sample.
  FrequencyXlator(double offset) {
    _rot.resetPhase();
    _rot.setDelta(offset);
  }

  /// `init(in, offset, samplerate)` — [offset] in Hz.
  FrequencyXlator.hz(double offset, double samplerate) : this(hzToRads(offset, samplerate));

  final Rotator _rot = Rotator();

  @override
  SampleType get type => SampleType.complex;

  /// setOffset(offset) — radians/sample.
  void setOffset(double offset) => _rot.setDelta(offset);

  /// setOffset(offset, samplerate) — Hz.
  void setOffsetHz(double offset, double samplerate) => setOffset(hzToRads(offset, samplerate));

  @override
  void reset() => _rot.resetPhase();

  /// In-place allowed.
  @override
  int process(int count, Float32List input, Float32List output) {
    _rot.rotate(count, input, output);
    return count;
  }
}
