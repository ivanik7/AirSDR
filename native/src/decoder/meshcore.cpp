// SPDX-License-Identifier: GPL-3.0-or-later
// OpenWebRX+ MeshcoreDemodulator argv, using the shared embedded lorarx PHY.
#include "decoder.hpp"
#include "lorarx_session.hpp"
#include "lorarx_embed.h"
#include "meshcore/meshcore.h"
#include <nlohmann/json.hpp>

#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <deque>
#include <string>
#include <vector>

namespace sdrcore::decoder {
namespace {
constexpr size_t kBlock = LORARX_EMBED_BLOCK_FRAMES;
constexpr size_t kEvents = 256;
using namespace lorarx_session;

int64_t now_ms() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::system_clock::now().time_since_epoch()).count();
}

// lorarx's JSON payload is RFC 4648 base64; reject bad padding and leftover bits.
bool base64_decode(const std::string& in, std::vector<uint8_t>& out) {
  if (in.empty() || in.size() % 4) return false;
  auto digit = [](char ch) -> int {
    if (ch >= 'A' && ch <= 'Z') return ch - 'A';
    if (ch >= 'a' && ch <= 'z') return ch - 'a' + 26;
    if (ch >= '0' && ch <= '9') return ch - '0' + 52;
    if (ch == '+') return 62;
    if (ch == '/') return 63;
    return -1;
  };
  out.clear();
  for (size_t i = 0; i < in.size(); i += 4) {
    int a = digit(in[i]), b = digit(in[i + 1]);
    int c = in[i + 2] == '=' ? -2 : digit(in[i + 2]);
    int d = in[i + 3] == '=' ? -2 : digit(in[i + 3]);
    if (a < 0 || b < 0 || c == -1 || d == -1 ||
        (c == -2 && d != -2) || (i + 4 < in.size() && d == -2) ||
        (c == -2 && (b & 15)) || (d == -2 && c >= 0 && (c & 3))) return false;
    out.push_back(static_cast<uint8_t>((a << 2) | (b >> 4)));
    if (c >= 0) out.push_back(static_cast<uint8_t>((b << 4) | (c >> 2)));
    if (d >= 0) out.push_back(static_cast<uint8_t>((c << 6) | d));
  }
  return out.size() <= 255;
}

class MeshcoreBackend final : public Decoder {
 public:
  ~MeshcoreBackend() override {
    std::lock_guard<std::mutex> lock(mutex);
    if (owner == this) {
      lorarx_embed_clear();
      owner = nullptr;
      sink = nullptr;
    }
  }

  bool configure(std::string_view config) override {
    if (!parser_.configure(config)) return false;
    auto doc = nlohmann::json::parse(config, nullptr, false);
    if (doc.is_discarded()) return false;
    const auto& settings = doc["settings"];
    const auto& bw = settings.value("bandwidth", std::string("6"));
    bw_ = bw[0] - '0';
    {
      std::lock_guard<std::mutex> lock(mutex);
      owner = this;
      sink = [](void* context, const char* json, size_t length) {
        static_cast<MeshcoreBackend*>(context)->emit(json, length);
      };
    }
    reset();
    return ready_;
  }

  void reset() override {
    parser_.reset();
    frames_ = 0;
    pending_.clear();
    std::lock_guard<std::mutex> lock(mutex);
    ready_ = false;
    if (owner != this || bw_ < 0) return;
    lorarx_embed_clear();
    std::vector<std::string> args = {
        "lorarx", "-i", "/dev/stdin", "-r", "1000000", "-f", "f32", "-v", "-N",
        "-Q", "-H", "5", "-W", "50", "-b", std::to_string(bw_), "-s", "7",
        "-s", "8", "-j", "/dev/stdout"};
    std::vector<char*> argv;
    for (auto& arg : args) argv.push_back(arg.data());
    argv.push_back(nullptr);
    ready_ = lorarx_embed_start(static_cast<int>(args.size()), argv.data()) != 0;
  }

  void set_tuning(uint64_t frequency_hz, uint32_t) override { frequency_ = frequency_hz; }

  void process(const float* iq, size_t frames, uint32_t rate) override {
    if (!ready_ || !iq || rate != 1000000) return;
    for (size_t n = 0; n < frames; ++n) {
      float re = iq[2 * n], im = iq[2 * n + 1];
      buffer_[2 * frames_] = std::isfinite(re) ? re : 0.0f;
      buffer_[2 * frames_ + 1] = std::isfinite(im) ? im : 0.0f;
      if (++frames_ == kBlock) {
        frames_ = 0;
        std::lock_guard<std::mutex> lock(mutex);
        if (owner != this || !lorarx_embed_block(buffer_.data(), kBlock)) {
          ready_ = false;
          return;
        }
      }
    }
  }

  bool take_event(Event& out) override {
    if (pending_.empty()) return false;
    out = std::move(pending_.front());
    pending_.pop_front();
    return true;
  }
  uint64_t take_dropped_count() override {
    auto count = dropped_;
    dropped_ = 0;
    return count;
  }

  void emit(const char* data, size_t length) {
    if (length > 8192) return;
    auto row = nlohmann::json::parse(std::string_view(data, length), nullptr, false);
    if (row.is_discarded() || !row.is_object() || !row.contains("payload") ||
        !row["payload"].is_string()) return;
    std::vector<uint8_t> bytes;
    if (!base64_decode(row["payload"].get<std::string>(), bytes)) return;
    meshcore::PhyMeta phy;
    phy.timestamp_ms = now_ms();
    phy.frequency_hz = frequency_;
    phy.crc = row.value("crc", -1);
    phy.sf = row.value("sf", 0);
    phy.cr = row.value("cr", 0);
    phy.bw_khz = row.value("bw", 0.0) / 1000.0;
    if (row.contains("level") && row["level"].is_number())
      phy.level_db = row["level"].get<double>();
    if (row.contains("snr") && row["snr"].is_number())
      phy.snr_db = row["snr"].get<double>();
    auto result = parser_.parse(bytes.data(), bytes.size(), phy);
    if (!result || result->size() > 65536) return;
    if (pending_.size() == kEvents) {
      pending_.pop_front();
      ++dropped_;
    }
    pending_.push_back(Event{Result::message, {result->begin(), result->end()}});
  }

 private:
  meshcore::PacketParser parser_;
  int bw_ = -1;
  bool ready_ = false;
  uint64_t frequency_ = 0;
  std::array<float, kBlock * 2> buffer_{};
  size_t frames_ = 0;
  std::deque<Event> pending_;
  uint64_t dropped_ = 0;
};
}  // namespace

std::unique_ptr<Decoder> create_meshcore() {
  return std::make_unique<MeshcoreBackend>();
}
}  // namespace sdrcore::decoder
