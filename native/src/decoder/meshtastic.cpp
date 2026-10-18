// SPDX-License-Identifier: GPL-3.0-or-later
// Meshtastic data decoder: the embedded OE5DXL lorarx LoRa PHY (vendored in
// native/third_party/lorarx, built with SDRCORE_LORARX_EMBED) followed by the
// native OpenWebRX+ MeshtasticParser port (src/meshtastic).
//
// lorarx is driven with exactly the OpenWebRX+ MeshtasticDemodulator command
// (csdr/module/lora.py) on the receiver's 1 MS/s complex-f32 tap:
//   lorarx -i /dev/stdin -r 1000000 -f f32 -v -N -Q -H 5 -W 50 -b <bw>
//          -s 7 -s 8 -s 9 -s 10 -s 11 -j /dev/stdout
// Every JSON line it would write to -j is parsed like owrx/meshtastic.py does
// (base64 payload + PHY metadata) and becomes one `message` event.
//
// lorarx keeps all state in process globals, so at most one instance can
// demodulate per process. A backend claims the PHY in configure(); a backend
// that has lost the claim (sdr_decoder_select configures the replacement
// before it destroys the previous decoder) stays inert and emits nothing
// instead of corrupting the new owner's state.
#include "decoder.hpp"
#include "lorarx_embed.h"
#include "meshtastic/meshtastic.h"
#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

namespace sdrcore::decoder {
namespace {
constexpr size_t kBlock = LORARX_EMBED_BLOCK_FRAMES;
constexpr size_t kEvents = 256;
constexpr uint32_t kRate = 1000000;

class MeshtasticBackend;
// Guards every lorarx call; lorarx_embed_emit() runs inside block() under it.
std::mutex g_phy_mutex;
MeshtasticBackend* g_owner = nullptr;

// OpenWebRX+ LoraBandwidthInput index for each supported preset bandwidth
// (0:7.8 .. 6:62.5 7:125 8:250 9:500 kHz). SF12 (LongSlow) and the 15.6 kHz
// Tiny presets are outside the OpenWebRX+ SF 7..11 / standard-BW chain.
int bandwidth_index(const std::string& preset) {
  if (preset == "NarrowFast" || preset == "NarrowSlow") return 6;
  if (preset == "LongMod" || preset == "LiteFast" || preset == "LiteSlow") return 7;
  if (preset == "LongFast" || preset == "MediumSlow" || preset == "MediumFast" ||
      preset == "ShortSlow" || preset == "ShortFast") return 8;
  if (preset == "ShortTurbo" || preset == "LongTurbo" || preset == "MediumTurbo") return 9;
  return -1;
}

int64_t now_ms() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch()).count();
}
int64_t steady_ms() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch()).count();
}

// Strict RFC 4648 base64 (lorarx always pads to a multiple of four).
bool base64_decode(const std::string& in, std::vector<uint8_t>& out) {
  auto value = [](char ch) -> int {
    if (ch >= 'A' && ch <= 'Z') return ch - 'A';
    if (ch >= 'a' && ch <= 'z') return ch - 'a' + 26;
    if (ch >= '0' && ch <= '9') return ch - '0' + 52;
    if (ch == '+') return 62;
    if (ch == '/') return 63;
    return -1;
  };
  if (in.size() % 4 != 0) return false;
  out.clear();
  uint32_t bits = 0;
  int nbits = 0;
  size_t pad = 0;
  for (size_t n = 0; n < in.size(); ++n) {
    if (in[n] == '=') {
      if (n + 2 < in.size()) return false;
      ++pad;
      continue;
    }
    if (pad) return false;
    const int v = value(in[n]);
    if (v < 0) return false;
    bits = (bits << 6) | static_cast<uint32_t>(v);
    nbits += 6;
    if (nbits >= 8) {
      nbits -= 8;
      out.push_back(static_cast<uint8_t>(bits >> nbits));
    }
  }
  return pad <= 2;
}

void read_int(const nlohmann::json& row, const char* key, int& out) {
  const auto it = row.find(key);
  if (it != row.end() && it->is_number_integer()) out = it->get<int>();
}
void read_double(const nlohmann::json& row, const char* key, double& out) {
  const auto it = row.find(key);
  if (it != row.end() && it->is_number()) out = it->get<double>();
}

class MeshtasticBackend final : public Decoder {
 public:
  ~MeshtasticBackend() override {
    std::lock_guard<std::mutex> lock(g_phy_mutex);
    if (g_owner == this) {
      lorarx_embed_clear();
      g_owner = nullptr;
    }
  }

