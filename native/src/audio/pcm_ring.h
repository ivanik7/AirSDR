// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef SDRCORE_PCM_RING_H
#define SDRCORE_PCM_RING_H

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstring>
#include <vector>

namespace sdrcore {

// Single producer (DSP) / single consumer (AAudio callback), with no allocation,
// lock, or wait in the real-time callback. Capacity is measured in stereo frames.
class PcmRing {
 public:
  explicit PcmRing(size_t capacity) : data_(capacity * 2), capacity_(capacity) {}

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

  size_t pop(float* stereo, size_t frames) {
    const auto read = read_.load(std::memory_order_relaxed);
    const auto write = write_.load(std::memory_order_acquire);
    const auto count = std::min(frames, write - read);
    for (size_t i = 0; i < count; ++i) {
      const auto slot = ((read + i) % capacity_) * 2;
      stereo[i * 2] = data_[slot];
      stereo[i * 2 + 1] = data_[slot + 1];
    }
    std::fill(stereo + count * 2, stereo + frames * 2, 0.0f);
    read_.store(read + count, std::memory_order_release);
    return count;
  }

 private:
  std::vector<float> data_;
  const size_t capacity_;
  std::atomic<size_t> read_{0};
  std::atomic<size_t> write_{0};
};

}  // namespace sdrcore
#endif  // SDRCORE_PCM_RING_H
