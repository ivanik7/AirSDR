// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/demod/ssb.h (@8c9f5ee, lines 1-128). USB/LSB/DSB.
// xlator(+bw/2 USB, −bw/2 LSB, 0 DSB) → Re() → AGC → [mono → stereo].
// There is no Hilbert filter: the RxVFO low-pass (centred on carrier ± bw/2 through the
// REF_LOWER/REF_UPPER VFO reference) is the sideband filter (docs/02 §3.16).
import 'dart:typed_data';

import '../channel/frequency_xlator.dart';
import '../loop/agc.dart';
import '../math/ops.dart';
import '../processor.dart';

enum SSBMode { usb, lsb, dsb }

class SSB extends Processor {
  SSB(this.outType, SSBMode mode, double bandwidth, double samplerate, double agcAttack, double agcDecay) {
    _mode = mode;
    _bandwidth = bandwidth;
    _samplerate = samplerate;
    xlator = FrequencyXlator.hz(_getTranslation(), _samplerate);
    agc = AGC(SampleType.real, 1.0, agcAttack, agcDecay, 10e6, 10.0, double.infinity);
  }

  @override
  SampleType get inType => SampleType.complex;
  @override
  final SampleType outType;

  late SSBMode _mode;
  late double _bandwidth;
  late double _samplerate;
  late FrequencyXlator xlator;
  late AGC agc;
  Float32List _xbuf = Float32List(0);

  SSBMode get mode => _mode;

  void setMode(SSBMode mode) {
    _mode = mode;
    xlator.setOffsetHz(_getTranslation(), _samplerate);
  }

  void setBandwidth(double bandwidth) {
    _bandwidth = bandwidth;
    xlator.setOffsetHz(_getTranslation(), _samplerate);
  }

  void setSamplerate(double samplerate) {
    _samplerate = samplerate;
    xlator.setOffsetHz(_getTranslation(), _samplerate);
  }

  void setAGCAttack(double attack) => agc.setAttack(attack);

  void setAGCDecay(double decay) => agc.setDecay(decay);

  @override
  void reset() {
    xlator.reset();
    agc.reset();
  }

  /// ssb.h:81. Output may alias input.
  @override
  int process(int count, Float32List input, Float32List output) {
    if (_xbuf.length < 2 * count) _xbuf = Float32List(3 * count);
    // Move back sideband
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

  double _getTranslation() {
    if (_mode == SSBMode.usb) {
      return _bandwidth / 2.0;
    } else if (_mode == SSBMode.lsb) {
      return -_bandwidth / 2.0;
    } else {
      return 0.0;
    }
  }
}
