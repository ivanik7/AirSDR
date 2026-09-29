// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/signal_path/iq_frontend.h (lines 1-106) and iq_frontend.cpp
// (lines 1-308) @8c9f5ee.
//
// Topology (iq_frontend.cpp:17-70, docs/02 §2.3):
//   source ─► inBuf ─► preproc [PowerDecimator ─► DCBlocker ─► Conjugate] ─► split
//                                                    ├─► Reshaper(nz, skip) ─► handler (FFT)
//                                                    └─► RxVFO per VFO ─► VFO output handler
//
// Differences forced by the synchronous single-isolate graph (docs/02 §1.8):
//  * No threads/streams: [process] runs the whole frontend for one source block. `start/stop`,
//    `tempStop/tempStart` disappear; setters are applied between blocks.
//  * `inBuf` (SampleFrameBuffer, a 32-slot jitter buffer between two threads) has no meaning
//    without threads: the buffering flag is stored and reported but data is always bypassed.
//    Jitter is absorbed by the source→DSP-isolate message queue instead.
//  * `vfo->out` streams become output handlers ([setVFOOutput]).
//  * `init()`'s window bug (no (−1)^i, RECTANGULAR = 0, iq_frontend.cpp:50-58) is not
//    reproduced: C++ always overwrites it through updateFFTPath() from displaymenu::init,
//    so the port builds the window once, in [updateFFTPath] (docs/03 §1.4).
//  * `volk_32fc_s32f_power_spectrum_32f` gives −inf for an exactly zero bin; the port floors the
//    power at 1e-20 (−200 dB) so the UI never sees non-finite values.
//  * `gui::waterfall.setRawFFTSize` is replaced by the [onFFTSizeChanged] event.
import 'dart:math' as math;
import 'dart:typed_data';

import '../core/event.dart';
import '../dsp/dsp.dart';

/// FFT output callbacks (C++ `_acquireFFTBuffer(ctx)` / `_releaseFFTBuffer(ctx)`).
/// [FFTAcquire] returns a buffer of at least `fftSize` floats, or null to drop this row.
typedef FFTAcquire = Float32List? Function(int fftSize);
typedef FFTRelease = void Function(int fftSize);

/// Receives VFO output: [count] complex samples in [iq] (valid only during the call).
typedef VFOOutputHandler = void Function(Float32List iq, int count);

/// `dsp::math::Conjugate` as a chain block.
class ConjugateBlock extends ProcessorTT {
  @override
  SampleType get type => SampleType.complex;
  @override
  int process(int count, Float32List input, Float32List output) => conjugate(count, input, output);
}

class _VFOEntry {
  _VFOEntry(this.vfo);
  final RxVFO vfo;
  Float32List out = Float32List(0);
  VFOOutputHandler? handler;
}

class IQFrontEnd {
  /// iq_frontend.cpp:17 `init(...)`. [in] of C++ is replaced by the caller feeding [process].
  IQFrontEnd({
    double sampleRate = 8000000,
    bool buffering = true,
    int decimRatio = 1,
    bool dcBlocking = false,
    int fftSize = 8192,
    double fftRate = 20,
    FFTWindow fftWindow = FFTWindow.nuttall,
    this.acquireFFTBuffer,
    this.releaseFFTBuffer,
  }) {
    _sampleRate = sampleRate;
    _decimRatio = decimRatio;
    _fftSize = fftSize;
    _fftRate = fftRate;
    _fftWindow = fftWindow;
    _buffering = buffering;

    effectiveSr = _sampleRate / _decimRatio;

    decim = PowerDecimator(SampleType.complex, _decimRatio);
    dcBlock = DCBlocker(SampleType.complex, genDCBlockRate(effectiveSr));
    conj = ConjugateBlock();

    preproc = Chain(SampleType.complex);
    preproc.addBlock(decim, _decimRatio > 1);
    preproc.addBlock(dcBlock, dcBlocking);
    preproc.addBlock(conj, false); // TODO: Replace by parameter

    reshape = Reshaper(SampleType.complex, 1, 0, _handler);
    updateFFTPath();
  }

  // ---- Parameters ----
  late double _sampleRate;
  late int _decimRatio;
  late int _fftSize;
  late double _fftRate;
  late FFTWindow _fftWindow;
  late bool _buffering;

  /// C++ `effectiveSr`.
  late double effectiveSr;

  FFTAcquire? acquireFFTBuffer;
  FFTRelease? releaseFFTBuffer;
  /// Skip reshaping/window/FFT altogether while the app is in the background.
  bool fftEnabled = true;

  /// Wired by the core: IQFrontEnd::setDecimation calls `core::setInputSampleRate`
  /// (iq_frontend.cpp:121).
  void Function(double sampleRate)? coreSetInputSampleRate;

  /// Replaces `gui::waterfall.setRawFFTSize(_fftSize)` (iq_frontend.cpp:304).
  final Event<int> onFFTSizeChanged = Event<int>();