  // {"version":1,"settings":{"preset":..,"region":..,"channels":[{name,psk}]}}
  // (lib/ui/decoders/decoder_session.dart). `region` drives Dart quick-tune
  // only. Keys are never logged or echoed.
  bool configure(std::string_view text) override {
    auto doc = nlohmann::json::parse(text, nullptr, false);
    if (doc.is_discarded() || !doc.is_object()) return false;
    const auto version = doc.find("version");
    const auto settings = doc.find("settings");
    if (version == doc.end() || !version->is_number_integer() || *version != 1 ||
        settings == doc.end() || !settings->is_object()) return false;
    meshtastic::ParserConfig config;
    const auto preset = settings->find("preset");
    if (preset != settings->end()) {
      if (!preset->is_string()) return false;
      config.preset = preset->get<std::string>();
    }
    const int bw = bandwidth_index(config.preset);
    if (bw < 0) return false;
    const auto channels = settings->find("channels");
    if (channels != settings->end()) {
      if (!channels->is_array() || channels->size() > 8) return false;
      for (const auto& channel : *channels) {
        if (!channel.is_object()) return false;
        const auto name = channel.find("name");
        const auto psk = channel.find("psk");
        if ((name != channel.end() && !name->is_string()) ||
            psk == channel.end() || !psk->is_string()) return false;
        meshtastic::ChannelConfig entry{
            name == channel.end() ? std::string() : name->get<std::string>(),
            psk->get<std::string>()};
        if (entry.name.size() > 11 ||
            !std::all_of(entry.name.begin(), entry.name.end(),
                         [](unsigned char ch) { return ch >= 32 && ch <= 126; }))
          return false;
        config.channels.push_back(std::move(entry));
      }
    }
    if (!parser_.configure(config)) return false;
    bw_ = bw;
    {
      std::lock_guard<std::mutex> lock(g_phy_mutex);
      g_owner = this;
    }
    reset();
    return ready_;
  }

  // Stream discontinuity: restart lorarx from a clean process state, exactly
  // like OpenWebRX+ restarting the demodulator chain, and forget duplicates.
  void reset() override {
    parser_.reset();
    frames_ = 0;
    pending_.clear();
    std::lock_guard<std::mutex> lock(g_phy_mutex);
    ready_ = false;
    if (g_owner != this || bw_ < 0) return;
    lorarx_embed_clear();
    const std::string bw = std::to_string(bw_);
    std::vector<std::string> args = {
        "lorarx", "-i", "/dev/stdin", "-r", "1000000", "-f", "f32", "-v", "-N",
        "-Q", "-H", "5", "-W", "50", "-b", bw, "-s", "7", "-s", "8", "-s", "9",
        "-s", "10", "-s", "11", "-j", "/dev/stdout"};
    std::vector<char*> argv;
    for (auto& arg : args) argv.push_back(arg.data());
    argv.push_back(nullptr);
    ready_ = lorarx_embed_start(static_cast<int>(args.size()), argv.data()) != 0;
  }

  void set_tuning(uint64_t frequency, uint32_t) override { frequency_ = frequency; }

  void process(const float* iq, size_t frames, uint32_t rate) override {
    if (!ready_ || !iq || rate != kRate) return;
    for (size_t n = 0; n < frames; ++n) {
      const float re = iq[2 * n], im = iq[2 * n + 1];
      buffer_[2 * frames_] = std::isfinite(re) ? re : 0.0f;
      buffer_[2 * frames_ + 1] = std::isfinite(im) ? im : 0.0f;
      if (++frames_ == kBlock) {
        frames_ = 0;
        std::lock_guard<std::mutex> lock(g_phy_mutex);
        if (g_owner != this || !lorarx_embed_block(buffer_.data(), kBlock)) {
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
    const auto count = dropped_;
    dropped_ = 0;
    return count;
  }

  // One lorarx JSON line (owrx/meshtastic.py MeshtasticParser.parse): lines
  // that do not parse, or carry no base64 payload, are ignored.
  void emit(const char* json, size_t length) {
    auto row = nlohmann::json::parse(std::string_view(json, length), nullptr, false);
    if (row.is_discarded() || !row.is_object()) return;
    const auto payload = row.find("payload");
    if (payload == row.end() || !payload->is_string()) return;
    std::vector<uint8_t> bytes;
    if (!base64_decode(payload->get<std::string>(), bytes) ||
        bytes.size() > meshtastic::kMaxLoraPayload) return;
    meshtastic::PhyMeta meta;
    meta.timestamp_ms = now_ms();
    meta.monotonic_ms = steady_ms();
    meta.frequency_hz = frequency_;
    meta.crc = -1;
    read_int(row, "crc", meta.crc);
    double bw_hz = NAN;
    read_double(row, "bw", bw_hz);
    if (std::isfinite(bw_hz)) meta.bw_khz = bw_hz / 1000.0;  // lorarx reports Hz
    read_int(row, "sf", meta.sf);
    read_int(row, "cr", meta.cr);
    read_int(row, "invers", meta.inverted);
    read_int(row, "preamb", meta.preamble);
    read_int(row, "duration", meta.duration_ms);
    read_double(row, "level", meta.level_db);
    read_double(row, "snr", meta.snr_db);
    read_double(row, "nfloor", meta.noise_floor_db);
    read_double(row, "pknfloor", meta.peak_noise_floor_db);
    read_int(row, "afc", meta.afc_hz);
    read_int(row, "fec", meta.fec);
    auto parsed = parser_.parse(bytes.data(), bytes.size(), meta);
    if (!parsed || parsed->size() > 65536) return;
    if (pending_.size() == kEvents) {
      pending_.pop_front();
      ++dropped_;
    }
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
  return std::make_unique<MeshtasticBackend>();
}
}  // namespace sdrcore::decoder

// Called by lorarx only inside lorarx_embed_block(), i.e. with g_phy_mutex
// held by the owning backend's process().
extern "C" void lorarx_embed_emit(const char* json, size_t length) {
  if (sdrcore::decoder::g_owner) sdrcore::decoder::g_owner->emit(json, length);
}
