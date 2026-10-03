// SPDX-License-Identifier: GPL-3.0-or-later
#include "null_sink.h"

#include <mutex>

#include "audio_internal.h"

namespace sdrcore {
namespace {

// Discards every sample while tracking the same counters a real backend
// would (frames_written, nonsilent_frames, peak). Used for headless tests
// and as the default sink when no audio output is configured.
class NullSink final : public AudioSink {
 public:
  const char* name() const override { return "null"; }

  int open(uint32_t sample_rate) override {
    if (!valid_sample_rate(sample_rate)) return kAudioInvalidArgument;
    std::lock_guard<std::mutex> lock(mutex_);
    stats_ = AudioSinkStats{};
    stats_.sample_rate = sample_rate;
    open_ = true;
    return kAudioOk;
  }

  size_t write(const float* interleaved, size_t frames) override {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!open_ || frames == 0) return 0;
    for (size_t i = 0; i < frames; ++i) {
      update_level_stats(stats_, interleaved[2 * i], interleaved[2 * i + 1]);
    }
    stats_.frames_written += frames;
    return frames;
  }

  void close() override {
    std::lock_guard<std::mutex> lock(mutex_);
    open_ = false;
    stats_.sample_rate = 0;
  }

  AudioSinkStats stats() const override {
    std::lock_guard<std::mutex> lock(mutex_);
    return stats_;
  }

 private:
  mutable std::mutex mutex_;
  bool open_ = false;
  AudioSinkStats stats_;
};

}  // namespace

std::unique_ptr<AudioSink> make_null_sink() {
  return std::make_unique<NullSink>();
}

}  // namespace sdrcore
