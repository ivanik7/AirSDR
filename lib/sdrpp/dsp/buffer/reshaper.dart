// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/buffer/reshaper.h (@8c9f5ee, lines 1-152).
//
// Re-chunks a stream into blocks of `keep` samples, dropping `skip` samples between blocks.
// A negative skip means overlap; in that case the C++ divides the overlapped (re-used)
// samples by 10 for complex/stereo (reshaper.h:114-121) — preserved here.
//
// C++ uses two threads and a blocking RingBuffer(maxLatency = 2·keep). The synchronous port
// accumulates internally and calls [onBlock] for every complete block. Output data is
// identical; the only difference is that a block is emitted as soon as its `keep` samples are
// available instead of after the following `skip` samples have also arrived (lower latency).
// Unlike the blocking C++ ring (which applies backpressure to the writer), the sync version
// never drops input.
import 'dart:typed_data';

import '../types.dart';

typedef BlockHandler = void Function(Float32List data, int count);

class Reshaper {
  Reshaper(this.type, int keep, int skip, this.onBlock) {
    _keep = keep;
    _skip = skip;
    _configure();
  }

  final SampleType type;
  BlockHandler onBlock;

  late int _keep;
  late int _skip;
  late Float32List _buf;
  late bool _delay;
  late int _readCount;
  late int _skipCount;
  late int _startIdx;
  late int _delayCount;

  // Progress of the current cycle
  int _filled = 0; // samples written at _startIdx in this cycle
  int _skipped = 0; // samples skipped in this cycle
  bool _needPrep = true; // run the delay memmove at the start of the cycle

  int get keep => _keep;
  int get skip => _skip;

  void setKeep(int keep) {
    _keep = keep;
    _configure();
  }

  void setSkip(int skip) {
    _skip = skip;
    _configure();
  }

  /// Clears partially accumulated data.
  void reset() => _configure();

  void _configure() {
    final st = type.stride;
    _buf = Float32List(_keep * st);
    _delay = _skip < 0;
    _readCount = (_keep + _skip) < _keep ? _keep + _skip : _keep;
    _skipCount = _skip > 0 ? _skip : 0;
    _delayCount = -_skip;
    _startIdx = (-_skip) > 0 ? -_skip : 0;
    _filled = 0;
    _skipped = 0;
    _needPrep = true;
  }

  /// Feeds [count] samples.
  void process(int count, Float32List input) {
    final st = type.stride;
    int i = 0;
    while (i < count) {
      if (_needPrep) {
        if (_delay) {
          // memmove(buf, delayStart = &buf[keep + skip], delaySize)
          final ds = (_keep + _skip) * st;
          _buf.setRange(0, _delayCount * st, _buf, ds);
          if (type != SampleType.real) {
            for (int k = 0; k < _delayCount * st; k++) {
              _buf[k] /= 10.0;
            }
          }
        }
        _needPrep = false;
      }
      if (_filled < _readCount) {
        int n = _readCount - _filled;
        if (n > count - i) n = count - i;
        _buf.setRange((_startIdx + _filled) * st, (_startIdx + _filled + n) * st, input, i * st);
        _filled += n;
        i += n;
        if (_filled == _readCount) {
          onBlock(_buf, _keep);
        }
        continue;
      }
      if (_skipped < _skipCount) {
        int n = _skipCount - _skipped;
        if (n > count - i) n = count - i;
        _skipped += n;
        i += n;
      }
      if (_skipped >= _skipCount) {
        _filled = 0;
        _skipped = 0;
        _needPrep = true;
      }
    }
    // A cycle with skip == 0 completes right after the block.
    if (_filled == _readCount && _skipped >= _skipCount) {
      _filled = 0;
      _skipped = 0;
      _needPrep = true;
    }
  }
}
