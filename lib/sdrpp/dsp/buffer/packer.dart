// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/buffer/packer.h (@8c9f5ee, lines 1-72).
//
// Accumulates exactly `samples` items per output block (Android audio sink: 800 frames).
// The synchronous port calls [onBlock] for every full block instead of `out.swap(samples)`.
import 'dart:typed_data';

import '../types.dart';
import 'reshaper.dart' show BlockHandler;

export 'reshaper.dart' show BlockHandler;

class Packer {
  Packer(this.type, int count, this.onBlock) {
    setSampleCount(count);
  }

  final SampleType type;
  BlockHandler onBlock;
  int samples = 1;
  int _read = 0;
  late Float32List _out;

  void setSampleCount(int count) {
    samples = count;
    _out = Float32List(count * type.stride);
    _read = 0;
  }

  void reset() {
    _read = 0;
  }

  /// Feeds [count] samples; returns [count] like `run()`.
  int process(int count, Float32List input) {
    final st = type.stride;
    int i = 0;
    while (i < count) {
      int n = samples - _read;
      if (n > count - i) n = count - i;
      _out.setRange(_read * st, (_read + n) * st, input, i * st);
      _read += n;
      i += n;
      if (_read >= samples) {
        _read = 0;
        onBlock(_out, samples);
      }
    }
    return count;
  }
}
