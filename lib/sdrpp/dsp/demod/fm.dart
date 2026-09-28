// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/demod/fm.h (@8c9f5ee, lines 1-150). Used by the NFM demodulator.
// Quadrature(dev = bw/2, sr) → [FIR lowPass(bw/2, bw/2·0.1, sr) if lowPass] → [MonoToStereo].
import 'dart:typed_data';

import '../filter/fir.dart';
import '../math/ops.dart';
import '../processor.dart';
import '../taps/taps.dart';
import 'quadrature.dart';

class FM extends Processor {
  /// [outType]: real (`FM<float>`) or stereo (`FM<stereo_t>`).
  FM(this.outType, double samplerate, double bandwidth, bool lp) {
    if (outType == SampleType.complex) throw ArgumentError('FM<complex_t> does not exist');
    _samplerate = samplerate;
    _bandwidth = bandwidth;
    _lowPass = lp;
    demod = Quadrature.hz(bandwidth / 2.0, _samplerate);
    filterTaps = _dummyTaps();
    fir = FIR(SampleType.real, filterTaps);
    _updateFilter(lp);
  }

  @override
  SampleType get inType => SampleType.complex;
  @override
  final SampleType outType;

  late double _samplerate;
  late double _bandwidth;
  late bool _lowPass;
  late Quadrature demod;
  late Taps filterTaps;
  late FIR fir;
  Float32List _mono = Float32List(0);

  void setSamplerate(double samplerate) {
    _samplerate = samplerate;
    demod.setDeviationHz(_bandwidth / 2.0, _samplerate);
    _updateFilter(_lowPass);
  }

  void setBandwidth(double bandwidth) {
    if (bandwidth == _bandwidth) return;
    _bandwidth = bandwidth;
    demod.setDeviationHz(_bandwidth / 2.0, _samplerate);
    _updateFilter(_lowPass);
  }

  void setLowPass(bool lp) => _updateFilter(lp);

  @override
  void reset() {
    demod.reset();
    fir.reset();
  }

  @override
  int process(int count, Float32List input, Float32List output) {
    if (outType == SampleType.real) {
      demod.process(count, input, output);
      if (_lowPass) fir.process(count, output, output);
    } else {
      if (_mono.length < count) _mono = Float32List(count + (count >> 1));
      demod.process(count, input, _mono);
      if (_lowPass) fir.process(count, _mono, _mono);
      monoToStereo(count, _mono, output);
    }
    return count;
  }

  void _updateFilter(bool lp) {
    _lowPass = lp;
    if (_lowPass) {
      filterTaps = lowPass(_bandwidth / 2.0, (_bandwidth / 2.0) * 0.1, _samplerate);
    } else {
      filterTaps = _dummyTaps();
    }
    fir.setTaps(filterTaps);
    fir.reset();
  }

  static Taps _dummyTaps() => fromArray(const [1.0]);
}
