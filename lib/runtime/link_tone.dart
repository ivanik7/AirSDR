// SPDX-License-Identifier: GPL-3.0-or-later
// USB link earcons: generated only in the DSP isolate, outside the radio audio hot path.
import 'dart:math' as math;
import 'dart:typed_data';

import 'audio_output.dart';

enum LinkToneKind { disconnected, reconnected }

class LinkTone {
  static const sampleRate = 48000;
  static const frames = 5760; // 120 ms
  static const fadeFrames = 384; // 8 ms
  static const _level = 0.18;

  final Float32List _buffer = Float32List(frames * 2);

  /// The output is the same 48 kHz stereo device as the radio. The caller owns its lifetime.
  /// Volume follows SinkStream's squared volume curve; the amplitude stays below full scale.
  bool play(AudioOutput output, LinkToneKind kind, double volume) {
    final frequency = kind == LinkToneKind.disconnected ? 440 : 880;
    final gain = _level * volume.clamp(0.0, 1.0) * volume.clamp(0.0, 1.0);
    for (var i = 0; i < frames; i++) {
      final fade = math.min(
        1.0,
        math.min(i / fadeFrames, (frames - 1 - i) / fadeFrames),
      );
      final sample =
          gain * fade * math.sin(2 * math.pi * frequency * i / sampleRate);
      _buffer[2 * i] = sample;
      _buffer[2 * i + 1] = sample;
    }
    return output.write(_buffer, frames);
  }
}
