// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/demod/broadcast_fm.h (@8c9f5ee, lines 1-250). WFM, stereo_t out.
//
// init (docs/02 §3.14): demod = Quadrature(deviation, sr);
//   pilotFirTaps = bandPass<complex_t>(18750, 19250, 3000, sr, odd = true);
//   pilotPLL.init(25000/sr, 0, ω(19 kHz), ω(18.75 kHz), ω(19.25 kHz));
//   lprDelay/lmrDelay = (pilotTaps − 1)/2 + 1; audioFirTaps = lowPass(15000, 4000, sr).
// process (stereo): mpx = quad(in); c = rtoc(mpx); p = pilotFIR(c); vco = PLL(p);
//   mpx = delay(mpx); c = delay(c); vco = conj(vco); c = c·vco·vco; lmr = 2·Re(c);
//   l = mpx + lmr; r = mpx − lmr; [l, r = FIR]; out = interleave(l, r).
// process (mono): [mpx = FIR(mpx)]; out = interleave(mpx, mpx).
//
// RDS output (xlator −57 kHz + resampler to 5 kHz) is ported but only runs when rdsOut is
// enabled; it is out of scope for the first milestone (no RDS decoder yet).
import 'dart:typed_data';

import '../channel/frequency_xlator.dart';
import '../filter/fir.dart';
import '../loop/pll.dart';
import '../math/math.dart';
import '../math/ops.dart';
import '../multirate/rational_resampler.dart';
import '../processor.dart';
import '../taps/taps.dart';
import '../taps/taps.dart' as taps show lowPass;
import 'quadrature.dart';

class BroadcastFM extends Processor {
  BroadcastFM(double deviation, double samplerate,
      {bool stereo = true, bool lowPass = true, bool rdsOut = false}) {
    _deviation = deviation;
    _samplerate = samplerate;
    _stereo = stereo;
    _lowPass = lowPass;
    _rdsOut = rdsOut;

    demod = Quadrature.hz(_deviation, _samplerate);
    pilotFirTaps = bandPassComplex(18750.0, 19250.0, 3000.0, _samplerate, true);
    pilotFir = FIR(SampleType.complex, pilotFirTaps);
    pilotPLL = PLL(25000.0 / _samplerate, 0.0, hzToRads(19000.0, _samplerate), hzToRads(18750.0, _samplerate),
        hzToRads(19250.0, _samplerate));
    lprDelay = Delay(SampleType.real, ((pilotFirTaps.size - 1) ~/ 2) + 1);
    lmrDelay = Delay(SampleType.complex, ((pilotFirTaps.size - 1) ~/ 2) + 1);
    audioFirTaps = taps.lowPass(15000.0, 4000.0, _samplerate);
    alFir = FIR(SampleType.real, audioFirTaps);
    arFir = FIR(SampleType.real, audioFirTaps);
    xlator = FrequencyXlator.hz(-57000.0, samplerate);
    rdsResamp = RationalResampler(SampleType.complex, samplerate, 5000.0);
  }

  @override
  SampleType get inType => SampleType.complex;
  @override
  SampleType get outType => SampleType.stereo;

  late double _deviation;
  late double _samplerate;
  late bool _stereo;
  late bool _lowPass;
  late bool _rdsOut;

  late Quadrature demod;
  late Taps pilotFirTaps;
  late FIR pilotFir;
  late PLL pilotPLL;
  late Delay lprDelay;
  late Delay lmrDelay;
  late Taps audioFirTaps;
  late FIR arFir;
  late FIR alFir;
  late FrequencyXlator xlator;
  late RationalResampler rdsResamp;

  // Work buffers (C++: demod.out, rtoc.out, pilotFir.out, pilotPLL.out, lmrDelay.out, lmr, l, r)
  Float32List _mpx = Float32List(0);
  Float32List _rtoc = Float32List(0);
  Float32List _pilot = Float32List(0);
  Float32List _vco = Float32List(0);
  Float32List _lmrC = Float32List(0);
  Float32List _lmr = Float32List(0);
  Float32List _l = Float32List(0);
  Float32List _r = Float32List(0);

  /// RDS output buffer (complex @ 5 kHz) and count of the last [process] call.
  Float32List rdsOutBuf = Float32List(0);
  int rdsOutCount = 0;

  bool get stereo => _stereo;
  bool get lowPass => _lowPass;
  bool get rdsOut => _rdsOut;

  void setDeviation(double deviation) {
    _deviation = deviation;
    demod.setDeviationHz(_deviation, _samplerate);
  }

