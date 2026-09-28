// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/demod/am.h (@8c9f5ee, lines 1-150).
// [CARRIER: in = carrierAgc(in)] → a = |in| → dcBlock(a) → [AUDIO: a = audioAgc(a)] → lpf(a)
// → [mono → stereo].
import 'dart:typed_data';

import '../correction/dc_blocker.dart';
import '../filter/fir.dart';
import '../loop/agc.dart';
import '../math/ops.dart';
import '../processor.dart';
import '../taps/taps.dart';

enum AGCMode { carrier, audio }

class AM extends Processor {
  /// [outType]: real (`AM<float>`) or stereo (`AM<stereo_t>`).
  AM(this.outType, AGCMode agcMode, double bandwidth, double agcAttack, double agcDecay, double dcBlockRate,
      double samplerate) {
    _agcMode = agcMode;
    _bandwidth = bandwidth;
    _samplerate = samplerate;
    carrierAgc = AGC(SampleType.complex, 1.0, agcAttack, agcDecay, 10e6, 10.0, double.infinity);
    audioAgc = AGC(SampleType.real, 1.0, agcAttack, agcDecay, 10e6, 10.0, double.infinity);
    dcBlock = DCBlocker(SampleType.real, dcBlockRate);
    lpfTaps = lowPass(bandwidth / 2.0, (bandwidth / 2.0) * 0.1, samplerate);
    lpf = FIR(SampleType.real, lpfTaps);
  }

  @override
  SampleType get inType => SampleType.complex;
  @override
  final SampleType outType;

  late AGCMode _agcMode;
  late double _samplerate;
  late double _bandwidth;
  late AGC carrierAgc;
  late AGC audioAgc;
  late DCBlocker dcBlock;
  late Taps lpfTaps;
  late FIR lpf;
  Float32List _cbuf = Float32List(0);
  Float32List _mono = Float32List(0);

  AGCMode get agcMode => _agcMode;

  void setAGCMode(AGCMode agcMode) {
    _agcMode = agcMode;
    reset();
  }

  void setBandwidth(double bandwidth) {
    if (bandwidth == _bandwidth) return;
    _bandwidth = bandwidth;
    lpfTaps = lowPass(_bandwidth / 2.0, (_bandwidth / 2.0) * 0.1, _samplerate);
    lpf.setTaps(lpfTaps);
  }

  void setAGCAttack(double attack) {
    carrierAgc.setAttack(attack);
    audioAgc.setAttack(attack);
  }

  void setAGCDecay(double decay) {
    carrierAgc.setDecay(decay);
    audioAgc.setDecay(decay);
  }

  void setDCBlockRate(double rate) => dcBlock.setRate(rate);

  // TODO (as in C++): Implement setSamplerate

  @override
  void reset() {
    carrierAgc.reset();
    audioAgc.reset();
    dcBlock.reset();
  }

  /// am.h:101. Output may alias input.
  @override
  int process(int count, Float32List input, Float32List output) {
    Float32List inp = input;
    // Apply carrier AGC if needed
    if (_agcMode == AGCMode.carrier) {
      if (_cbuf.length < 2 * count) _cbuf = Float32List(3 * count);
      carrierAgc.process(count, input, _cbuf);
      inp = _cbuf;
    }
    final Float32List a;
    if (outType == SampleType.real) {
      a = output;
    } else {
      if (_mono.length < count) _mono = Float32List(count + (count >> 1));
      a = _mono;
    }
    magnitude(count, inp, a);
    dcBlock.process(count, a, a);
    if (_agcMode == AGCMode.audio) {
      audioAgc.process(count, a, a);
    }
    lpf.process(count, a, a);
    if (outType == SampleType.stereo) {
      monoToStereo(count, a, output);
    }
    return count;
  }
}
