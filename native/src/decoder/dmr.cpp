// SPDX-License-Identifier: GPL-3.0-or-later
// Thin, worker-thread-only adapter over the upstream DMR channel, digiham
// framing and mbelib synthesis. No tuner, subprocess or sample FFI.
#include "dmr/backend.hpp"
#include "dmr/channel_tap.hpp"
#include "dmr/framing.hpp"
#include "dmr/vocoder.hpp"
#include <nlohmann/json.hpp>

#include <cstdint>
#include <deque>
#include <memory>
#include <string>
#include <string_view>
#include <utility>

namespace sdrcore::decoder {
namespace {
using nlohmann::json;

class Dmr final : public dmr::ChannelDecoder {
 public:
  Dmr() : framing_(dmr::framing_voice_sink(voice_),
                    [this](const dmr::SlotMeta& meta) { on_metadata(meta); }) {}

  bool configure(std::string_view text) override {
    if (text.empty() || text.size() > 4096) return false;
    auto config = json::parse(text, nullptr, false);
    if (config.is_discarded() || !config.is_object() || config.size() != 4 ||
        !config.contains("schema") || config["schema"] != "dmr/1" ||
        !config.contains("slot_filter") || !config["slot_filter"].is_number_integer() ||
        !config.contains("color_code") || !config["color_code"].is_number_integer() ||
        !config.contains("voice") || !config["voice"].is_boolean()) return false;
    const auto slot = config["slot_filter"].get<int>();
    const auto color = config["color_code"].get<int>();
    if (slot < 1 || slot > 3 || color < -1 || color > 15) return false;
    slot_filter_ = static_cast<uint8_t>(slot);
    color_code_ = color;
    voice_enabled_ = config["voice"].get<bool>();
    reset();
    return true;
  }

  void reset() override {
    ChannelDecoder::reset();
    voice_.reset();
    voice_.set_enabled(voice_enabled_);
    events_.clear();
    framing_.reset(); // Two real no-sync slot events, no stale calls or PCM.
    framing_.set_slot_filter(slot_filter_);
    framing_.set_color_filter(color_code_);
  }

  void on_symbols(const uint8_t* dibits, size_t count) override {
    framing_.on_symbols(dibits, count);
  }

  bool provides_audio() const override { return voice_enabled_ && dmr::vocoder_available(); }
  size_t read_audio(float* mono, size_t frames) override {
    return provides_audio() ? voice_.read_audio(mono, frames) : 0;
  }
  bool take_event(Event& out) override {
    if (events_.empty()) return false;
    out = std::move(events_.front());
    events_.pop_front();
    return true;
  }
  uint64_t take_dropped_count() override {
    auto count = dropped_;
    dropped_ = 0;
    return count;
  }

 private:
  void on_metadata(const dmr::SlotMeta& meta) {
    json value = {{"schema", "dmr/1"}, {"protocol", "DMR"},
                  {"slot", meta.slot},
                  {"voice", !dmr::vocoder_available() ? "unavailable" :
                                voice_enabled_ ? "ok" : "muted"}};
    if (meta.sync == 2) value["sync"] = "voice";
    else if (meta.sync == 1) value["sync"] = "data";
    if (meta.type == 2) value["type"] = "group";
    else if (meta.type == 1) value["type"] = "direct";
    if (meta.source) value["source"] = meta.source;
    if (meta.target) value["target"] = meta.target;
    if (meta.color_code != 0xff) value["color_code"] = meta.color_code;
    if (meta.privacy) value["privacy"] = *meta.privacy;
    if (meta.duration_ms) value["duration_ms"] = meta.duration_ms;
    if (!meta.alias.empty()) value["talkeralias"] = meta.alias;
    if (meta.latlon) {
      value["lat"] = meta.latlon->first;
      value["lon"] = meta.latlon->second;
    }
    const auto data = value.dump(-1, ' ', false, json::error_handler_t::replace);
    if (data.size() > 65536) { ++dropped_; return; }
    if (events_.size() == 64) { events_.pop_front(); ++dropped_; }
    events_.push_back(Event{Result::message, {data.begin(), data.end()}});
  }

  // Declaration order: voice must outlive framing's callback; both are
  // confined to Decoder::process() on the DSP worker.
  dmr::VoiceOutput voice_;
  dmr::Framing framing_;
  std::deque<Event> events_;
  uint64_t dropped_ = 0;
  uint8_t slot_filter_ = 3;
  int color_code_ = -1;
  bool voice_enabled_ = true;
};
}  // namespace

std::unique_ptr<Decoder> create_dmr() { return std::make_unique<Dmr>(); }
}  // namespace sdrcore::decoder
