// SPDX-License-Identifier: GPL-3.0-or-later
// In-process FlightAware dump1090-fa SC16/magnitude/demod/track adapter.
// Upstream: native/third_party/dump1090/PROVENANCE.md.
#include "decoder.hpp"

extern "C" {
#include "dump1090.h"
void sdrcore_dump1090_reset_modeac(void);
}
#include <nlohmann/json.hpp>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace sdrcore::decoder {
namespace {
constexpr size_t kChunk = 16384;
// Upstream's 8us preamble + 112us message + 16 samples of lookahead.
constexpr size_t kLookahead = (MODES_PREAMBLE_US + MODES_LONG_MSG_BITS + 16) * 12 / 5;
constexpr size_t kMaxAircraft = 128;
constexpr size_t kMaxPayload = 65536;
std::atomic<bool> occupied{false};

int16_t sc16(float value) {
  if (!std::isfinite(value)) return 0;
  return static_cast<int16_t>(std::clamp(value, -1.0f, 1.0f) * 32767.0f);
}

void clear_tracks() {
  while (Modes.aircrafts) {
    auto* next = Modes.aircrafts->next;
    std::free(Modes.aircrafts);
    Modes.aircrafts = next;
  }
}

std::string aircraft_id(uint32_t addr) {
  char buf[9];
  std::snprintf(buf, sizeof(buf), "%s%06X", (addr & MODES_NON_ICAO_ADDRESS) ? "~" : "",
                addr & 0xFFFFFF);
  return buf;
}

nlohmann::json aircraft_json(const aircraft& a) {
  nlohmann::json row = {{"icao", aircraft_id(a.addr)},
                        {"last_seen_ms", a.seen}, {"messages", a.messages}};
  double sum = 0;
  for (double level : a.signalLevel) sum += level;
  if (sum > 0) row["rssi"] = 10.0 * std::log10(sum / 8.0);
  if (trackDataValid(&a.callsign_valid)) {
    std::string flight(a.callsign, strnlen(a.callsign, 8));
    const auto end = flight.find_last_not_of(' ');
    if (end != std::string::npos) row["callsign"] = flight.substr(0, end + 1);
  }
  if (trackDataValid(&a.squawk_valid)) {
    char squawk[5];
    std::snprintf(squawk, sizeof(squawk), "%04X", a.squawk & 0xFFFF);
    row["squawk"] = squawk;
  }
  if (trackDataValid(&a.altitude_geom_valid)) row["altitude_ft"] = a.altitude_geom;
  else if (trackDataValid(&a.altitude_baro_valid)) row["altitude_ft"] = a.altitude_baro;
  if (trackDataValid(&a.gs_valid)) row["ground_speed_kt"] = a.gs;
  if (trackDataValid(&a.track_valid)) row["track_deg"] = a.track;
  if (trackDataValid(&a.geom_rate_valid)) row["vertical_rate_fpm"] = a.geom_rate;
  else if (trackDataValid(&a.baro_rate_valid)) row["vertical_rate_fpm"] = a.baro_rate;
  if (trackDataValid(&a.position_valid)) {
    row["latitude"] = a.lat;
    row["longitude"] = a.lon;
  }
  return row;
}

class AdsbBackend final : public Decoder {
 public:
  AdsbBackend() { reset(); }
  ~AdsbBackend() override {
    clear_tracks();
    occupied.store(false, std::memory_order_release);
  }

  bool configure(std::string_view text) override {
    if (text.empty()) return false;
    auto doc = nlohmann::json::parse(text, nullptr, false);
    if (doc.is_discarded() || !doc.is_object() || doc.size() != 2 ||
        !doc.contains("version") || !doc["version"].is_number_integer() ||
        doc["version"] != 1 || !doc.contains("settings") ||
        !doc["settings"].is_object() || !doc["settings"].empty()) return false;
    return true;
  }

  void reset() override {
    clear_tracks();
    // Upstream uses process-global tables/state. The factory enforces exactly
    // one owner, including while stopped. No second independent receiver.
    Modes.stats_current = {};
    Modes.quiet = 1;
    Modes.net = 0;
    Modes.mode_ac = 1;
    Modes.fix_df = 1;
    Modes.nfix_crc = 0; // OpenWebRX+ does not pass --fix.
    Modes.sample_rate = 2400000;
    Modes.maxRange = 1852 * 300;
    Modes.bUserFlags = 0; // No implicit receiver location.
    Modes.fUserLat = Modes.fUserLon = 0;
    Modes.adaptive_burst_control = Modes.adaptive_range_control = false;
    modesChecksumInit(0);
    icaoFilterInit();
    // Upstream's reverse Mode A/C table is process-global and built with an
    // assertion that each slot is empty. Rebuilding it on retune or a new
    // decoder session aborts Debug builds; its contents never change.
    static std::once_flag mode_ac_initialized;
    std::call_once(mode_ac_initialized, modeACInit);
    sdrcore_dump1090_reset_modeac();
    _messageNow = 0;
    iq_.clear();
    magnitude_.clear();
    sample_offset_ = 0;
    first_block_ = true;
    start_ms_ = 0;
    last_snapshot_ms_ = 0;
    previous_messages_ = 0;
    pending_ = {};
    pending_valid_ = false;
  }

