// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/buffer/buffer.h (lines 1-19) and ring_buffer.h (lines 1-259)
// (@8c9f5ee).
//
// The C++ RingBuffer is a blocking MPMC-ish ring (mutexes + condition variables, fixed
// RING_BUF_SZ = 1M, `maxLatency` limits the writable amount). In the single-isolate graph
// nothing may block, so this port is a non-blocking ring with the same `maxLatency`
// semantics: `write` stores as much as fits and returns the stored count, `read` returns what
// is available. `readAndSkip` fails (returns 0) instead of blocking if not enough data.
import 'dart:typed_data';

import '../types.dart';

/// buffer::clear(buffer, count, offset) — clears [count] samples of [stride] floats.
void bufferClear(Float32List buf, int count, {int offset = 0, int stride = 1}) {
  buf.fillRange(offset * stride, (offset + count) * stride, 0.0);
}

/// RING_BUF_SZ
const int ringBufSz = 1000000;

class RingBuffer {
  /// [maxLatency] in samples; [size] is the storage capacity (defaults to 2·maxLatency, the
  /// C++ uses a fixed 1M which only matters when maxLatency > 1M).
  RingBuffer(this.type, int maxLatency, {int? size}) {
    init(maxLatency, size: size);
  }

  final SampleType type;
  late Float32List _buffer;
  late int size;
  int readc = 0;
  int writec = 0;
  int readable = 0;
  int writable = 0;
  late int maxLatency;

  void init(int maxLatency, {int? size}) {
    this.size = size ?? (maxLatency < 1 ? 1 : maxLatency * 2);
    this.maxLatency = maxLatency;
    writec = 0;
    readc = 0;
    readable = 0;
    writable = this.size;
    _buffer = Float32List(this.size * type.stride);
  }

  int getReadable() => readable;

  /// C++ getWritable(): max(min(writable, maxLatency - readable), 0).
  int getWritable() {
    final w = writable < maxLatency - readable ? writable : maxLatency - readable;
    return w > 0 ? w : 0;
  }

  void setMaxLatency(int maxLatency) {
    this.maxLatency = maxLatency;
    if (maxLatency > size) {
      // Grow storage keeping contents in order.
      final st = type.stride;
      final nb = Float32List(maxLatency * 2 * st);
      final n = readable;
      _copyOut(nb, 0, n);
      _buffer = nb;
      size = maxLatency * 2;
      readc = 0;
      writec = n;
      writable = size - n;
    }
  }

  void _copyOut(Float32List dst, int dstOff, int n) {
    final st = type.stride;
    final first = (readc + n > size) ? size - readc : n;
    dst.setRange(dstOff * st, (dstOff + first) * st, _buffer, readc * st);
    if (first < n) {
      dst.setRange((dstOff + first) * st, (dstOff + n) * st, _buffer, 0);
    }
  }

  /// Writes up to [len] samples from [data] starting at sample [offset]. Returns the count
  /// written (less than [len] when the latency limit is reached).
  int write(Float32List data, int len, {int offset = 0}) {
    final st = type.stride;
    int toWrite = getWritable();
    if (toWrite > len) toWrite = len;
    final first = (writec + toWrite > size) ? size - writec : toWrite;
    _buffer.setRange(writec * st, (writec + first) * st, data, offset * st);
    if (first < toWrite) {
      _buffer.setRange(0, (toWrite - first) * st, data, (offset + first) * st);
    }
    readable += toWrite;
    writable -= toWrite;
    writec = (writec + toWrite) % size;
    return toWrite;
  }

  /// Reads up to [len] samples into [data] at sample [offset]. Returns the count read.
  int read(Float32List data, int len, {int offset = 0}) {
    int toRead = readable < len ? readable : len;
    _copyOut(data, offset, toRead);
    _consume(toRead);
    return toRead;
  }

  /// Reads exactly [len] samples then drops [skip] samples. Returns [len] on success or 0
  /// (nothing consumed) if fewer than len + skip samples are buffered.
  int readAndSkip(Float32List data, int len, int skip, {int offset = 0}) {
    if (readable < len + skip) return 0;
    _copyOut(data, offset, len);
    _consume(len + skip);
    return len;
  }

  void _consume(int n) {
    readable -= n;
    writable += n;
    readc = (readc + n) % size;
  }
}
