// SPDX-License-Identifier: GPL-3.0-or-later
//
// ALSA playback backend. Only compiled when audio.cmake finds ALSA on a
// non-Android build (SDRCORE_HAVE_ALSA). Never blocks the producer: a full
// device buffer or any I/O error drops the block and is counted/reported,
// not retried in a loop (except the one documented -EPIPE recovery retry).
#include "alsa_sink.h"

#include <alsa/asoundlib.h>

#include <mutex>
#include <vector>

#include "audio_internal.h"

namespace sdrcore {
namespace {

constexpr unsigned int kChannels = 2;
constexpr unsigned int kLatencyUs = 100000;  // ~100 ms buffer.

class AlsaSink final : public AudioSink {
 public:
  explicit AlsaSink(std::string pcm_name) : pcm_name_(std::move(pcm_name)) {}
  ~AlsaSink() override { close(); }

  const char* name() const override { return "alsa"; }

  int open(uint32_t sample_rate) override {
    if (!valid_sample_rate(sample_rate)) return kAudioInvalidArgument;
    std::lock_guard<std::mutex> lock(mutex_);
    close_locked();
    stats_ = AudioSinkStats{};

    int err = snd_pcm_open(&pcm_, pcm_name_.c_str(), SND_PCM_STREAM_PLAYBACK,
                            SND_PCM_NONBLOCK);
    if (err < 0) {
      pcm_ = nullptr;
      stats_.last_error = kAudioIoError;
      return kAudioIoError;
    }
    err = snd_pcm_set_params(pcm_, SND_PCM_FORMAT_S16_LE,
                              SND_PCM_ACCESS_RW_INTERLEAVED, kChannels,
                              sample_rate, /*soft_resample=*/1, kLatencyUs);
    if (err < 0) {
      snd_pcm_close(pcm_);
      pcm_ = nullptr;
      stats_.last_error = kAudioIoError;
      return kAudioIoError;
    }
    stats_.sample_rate = sample_rate;
    return kAudioOk;
  }

  size_t write(const float* interleaved, size_t frames) override {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!pcm_ || frames == 0) return 0;

    if (buffer_.size() < frames * kChannels) {
      buffer_.resize(frames * kChannels);
    }
    for (size_t i = 0; i < frames; ++i) {
      const float l = interleaved[2 * i];
      const float r = interleaved[2 * i + 1];
      update_level_stats(stats_, l, r);
      buffer_[2 * i] = float_to_s16(l);
      buffer_[2 * i + 1] = float_to_s16(r);
    }

    snd_pcm_sframes_t written =
        snd_pcm_writei(pcm_, buffer_.data(), frames);
    if (written == -EPIPE) {
      // Underrun: recover once and retry; otherwise drop the whole block.
      snd_pcm_prepare(pcm_);
      written = snd_pcm_writei(pcm_, buffer_.data(), frames);
    }
    if (written < 0) {
      // -EAGAIN (device buffer full, non-blocking) or any other error:
      // never block the producer, count the block as dropped.
      stats_.frames_dropped += frames;
      if (written != -EAGAIN) stats_.last_error = kAudioIoError;
      return 0;
    }
    const size_t accepted = static_cast<size_t>(written);
    if (accepted < frames) stats_.frames_dropped += (frames - accepted);
    stats_.frames_written += accepted;
    return accepted;
  }

  void close() override {
    std::lock_guard<std::mutex> lock(mutex_);
    close_locked();
  }

  AudioSinkStats stats() const override {
    std::lock_guard<std::mutex> lock(mutex_);
    return stats_;
  }

 private:
  void close_locked() {
    if (pcm_) {
      snd_pcm_drop(pcm_);
      snd_pcm_close(pcm_);
      pcm_ = nullptr;
    }
    stats_.sample_rate = 0;
  }

  std::string pcm_name_;
  mutable std::mutex mutex_;
  snd_pcm_t* pcm_ = nullptr;
  std::vector<int16_t> buffer_;
  AudioSinkStats stats_;
};

}  // namespace

std::unique_ptr<AudioSink> make_alsa_sink(std::string pcm_name) {
  return std::make_unique<AlsaSink>(std::move(pcm_name));
}

}  // namespace sdrcore
