// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/stream.h (@8c9f5ee, lines 1-152).
//
// C++ `stream<T>` is a blocking double buffer (swap/read/flush with two mutexes and condition
// variables) with STREAM_BUFFER_SIZE = 1 000 000 samples. In the single-isolate Dart graph an
// edge is just a buffer plus the number of valid samples (docs/02 §6.1 item 3). There is no
// locking; `swap` records the size, `read` returns it and `flush` clears it.
import 'dart:typed_data';

import 'types.dart';

/// STREAM_BUFFER_SIZE (stream.h:9). Kept for reference; Dart buffers are sized by the
/// maximum block size instead (docs/02 §1.2).
const int streamBufferSize = 1000000;

class DspStream {
  DspStream(this.type, int capacity) : writeBuf = Float32List(capacity * type.stride);

  final SampleType type;

  /// Buffer that the writer fills (C++ `writeBuf`; there is no separate `readBuf`).
  Float32List writeBuf;

  int _dataSize = 0;
  bool _dataReady = false;

  /// Capacity in samples.
  int get capacity => writeBuf.length ~/ type.stride;

  /// `setBufferSize(samples)`: reallocates (contents are lost).
  void setBufferSize(int samples) {
    writeBuf = Float32List(samples * type.stride);
  }

  /// Ensures room for [samples] samples, keeping the data.
  void ensureCapacity(int samples) {
    if (capacity >= samples) return;
    final nb = Float32List(samples * type.stride);
    nb.setRange(0, writeBuf.length, writeBuf);
    writeBuf = nb;
  }

  /// Writer: publish [size] samples. Always succeeds (no writer stop in the sync graph).
  bool swap(int size) {
    _dataSize = size;
    _dataReady = true;
    return true;
  }

  /// Reader: number of samples available, or 0 if none.
  int read() => _dataReady ? _dataSize : 0;

  /// Reader: mark the data consumed.
  void flush() {
    _dataReady = false;
  }

  /// View of the valid samples (as floats).
  Float32List get readBuf => writeBuf;
}
