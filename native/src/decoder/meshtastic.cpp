// SPDX-License-Identifier: GPL-3.0-or-later
// Thin single-owner adapter for OE5DXL's process-global lorarx demodulator.
#include "decoder.hpp"
#include "meshtastic/meshtastic.h"
#include "lorarx_embed.h"
#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <deque>
#include <limits>
#include <string>
#include <vector>

namespace sdrcore::decoder {
namespace {
std::atomic<bool> occupied{false};
constexpr size_t kBlock = 8192;
constexpr size_t kEvents = 256;

int bandwidth_index(const std::string& preset) {
  if (preset == "NarrowFast" || preset == "NarrowSlow") return 6;
  if (preset == "LongMod" || preset == "LiteFast" || preset == "LiteSlow") return 7;
  if (preset == "LongFast" || preset == "MediumSlow" || preset == "MediumFast" ||
      preset == "ShortSlow" || preset == "ShortFast") return 8;
  if (preset == "ShortTurbo" || preset == "LongTurbo" || preset == "MediumTurbo") return 9;
  return -1;  // SF12 / 15.6 kHz / 2.4 GHz are not in the supported receive mode.
}

int64_t now_ms() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch()).count();
}
int64_t steady_ms() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch()).count();
}

class MeshtasticBackend;
MeshtasticBackend* active = nullptr;  // lorarx's state is global; occupied enforces one owner.

