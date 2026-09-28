// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/multirate/rational_resampler.h (@8c9f5ee, lines 1-173).
//
// reconfigure() (docs/02 §3.3, §6.6):
//  1. predecPower = min(floor(log2(in/out)), maxRatio); predecRatio = min(1 << power, maxRatio);
//     useDecim = in > out && power > 0; intSr = in / predecRatio.
//  2. interp = round(out)/gcd, decim = round(intSr)/gcd (gcd of the *rounded* rates).
//  3. interp == decim → DECIM_ONLY or NONE.
//  4. else taps = lowPass(min(in,out)/2, that·0.1, intSr·interp) · interp → BOTH / RESAMP_ONLY.
import 'dart:io' show stderr;
import 'dart:math' as math;
import 'dart:typed_data';

import '../processor.dart';
import '../taps/taps.dart';
import 'polyphase_resampler.dart';
import 'power_decimator.dart';

enum _Mode { both, decimOnly, resampOnly, none }

class RationalResampler extends ProcessorTT {
  RationalResampler(this.type, double inSamplerate, double outSamplerate) {
    _inSamplerate = inSamplerate;
    _outSamplerate = outSamplerate;
    // Dummy initialization since only used for processing
    rtaps = lowPass(0.25, 0.1, 1.0);
    decim = PowerDecimator(type, 2);
    resamp = PolyphaseResampler(type, 1, 1, rtaps);
    _reconfigure();
  }

  @override
  final SampleType type;
  late PowerDecimator decim;
  late PolyphaseResampler resamp;
  late Taps rtaps;
  late double _inSamplerate;
  late double _outSamplerate;
  _Mode _mode = _Mode.none;

  /// Set to false to silence the "[Resamp] ..." configuration log (C++ printf).
  static bool verbose = false;

  double get inSamplerate => _inSamplerate;
  double get outSamplerate => _outSamplerate;

  /// For diagnostics/tests: "both", "decimOnly", "resampOnly", "none".
  String get modeName => _mode.name;

  /// Required [process] output buffer size (samples) for [count] input samples: the upper
  /// bound of produced samples, and at least [count] because the pre-decimator writes its
  /// intermediate result into the output buffer.
  int maxOutput(int count) => math.max(count, (count * _outSamplerate / _inSamplerate).ceil() + 4);

  @override
  void reset() {
    decim.reset();
    resamp.reset();
  }

  void setInSamplerate(double inSamplerate) {
    _inSamplerate = inSamplerate;
    _reconfigure();
  }

  void setOutSamplerate(double outSamplerate) {
    _outSamplerate = outSamplerate;
    _reconfigure();
  }

  void setRates(double inSamplerate, double outSamplerate) {
    _inSamplerate = inSamplerate;
    _outSamplerate = outSamplerate;
    _reconfigure();
  }

  /// In-place allowed. [output] must hold [maxOutput] samples.
  @override
  int process(int count, Float32List input, Float32List output) {
    switch (_mode) {
      case _Mode.both:
        count = decim.process(count, input, output);
        return resamp.process(count, output, output);
      case _Mode.decimOnly:
        return decim.process(count, input, output);
      case _Mode.resampOnly:
        return resamp.process(count, input, output);
      case _Mode.none:
        if (!identical(input, output)) {
          output.setRange(0, count * type.stride, input);
        }
        return count;
    }
  }

  void _reconfigure() {
    // Calculate highest power-of-two decimation for the power decimator
    final maxRatio = PowerDecimator.getMaxRatio();
    int predecPower = (math.log(_inSamplerate / _outSamplerate) / math.ln2).floor();
    if (predecPower > maxRatio) predecPower = maxRatio;
    // (C++: 1 << negative is UB but unused because useDecim is false then.)
    int predecRatio = predecPower >= 0 && predecPower < 31 ? (1 << predecPower) : 1;
    if (predecRatio > maxRatio) predecRatio = maxRatio;
    double intSamplerate = _inSamplerate;

    // Configure the DDC
    final useDecim = (_inSamplerate > _outSamplerate && predecPower > 0);
    if (useDecim) {
      intSamplerate = _inSamplerate / predecRatio;
      decim.setRatio(predecRatio);
    }

    // Calculate interpolation and decimation for polyphase resampler
    final intSR = intSamplerate.round();
    final outSR = _outSamplerate.round();
    final gcd = intSR.gcd(outSR);
    final interp = outSR ~/ gcd;
    final dec = intSR ~/ gcd;

    // Check for excessive error
    final actualOutSR = intSR.toDouble() * interp / dec;
    final error = ((actualOutSR - _outSamplerate) / _outSamplerate).abs() * 100.0;
    if (error > 0.01) {
      stderr.writeln('Warning: resampling error is over 0.01%: $error');
    }

    // If the power decimator already did all the work, don't use the resampler
    if (interp == dec) {
      _mode = useDecim ? _Mode.decimOnly : _Mode.none;
      return;
    }

    // Configure the polyphase resampler
    final tapSamplerate = intSamplerate * interp;
    final tapBandwidth = math.min(_inSamplerate, _outSamplerate) / 2.0;
    final tapTransWidth = tapBandwidth * 0.1;
    rtaps = lowPass(tapBandwidth, tapTransWidth, tapSamplerate);
    final t = rtaps.taps;
    final fi = interp.toDouble();
    for (int i = 0; i < rtaps.size; i++) {
      t[i] *= fi;
    }
    resamp.setRatio(interp, dec, rtaps);

    if (verbose) {
      stderr.writeln('[Resamp] predec: $predecRatio, interp: $interp, decim: $dec, inacc: $error%, taps: ${rtaps.size}');
    }

    _mode = useDecim ? _Mode.both : _Mode.resampOnly;
  }
}
