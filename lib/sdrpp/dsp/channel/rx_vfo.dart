// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/channel/rx_vfo.h (@8c9f5ee, lines 1-139).
//
// Children: FrequencyXlator(−offset, inSr) → RationalResampler<complex_t>(inSr, outSr) →
// FIR<complex_t, float>(lowPass(bw/2, bw/2·0.1, outSr)) if bandwidth != outSr.
// process returns the resampled count. The DSP offset is the VFO *centre* offset (§2.4).
import 'dart:typed_data';

import '../filter/fir.dart';
import '../multirate/rational_resampler.dart';
import '../processor.dart';
import '../taps/taps.dart';
import 'frequency_xlator.dart';

class RxVFO extends ProcessorTT {
  RxVFO(double inSamplerate, double outSamplerate, double bandwidth, double offset) {
    _inSamplerate = inSamplerate;
    _outSamplerate = outSamplerate;
    _bandwidth = bandwidth;
    _offset = offset;
    filterNeeded = (_bandwidth != _outSamplerate);

    xlator = FrequencyXlator.hz(-_offset, _inSamplerate);
    resamp = RationalResampler(SampleType.complex, _inSamplerate, _outSamplerate);
    _generateTaps();
    filter = FIR(SampleType.complex, ftaps);
  }

  @override
  SampleType get type => SampleType.complex;

  late FrequencyXlator xlator;
  late RationalResampler resamp;
  late FIR filter;
  late Taps ftaps;
  late bool filterNeeded;

  late double _inSamplerate;
  late double _outSamplerate;
  late double _bandwidth;
  late double _offset;

  double get inSamplerate => _inSamplerate;
  double get outSamplerate => _outSamplerate;
  double get bandwidth => _bandwidth;
  double get offset => _offset;

  /// Required output buffer size (samples) for [count] input samples (≥ count).
  int maxOutput(int count) => resamp.maxOutput(count);

  void setInSamplerate(double inSamplerate) {
    _inSamplerate = inSamplerate;
    xlator.setOffsetHz(-_offset, _inSamplerate);
    resamp.setInSamplerate(_inSamplerate);
  }

  void setOutSamplerate(double outSamplerate, double bandwidth) {
    _outSamplerate = outSamplerate;
    _bandwidth = bandwidth;
    filterNeeded = (_bandwidth != _outSamplerate);
    resamp.setOutSamplerate(_outSamplerate);
    if (filterNeeded) {
      _generateTaps();
      filter.setTaps(ftaps);
    }
  }

  void setBandwidth(double bandwidth) {
    _bandwidth = bandwidth;
    filterNeeded = (_bandwidth != _outSamplerate);
    if (filterNeeded) {
      _generateTaps();
      filter.setTaps(ftaps);
    }
  }

  void setOffset(double offset) {
    _offset = offset;
    xlator.setOffsetHz(-_offset, _inSamplerate);
  }

  @override
  void reset() {
    xlator.reset();
    resamp.reset();
    filter.reset();
  }

  /// rx_vfo.h:89. [output] must hold [maxOutput] complex samples; in-place allowed.
  @override
  int process(int count, Float32List input, Float32List output) {
    xlator.process(count, input, output);
    if (!filterNeeded) {
      return resamp.process(count, output, output);
    }
    count = resamp.process(count, output, output);
    filter.process(count, output, output);
    return count;
  }

  void _generateTaps() {
    final filterWidth = _bandwidth / 2.0;
    ftaps = lowPass(filterWidth, filterWidth * 0.1, _outSamplerate);
  }
}
