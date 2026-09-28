// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/demod/cw.h (@8c9f5ee, lines 1-95).
// xlator(+tone, sr) → Re() → AGC → [mono → stereo].
import 'dart:typed_data';

import '../channel/frequency_xlator.dart';
import '../loop/agc.dart';
import '../math/ops.dart';
import '../processor.dart';

class CW extends Processor {
  CW(this.outType, double tone, double agcAttack, double agcDecay, double samplerate) {
    _tone = tone;
    _samplerate = samplerate;
    xlator = FrequencyXlator.hz(tone, samplerate);
    agc = AGC(SampleType.real, 1.0, agcAttack, agcDecay, 10e6, 10.0, double.infinity);
  }

  @override
  SampleType get inType => SampleType.complex;
  @override
  final SampleType outType;

  late double _tone;
  late double _samplerate;
  late FrequencyXlator xlator;
  late AGC agc;
  Float32List _xbuf = Float32List(0);

  void setTone(double tone) {
    _tone = tone;
    xlator.setOffsetHz(_tone, _samplerate);
  }

  void setAGCAttack(double attack) => agc.setAttack(attack);

  void setAGCDecay(double decay) => agc.setDecay(decay);

  void setSamplerate(double samplerate) {
    _samplerate = samplerate;
    xlator.setOffsetHz(_tone, _samplerate);
  }

  @override
  void reset() {
    xlator.reset();
    agc.reset();
  }

  /// cw.h:61. Output may alias input.
  @override
  int process(int count, Float32List input, Float32List output) {
    if (_xbuf.length < 2 * count) _xbuf = Float32List(3 * count);
    xlator.process(count, input, _xbuf);
    complexToReal(count, _xbuf, _xbuf);
    agc.process(count, _xbuf, _xbuf);
    if (outType == SampleType.real) {
      output.setRange(0, count, _xbuf);
    } else {
      monoToStereo(count, _xbuf, output);
    }
    return count;
  }
}