class MeshtasticBackend final : public Decoder {
 public:
  ~MeshtasticBackend() override {
    lorarx_embed_clear();
    active = nullptr;
    occupied.store(false, std::memory_order_release);
  }
  bool configure(std::string_view text) override {
    auto doc = nlohmann::json::parse(text, nullptr, false);
    if (doc.is_discarded() || !doc.is_object() || doc.value("version", 0) != 1 ||
        !doc.contains("settings") || !doc["settings"].is_object()) return false;
    auto& settings = doc["settings"];
    if (!settings.contains("preset") || !settings["preset"].is_string() ||
        !settings.contains("channels") || !settings["channels"].is_array() ||
        settings["channels"].size() > 8) return false;
    meshtastic::ParserConfig config;
    config.preset = settings["preset"].get<std::string>();
    const int bw = bandwidth_index(config.preset);
    if (bw < 0) return false;
    for (const auto& channel : settings["channels"]) {
      if (!channel.is_object() || !channel.contains("name") ||
          !channel["name"].is_string() || !channel.contains("psk") ||
          !channel["psk"].is_string()) return false;
      meshtastic::ChannelConfig entry{channel["name"].get<std::string>(),
                                      channel["psk"].get<std::string>()};
      if (entry.name.size() > 11 ||
          !std::all_of(entry.name.begin(), entry.name.end(),
                       [](unsigned char ch) { return ch >= 32 && ch <= 126; })) return false;
      config.channels.push_back(std::move(entry));
    }
    if (!parser_.configure(config)) return false;
    bw_ = bw;
    reset();
    return ready_;
  }
  void reset() override {
    parser_.reset();
    frames_ = 0;
    pending_.clear();
    ready_ = false;
    lorarx_embed_clear();
    if (bw_ < 0) return;
    // Same options and SF bank as OpenWebRX+ MeshtasticDemodulator. No -c:
    // explicit headers carry their own coding rate, CRC and packet length.
    std::string bw = std::to_string(bw_);
    std::vector<std::string> args = {"lorarx", "-i", "/dev/stdin", "-r", "1000000",
      "-f", "f32", "-v", "-N", "-Q", "-H", "5", "-W", "50", "-b", bw,
      "-s", "7", "-s", "8", "-s", "9", "-s", "10", "-s", "11"};
    std::vector<char*> argv;
    for (auto& arg : args) argv.push_back(arg.data());
    active = this;
    ready_ = lorarx_embed_start(static_cast<int>(argv.size()), argv.data()) != 0;
  }
  void set_tuning(uint64_t frequency, uint32_t) override { frequency_ = frequency; }
  void process(const float* iq, size_t frames, uint32_t rate) override {
    if (!ready_ || !iq || rate != 1000000) return;
    for (size_t n = 0; n < frames; ++n) {
      buffer_[2 * frames_] = std::isfinite(iq[2 * n]) ? iq[2 * n] : 0.0f;
      buffer_[2 * frames_ + 1] = std::isfinite(iq[2 * n + 1]) ? iq[2 * n + 1] : 0.0f;
      if (++frames_ == kBlock) {
        if (!lorarx_embed_block(buffer_.data(), kBlock)) ready_ = false;
        frames_ = 0;
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
    const auto count = dropped_;
    dropped_ = 0;
    return count;
  }
  void emit(const char* json, size_t length) {
    if (length > 1000) return;
    auto row = nlohmann::json::parse(std::string_view(json, length), nullptr, false);
    if (row.is_discarded() || !row.is_object() || !row.contains("payload") ||
        !row["payload"].is_string()) return;
    const std::string encoded = row["payload"].get<std::string>();
    if (encoded.size() > 344 || encoded.size() % 4 != 0) return;
    static constexpr char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::vector<uint8_t> bytes;
    uint32_t bits = 0;
    int nbits = 0;
    for (char ch : encoded) {
      if (ch == '=') break;
      const char* pos = std::strchr(alphabet, ch);
      if (!pos) return;
      bits = (bits << 6) | static_cast<uint32_t>(pos - alphabet);
      nbits += 6;
      if (nbits >= 8) {
        nbits -= 8;
        bytes.push_back(static_cast<uint8_t>(bits >> nbits));
      }
    }
    if (bytes.size() > meshtastic::kMaxLoraPayload) return;
    meshtastic::PhyMeta meta;
    meta.timestamp_ms = now_ms();
    meta.monotonic_ms = steady_ms();
    meta.frequency_hz = frequency_;
    meta.crc = row.value("crc", -1);
    if (row.contains("bw") && row["bw"].is_number()) meta.bw_khz = row["bw"].get<double>() / 1000.0;
    if (row.contains("sf") && row["sf"].is_number_integer()) meta.sf = row["sf"].get<int>();
    if (row.contains("cr") && row["cr"].is_number_integer()) meta.cr = row["cr"].get<int>();
    if (row.contains("invers") && row["invers"].is_number_integer()) meta.inverted = row["invers"].get<int>();
    if (row.contains("preamb") && row["preamb"].is_number_integer()) meta.preamble = row["preamb"].get<int>();
    if (row.contains("duration") && row["duration"].is_number_integer()) meta.duration_ms = row["duration"].get<int>();
    if (row.contains("level") && row["level"].is_number()) meta.level_db = row["level"].get<double>();
    if (row.contains("snr") && row["snr"].is_number()) meta.snr_db = row["snr"].get<double>();
    if (row.contains("nfloor") && row["nfloor"].is_number()) meta.noise_floor_db = row["nfloor"].get<double>();
    if (row.contains("pknfloor") && row["pknfloor"].is_number()) meta.peak_noise_floor_db = row["pknfloor"].get<double>();
    if (row.contains("afc") && row["afc"].is_number_integer()) meta.afc_hz = row["afc"].get<int>();
    if (row.contains("fec") && row["fec"].is_number_integer()) meta.fec = row["fec"].get<int>();
    auto parsed = parser_.parse(bytes.data(), bytes.size(), meta);
    if (!parsed || parsed->size() > 65536) return;
    if (pending_.size() == kEvents) { pending_.pop_front(); ++dropped_; }
    pending_.push_back(Event{Result::message, {parsed->begin(), parsed->end()}});
  }
 private:
  meshtastic::PacketParser parser_;
  int bw_ = -1;
  bool ready_ = false;
  uint64_t frequency_ = 0;
  std::array<float, kBlock * 2> buffer_{};
  size_t frames_ = 0;
  std::deque<Event> pending_;
  uint64_t dropped_ = 0;
};
}  // namespace
std::unique_ptr<Decoder> create_meshtastic() {
  bool expected = false;
  if (!occupied.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) return nullptr;
  return std::make_unique<MeshtasticBackend>();
}
}  // namespace sdrcore::decoder

extern "C" void lorarx_embed_emit(const char* json, size_t length) {
  if (sdrcore::decoder::active) sdrcore::decoder::active->emit(json, length);
}