  void process(const float* samples, size_t frames, uint32_t rate) override {
    if (!samples || rate != 2400000 || frames == 0) return;
    const uint64_t now = mstime();
    if (!start_ms_) start_ms_ = now;
    // Bound work and allocation on malformed caller input; the receiver sends
    // modest blocks, so this limit is well above its ordinary callback size.
    if (frames > 2400000) { reset(); return; }
    iq_.reserve(iq_.size() + frames);
    for (size_t i = 0; i < frames; ++i)
      iq_.push_back(sc16_t{sc16(samples[2 * i]), sc16(samples[2 * i + 1])});
    while (iq_.size() >= kChunk + kLookahead) {
      magnitude_.resize(kChunk + kLookahead);
      starch_magnitude_sc16(iq_.data(), magnitude_.data(),
                            static_cast<unsigned>(magnitude_.size()));
      double mean_level = 0, mean_power = 0;
      starch_mean_power_u16(magnitude_.data(), static_cast<unsigned>(magnitude_.size()),
                            &mean_level, &mean_power);
      mag_buf block{};
      block.data = magnitude_.data();
      block.totalLength = block.validLength = static_cast<unsigned>(magnitude_.size());
      block.overlap = kLookahead;
      block.sampleTimestamp = sample_offset_ * 5; // 12 MHz ticks at 2.4 MS/s.
      block.sysTimestamp = start_ms_ + sample_offset_ * 1000 / 2400000;
      block.mean_level = mean_level;
      block.mean_power = mean_power;
      if (first_block_) block.flags = MAGBUF_DISCONTINUOUS;
      demodulate2400(&block);
      demodulate2400AC(&block);
      first_block_ = false;
      sample_offset_ += kChunk;
      iq_.erase(iq_.begin(), iq_.begin() + kChunk);
    }
    if (!last_snapshot_ms_) last_snapshot_ms_ = now;
    if (now - last_snapshot_ms_ >= 1000) {
      icaoFilterExpire();
      trackPeriodicUpdate();
      _messageNow = now;
      emit_snapshot(now, now - last_snapshot_ms_);
      last_snapshot_ms_ = now;
    }
  }

  bool take_event(Event& out) override {
    if (!pending_valid_) return false;
    out = std::move(pending_);
    pending_ = {};
    pending_valid_ = false;
    return true;
  }

 private:
  void emit_snapshot(uint64_t now, uint64_t interval_ms) {
    std::vector<const aircraft*> sorted;
    for (const aircraft* a = Modes.aircrafts; a; a = a->next)
      if (a->reliable && a->seen <= now && now - a->seen <= TRACK_AIRCRAFT_TTL)
        sorted.push_back(a);
    std::sort(sorted.begin(), sorted.end(), [](const aircraft* a, const aircraft* b) {
      if (a->seen != b->seen) return a->seen > b->seen;
      return aircraft_id(a->addr) < aircraft_id(b->addr);
    });
    nlohmann::json doc = {{"version", 1}, {"source", "adsb"},
                          {"timestamp_ms", now}, {"input_rate_hz", 2400000},
                          {"message_rate", static_cast<double>(Modes.stats_current.messages_total - previous_messages_) * 1000.0 / interval_ms},
                          {"crc_fixed", Modes.stats_current.demod_accepted[1] + Modes.stats_current.demod_accepted[2]},
                          {"aircraft", nlohmann::json::array()}};
    previous_messages_ = Modes.stats_current.messages_total;
    for (size_t i = 0; i < std::min(sorted.size(), kMaxAircraft); ++i) {
      doc["aircraft"].push_back(aircraft_json(*sorted[i]));
      // The cap is on serialized bytes too; drop oldest, never fragment JSON.
      if (doc.dump().size() > kMaxPayload) {
        doc["aircraft"].erase(doc["aircraft"].end() - 1);
        break;
      }
    }
    const auto text = doc.dump();
    if (text.size() <= kMaxPayload) {
      pending_ = Event{Result::aircraft, {text.begin(), text.end()}};
      pending_valid_ = true;
    }
  }

  std::vector<sc16_t> iq_;
  std::vector<uint16_t> magnitude_;
  uint64_t sample_offset_ = 0;
  uint64_t start_ms_ = 0;
  uint64_t last_snapshot_ms_ = 0;
  uint64_t previous_messages_ = 0;
  bool first_block_ = true;
  Event pending_{};
  bool pending_valid_ = false;
};
} // namespace

std::unique_ptr<Decoder> create_adsb() {
  bool expected = false;
  if (!occupied.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) return nullptr;
  try { return std::make_unique<AdsbBackend>(); }
  catch (...) { occupied.store(false, std::memory_order_release); throw; }
}
} // namespace sdrcore::decoder
