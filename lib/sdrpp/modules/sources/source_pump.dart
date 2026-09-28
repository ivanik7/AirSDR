// SPDX-License-Identifier: GPL-3.0-or-later
// Block pacing shared by the file and synthetic sources.
//
// Replaces the C++ source worker threads (file_source/src/main.cpp:154-181): a worker fills a
// block of `sampleRate / 200` samples (≤ STREAM_BUFFER_SIZE) and `stream.swap`s it; the
// downstream blocking stream paces it (file source: as fast as the DSP consumes it, throttled
// by the audio sink). A Dart isolate has no blocking streams, so the pump runs either:
//  * [PumpMode.realTime]: a periodic Timer pushes the blocks that are due according to a
//    Stopwatch (wall clock). A stall longer than [maxCatchUp] is dropped rather than replayed.
//  * [PumpMode.asFastAsPossible]: pushes [burstBlocks] blocks per event-loop turn (yields to
//    the isolate's message queue between bursts) — for tests and benchmarks.
//  * [PumpMode.manual]: nothing is scheduled; the owner calls [SourcePump.pump] (synchronous,
//    deterministic — unit tests).
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../signal_path/source_handler.dart';

enum PumpMode { realTime, asFastAsPossible, manual }

/// Fills [count] complex samples (interleaved) into [buf].
typedef BlockFiller = void Function(Float32List buf, int count);

/// `STREAM_BUFFER_SIZE` (core/src/dsp/stream.h:8).
const int streamBufferSize = 1000000;

class SourcePump {
  SourcePump(this.fill,
      {required double sampleRate,
      this.mode = PumpMode.realTime,
      this.tick = const Duration(milliseconds: 10),
      this.burstBlocks = 4,
      this.maxCatchUp = const Duration(milliseconds: 250)}) {
    setSampleRate(sampleRate);
  }

  final BlockFiller fill;
  PumpMode mode;
  final Duration tick;
  final int burstBlocks;
  final Duration maxCatchUp;

  double _sampleRate = 1;
  int _blockSize = 1;
  Float32List _buf = Float32List(2);

  SourceSink? _sink;
  Timer? _timer;
  final Stopwatch _clock = Stopwatch();
  int _sent = 0; // samples sent since start (real-time accounting)
  int _gen = 0; // bumps on stop, cancels pending async loops

  /// Total samples pushed (diagnostics / tests).
  int samplesPushed = 0;

  /// Samples skipped by the real-time pacer after a stall.
  int samplesDropped = 0;

  bool get running => _sink != null;
  int get blockSize => _blockSize;
  double get sampleRate => _sampleRate;

  /// C++: `blockSize = min(sampleRate / 200, STREAM_BUFFER_SIZE)`.
  void setSampleRate(double sampleRate) {
    _sampleRate = math.max(sampleRate, 1);
    _blockSize = math.max(1, math.min((_sampleRate / 200.0).floor(), streamBufferSize));
    if (_buf.length < 2 * _blockSize) _buf = Float32List(2 * _blockSize);
    _sent = 0;
    _clock
      ..reset()
      ..start();
  }

  void start(SourceSink sink) {
    if (_sink != null) return;
    _sink = sink;
    _sent = 0;
    _clock
      ..reset()
      ..start();
    final gen = ++_gen;
    switch (mode) {
      case PumpMode.realTime:
        _timer = Timer.periodic(tick, (_) => _onTick());
      case PumpMode.asFastAsPossible:
        _fastLoop(gen);
      case PumpMode.manual:
        break;
    }
  }

  void stop() {
    _gen++;
    _timer?.cancel();
    _timer = null;
    _sink = null;
    _clock.stop();
  }

  /// Pushes [blocks] blocks synchronously. Returns the number of samples pushed.
  int pump([int blocks = 1]) {
    final sink = _sink;
    if (sink == null) return 0;
    int total = 0;
    for (int b = 0; b < blocks; b++) {
      if (!identical(_sink, sink)) break;
      total += _pushBlock(sink, _blockSize);
    }
    return total;
  }

  int _pushBlock(SourceSink sink, int n) {
    fill(_buf, n);
    samplesPushed += n;
    _sent += n;
    sink(_buf, n);
    return n;
  }

  void _onTick() {
    final sink = _sink;
    if (sink == null) return;
    final due = (_clock.elapsedMicroseconds * _sampleRate / 1e6).floor();
    int behind = due - _sent;
    final maxBehind = (maxCatchUp.inMicroseconds * _sampleRate / 1e6).floor();
    if (behind > maxBehind) {
      // Stall (GC, device busy…): skip the backlog instead of bursting it.
      samplesDropped += behind - _blockSize;
      _sent = due - _blockSize;
      behind = _blockSize;
    }
    while (behind >= _blockSize && identical(_sink, sink)) {
      _pushBlock(sink, _blockSize);
      behind -= _blockSize;
    }
  }

  Future<void> _fastLoop(int gen) async {
    while (gen == _gen) {
      final sink = _sink;
      if (sink == null) return;
      for (int i = 0; i < burstBlocks && gen == _gen; i++) {
        _pushBlock(sink, _blockSize);
      }
      // Yield to the event loop (control messages, timers).
      await Future<void>.delayed(Duration.zero);
    }
  }
}
