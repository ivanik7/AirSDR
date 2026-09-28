// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/dsp/audio/volume.h (@8c9f5ee, lines 1-60).
// out = in · (muted ? 0 : volume²)  (volk_32f_s32f_multiply_32f over 2·count floats).
import 'dart:typed_data';

import '../processor.dart';

class Volume extends ProcessorTT {
  Volume(double volume, bool muted) {
    setVolume(volume);
    _muted = muted;
  }

  @override
  SampleType get type => SampleType.stereo;

  final Float32List _f = Float32List(1);
  double _volume = 1;
  bool _muted = false;

  void setVolume(double volume) {
    _f[0] = volume * volume; // powf(volume, 2)
    _volume = _f[0];
  }

  void setMuted(bool muted) => _muted = muted;

  bool getMuted() => _muted;

  /// In-place allowed.
  @override
  @pragma('vm:unsafe:no-bounds-checks')
  int process(int count, Float32List input, Float32List output) {
    final g = _muted ? 0.0 : _volume;
    for (int i = 0; i < 2 * count; i++) {
      output[i] = input[i] * g;
    }
    return count;
  }
}
