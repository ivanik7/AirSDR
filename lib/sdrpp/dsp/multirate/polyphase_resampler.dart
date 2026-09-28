// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/multirate/polyphase_resampler.h (@8c9f5ee, lines 1-128).
//
// process():
//   memcpy(bufStart, in, n)                      // bufStart = &buffer[tapsPerPhase − 1]
//   while (offset < n) {
//       out[k++] = dot(&buffer[offset], phases[phase], tapsPerPhase)
//       phase += decim; offset += phase / interp; phase %= interp;
//   }
//   offset −= n; memmove(buffer, &buffer[n], tapsPerPhase − 1)
import 'dart:typed_data';

import '../kernels/dot.dart';
import '../processor.dart';
import '../taps/taps.dart';
import 'polyphase_bank.dart';

class PolyphaseResampler extends ProcessorTT {
  PolyphaseResampler(this.type, int interp, int decim, Taps taps) {
    _interp = interp;
    _decim = decim;
    _taps = taps;
    phases = buildPolyphaseBank(_interp, _taps);
    _buffer = Float32List(simdAllocLen((phases.tapsPerPhase - 1 + 4096) * type.stride));
    _buf4 = Float32x4List.view(_buffer.buffer);
  }

  @override
  final SampleType type;
  late int _interp;
  late int _decim;
  late Taps _taps;
  late PolyphaseBank phases;
  int phase = 0;
  int offset = 0;
  late Float32List _buffer;
  late Float32x4List _buf4;

  int get interp => _interp;
  int get decim => _decim;
  Taps get taps => _taps;

  /// Upper bound of output samples for [count] input samples.
  int maxOutput(int count) => (count * _interp) ~/ _decim + 2;

  void setRatio(int interp, int decim, Taps taps) {
    _interp = interp;
    _decim = decim;
    _taps = taps;
    phases = buildPolyphaseBank(_interp, _taps);
    _ensureBuffer(phases.tapsPerPhase);
    reset();
  }

  @override
  void reset() {
    _buffer.fillRange(0, (phases.tapsPerPhase - 1) * type.stride, 0.0);
    phase = 0;
    offset = 0;
  }

  void _ensureBuffer(int samples) {
    final need = simdAllocLen(samples * type.stride);
    if (_buffer.length >= need) return;
    int len = _buffer.length;
    while (len < need) {
      len += len >> 1;
    }
    len = (len + 3) & ~3;
    final nb = Float32List(len);
    nb.setRange(0, _buffer.length, _buffer);
    _buffer = nb;
    _buf4 = Float32x4List.view(_buffer.buffer);
  }

  /// In-place (output == input) allowed; output needs room for [maxOutput] samples.
  @override
  @pragma('vm:unsafe:no-bounds-checks')
  int process(int count, Float32List input, Float32List output) {
    if (count <= 0) return 0;
    final st = type.stride;
    final tpp = phases.tapsPerPhase;
    final hist = tpp - 1;
    _ensureBuffer(hist + count);
    // Copy input to buffer
    _buffer.setRange(hist * st, (hist + count) * st, input);

    int outCount = 0;
    int ph = phase, off = offset;
    final interp = _interp, decim = _decim;
    final bank = phases.phases;
    final buf = _buffer;
    final simd = DspKernels.useSimd;
    if (type == SampleType.real) {
      final rr = simd ? phases.simdRR : null;
      while (off < count) {
        if (simd) {
          output[outCount++] = dotRRSimd(_buf4, off, rr![ph]);
        } else {
          output[outCount++] = _dotRRBank(buf, off, bank, ph * tpp, tpp);
        }
        ph += decim;
        off += ph ~/ interp;
        ph = ph % interp;
      }
    } else {
      final cr = simd ? phases.simdCR : null;
      while (off < count) {
        if (simd) {
          dotCRSimd(_buf4, off, cr![ph], output, outCount++);
        } else {
          _dotCRBank(buf, off, bank, ph * tpp, tpp, output, outCount++);
        }
        ph += decim;
        off += ph ~/ interp;
        ph = ph % interp;
      }
    }
    phase = ph;
    offset = off - count;

    // Move delay
    _buffer.setRange(0, hist * st, _buffer, count * st);
    return outCount;
  }

  @pragma('vm:prefer-inline')
  @pragma('vm:unsafe:no-bounds-checks')
  static double _dotRRBank(Float32List buf, int off, Float32List bank, int tOff, int n) {
    double s = 0;
    for (int k = 0; k < n; k++) {
      s += buf[off + k] * bank[tOff + k];
    }
    return s;
  }

  @pragma('vm:prefer-inline')
  @pragma('vm:unsafe:no-bounds-checks')
  static void _dotCRBank(Float32List buf, int cOff, Float32List bank, int tOff, int n, Float32List out, int o) {
    double re = 0, im = 0;
    int b = cOff * 2;
    for (int k = 0; k < n; k++) {
      final t = bank[tOff + k];
      re += buf[b] * t;
      im += buf[b + 1] * t;
      b += 2;
    }
    out[2 * o] = re;
    out[2 * o + 1] = im;
  }
}
