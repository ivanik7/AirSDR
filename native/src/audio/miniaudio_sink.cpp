// SPDX-License-Identifier: GPL-3.0-or-later
//
// Desktop playback sink over the vendored miniaudio (CoreAudio on macOS,
// WASAPI on Windows, PulseAudio/ALSA on Linux, or the null backend for tests).
// Same real-time model as AAudioSink: write() pushes into a nonblocking SPSC
// PcmRing (kPlaybackRingFrames, 60 ms pre-roll, re-prime after an underflow)
// and the device callback pops from it without locks or allocation.
#include "miniaudio_sink.h"

#include "miniaudio_config.h"
#include "miniaudio.h"

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <memory>
#include <mutex>

#include "audio_internal.h"
#include "pcm_ring.h"

namespace sdrcore {
namespace {

class MiniaudioSink final : public AudioSink {
 public:
  explicit MiniaudioSink(std::string target) : null_backend_(target == "null") {}
  ~MiniaudioSink() override { close(); }
  const char* name() const override { return "miniaudio"; }

  int open(uint32_t sample_rate) override {
    if (!valid_sample_rate(sample_rate)) return kAudioInvalidArgument;
    close();
    ring_ = std::make_unique<PcmRing>(kPlaybackRingFrames, kPlaybackPrefillFrames);
    context_ = std::make_unique<ma_context>();
    const ma_backend null_only[] = {ma_backend_null};
    ma_context_config context_config = ma_context_config_init();
    if (ma_context_init(null_backend_ ? null_only : nullptr, null_backend_ ? 1 : 0,
                        &context_config, context_.get()) != MA_SUCCESS) {
      context_.reset();
      ring_.reset();
      return kAudioIoError;
    }
    // Request exactly the stream format the DSP produces. When the shared-mode
    // device runs at another rate/format (CoreAudio and WASAPI usually mix at
    // 44.1/48 kHz), miniaudio's data converter resamples inside the callback.
    ma_device_config config = ma_device_config_init(ma_device_type_playback);
    config.playback.format = ma_format_f32;
    config.playback.channels = 2;
    config.sampleRate = sample_rate;
    config.performanceProfile = ma_performance_profile_low_latency;
    config.periodSizeInMilliseconds = 10;
    config.dataCallback = &MiniaudioSink::data_callback;
    config.notificationCallback = &MiniaudioSink::notification_callback;
    config.pUserData = this;
    device_ = std::make_unique<ma_device>();
    closing_.store(false, std::memory_order_release);
    error_.store(0, std::memory_order_release);
    if (ma_device_init(context_.get(), &config, device_.get()) != MA_SUCCESS) {
      device_.reset();
      close();
      return kAudioIoError;
    }
    if (device_->playback.format != ma_format_f32 || device_->playback.channels != 2 ||
        device_->sampleRate != sample_rate) {
      close();
      return kAudioIoError;
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      stats_ = AudioSinkStats{};
      stats_.sample_rate = sample_rate;
    }
    if (ma_device_start(device_.get()) != MA_SUCCESS) {
      close();
      return kAudioIoError;
    }
    char device_name[256] = {0};
    ma_device_get_name(device_.get(), ma_device_type_playback, device_name,
                       sizeof(device_name), nullptr);
    std::fprintf(stderr,
                 "[sdrcore] miniaudio open: backend %s, device \"%s\", %u Hz "
                 "(device %u Hz, %u ch), period %u frames, ring %zu, pre-roll %zu\n",
                 ma_get_backend_name(context_->backend), device_name, sample_rate,
                 device_->playback.internalSampleRate,
                 device_->playback.internalChannels,
                 device_->playback.internalPeriodSizeInFrames, kPlaybackRingFrames,
                 kPlaybackPrefillFrames);
    return kAudioOk;
  }

  size_t write(const float* stereo, size_t frames) override {
    if (!stereo || closing_.load(std::memory_order_acquire) || !ring_) return 0;
    const size_t accepted = ring_->push(stereo, frames);
    std::lock_guard<std::mutex> lock(mutex_);
    for (size_t i = 0; i < accepted; ++i)
      update_level_stats(stats_, stereo[i * 2], stereo[i * 2 + 1]);
    stats_.frames_written += accepted;
    stats_.frames_dropped += frames - accepted;
    return accepted;
  }

  void close() override {
    closing_.store(true, std::memory_order_release);
    if (device_) {
      // Stops the device and joins its callback thread before the ring goes.
      ma_device_uninit(device_.get());
      device_.reset();
    }
    if (context_) {
      ma_context_uninit(context_.get());
      context_.reset();
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (ring_) refresh_ring_stats_locked();
    ring_.reset();
    stats_.sample_rate = 0;
  }

  AudioSinkStats stats() const override {
    std::lock_guard<std::mutex> lock(mutex_);
    AudioSinkStats copy = stats_;
    if (ring_) {
      const auto ring = ring_->stats();
      copy.underflows = ring.underflows;
      copy.zero_filled_frames = ring.zero_frames;
    }
    if (error_.load(std::memory_order_acquire) != 0) copy.last_error = kAudioIoError;
    return copy;
  }

 private:
  void refresh_ring_stats_locked() {
    const auto ring = ring_->stats();
    stats_.underflows = ring.underflows;
    stats_.zero_filled_frames = ring.zero_frames;
  }

  static void data_callback(ma_device* device, void* output, const void*,
                            ma_uint32 frames) {
    auto* self = static_cast<MiniaudioSink*>(device->pUserData);
    float* out = static_cast<float*>(output);
    if (self->closing_.load(std::memory_order_acquire) || !self->ring_) {
      std::fill_n(out, static_cast<size_t>(frames) * 2, 0.0f);
      return;
    }
    self->ring_->pop(out, static_cast<size_t>(frames));
  }

  static void notification_callback(const ma_device_notification* notification) {
    auto* self = static_cast<MiniaudioSink*>(notification->pDevice->pUserData);
    // A stop that close() did not request means the device was lost
    // (unplugged, default device removed, audio service restarted).
    if (notification->type == ma_device_notification_type_stopped &&
        !self->closing_.load(std::memory_order_acquire))
      self->error_.store(1, std::memory_order_release);
  }

  const bool null_backend_;
  std::unique_ptr<ma_context> context_;
  std::unique_ptr<ma_device> device_;
  std::unique_ptr<PcmRing> ring_;
  std::atomic<bool> closing_{true};
  std::atomic<int32_t> error_{0};
  mutable std::mutex mutex_;
  AudioSinkStats stats_;
};

}  // namespace

std::unique_ptr<AudioSink> make_miniaudio_sink(std::string target) {
  return std::make_unique<MiniaudioSink>(std::move(target));
}

}  // namespace sdrcore
