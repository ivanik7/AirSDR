// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/correction/dc_blocker.h (@8c9f5ee, lines 1-80).
// out[i] = in[i] − offset; offset += out[i]·rate (leaky integrator = 1st-order high-pass).
import 'dart:typed_data';

import '../processor.dart';

class DCBlocker extends ProcessorTT {
  /// `init(in, rate)`; [type] = real, complex or stereo.
  DCBlocker(this.type, double rate) {
    setRate(rate);
  }

  /// `init(in, rate, samplerate)` → rate / samplerate.
  DCBlocker.withSamplerate(SampleType type, double rate, double samplerate) : this(type, rate / samplerate);

  @override
  final SampleType type;
  double _rate = 0;
  double _off0 = 0;
  double _off1 = 0;
  final Float32List _f = Float32List(2);

  void setRate(double rate) {
    _f[0] = rate; // stored as float in C++
    _rate = _f[0];
  }

  void setRateSr(double rate, double samplerate) => setRate(rate / samplerate);

  @override
  void reset() {
    _off0 = 0;
    _off1 = 0;
  }

  @override
  @pragma('vm:unsafe:no-bounds-checks')
  int process(int count, Float32List input, Float32List output) {
    final r = _rate;
    final f = _f;
    if (type == SampleType.real) {
      double off = _off0;
      for (int i = 0; i < count; i++) {
        output[i] = input[i] - off;
        f[0] = off + output[i] * r; // float state
        off = f[0];
      }
      _off0 = off;
    } else {
      double o0 = _off0, o1 = _off1;
      for (int i = 0; i < 2 * count; i += 2) {
        output[i] = input[i] - o0;
        output[i + 1] = input[i + 1] - o1;
        f[0] = o0 + output[i] * r;
        f[1] = o1 + output[i + 1] * r;
        o0 = f[0];
        o1 = f[1];
      }
      _off0 = o0;
      _off1 = o1;
    }
    return count;
  }
}
