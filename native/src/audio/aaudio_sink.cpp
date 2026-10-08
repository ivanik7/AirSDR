// SPDX-License-Identifier: GPL-3.0-or-later
#include "aaudio_sink.h"

#include <aaudio/AAudio.h>
#include <android/log.h>
#include <dlfcn.h>

#include <atomic>
#include <algorithm>
#include <chrono>
#include <memory>
#include <mutex>

#include "audio_internal.h"
#include "pcm_ring.h"

namespace sdrcore {
namespace {

// The app supports API 24/25. Never link libaaudio.so as DT_NEEDED: it does
// not exist before API 26, and would prevent the entire core from loading.
struct Api {
  void* library = nullptr;
#define FN(ret, name, ...) ret (*name)(__VA_ARGS__) = nullptr
  FN(aaudio_result_t, AAudio_createStreamBuilder, AAudioStreamBuilder**);
  FN(aaudio_result_t, AAudioStreamBuilder_delete, AAudioStreamBuilder*);
  FN(void, AAudioStreamBuilder_setDirection, AAudioStreamBuilder*, aaudio_direction_t);
  FN(void, AAudioStreamBuilder_setSampleRate, AAudioStreamBuilder*, int32_t);
  FN(void, AAudioStreamBuilder_setChannelCount, AAudioStreamBuilder*, int32_t);
  FN(void, AAudioStreamBuilder_setFormat, AAudioStreamBuilder*, aaudio_format_t);
  FN(void, AAudioStreamBuilder_setPerformanceMode, AAudioStreamBuilder*, aaudio_performance_mode_t);
  FN(void, AAudioStreamBuilder_setDataCallback, AAudioStreamBuilder*, AAudioStream_dataCallback, void*);
  FN(void, AAudioStreamBuilder_setErrorCallback, AAudioStreamBuilder*, AAudioStream_errorCallback, void*);
  FN(aaudio_result_t, AAudioStreamBuilder_openStream, AAudioStreamBuilder*, AAudioStream**);
  FN(int32_t, AAudioStream_getSampleRate, AAudioStream*);
  FN(int32_t, AAudioStream_getChannelCount, AAudioStream*);
  FN(aaudio_format_t, AAudioStream_getFormat, AAudioStream*);
  FN(aaudio_result_t, AAudioStream_requestStart, AAudioStream*);
  FN(aaudio_result_t, AAudioStream_requestStop, AAudioStream*);
  FN(aaudio_result_t, AAudioStream_close, AAudioStream*);
  // Optional diagnostics; the sink works without them.
  FN(int32_t, AAudioStream_getXRunCount, AAudioStream*);
  FN(int32_t, AAudioStream_getFramesPerBurst, AAudioStream*);
  FN(int32_t, AAudioStream_getBufferSizeInFrames, AAudioStream*);
#undef FN

  Api() {
    library = dlopen("libaaudio.so", RTLD_NOW | RTLD_LOCAL);
    if (!library) return;
#define RESOLVE(name) name = reinterpret_cast<decltype(name)>(dlsym(library, #name)); if (!name) return
    RESOLVE(AAudio_createStreamBuilder);
    RESOLVE(AAudioStreamBuilder_delete);
    RESOLVE(AAudioStreamBuilder_setDirection);
    RESOLVE(AAudioStreamBuilder_setSampleRate);
    RESOLVE(AAudioStreamBuilder_setChannelCount);
    RESOLVE(AAudioStreamBuilder_setFormat);
    RESOLVE(AAudioStreamBuilder_setPerformanceMode);
    RESOLVE(AAudioStreamBuilder_setDataCallback);
    RESOLVE(AAudioStreamBuilder_setErrorCallback);
    RESOLVE(AAudioStreamBuilder_openStream);
    RESOLVE(AAudioStream_getSampleRate);
    RESOLVE(AAudioStream_getChannelCount);
    RESOLVE(AAudioStream_getFormat);
    RESOLVE(AAudioStream_requestStart);
    RESOLVE(AAudioStream_requestStop);
    RESOLVE(AAudioStream_close);
#undef RESOLVE
    AAudioStream_getXRunCount = reinterpret_cast<decltype(AAudioStream_getXRunCount)>(
        dlsym(library, "AAudioStream_getXRunCount"));
    AAudioStream_getFramesPerBurst = reinterpret_cast<decltype(AAudioStream_getFramesPerBurst)>(
        dlsym(library, "AAudioStream_getFramesPerBurst"));
    AAudioStream_getBufferSizeInFrames =
        reinterpret_cast<decltype(AAudioStream_getBufferSizeInFrames)>(
            dlsym(library, "AAudioStream_getBufferSizeInFrames"));
  }
  ~Api() { if (library) dlclose(library); }
  bool available() const { return AAudioStream_close != nullptr; }
};

Api& api() {
  static Api instance;
  return instance;
}

class AAudioSink final : public AudioSink {
 public:
  ~AAudioSink() override { close(); }
  const char* name() const override { return "aaudio"; }

