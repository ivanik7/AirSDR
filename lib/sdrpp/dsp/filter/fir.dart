// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/filter/fir.h (@8c9f5ee, lines 1-101) and
// core/src/dsp/filter/decimating_fir.h (lines 1-91).
//
// FIR<D, T>: D = data type (float / complex_t / stereo_t), T = tap type (float / complex_t).
// `buffer` = (taps − 1) history samples + the input block; `bufStart = &buffer[taps − 1]`.
// process(): memcpy(bufStart, in, n); out[i] = dot(&buffer[i], taps, ntaps) — a *correlation*:
// the newest sample meets taps[last] (docs/02 §3.5, §6.6); memmove(buffer, &buffer[n], taps − 1).
//
// Dart: the history buffer grows on demand (instead of STREAM_BUFFER_SIZE + 64000) and the dot
// products use the kernels in kernels/dot.dart (Float32x4 when [DspKernels.useSimd]).
import 'dart:typed_data';

import '../kernels/dot.dart';
import '../processor.dart';
import '../taps/taps.dart';

class FIR extends ProcessorTT {
  /// [type]: data type D. [taps]: real (T = float) or complex (T = complex_t, only for
  /// complex/stereo data).
  FIR(this.type, Taps taps) {
    _setTapsInternal(taps);
    _buffer = Float32List(simdAllocLen((taps.size - 1 + 4096) * type.stride));
    _buf4 = Float32x4List.view(_buffer.buffer);
    // buffer::clear(buffer, taps.size - 1) — new list is already zero.
  }

  @override
  final SampleType type;

  late Taps _taps;
  late Float32List _buffer;
  late Float32x4List _buf4;
  TapsRR? _tapsRR;
  TapsCR? _tapsCR;
  TapsCC? _tapsCC;

  Taps get taps => _taps;

  void _setTapsInternal(Taps taps) {
    if (taps.isComplex && type == SampleType.real) {
      throw ArgumentError('FIR<float, complex_t> does not exist in SDR++');
    }
    _taps = taps;
    _tapsRR = null;
    _tapsCR = null;
    _tapsCC = null;
    if (type == SampleType.real) {
      _tapsRR = TapsRR(taps.taps);
    } else if (!taps.isComplex) {
      _tapsCR = TapsCR(taps.taps);
    } else {
      _tapsCC = TapsCC(taps.taps);
    }
  }

  /// fir.h:26 setTaps — keeps history continuity when the tap count changes.
  void setTaps(Taps taps) {
    final st = type.stride;
    final oldTC = _taps.size;
    _setTapsInternal(taps);
    final newTC = _taps.size;
    _ensureBuffer(newTC - 1 + 1);
    if (newTC < oldTC) {
      // memmove(buffer, &buffer[oldTC - newTC], (newTC - 1))
      _buffer.setRange(0, (newTC - 1) * st, _buffer, (oldTC - newTC) * st);
    } else if (newTC > oldTC) {
      // memmove(&buffer[newTC - oldTC], buffer, oldTC - 1); clear(buffer, newTC - oldTC)
      _buffer.setRange((newTC - oldTC) * st, (newTC - 1) * st, _buffer, 0);
      _buffer.fillRange(0, (newTC - oldTC) * st, 0.0);
    }
  }

  /// fir.h:54 reset — clears the history.
  @override
  void reset() {
    _buffer.fillRange(0, (_taps.size - 1) * type.stride, 0.0);
  }

  void _ensureBuffer(int samples) {
    final need = samples * type.stride;
    if (_buffer.length >= simdAllocLen(need)) return;
    int len = _buffer.length;
    while (len < simdAllocLen(need)) {
      len += len >> 1;
    }
    len = (len + 3) & ~3;
    final nb = Float32List(len);
    nb.setRange(0, _buffer.length, _buffer);
    _buffer = nb;
    _buf4 = Float32x4List.view(_buffer.buffer);
  }

  /// Copies the input block after the history (memcpy(bufStart, in, count)).
  void _load(int count, Float32List input) {
    final st = type.stride;
    final hist = _taps.size - 1;
    _ensureBuffer(hist + count);
    _buffer.setRange(hist * st, (hist + count) * st, input);
  }

  /// memmove(buffer, &buffer[count], taps − 1)
  void _shift(int count) {
    final st = type.stride;
    _buffer.setRange(0, (_taps.size - 1) * st, _buffer, count * st);
  }

  /// Computes outputs for buffer offsets start, start+step, … < count into out[0..].
  /// Returns the next offset (≥ count).
  @pragma('vm:unsafe:no-bounds-checks')
  int _filter(int start, int count, int step, Float32List out) {
    final buf = _buffer;
    final n = _taps.size;
    int o = 0;
    int off = start;
    if (type == SampleType.real) {
      if (DspKernels.useSimd) {
        final t = _tapsRR!;
        final b4 = _buf4;
        for (; off < count; off += step) {
          out[o++] = dotRRSimd(b4, off, t);
        }
      } else {
        final t = _taps.taps;
        for (; off < count; off += step) {
          out[o++] = dotRR(buf, off, t, n);
        }
      }
    } else if (!_taps.isComplex) {
      if (DspKernels.useSimd) {
        final t = _tapsCR!;
        final b4 = _buf4;
        for (; off < count; off += step) {
          dotCRSimd(b4, off, t, out, o++);
        }
      } else {
        final t = _taps.taps;
        for (; off < count; off += step) {
          dotCR(buf, off, t, n, out, o++);
        }
      }
    } else {
      if (DspKernels.useSimd) {
        final t = _tapsCC!;
        final b4 = _buf4;
        for (; off < count; off += step) {
          dotCCSimd(b4, off, t, out, o++);
        }
      } else {
        final t = _taps.taps;
        for (; off < count; off += step) {
          dotCC(buf, off, t, n, out, o++);
        }
      }
    }
    return off;
  }

  /// fir.h:62 process. In-place (output == input) allowed.
  @override
  int process(int count, Float32List input, Float32List output) {
    if (count <= 0) return 0;
    _load(count, input);
    _filter(0, count, 1, output);
    _shift(count);
    return count;
  }
}

/// decimating_fir.h:6 — `DecimatingFIR<D, T>`. The phase (`offset`) carries across blocks.
class DecimatingFIR extends FIR {
  DecimatingFIR(super.type, super.taps, int decimation) : _decimation = decimation;

  int _decimation;
  int offset = 0;

  int get decimation => _decimation;

  @override
  void setTaps(Taps taps) {
    offset = 0;
    super.setTaps(taps);
  }

  void setDecimation(int decimation) {
    _decimation = decimation;
    offset = 0;
  }

  @override
  void reset() {
    offset = 0;
    super.reset();
  }

  /// decimating_fir.h:45 process. Returns the number of output samples.
  /// In-place allowed (outputs never overtake the already-copied input).
  @override
  int process(int count, Float32List input, Float32List output) {
    if (count <= 0) return 0;
    _load(count, input);
    final start = offset;
    final end = _filter(start, count, _decimation, output);
    final outCount = (end - start) ~/ _decimation;
    offset = end - count;
    _shift(count);
    return outCount;
  }
}
