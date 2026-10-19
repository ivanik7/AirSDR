// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef SDRCORE_RECORD_AUDIO_ENCODER_H
#define SDRCORE_RECORD_AUDIO_ENCODER_H
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>

namespace sdrcore::record {
// Owned only by the recorder's writer thread. Callbacks write through the
// current output fd; no encoder work is done on the receiver/DSP thread.
class AudioEncoder {
 public:
  using Writer = std::function<bool(const uint8_t*, size_t)>;
  using Seeker = std::function<bool(uint64_t)>;
  using Teller = std::function<bool(uint64_t*)>;
  AudioEncoder(uint32_t format, uint32_t channels, uint32_t bitrate_kbps,
               Writer writer, Seeker seeker, Teller teller);
  ~AudioEncoder();
  AudioEncoder(const AudioEncoder&) = delete;
  AudioEncoder& operator=(const AudioEncoder&) = delete;
  bool begin();
  bool append(const float* interleaved, size_t frames);
  bool finish();
 private:
  struct Impl;
  std::unique_ptr<Impl> p_;
};
} // namespace sdrcore::record
#endif
