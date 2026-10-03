// SPDX-License-Identifier: GPL-3.0-or-later
#include "wav_sink.h"

#include <cstdio>
#include <mutex>
#include <utility>

#include "audio_internal.h"

namespace sdrcore {
namespace {

// Writes one little-endian byte at a time, as required by the task's audio
// backend contract notes (never relies on host endianness/struct packing).
void put_u16_le(std::FILE* f, uint16_t v) {
  std::fputc(static_cast<int>(v & 0xFF), f);
  std::fputc(static_cast<int>((v >> 8) & 0xFF), f);
}

void put_u32_le(std::FILE* f, uint32_t v) {
  std::fputc(static_cast<int>(v & 0xFF), f);
  std::fputc(static_cast<int>((v >> 8) & 0xFF), f);
  std::fputc(static_cast<int>((v >> 16) & 0xFF), f);
  std::fputc(static_cast<int>((v >> 24) & 0xFF), f);
}

void put_s16_le(std::FILE* f, int16_t v) {
  put_u16_le(f, static_cast<uint16_t>(v));
}

// Canonical 44-byte PCM WAV header: RIFF/WAVE, 16-byte "fmt " chunk, "data"
// chunk. Stereo, 16-bit, little-endian throughout.
constexpr long kHeaderBytes = 44;
constexpr uint32_t kChannels = 2;
constexpr uint32_t kBitsPerSample = 16;
constexpr uint32_t kBlockAlign = kChannels * (kBitsPerSample / 8);  // 4

class WavSink final : public AudioSink {
 public:
  explicit WavSink(std::string path) : path_(std::move(path)) {}
  ~WavSink() override { close(); }

  const char* name() const override { return "wav"; }

  int open(uint32_t sample_rate) override {
    if (!valid_sample_rate(sample_rate)) return kAudioInvalidArgument;
    std::lock_guard<std::mutex> lock(mutex_);
    close_locked();
    file_ = std::fopen(path_.c_str(), "wb");
    if (!file_) {
      stats_.last_error = kAudioIoError;
      return kAudioIoError;
    }
    sample_rate_ = sample_rate;
    data_bytes_ = 0;
    frames_since_flush_ = 0;
    stats_ = AudioSinkStats{};
    stats_.sample_rate = sample_rate;
    write_header_locked();  // Placeholder sizes; a killed process still
                             // leaves a parseable zero-length WAV file.
    return kAudioOk;
  }

  size_t write(const float* interleaved, size_t frames) override {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!file_ || frames == 0) return 0;
    for (size_t i = 0; i < frames; ++i) {
      const float l = interleaved[2 * i];
      const float r = interleaved[2 * i + 1];
      update_level_stats(stats_, l, r);
      put_s16_le(file_, float_to_s16(l));
      put_s16_le(file_, float_to_s16(r));
    }
    data_bytes_ += static_cast<uint64_t>(frames) * kBlockAlign;
    stats_.frames_written += frames;
    frames_since_flush_ += frames;
    // Keep the header sizes valid at least once per second of audio so a
    // killed/crashed process still leaves a readable file.
    if (frames_since_flush_ >= sample_rate_) {
      flush_header_locked();
      frames_since_flush_ = 0;
    }
    return frames;
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
  void write_header_locked() {
    std::fseek(file_, 0, SEEK_SET);
    std::fwrite("RIFF", 1, 4, file_);
    put_u32_le(file_, 36);  // 36 + data_bytes_ (0 so far).
    std::fwrite("WAVE", 1, 4, file_);
    std::fwrite("fmt ", 1, 4, file_);
    put_u32_le(file_, 16);  // PCM fmt chunk size.
    put_u16_le(file_, 1);   // Audio format: PCM.
    put_u16_le(file_, static_cast<uint16_t>(kChannels));
    put_u32_le(file_, sample_rate_);
    put_u32_le(file_, sample_rate_ * kBlockAlign);  // Byte rate.
    put_u16_le(file_, static_cast<uint16_t>(kBlockAlign));
    put_u16_le(file_, static_cast<uint16_t>(kBitsPerSample));
    std::fwrite("data", 1, 4, file_);
    put_u32_le(file_, 0);  // data_bytes_ placeholder.
    std::fseek(file_, 0, SEEK_END);
  }

  // Rewrites only the two size fields (RIFF size @4, data size @40) in
  // place, then restores the write position, so appends keep working.
  void flush_header_locked() {
    const long pos = std::ftell(file_);
    std::fseek(file_, 4, SEEK_SET);
    put_u32_le(file_, static_cast<uint32_t>(36 + data_bytes_));
    std::fseek(file_, 40, SEEK_SET);
    put_u32_le(file_, static_cast<uint32_t>(data_bytes_));
    std::fseek(file_, pos, SEEK_SET);
    std::fflush(file_);
  }

  void close_locked() {
    if (file_) {
      flush_header_locked();
      std::fclose(file_);
      file_ = nullptr;
    }
    stats_.sample_rate = 0;
  }

  std::string path_;
  mutable std::mutex mutex_;
  std::FILE* file_ = nullptr;
  uint32_t sample_rate_ = 0;
  uint64_t data_bytes_ = 0;
  uint64_t frames_since_flush_ = 0;
  AudioSinkStats stats_;
};

}  // namespace

std::unique_ptr<AudioSink> make_wav_sink(std::string path) {
  return std::make_unique<WavSink>(std::move(path));
}

}  // namespace sdrcore