  int open(uint32_t sample_rate) override {
    if (!valid_sample_rate(sample_rate)) return kAudioInvalidArgument;
    close();
    auto& a = api();
    if (!a.available()) return kAudioIoError;
    // ~340 ms capacity, 60 ms pre-roll and re-prime after an underflow.
    ring_ = std::make_unique<PcmRing>(kPlaybackRingFrames, kPlaybackPrefillFrames);
    AAudioStreamBuilder* builder = nullptr;
    if (a.AAudio_createStreamBuilder(&builder) != AAUDIO_OK) {
      ring_.reset();
      return kAudioIoError;
    }
    a.AAudioStreamBuilder_setDirection(builder, AAUDIO_DIRECTION_OUTPUT);
    a.AAudioStreamBuilder_setSampleRate(builder, static_cast<int32_t>(sample_rate));
    a.AAudioStreamBuilder_setChannelCount(builder, 2);
    a.AAudioStreamBuilder_setFormat(builder, AAUDIO_FORMAT_PCM_FLOAT);
    a.AAudioStreamBuilder_setPerformanceMode(builder, AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);
    a.AAudioStreamBuilder_setDataCallback(builder, dataCallback, this);
    a.AAudioStreamBuilder_setErrorCallback(builder, errorCallback, this);
    const auto result = a.AAudioStreamBuilder_openStream(builder, &stream_);
    a.AAudioStreamBuilder_delete(builder);
    if (result != AAUDIO_OK || !stream_) {
      stream_ = nullptr;
      ring_.reset();
      return kAudioIoError;
    }
    if (a.AAudioStream_getSampleRate(stream_) != static_cast<int32_t>(sample_rate) ||
        a.AAudioStream_getChannelCount(stream_) != 2 ||
        a.AAudioStream_getFormat(stream_) != AAUDIO_FORMAT_PCM_FLOAT) {
      close();
      return kAudioIoError;
    }
    closing_.store(false, std::memory_order_release);
    error_.store(0, std::memory_order_release);
    if (a.AAudioStream_requestStart(stream_) != AAUDIO_OK) {
      close();
      return kAudioIoError;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    stats_ = AudioSinkStats{};
    stats_.sample_rate = sample_rate;
    last_log_ = std::chrono::steady_clock::now();
    logged_underflows_ = 0;
    logged_xruns_ = 0;
    min_queued_ = ~size_t{0};
    if (a.AAudioStream_getFramesPerBurst && a.AAudioStream_getBufferSizeInFrames)
      __android_log_print(ANDROID_LOG_INFO, "sdrcore",
                          "aaudio open: burst %d frames, device buffer %d frames, "
                          "ring %zu, pre-roll %zu",
                          a.AAudioStream_getFramesPerBurst(stream_),
                          a.AAudioStream_getBufferSizeInFrames(stream_), kPlaybackRingFrames,
                          kPlaybackPrefillFrames);
    return kAudioOk;
  }

  size_t write(const float* stereo, size_t frames) override {
    if (!stereo || closing_.load(std::memory_order_acquire) || !ring_) return 0;
    const size_t before = ring_->queued();
    const size_t accepted = ring_->push(stereo, frames);
    std::lock_guard<std::mutex> lock(mutex_);
    for (size_t i = 0; i < accepted; ++i)
      update_level_stats(stats_, stereo[i * 2], stereo[i * 2 + 1]);
    stats_.frames_written += accepted;
    stats_.frames_dropped += frames - accepted;
    min_queued_ = std::min(min_queued_, before);
    refresh_realtime_stats_locked();
    const auto now = std::chrono::steady_clock::now();
    if (now - last_log_ >= std::chrono::seconds(1)) {
      // Once a second, only when something went wrong or worth tracking:
      // the lowest ring level seen just before a push is the jitter margin.
      if (stats_.underflows != logged_underflows_ || stats_.xruns != logged_xruns_ ||
          min_queued_ < kPlaybackPrefillFrames / 2)
        __android_log_print(ANDROID_LOG_INFO, "sdrcore",
                            "aaudio: underflows %llu (+%llu), zero-filled %llu frames, "
                            "xruns %d, min ring level %zu frames",
                            static_cast<unsigned long long>(stats_.underflows),
                            static_cast<unsigned long long>(stats_.underflows - logged_underflows_),
                            static_cast<unsigned long long>(stats_.zero_filled_frames),
                            stats_.xruns, min_queued_);
      logged_underflows_ = stats_.underflows;
      logged_xruns_ = stats_.xruns;
      min_queued_ = ~size_t{0};
      last_log_ = now;
    }
    return accepted;
  }

  void close() override {
    closing_.store(true, std::memory_order_release);
    if (stream_) {
      api().AAudioStream_requestStop(stream_);
      // close waits for the callback to exit before the ring can be destroyed.
      api().AAudioStream_close(stream_);
      stream_ = nullptr;
    }
    ring_.reset();
    std::lock_guard<std::mutex> lock(mutex_);
    stats_.sample_rate = 0;
  }

  AudioSinkStats stats() const override {
    std::lock_guard<std::mutex> lock(mutex_);
    AudioSinkStats copy = stats_;
    if (error_.load(std::memory_order_acquire) != 0) copy.last_error = kAudioIoError;
    return copy;
  }

 private:
  void refresh_realtime_stats_locked() {
    const auto ring = ring_->stats();
    stats_.underflows = ring.underflows;
    stats_.zero_filled_frames = ring.zero_frames;
    if (stream_ && api().AAudioStream_getXRunCount) {
      const int32_t xruns = api().AAudioStream_getXRunCount(stream_);
      if (xruns >= 0) stats_.xruns = xruns;
    }
  }
  static aaudio_data_callback_result_t dataCallback(AAudioStream*, void* user,
                                                     void* data, int32_t frames) {
    auto* self = static_cast<AAudioSink*>(user);
    if (self->closing_.load(std::memory_order_acquire)) {
      std::fill_n(static_cast<float*>(data), static_cast<size_t>(frames) * 2, 0.0f);
      return AAUDIO_CALLBACK_RESULT_STOP;
    }
    self->ring_->pop(static_cast<float*>(data), static_cast<size_t>(frames));
    return AAUDIO_CALLBACK_RESULT_CONTINUE;
  }
  static void errorCallback(AAudioStream*, void* user, aaudio_result_t error) {
    static_cast<AAudioSink*>(user)->error_.store(error, std::memory_order_release);
  }

  AAudioStream* stream_ = nullptr;
  std::unique_ptr<PcmRing> ring_;
  std::atomic<bool> closing_{true};
  std::atomic<int32_t> error_{0};
  mutable std::mutex mutex_;
  AudioSinkStats stats_;
  std::chrono::steady_clock::time_point last_log_{};
  uint64_t logged_underflows_ = 0;
  int32_t logged_xruns_ = 0;
  size_t min_queued_ = ~size_t{0};
};
}  // namespace

std::unique_ptr<AudioSink> make_aaudio_sink() { return std::make_unique<AAudioSink>(); }
}  // namespace sdrcore