  // ---- Pre-processing chain ----
  late final PowerDecimator decim;
  late final DCBlocker dcBlock;
  late final ConjugateBlock conj;
  late final Chain preproc;

  // ---- FFT ----
  late final Reshaper reshape;
  int _nzFFTSize = 0;
  Float32List fftWindowBuf = Float32List(0);
  Float32List fftInBuf = Float32List(0);
  Float32List fftOutBuf = Float32List(0);
  FftPlan? _fftPlan;

  // ---- VFOs ----
  final Map<String, _VFOEntry> _vfos = <String, _VFOEntry>{};
  List<_VFOEntry> _vfoList = const <_VFOEntry>[];

  // ---- Extra IQ consumers (bindIQStream) ----
  final List<VFOOutputHandler> _iqStreams = <VFOOutputHandler>[];

  // ---- Working buffer ----
  Float32List _work = Float32List(0);

  /// Statistics.
  int samplesIn = 0;
  int fftFrames = 0;

  double get sampleRate => _sampleRate;

  /// iq_frontend.h:27 `getSampleRate()` = sampleRate / decimRatio.
  double getSampleRate() => _sampleRate / _decimRatio;
  double getEffectiveSamplerate() => effectiveSr;
  int get decimRatio => _decimRatio;
  int get fftSize => _fftSize;
  double get fftRate => _fftRate;
  FFTWindow get fftWindow => _fftWindow;
  int get nzFFTSize => _nzFFTSize;
  bool get buffering => _buffering;
  bool get dcBlocking => preproc.isEnabled(dcBlock);
  bool get invertIQ => preproc.isEnabled(conj);
  Iterable<String> get vfoNames => _vfos.keys;

  /// iq_frontend.h:55.
  static double genDCBlockRate(double sampleRate) => 50.0 / sampleRate;

  /// iq_frontend.h:59-63. Returns (skip, nzSampCount).
  static (int, int) genReshapeParams(double sampleRate, int size, double rate) {
    final fftInterval = (sampleRate / rate).round();
    final nzSampCount = math.min(fftInterval, size);
    final skip = fftInterval - nzSampCount;
    return (skip, nzSampCount);
  }

  /// iq_frontend.cpp:76-97.
  void setSampleRate(double sampleRate) {
    _sampleRate = sampleRate;
    effectiveSr = _sampleRate / _decimRatio;
    dcBlock.setRate(genDCBlockRate(effectiveSr));
    for (final e in _vfoList) {
      e.vfo.setInSamplerate(effectiveSr);
    }
    updateFFTPath();
  }

  /// iq_frontend.cpp:99. See header: stored only.
  void setBuffering(bool enabled) {
    _buffering = enabled;
  }

  /// iq_frontend.cpp:103-122.
  void setDecimation(int ratio) {
    _decimRatio = ratio;
    if (_decimRatio > 1) {
      decim.setRatio(_decimRatio);
    }
    setSampleRate(_sampleRate);
    decim.reset();
    preproc.setBlockEnabled(decim, _decimRatio > 1);
    // Update the DSP sample rate (TODO: Find a way to get rid of this)
    coreSetInputSampleRate?.call(_sampleRate);
  }

  /// iq_frontend.cpp:124.
  void setDCBlocking(bool enabled) => preproc.setBlockEnabled(dcBlock, enabled);

  /// iq_frontend.cpp:128.
  void setInvertIQ(bool enabled) => preproc.setBlockEnabled(conj, enabled);

  /// iq_frontend.cpp:132 — raw IQ tap after preprocessing (C++ `split.bindStream`).
  void bindIQStream(VFOOutputHandler stream) => _iqStreams.add(stream);

  /// iq_frontend.cpp:136.
  void unbindIQStream(VFOOutputHandler stream) => _iqStreams.remove(stream);

  /// iq_frontend.cpp:140-160.
  RxVFO? addVFO(String name, double sampleRate, double bandwidth, double offset) {
    if (_vfos.containsKey(name)) {
      // flog::error("[IQFrontEnd] Tried to add VFO with existing name.")
      return null;
    }
    final vfo = RxVFO(effectiveSr, sampleRate, bandwidth, offset);
    _vfos[name] = _VFOEntry(vfo);
    _vfoList = _vfos.values.toList(growable: false);
    return vfo;
  }

  /// iq_frontend.cpp:162-183.
  void removeVFO(String name) {
    if (_vfos.remove(name) == null) {
      // flog::error("[IQFrontEnd] Tried to remove a VFO that doesn't exist.")
      return;
    }
    _vfoList = _vfos.values.toList(growable: false);
  }

  /// Binds the consumer of a VFO's output (C++: whatever reads `vfo->out`).
  void setVFOOutput(String name, VFOOutputHandler? handler) {
    final e = _vfos[name];
    if (e != null) e.handler = handler;
  }

  RxVFO? getVFO(String name) => _vfos[name]?.vfo;

  /// iq_frontend.cpp:185.
  void setFFTSize(int size) {
    _fftSize = size;
    updateFFTPath(true);
  }

