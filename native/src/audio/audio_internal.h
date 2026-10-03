// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shared helpers for the audio sink backends (null/WAV/ALSA). Intentionally
// free of any dependency on native/include/sdrcore.h (see audio_sink.h); the
// error codes below are literal mirrors of the SdrResult values used there
// (SDR_INVALID_ARGUMENT = -1, SDR_IO_ERROR = -4) kept by convention.
#ifndef SDRCORE_AUDIO_INTERNAL_H
#define SDRCORE_AUDIO_INTERNAL_H

#include <algorithm>
#include <cmath>
#include <cstdint>

#include "audio_sink.h"

namespace sdrcore {

inline constexpr int kAudioOk = 0;
inline constexpr int kAudioInvalidArgument = -1;
inline constexpr int kAudioIoError = -4;

// Frame is "nonsilent" when either channel exceeds one LSB of 16-bit PCM.
inline constexpr float kSilenceThreshold = 1.0f / 32768.0f;

inline bool valid_sample_rate(uint32_t sample_rate) {
  return sample_rate >= 8000 && sample_rate <= 192000;
}

// Updates peak/nonsilent_frames in `stats` for one interleaved stereo frame.
// Shared by every backend so the "nonsilent" definition never drifts.
inline void update_level_stats(AudioSinkStats& stats, float l, float r) {
  const float peak_frame = std::max(std::fabs(l), std::fabs(r));
  if (peak_frame > stats.peak) stats.peak = peak_frame;
  if (std::fabs(l) > kSilenceThreshold || std::fabs(r) > kSilenceThreshold) {
    stats.nonsilent_frames++;
  }
}

// Converts a float sample in (roughly) [-1, 1] to signed 16-bit PCM with
// rounding to nearest and clipping to the full int16 range. Values outside
// [-1, 1] clip: +1.5 -> 32767, -1.5 -> -32768 (asymmetric int16 range; we use
// the full negative extreme rather than mirroring +32767, since nothing in
// the contract requires symmetric clipping and this preserves one more code
// point of headroom on the negative side).
inline int16_t float_to_s16(float x) {
  const float scaled = x * 32767.0f;
  long rounded = std::lround(scaled);
  if (rounded > 32767) rounded = 32767;
  if (rounded < -32768) rounded = -32768;
  return static_cast<int16_t>(rounded);
}

}  // namespace sdrcore

#endif  // SDRCORE_AUDIO_INTERNAL_H