  void setSamplerate(double samplerate) {
    _samplerate = samplerate;
    demod.setDeviationHz(_deviation, _samplerate);
    pilotFirTaps = bandPassComplex(18750.0, 19250.0, 3000.0, samplerate, true);
    pilotFir.setTaps(pilotFirTaps);

    pilotPLL.setFrequencyLimits(hzToRads(18750.0, _samplerate), hzToRads(19250.0, _samplerate));
    pilotPLL.setInitialFreq(hzToRads(19000.0, _samplerate));
    lprDelay.setDelay(((pilotFirTaps.size - 1) ~/ 2) + 1);
    lmrDelay.setDelay(((pilotFirTaps.size - 1) ~/ 2) + 1);

    audioFirTaps = taps.lowPass(15000.0, 4000.0, _samplerate);
    alFir.setTaps(audioFirTaps);
    arFir.setTaps(audioFirTaps);

    xlator.setOffsetHz(-57000.0, samplerate);
    rdsResamp.setInSamplerate(samplerate);

    reset();
  }

  void setStereo(bool stereo) {
    _stereo = stereo;
    reset();
  }

  void setLowPass(bool lowPass) {
    _lowPass = lowPass;
    reset();
  }

  void setRDSOut(bool rdsOut) {
    _rdsOut = rdsOut;
    reset();
  }

  @override
  void reset() {
    demod.reset();
    pilotFir.reset();
    pilotPLL.reset();
    lprDelay.reset();
    lmrDelay.reset();
    alFir.reset();
    arFir.reset();
  }

  static Float32List _grow(Float32List b, int n) => b.length >= n ? b : Float32List(n + (n >> 1));

  void _ensure(int count) {
    _mpx = _grow(_mpx, count);
    _rtoc = _grow(_rtoc, 2 * count);
    if (_stereo) {
      _pilot = _grow(_pilot, 2 * count);
      _vco = _grow(_vco, 2 * count);
      _lmrC = _grow(_lmrC, 2 * count);
      _lmr = _grow(_lmr, count);
      _l = _grow(_l, count);
      _r = _grow(_r, count);
    }
    if (_rdsOut) rdsOutBuf = _grow(rdsOutBuf, 2 * rdsResamp.maxOutput(count));
  }

  /// broadcast_fm.h:144. [output] (stereo) must not alias [input].
  /// RDS samples (if enabled) are written to [rdsOutBuf], count in [rdsOutCount].
  @override
  int process(int count, Float32List input, Float32List output) {
    _ensure(count);
    rdsOutCount = 0;
    // Demodulate
    demod.process(count, input, _mpx);
    if (_stereo) {
      // Convert to complex
      realToComplex(count, _mpx, _rtoc);

      // Filter out pilot and run through PLL
      pilotFir.process(count, _rtoc, _pilot);
      pilotPLL.process(count, _pilot, _vco);

      // Delay
      lprDelay.process(count, _mpx, _mpx);
      lmrDelay.process(count, _rtoc, _lmrC);

      // conjugate PLL output to down convert twice the L-R signal
      conjugate(count, _vco, _vco);
      multiplyC(count, _lmrC, _vco, _lmrC);
      multiplyC(count, _lmrC, _vco, _lmrC);

      // Do RDS demod
      if (_rdsOut) {
        // Translate to 0Hz
        xlator.process(count, _rtoc, _rtoc);
        // Resample to the output samplerate
        rdsOutCount = rdsResamp.process(count, _rtoc, rdsOutBuf);
      }

      // Convert output back to real for further processing
      complexToReal(count, _lmrC, _lmr);

      // Amplify by 2x
      scaleF(count, _lmr, 2.0, _lmr);

      // Do L = (L+R) + (L-R), R = (L+R) - (L-R)
      addF(count, _mpx, _lmr, _l);
      subtractF(count, _mpx, _lmr, _r);

      // Filter if needed
      if (_lowPass) {
        alFir.process(count, _l, _l);
        arFir.process(count, _r, _r);
      }

      // Interleave into stereo
      lrToStereo(count, _l, _r, output);
    } else {
      // Process RDS if needed
      if (_rdsOut) {
        realToComplex(count, _mpx, _rtoc);
        xlator.process(count, _rtoc, _rtoc);
        rdsOutCount = rdsResamp.process(count, _rtoc, rdsOutBuf);
      }

      // Filter if needed
      if (_lowPass) {
        alFir.process(count, _mpx, _mpx);
      }

      // Interleave raw MPX to stereo
      lrToStereo(count, _mpx, _mpx, output);
    }
    return count;
  }
}
