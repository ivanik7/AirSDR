// SPDX-License-Identifier: GPL-3.0-or-later
// In-process adapter wrapping the vendored csdr-plus SstvDecoder<float>
// (native/third_party/csdr_sstv). Implements sdrcore::decoder::Decoder per
// native/include/decoder.hpp and the Frozen v1 image event contract in
// STATUS-sstv-audit.md ("Frozen v1 image event contract for native and UI
// children"). See native/third_party/csdr_sstv/PROVENANCE.md for the exact
// list of patches applied to the vendored upstream source and the rationale
// for every design decision summarized here.
#include "decoder.hpp"
#include "sdrcore_v3.h"

#include "sstv.hpp"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>

namespace sdrcore::decoder {
namespace {

// --- VIS -> {display name, width, height} table ----------------------------
// Mirrors the 24 SstvMode subclasses actually instantiated by upstream's
// SstvDecoder<T> constructor (native/third_party/csdr_sstv/src/sstv.cpp),
// excluding VIS_AVT90 (commented out upstream: "AVT90 mode is not working
// very well"). This is pure metadata (VIS id, upstream NAME string,
// dimensions) reproduced for the adapter's own BMP-header validation and
// event payload construction; it does not reimplement any decoding
// algorithm. Cross-reference: STATUS-sstv-audit.md "Exactly what the
// upstream code can decode" table.
struct VisEntry {
  int vis;
  const char* name;
  int width;
  int height;
};
constexpr std::array<VisEntry, 24> kVisTable = {{
    {0, "Robot 12", 160, 120},
    {4, "Robot 24", 160, 120},
    {8, "Robot 36", 320, 240},
    {12, "Robot 72", 320, 240},
    {32, "Martin 4", 320, 128},
    {36, "Martin 3", 320, 128},
    {40, "Martin 2", 320, 256},
    {44, "Martin 1", 320, 256},
    {48, "Scottie 4", 320, 128},
    {51, "Wraase SC2-30", 320, 128},
    {52, "Scottie 3", 320, 128},
    {55, "Wraase SC2-180", 320, 256},
    {56, "Scottie 2", 320, 256},
    {59, "Wraase SC2-60", 320, 256},
    {60, "Scottie 1", 320, 256},
    {63, "Wraase SC2-120", 320, 256},
    {76, "Scottie DX", 320, 256},
    {93, "PD-50", 320, 256},
    {94, "PD-290", 800, 616},
    {95, "PD-120", 640, 496},
    {96, "PD-180", 640, 496},
    {97, "PD-240", 640, 496},
    {98, "PD-160", 512, 400},
    {99, "PD-90", 320, 256},
}};

const VisEntry* lookup_vis(int vis) {
  for (const auto& e : kVisTable) if (e.vis == vis) return &e;
  return nullptr;
}

// --- Small utilities ---------------------------------------------------
uint32_t read_u32_le(const uint8_t* p) {
  return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

std::string base64_encode(const uint8_t* data, size_t len) {
  static const char kTable[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  out.reserve(((len + 2) / 3) * 4);
  size_t i = 0;
  for (; i + 3 <= len; i += 3) {
    uint32_t n = (static_cast<uint32_t>(data[i]) << 16) |
                 (static_cast<uint32_t>(data[i + 1]) << 8) | data[i + 2];
    out.push_back(kTable[(n >> 18) & 0x3F]);
    out.push_back(kTable[(n >> 12) & 0x3F]);
    out.push_back(kTable[(n >> 6) & 0x3F]);
    out.push_back(kTable[n & 0x3F]);
  }
  const size_t rem = len - i;
  if (rem == 1) {
    uint32_t n = static_cast<uint32_t>(data[i]) << 16;
    out.push_back(kTable[(n >> 18) & 0x3F]);
    out.push_back(kTable[(n >> 12) & 0x3F]);
    out.push_back('=');
    out.push_back('=');
  } else if (rem == 2) {
    uint32_t n = (static_cast<uint32_t>(data[i]) << 16) | (static_cast<uint32_t>(data[i + 1]) << 8);
    out.push_back(kTable[(n >> 18) & 0x3F]);
    out.push_back(kTable[(n >> 12) & 0x3F]);
    out.push_back(kTable[(n >> 6) & 0x3F]);
    out.push_back('=');
  }
  return out;
}

std::string iso8601_utc_now() {
  using namespace std::chrono;
  const auto now = system_clock::now();
  const auto ms = duration_cast<milliseconds>(now.time_since_epoch()).count() % 1000;
  const std::time_t t = system_clock::to_time_t(now);
  std::tm tm{};
  gmtime_r(&t, &tm);
  char buf[32];
  std::snprintf(buf, sizeof buf, "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
                tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min,
                tm.tm_sec, static_cast<int>(ms));
  return buf;
}

const char* mode_to_underlying(uint32_t mode) {
  switch (mode) {
    case SDR_V3_USB: return "usb";
    case SDR_V3_LSB: return "lsb";
    case SDR_V3_NFM: return "nfm";
    default: return "";
  }
}

uint64_t next_frame_id() {
  static std::atomic<uint64_t> counter{0};
  return counter.fetch_add(1, std::memory_order_relaxed) + 1;
}

// FFTW's planner is process-global and not thread-safe against concurrent
// plan creation/destruction (see PROVENANCE.md "FFTW3 planner thread-
// safety"); fftwf_execute() itself needs no extra guard. One process-wide
// mutex serializes every SstvDecoder<float> construction/destruction,
// across however many handles/backends exist.
std::mutex& fftw_planner_mutex() {
  static std::mutex m;
  return m;
}

// --- Reader<float>/Writer<unsigned char> glue ---------------------------
// A minimal byte-buffer Reader/Writer pair, not csdr-plus's mmap-backed
// Ringbuffer: the adapter needs to append arbitrary amounts of audio per
// process() call and compact the consumed prefix afterwards, which fits a
// plain growable buffer better than a fixed-size double-mapped ring. See
// PROVENANCE.md for why Ringbuffer is vendored but unused.
class InputReader : public Csdr::Reader<float> {
 public:
  InputReader(std::vector<float>& buf, size_t& pos) : buf_(buf), pos_(pos) {}
  size_t available() override { return buf_.size() - pos_; }
  float* getReadPointer() override { return buf_.data() + pos_; }
  void advance(size_t how_much) override {
    pos_ += std::min(how_much, buf_.size() - pos_);
  }
  void wait() override {}
  void unblock() override {}

 private:
  std::vector<float>& buf_;
  size_t& pos_;
};

class OutputWriter : public Csdr::Writer<unsigned char> {
 public:
  explicit OutputWriter(std::vector<uint8_t>& buf, size_t capacity)
      : buf_(buf), capacity_(capacity) {}
  size_t writeable() override {
    return capacity_ > buf_.size() ? capacity_ - buf_.size() : 0;
  }
  unsigned char* getWritePointer() override {
    pending_base_ = buf_.size();
    buf_.resize(buf_.size() + writeable());
    return buf_.data() + pending_base_;
  }
  void advance(size_t how_much) override {
    buf_.resize(pending_base_ + how_much);
  }

 private:
  std::vector<uint8_t>& buf_;
  size_t capacity_;
  size_t pending_base_ = 0;
};

struct HeaderInfo {
  int vis = 0;
  std::string name;
  int width = 0;
  int height = 0;
};

// Validates the 54-byte BMP header upstream writes (see PROVENANCE.md /
// STATUS-sstv-audit.md "Framing, fidelity..."): 'BM' magic, byte 7 ==
// 0x73, a known mapped VIS whose table dimensions match the header's
// width/height (LE32 at 18; height stored as LE32(-LINE_COUNT) at 22).
bool parse_bmp_header(const std::vector<uint8_t>& buf, HeaderInfo& out) {
  if (buf.size() < 54) return false;
  if (buf[0] != 'B' || buf[1] != 'M') return false;
  if (buf[7] != 0x73) return false;
  const int vis = buf[6];
  const int32_t width = static_cast<int32_t>(read_u32_le(&buf[18]));
  const int32_t height_stored = static_cast<int32_t>(read_u32_le(&buf[22]));
  const int32_t height = -height_stored;
  if (width <= 0 || width > 800 || height <= 0 || height > 616) return false;
  const VisEntry* entry = lookup_vis(vis);
  if (!entry || entry->width != width || entry->height != height) return false;
  out.vis = vis;
  out.name = entry->name;
  out.width = width;
  out.height = height;
  return true;
}

// --- The adapter itself --------------------------------------------------
// Backend-local staging queue. The handle drains up to 256 events per DSP
// block into the public FIFO; the largest frame (PD-290) is 616 rows + 2.
constexpr size_t kQueueCapacity = 1024;
constexpr size_t kMaxPayloadBytes = 65536;   // SDR_DECODER_MAX_PAYLOAD.
// Output bytes are parsed after every upstream process() call, so only a
// few rows are ever pending; upstream canProcess() needs 2*800*3 writable.
// Upstream finishFrame() pads a missing tail in one all-or-nothing
// printBmpEmptyLines() call, but it only reaches that with rows missing
// after decodeLine() returns 0, which cannot happen once process() has
// checked size >= 2*lineSize. If it ever did, the frame would close as
// partial/sync_lost with fewer rows (honest, never fabricated).
// OutputWriter zero-fills up to capacity per write, so keep this small.
constexpr size_t kOutputCapacityBytes = 256 * 1024;
// Upstream canProcess() wants 2 s (48000 samples) buffered; anything beyond
// 10 s can only accumulate if the iteration cap below is hit, and is
// dropped oldest-first as a discontinuity.
constexpr size_t kMaxInputSamples = 10 * 24000;
// Compact the consumed input prefix only once it is this large, so a DSP
// block does not memmove the whole 2 s lookahead every call.
constexpr size_t kCompactThreshold = 24000;
constexpr int kMaxIterationsPerProcess = 200000;  // Defensive loop-safety cap.

class SstvBackend final : public Decoder {
 public:
  SstvBackend() : reader_(input_buf_, read_pos_), writer_(out_buf_, kOutputCapacityBytes) {
    init_engine();
  }

  ~SstvBackend() override {
    std::lock_guard<std::mutex> lock(fftw_planner_mutex());
    engine_.reset();
  }

  bool configure(std::string_view json) override {
    if (json.empty()) return false;
    const auto doc = nlohmann::json::parse(json, nullptr, /*allow_exceptions=*/false);
    if (doc.is_discarded() || !doc.is_object()) return false;
    if (doc.size() != 2 || !doc.contains("version") || !doc.contains("settings")) return false;
    const auto& version = doc.at("version");
    if (!version.is_number_integer() || version.get<int64_t>() != 1) return false;
    const auto& settings = doc.at("settings");
    if (!settings.is_object()) return false;
    for (const auto& item : settings.items()) {
      const std::string& key = item.key();
      const auto& value = item.value();
      if (key == "mode") {
        if (!value.is_string() || value.get<std::string>() != "auto") return false;
      } else if (key == "underlying") {
        if (!value.is_string()) return false;
        const std::string u = value.get<std::string>();
        if (u == "usb") underlying_ = SDR_V3_USB;
        else if (u == "lsb") underlying_ = SDR_V3_LSB;
        else if (u == "nfm") underlying_ = SDR_V3_NFM;
        else return false;
        have_underlying_ = true;
      } else {
        return false;  // Unknown key.
      }
    }
    return true;
  }

  bool accepts_mode(uint32_t mode) const override {
    const bool base = mode == static_cast<uint32_t>(SDR_V3_USB) ||
                       mode == static_cast<uint32_t>(SDR_V3_LSB) ||
                       mode == static_cast<uint32_t>(SDR_V3_NFM);
    if (!base) return false;
    if (have_underlying_) return mode == static_cast<uint32_t>(underlying_);
    return true;
  }

  void set_tuning(uint64_t tuned_frequency_hz, uint32_t mode) override {
    if (!have_applied_) pending_reason_ = "stop";
    else if (tuned_frequency_hz != applied_freq_hz_) pending_reason_ = "retune";
    else if (mode != applied_mode_) pending_reason_ = "mode";
    else pending_reason_ = "stop";
    pending_freq_hz_ = tuned_frequency_hz;
    pending_mode_ = mode;
  }

  void reset() override {
    if (frame_open_) finalize_frame(pending_reason_);
    frame_open_ = false;
    frame_broken_ = false;
    hook_events_.clear();
    out_buf_.clear();
    input_buf_.clear();
    read_pos_ = 0;
    init_engine();
    applied_freq_hz_ = pending_freq_hz_;
    applied_mode_ = pending_mode_;
    have_applied_ = true;
  }

  void process(const float* samples, size_t frames, uint32_t sample_rate_hz) override {
    if (!samples || frames == 0 || sample_rate_hz != 24000) return;
    input_buf_.insert(input_buf_.end(), samples, samples + frames);
    int iterations = 0;
    while (engine_->canProcess() && iterations < kMaxIterationsPerProcess) {
      engine_->process();
      ++iterations;
      drain_output();
    }
    if (input_buf_.size() - read_pos_ > kMaxInputSamples) {
      // Unreachable while upstream makes progress; bounded memory if not.
      read_pos_ = input_buf_.size() - kMaxInputSamples;
    }
    if (read_pos_ >= kCompactThreshold || read_pos_ == input_buf_.size()) {
      input_buf_.erase(input_buf_.begin(), input_buf_.begin() + read_pos_);
      read_pos_ = 0;
    }
  }

  bool take_event(Event& out) override {
    if (pending_.empty()) return false;
    out = std::move(pending_.front());
    pending_.pop_front();
    return true;
  }

  uint64_t take_dropped_count() override {
    const uint64_t d = dropped_count_;
    dropped_count_ = 0;
    return d;
  }

 private:
  struct HookEvent { enum Kind { kRow, kFinish } kind; bool flag; };

  void init_engine() {
    std::lock_guard<std::mutex> lock(fftw_planner_mutex());
    engine_.reset();
    // dbgTime=0: OpenWebRX+ passes 300000 only to gate periodic textual
    // debug printouts (SstvDecoder::printDebug/printString), which with
    // dbgTime==0 never fire and so never interleave non-BMP bytes into the
    // output stream this adapter parses. See PROVENANCE.md "dbgTime".
    engine_ = std::make_unique<Csdr::SstvDecoder<float>>(24000, 0);
    engine_->setReader(&reader_);
    engine_->setWriter(&writer_);
    engine_->onRowWritten = [this](bool padded) {
      hook_events_.push_back(HookEvent{HookEvent::kRow, padded});
    };
    engine_->onFinishFrame = [this](bool natural) {
      hook_events_.push_back(HookEvent{HookEvent::kFinish, natural});
    };
  }

  // Parses newly written BMP bytes (out_buf_) against the hook event queue
  // (hook_events_, filled synchronously during engine_->process() calls
  // above) to emit the Frozen v1 image_progress/image_complete events. See
  // the module header comment and PROVENANCE.md for the full design
  // rationale, including the Scottie start-sync-loss resync case handled
  // by the "implicit new header while frame_open_" branch below.
  void drain_output() {
    for (;;) {
      if (frame_open_) {
        if (!hook_events_.empty() && hook_events_.front().kind == HookEvent::kRow) {
          const HookEvent ev = hook_events_.front();
          if (out_buf_.size() < static_cast<size_t>(frame_row_size_)) break;
          if (!frame_broken_) emit_line_event(ev.flag);
          out_buf_.erase(out_buf_.begin(), out_buf_.begin() + frame_row_size_);
          hook_events_.pop_front();
          continue;
        }
        if (!hook_events_.empty() && hook_events_.front().kind == HookEvent::kFinish) {
          const bool natural = hook_events_.front().flag;
          hook_events_.pop_front();
          finalize_frame(natural ? "end" : "sync_lost");
          continue;
        }
        break;
      } else {
        // Row/finish hooks can only follow a header; a stray one would mean
        // the hook stream and byte stream disagree. Never guess: drop it.
        if (!hook_events_.empty()) {
          hook_events_.pop_front();
          continue;
        }
        if (out_buf_.size() < 54) break;
        HeaderInfo info;
        if (!parse_bmp_header(out_buf_, info)) {
          // Corruption resync: drop one byte and retry. Should not happen
          // against our own Writer, but documented by the audit as a
          // required defensive behavior.
          out_buf_.erase(out_buf_.begin());
          continue;
        }
        start_frame(info);
        out_buf_.erase(out_buf_.begin(), out_buf_.begin() + 54);
        continue;
      }
    }
  }

  void start_frame(const HeaderInfo& info) {
    frame_id_ = next_frame_id();
    frame_vis_ = info.vis;
    frame_name_ = info.name;
    frame_width_ = info.width;
    frame_height_ = info.height;
    frame_row_size_ = static_cast<size_t>(info.width) * 3;
    frame_timestamp_ = iso8601_utc_now();
    frame_freq_hz_ = applied_freq_hz_;
    frame_underlying_ = mode_to_underlying(applied_mode_);
    lines_emitted_ = 0;
    padded_emitted_ = 0;
    frame_open_ = true;
    frame_broken_ = false;

    nlohmann::json payload = base_metadata();
    payload["phase"] = "start";
    payload["line"] = nullptr;
    payload["pixels_bgr_base64"] = nullptr;
    payload["padded"] = nullptr;
    push_event(Result::image_progress, payload);
  }

  void emit_line_event(bool padded) {
    if (frame_broken_) return;
    nlohmann::json payload = base_metadata();
    payload["phase"] = "line";
    payload["line"] = static_cast<int>(lines_emitted_);
    payload["pixels_bgr_base64"] =
        base64_encode(out_buf_.data(), frame_row_size_);
    payload["padded"] = padded;
    if (push_event(Result::image_progress, payload)) {
      ++lines_emitted_;
      if (padded) ++padded_emitted_;
    }
  }

  void finalize_frame(const std::string& reason) {
    const std::string status =
        (!frame_broken_ && reason == "end" && lines_emitted_ == static_cast<uint32_t>(frame_height_))
            ? "complete"
            : "partial";
    nlohmann::json payload = base_metadata();
    payload["received_lines"] = lines_emitted_;
    payload["padded_lines"] = padded_emitted_;
    payload["status"] = status;
    payload["reason"] = reason;
    push_event(Result::image_complete, payload);
    frame_open_ = false;
    frame_broken_ = false;
  }

  nlohmann::json base_metadata() const {
    nlohmann::json j;
    j["source"] = "sstv";
    j["version"] = 1;
    j["frame_id"] = std::to_string(frame_id_);
    j["vis"] = frame_vis_;
    j["sstv_mode"] = frame_name_;
    j["width"] = frame_width_;
    j["height"] = frame_height_;
    j["timestamp_utc"] = frame_timestamp_;
    j["frequency_hz"] = static_cast<int64_t>(frame_freq_hz_);
    j["underlying"] = frame_underlying_;
    return j;
  }

  // Returns true iff the event was actually enqueued. On overflow (either
  // the bounded 1024-entry FIFO or, defensively, the 64 KiB payload cap)
  // the event is dropped, counted, and the current frame is marked broken
  // so no further rows are emitted for it (Frozen v1 contract, "Internal
  // event queue").
  bool push_event(Result kind, const nlohmann::json& payload) {
    const std::string text = payload.dump();
    if (text.size() > kMaxPayloadBytes || pending_.size() >= kQueueCapacity) {
      ++dropped_count_;
      frame_broken_ = true;
      return false;
    }
    pending_.push_back(Event{kind, std::vector<uint8_t>(text.begin(), text.end())});
    return true;
  }

  // Upstream engine + its byte-buffer Reader/Writer and the hook events
  // they produce synchronously from within engine_->process().
  std::unique_ptr<Csdr::SstvDecoder<float>> engine_;
  std::vector<float> input_buf_;
  size_t read_pos_ = 0;
  std::vector<uint8_t> out_buf_;
  InputReader reader_;
  OutputWriter writer_;
  std::deque<HookEvent> hook_events_;

  // Current-frame bookkeeping (valid while frame_open_).
  bool frame_open_ = false;
  bool frame_broken_ = false;
  uint64_t frame_id_ = 0;
  int frame_vis_ = 0;
  std::string frame_name_;
  int frame_width_ = 0;
  int frame_height_ = 0;
  size_t frame_row_size_ = 0;
  std::string frame_timestamp_;
  uint64_t frame_freq_hz_ = 0;
  std::string frame_underlying_;
  uint32_t lines_emitted_ = 0;
  uint32_t padded_emitted_ = 0;

  // Applied tuning (committed by reset()) and the pending set_tuning()
  // request/reason not yet committed (committed by the next reset()).
  bool have_applied_ = false;
  uint64_t applied_freq_hz_ = 0;
  uint32_t applied_mode_ = 0;
  uint64_t pending_freq_hz_ = 0;
  uint32_t pending_mode_ = 0;
  std::string pending_reason_ = "stop";

  // configure() result.
  bool have_underlying_ = false;
  SdrV3Mode underlying_ = SDR_V3_USB;

  // Output event FIFO.
  std::deque<Event> pending_;
  uint64_t dropped_count_ = 0;
};

}  // namespace

std::unique_ptr<Decoder> create_sstv() { return std::make_unique<SstvBackend>(); }

}  // namespace sdrcore::decoder