  /// iq_frontend.cpp:190.
  void setFFTRate(double rate) {
    _fftRate = rate;
    updateFFTPath();
  }

  /// iq_frontend.cpp:195.
  void setFFTWindow(FFTWindow fftWindow) {
    _fftWindow = fftWindow;
    updateFFTPath();
  }

  /// iq_frontend.cpp:200 — clears partially accumulated data (C++ flushes the frame buffer).
  /// Called on play/stop (main_window.cpp:676-692).
  void flushInputBuffer() {
    reshape.reset();
  }

  /// Runs the frontend on one source block ([count] complex samples, interleaved in [iq]).
  /// Replaces the chain of block threads started by `IQFrontEnd::start()`.
  @pragma('vm:prefer-inline')
  void process(Float32List iq, int count) {
    if (count <= 0) return;
    samplesIn += count;
    final n2 = 2 * count;
    if (_work.length < n2) _work = growBuffer(_work, n2, 0);
    final work = _work;
    work.setRange(0, n2, iq);

    // Pre-processing (in place)
    final n = preproc.process(count, work);
    if (n <= 0) return;

    // Splitter: FFT branch. Background reception keeps only the audio VFO path.
    if (fftEnabled) reshape.process(n, work);

    // Splitter: raw IQ streams
    for (int i = 0; i < _iqStreams.length; i++) {
      _iqStreams[i](work, n);
    }

    // Splitter: VFOs
    final vfos = _vfoList;
    for (int i = 0; i < vfos.length; i++) {
      final e = vfos[i];
      final need = 2 * e.vfo.maxOutput(n);
      if (e.out.length < need) e.out = growBuffer(e.out, need, 0);
      final outCount = e.vfo.process(n, work, e.out);
      final h = e.handler;
      if (h != null && outCount > 0) h(e.out, outCount);
    }
  }

  /// iq_frontend.cpp:248-267.
  @pragma('vm:unsafe:no-bounds-checks')
  void _handler(Float32List data, int count) {
    final nz = _nzFFTSize;
    final win = fftWindowBuf;
    final fin = fftInBuf;
    // Apply window (volk_32fc_32f_multiply_32fc)
    for (int i = 0; i < nz; i++) {
      final w = win[i];
      fin[2 * i] = data[2 * i] * w;
      fin[2 * i + 1] = data[2 * i + 1] * w;
    }

    // Execute FFT
    _fftPlan!.execute(fin, fftOutBuf);
    fftFrames++;

    // Acquire buffer
    final acq = acquireFFTBuffer;
    final fftBuf = acq?.call(_fftSize);

    // Convert the complex output of the FFT to dB amplitude
    if (fftBuf != null) {
      powerSpectrum(fftBuf, fftOutBuf, _fftSize.toDouble(), _fftSize);
    }

    // Release buffer
    releaseFFTBuffer?.call(_fftSize);
  }

  /// `volk_32fc_s32f_power_spectrum_32f(out, in, normalizationFactor, num)`:
  /// `out[i] = 10·log10(|in[i]/norm|²)`. Floored at 1e-20 (see header).
  @pragma('vm:unsafe:no-bounds-checks')
  static void powerSpectrum(Float32List out, Float32List input, double normalizationFactor, int num) {
    final inv = 1.0 / normalizationFactor;
    const k = 10.0 / math.ln10; // 10·log10(x) = k·ln(x)
    for (int i = 0; i < num; i++) {
      final re = input[2 * i] * inv;
      final im = input[2 * i + 1] * inv;
      double p = re * re + im * im;
      if (p < 1e-20) p = 1e-20;
      out[i] = k * math.log(p);
    }
  }

  /// iq_frontend.cpp:269-309.
  void updateFFTPath([bool updateWaterfall = false]) {
    // Update reshaper settings
    final (skip, nz) = genReshapeParams(effectiveSr, _fftSize, _fftRate);
    _nzFFTSize = nz;
    reshape.setKeep(_nzFFTSize);
    reshape.setSkip(skip);

    // Update window
    fftWindowBuf = Float32List(_nzFFTSize);
    final nzD = _nzFFTSize.toDouble();
    for (int i = 0; i < _nzFFTSize; i++) {
      final double w;
      switch (_fftWindow) {
        case FFTWindow.rectangular:
          w = 1.0;
        case FFTWindow.blackman:
          w = blackman(i.toDouble(), nzD);
        case FFTWindow.nuttall:
          w = nuttall(i.toDouble(), nzD);
      }
      fftWindowBuf[i] = w * ((i % 2) != 0 ? -1.0 : 1.0);
    }

    // Update FFT plan
    fftInBuf = Float32List(2 * _fftSize);
    fftOutBuf = Float32List(2 * _fftSize);
    _fftPlan = FftPlan.get(_fftSize);

    // Clear the rest of the FFT input buffer (fresh Float32List is already zero)

    if (updateWaterfall) onFFTSizeChanged.emit(_fftSize);
  }
}

/// `IQFrontEnd::FFTWindow` (iq_frontend.h:17-21).
enum FFTWindow { rectangular, blackman, nuttall }
