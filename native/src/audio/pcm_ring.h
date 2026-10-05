// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef SDRCORE_PCM_RING_H
#define SDRCORE_PCM_RING_H

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

namespace sdrcore {

// Real-time playback ring sizing (AAudio sink, jitter tests): ~340 ms of
// capacity and a 60 ms pre-roll, the same pre-roll the old Dart output used
// (audio_output.dart waitingMs=60). The DSP thread delivers audio in 1.7 ms
// blocks but can be delayed by tens of ms (scheduling while the UI renders a
// drag, USB hiccups); without a cushion every such delay was a hole.
constexpr size_t kPlaybackRingFrames = 16384;
constexpr size_t kPlaybackPrefillFrames = 2880;  // 60 ms at 48 kHz

// Single producer (DSP) / single consumer (AAudio callback), with no allocation,
// lock, or wait in the real-time callback. Capacity is measured in stereo frames.
//
// With prefill > 0 the consumer outputs silence until `prefill` frames are
// queued, and re-primes the same way after an underflow, so a starved stream
// resumes with a cushion instead of crackling on every block.
class PcmRing {
 public:
  struct Stats {
    uint64_t underflows = 0;   // pops that ran dry while playing
    uint64_t zero_frames = 0;  // frames zero-filled (priming or underflow)
  };

  explicit PcmRing(size_t capacity, size_t prefill = 0)
      : data_(capacity * 2), capacity_(capacity), prefill_(std::min(prefill, capacity)) {}

  size_t push(const float* stereo, size_t frames) {
    const auto write = write_.load(std::memory_order_relaxed);
    const auto read = read_.load(std::memory_order_acquire);
    const auto count = std::min(frames, capacity_ - (write - read));
    for (size_t i = 0; i < count; ++i) {
      const auto slot = ((write + i) % capacity_) * 2;
      data_[slot] = stereo[i * 2];
      data_[slot + 1] = stereo[i * 2 + 1];
    }
    write_.store(write + count, std::memory_order_release);
    return count;
  }

  // Consumer only. Always fills `frames` frames; returns how many came from
  // the ring (the rest is silence).
  size_t pop(float* stereo, size_t frames) {
    const auto read = read_.load(std::memory_order_relaxed);
    const auto write = write_.load(std::memory_order_acquire);
    const size_t available = write - read;
    size_t count = 0;
    if (!priming_ || available >= prefill_) {
      priming_ = false;
      count = std::min(frames, available);
      if (count < frames && prefill_) {
        priming_ = true;
        underflows_.fetch_add(1, std::memory_order_relaxed);
      }
    }
    for (size_t i = 0; i < count; ++i) {
      const auto slot = ((read + i) % capacity_) * 2;
      stereo[i * 2] = data_[slot];
      stereo[i * 2 + 1] = data_[slot + 1];
    }
    std::fill(stereo + count * 2, stereo + frames * 2, 0.0f);
    if (count < frames)
      zero_frames_.fetch_add(frames - count, std::memory_order_relaxed);
    read_.store(read + count, std::memory_order_release);
    return count;
  }

  // Any thread.
  size_t queued() const {
    return write_.load(std::memory_order_acquire) - read_.load(std::memory_order_acquire);
  }
  Stats stats() const {
    Stats s;
    s.underflows = underflows_.load(std::memory_order_relaxed);
    s.zero_frames = zero_frames_.load(std::memory_order_relaxed);
    return s;
  }

 private:
  std::vector<float> data_;
  const size_t capacity_;
  const size_t prefill_;
  bool priming_ = true;  // consumer-owned
  std::atomic<size_t> read_{0};
  std::atomic<size_t> write_{0};
  std::atomic<uint64_t> underflows_{0};
  std::atomic<uint64_t> zero_frames_{0};
};

}  // namespace sdrcore
#endif  // SDRCORE_PCM_RING_H
