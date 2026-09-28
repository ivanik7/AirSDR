// SPDX-License-Identifier: GPL-3.0-or-later
// Audio output of the DSP isolate (replaces SDR++'s audio_sink / android_audio_sink modules).
//
// mp_audio_stream (pub, 0.3.0) was checked for background-isolate use:
//  * It is a pure `ffiPlugin` (no platform channel): the Dart side only does
//    `DynamicLibrary.open("libmp_audio_stream.so")` + lookups, so it works from any isolate.
//  * Native state is one process-global miniaudio context (`_ctx`); `ma_stream_push` writes a
//    single-producer/single-consumer ring buffer read by the miniaudio device thread, and
//    rejects (drops) the whole block when the ring is full — never blocks.
//  * BUT its Dart `push(Float32List)` calloc()s + element-copies + frees on every call, which
//    breaks the allocation-free hot path. [MpAudioStreamOutput] therefore binds the same three
//    exported C symbols itself (ma_stream_init / ma_stream_push / ma_stream_uninit) with one
//    persistent native buffer. The package stays a dependency because it builds and bundles
//    libmp_audio_stream.so for Android/Linux/Windows.
//  * On the host `flutter test` VM the library is not built; [MpAudioStreamOutput.tryCreate]
//    returns null and the engine falls back to [NullAudioOutput].
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../sdrpp/signal_path/sink_manager.dart';

/// Where the DSP isolate sends the final 48 kHz stereo audio.
abstract class AudioOutput {
  String get name;

  /// Opens the device (idempotent). Returns false on failure.
  bool open(int sampleRate);

  /// Pushes [frames] interleaved stereo frames. Must not block. Returns false if dropped.
  bool write(Float32List data, int frames);

  void close();

  /// Frames written / dropped (diagnostics).
  int framesWritten = 0;
  int framesDropped = 0;
}

/// Discards audio (host tests, no device).
class NullAudioOutput extends AudioOutput {
  @override
  String get name => 'null';
  @override
  bool open(int sampleRate) => true;
  @override
  bool write(Float32List data, int frames) {
    framesWritten += frames;
    return true;
  }

  @override
  void close() {}
}

/// Collects audio in memory (tests).
class CaptureAudioOutput extends AudioOutput {
  CaptureAudioOutput({this.maxFrames = 48000 * 10});
  final int maxFrames;
  final List<double> samples = <double>[];
  @override
  String get name => 'capture';
  @override
  bool open(int sampleRate) => true;
  @override
  bool write(Float32List data, int frames) {
    framesWritten += frames;
    final keep = maxFrames * 2 - samples.length;
    final n = 2 * frames < keep ? 2 * frames : keep;
    for (int i = 0; i < n; i++) {
      samples.add(data[i]);
    }
    return true;
  }

  @override
  void close() {}
}

typedef _InitC = Int64 Function(Int64, Int64, Int64, Int64, Int64);
typedef _InitD = int Function(int, int, int, int, int);
typedef _PushC = Int64 Function(Pointer<Float>, Int64);
typedef _PushD = int Function(Pointer<Float>, int);
typedef _VoidC = Void Function();
typedef _VoidD = void Function();

/// miniaudio output through libmp_audio_stream.so (see file header).
class MpAudioStreamOutput extends AudioOutput {
  MpAudioStreamOutput._(DynamicLibrary lib, {this.bufferMs = 400, this.waitingMs = 60})
      : _init = lib.lookupFunction<_InitC, _InitD>('ma_stream_init'),
        _push = lib.lookupFunction<_PushC, _PushD>('ma_stream_push'),
        _uninit = lib.lookupFunction<_VoidC, _VoidD>('ma_stream_uninit');

  /// Returns null if the native library is not available (host tests).
  static MpAudioStreamOutput? tryCreate({int bufferMs = 400, int waitingMs = 60}) {
    try {
      final DynamicLibrary lib;
      if (Platform.isLinux || Platform.isAndroid) {
        lib = DynamicLibrary.open('libmp_audio_stream.so');
      } else if (Platform.isWindows) {
        lib = DynamicLibrary.open('mp_audio_stream.dll');
      } else {
        lib = DynamicLibrary.executable();
      }
      return MpAudioStreamOutput._(lib, bufferMs: bufferMs, waitingMs: waitingMs);
    } catch (_) {
      return null;
    }
  }

  /// Ring buffer length (latency ceiling) and pre-roll before playback starts.
  final int bufferMs;
  final int waitingMs;

  final _InitD _init;
  final _PushD _push;
  final _VoidD _uninit;

  bool _open = false;
  Pointer<Float> _buf = nullptr;
  int _bufFloats = 0;

  @override
  String get name => 'mp_audio_stream';

  @override
  bool open(int sampleRate) {
    if (_open) return true;
    const ch = 2;
    final r = _init(ch * bufferMs * sampleRate ~/ 1000, ch * waitingMs * sampleRate ~/ 1000, ch, sampleRate, 1);
    _open = r == 0;
    return _open;
  }

  @override
  bool write(Float32List data, int frames) {
    if (!_open || frames <= 0) return false;
    final n = 2 * frames;
    if (_bufFloats < n) {
      if (_buf != nullptr) calloc.free(_buf);
      _bufFloats = n < 4096 ? 4096 : n;
      _buf = calloc<Float>(_bufFloats);
    }
    _buf.asTypedList(n).setRange(0, n, data);
    if (_push(_buf, n) == 0) {
      framesWritten += frames;
      return true;
    }
    framesDropped += frames;
    return false;
  }

  @override
  void close() {
    if (_open) {
      _uninit();
      _open = false;
    }
    if (_buf != nullptr) {
      calloc.free(_buf);
      _buf = nullptr;
      _bufFloats = 0;
    }
  }
}

/// SinkManager provider wrapping an [AudioOutput] ("Audio" sink, 48 kHz).
class AudioOutputSink extends Sink {
  AudioOutputSink(this.output, {this.sampleRate = 48000});
  final AudioOutput output;
  final int sampleRate;
  bool _running = false;

  /// `SinkProvider` factory.
  static SinkProvider provider(AudioOutput output, {int sampleRate = 48000}) {
    return (SinkStream stream, String name) {
      stream.setSampleRate(sampleRate.toDouble());
      return AudioOutputSink(output, sampleRate: sampleRate);
    };
  }

  @override
  void start() {
    if (_running) return;
    _running = output.open(sampleRate);
  }

  @override
  void stop() {
    _running = false;
  }

  @override
  void write(Float32List data, int count) {
    if (_running) output.write(data, count);
  }
}
