// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef SDRCORE_RECORD_RECORDER_H
#define SDRCORE_RECORD_RECORDER_H

#include "sdrcore_record_v1.h"
#include "audio_encoder.h"
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <mutex>
#include <map>
#include <set>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace sdrcore::record {

struct Edge {
  size_t frame_offset; // First frame in this block with the new effective state.
  bool open;
};

// Process-wide provider registry. Calls and replacement are serialized; the
// built-in file: scheme cannot be replaced. Returns SDR_INVALID_ARGUMENT for
// malformed schemes, SDR_UNSUPPORTED for file: replacement.
int32_t set_provider(const char* scheme, uint32_t bytes,
                     SdrRecordCreateFile fn, void* context);
bool supports_folder(const std::string& folder);

class Recorder {
 public:
  Recorder();
  ~Recorder();
  Recorder(const Recorder&) = delete;
  Recorder& operator=(const Recorder&) = delete;

  // Caller validates handle state, format/log capabilities and folder syntax.
  // IQ CU8, selected decoder JSONL and selectable audio share the worker.
  // The first provider call/file creation occurs on the worker, not start().
  int32_t start(const SdrRecordConfig& config, const std::string& folder,
                const std::string& log_ids = {});
  // Synchronous drain and join. FAILED -> IDLE acknowledges the sticky error.
  int32_t stop(uint32_t reason);
  SdrRecordStatus status() const;
  // NULL unregister waits for any callback currently in flight. Never call
  // this, stop or destroy from inside the callback itself.
  void set_notify(SdrRecordNotify fn, void* context);

  // Nonblocking with respect to I/O; copy only, independent 8 MiB/2 MiB
  // payload limits. Caller gives *applied* LO/rate and DSP layout. Even-size
  // CU8 pairs and 48-kHz float PCM frames only. On overflow the writer fails
  // the session rather than producing discontinuous playable output.
  void offer_iq(const uint8_t* bytes, size_t size, uint32_t rate,
                uint64_t frequency_hz, const std::string& mode);
  void offer_audio(const float* pcm, size_t frames, uint32_t channels,
                   const std::vector<Edge>& edges, uint64_t frequency_hz,
                   const std::string& mode, bool squelch_open = false);
  void offer_log(const std::string& id, uint32_t kind, uint64_t generation,
                 uint64_t frequency_hz, const std::string& payload,
                 const std::string& mode = "LOG");

 private:
  enum class Kind { iq, audio, log };
  struct Item {
    Kind kind;
    std::vector<uint8_t> iq;
    std::vector<float> pcm;
    std::vector<Edge> edges;
    size_t frames = 0;
    uint32_t rate = 0, channels = 0;
    uint64_t frequency = 0;
    int64_t captured_unix_ms = 0;
    std::string mode;
    std::string id, payload;
    uint32_t event_kind = 0;
    uint64_t generation = 0;
  };
  struct File {
    int fd = -1;
    std::unique_ptr<AudioEncoder> encoder;
    uint64_t length = 0, data = 0, frequency = 0;
    uint32_t rate = 0, channels = 0;
    int64_t captured_unix_ms = 0;
    std::string stem;
    std::string mode;
  };
  void run();
  void process(const Item& item);
  void fail(int32_t error, uint32_t stream);
  void close_iq();
  void close_audio(bool segment);
  bool open_iq(const Item& item);
  bool open_audio(const Item& item, bool segment);
  bool write(File& file, const void* bytes, size_t size, uint32_t stream);
  int32_t create(File& file, const std::string& name, const char* mime,
                 uint32_t stream);
  std::string stem(uint64_t frequency, const std::string& mode, bool segment);
  void write_audio(const Item& item, size_t first, size_t last, bool segment);
  void notify_final(SdrRecordStatus snapshot);
  bool open_log(const Item& item);
  void write_log(const Item& item);
  static uint64_t elapsed(const std::chrono::steady_clock::time_point& start);

  mutable std::mutex mutex_;
  std::condition_variable cv_;
  std::deque<Item> queue_;
  size_t iq_queued_ = 0, audio_queued_ = 0, log_queued_ = 0;
  std::set<std::string> log_ids_;
  std::map<std::string, File> log_files_;
  bool stopping_ = false, overflow_ = false;
  uint32_t overflow_stream_ = 0;
  std::thread worker_;
  SdrRecordConfig config_{};
  std::string folder_;
  SdrRecordStatus status_{};
  std::chrono::steady_clock::time_point started_;
  File iq_file_, iq_meta_file_, audio_file_, segment_file_;
  bool segment_open_ = false;
  bool segment_initialized_ = false;
  uint64_t segment_number_ = 0;
  SdrRecordNotify notify_ = nullptr;
  void* notify_context_ = nullptr;
  // Callback runs without mutex_; replacement waits here, including teardown.
  std::mutex callback_mutex_;
};

} // namespace sdrcore::record
#endif
