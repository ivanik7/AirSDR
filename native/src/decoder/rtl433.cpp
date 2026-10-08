// SPDX-License-Identifier: GPL-3.0-or-later
// In-process adapter to upstream rtl_433 r_api/r_flow. IQ remains in the DSP worker.
#include "decoder.hpp"

extern "C" {
#include "rtl_433.h"
#include "r_private.h"
#include "r_api.h"
#include "r_flow.h"
#include "r_device.h"
#include "pulse_detect.h"
#include "pulse_detect_fsk.h"
#include "data.h"
#include "jsmn.h"
#include "logger.h"
}

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace sdrcore::decoder {
namespace {

// Accept exactly the v1 empty-settings object (either key order, optional JSON
// whitespace). Unknown keys, duplicate keys, trailing data and malformed JSON
// do not silently enable a different protocol/settings schema.
bool valid_config(std::string_view json) {
  if (json.size() > 4096) return false;
  jsmn_parser parser;
  jsmn_init(&parser);
  jsmntok_t t[8]{};
  int n = jsmn_parse(&parser, json.data(), json.size(), t, 8);
  if (n != 5 || t[0].type != JSMN_OBJECT || t[0].size != 2 ||
      t[1].type != JSMN_STRING || t[3].type != JSMN_STRING) return false;
  auto equal = [&](const jsmntok_t& tok, std::string_view text) {
    return tok.end >= tok.start &&
           json.substr(tok.start, tok.end - tok.start) == text;
  };
  bool first_version = equal(t[1], "version") && equal(t[3], "settings");
  bool second_version = equal(t[1], "settings") && equal(t[3], "version");
  if (!first_version && !second_version) return false;
  const auto& version = first_version ? t[2] : t[4];
  const auto& settings = first_version ? t[4] : t[2];
  if (version.type != JSMN_PRIMITIVE || !equal(version, "1") ||
      settings.type != JSMN_OBJECT || settings.size != 0) return false;
  auto space = [](char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; };
  size_t begin = 0, end = json.size();
  while (begin < end && space(json[begin])) ++begin;
  while (end > begin && space(json[end - 1])) --end;
  return t[0].start == static_cast<int>(begin) && t[0].end == static_cast<int>(end);
}

class Rtl433 final : public Decoder {
 public:
  Rtl433() {
    // baseband_init() builds shared lookup tables; don't race first use.
    static std::mutex init_mutex;
    std::lock_guard<std::mutex> lock(init_mutex);
    cfg_ = r_create_cfg();
    cfg_->report_time = REPORT_TIME_SAMPLES; // relative input position, not wall-clock
    // Decoder::process has no tuned-frequency parameter. Do not claim that
    // every VFO is 433.92 MHz in the JSON metadata.
    cfg_->report_meta = 0;
    cfg_->center_frequency = DEFAULT_FREQUENCY;
    cfg_->demod->center_frequency = DEFAULT_FREQUENCY;
    cfg_->demod->sample_size = 2;
    cfg_->demod->raw_handler = &cfg_->raw_handler;
    cfg_->demod->load_info.format = CU8_IQ; // file oracle processes silent frames
    cfg_->demod->fsk_pulse_detect_mode = FSK_PULSE_DETECT_OLD;
    register_all_protocols(cfg_, 0);
    for (void **it = cfg_->demod->r_devs.elems; it && *it; ++it) {
      if (static_cast<r_device *>(*it)->modulation >= FSK_DEMOD_MIN_VAL) {
        cfg_->demod->enable_FM_demod = 1;
        break;
      }
    }
    pulse_detect_set_levels(cfg_->demod->pulse_detect, cfg_->demod->use_mag_est,
                            cfg_->demod->level_limit, cfg_->demod->min_level,
                            cfg_->demod->min_snr, cfg_->demod->detect_verbosity);
    auto* output = new Output{};
    output->owner = this;
    output->api.output_print = &Rtl433::on_output;
    output->api.output_free = &Rtl433::free_output;
    list_push(&cfg_->output_handler, output);
    reset();
  }

  ~Rtl433() override {
    if (cfg_) {
      list_free_elems(&cfg_->demod->r_devs, reinterpret_cast<list_elem_free_fn>(free_protocol));
      pulse_detect_free(cfg_->demod->pulse_detect);
      list_free_elems(&cfg_->output_handler, reinterpret_cast<list_elem_free_fn>(data_output_free));
      list_free_elems(&cfg_->demod->dumper, nullptr);
      list_free_elems(&cfg_->in_files, nullptr);
      std::free(cfg_->devices);
      std::free(cfg_->demod);
      std::free(cfg_);
    }
  }

  bool configure(std::string_view json) override { return valid_config(json); }

  void reset() override {
    if (!cfg_) return;
    pending_.clear();
    // Upstream reset intentionally preserves registered protocol configuration.
    cfg_->demod->input_pos = 0;
    cfg_->demod->sample_file_pos = 0;
    cfg_->demod->pulse_data = {};
    cfg_->demod->fsk_pulse_data = {};
    reset_sdr_flow(cfg_);
  }

  void process(const float* samples, size_t frames, uint32_t rate_hz) override {
    if (!samples || rate_hz < 200000 || rate_hz > 300000) return;
    if (cfg_->demod->samp_rate != rate_hz) {
      cfg_->samp_rate = rate_hz;
      cfg_->demod->samp_rate = rate_hz;
      reset();
    }
    // The native DSP branch represents centered RTL CU8 as (u8-127.5)/128.
    // Round at the CU8 boundary, not at a CS16 boundary, and preserve block
    // continuity across process() calls. A fixed buffer bounds worker memory.
    constexpr size_t kFramesPerBlock = 16384;
    while (frames) {
      size_t count = std::min(frames, kFramesPerBlock);
      iq_.resize(count * 2);
      for (size_t i = 0; i < count * 2; ++i) {
        const float scaled = std::isfinite(samples[i]) ? samples[i] * 128.0f + 127.5f : 127.5f;
        iq_[i] = static_cast<uint8_t>(std::clamp(std::lround(scaled), 0L, 255L));
      }
      cfg_->demod->sample_file_pos += static_cast<float>(count) / rate_hz;
      push_sdr_flow(cfg_, iq_.data(), static_cast<uint32_t>(count * 2));
      samples += count * 2;
      frames -= count;
    }
  }

  bool take_event(Event& out) override {
    if (pending_.empty()) return false;
    out = std::move(pending_.front());
    pending_.pop_front();
    return true;
  }

 private:
  struct Output {
    data_output_t api{}; // first member required by upstream data_output_free
    Rtl433* owner = nullptr;
  };
  static void on_output(data_output_t* output, data_t* data) {
    auto* owner = reinterpret_cast<Output*>(output)->owner;
    if (!owner || !data) return;
    // Keep the upstream detector's level estimates but omit its synthetic RF
    // frequency: the branch API does not pass actual tuned VFO frequency.
    const auto& demod = *owner->cfg_->demod;
    const auto& pulse = demod.fsk_pulse_data.fsk_f2_est
                            ? demod.fsk_pulse_data : demod.pulse_data;
    data_str(data, "mod", "Modulation", nullptr,
             demod.fsk_pulse_data.fsk_f2_est ? "FSK" : "ASK");
    data_dbl(data, "rssi", "RSSI", "%.1f dB", pulse.rssi_db);
    data_dbl(data, "snr", "SNR", "%.1f dB", pulse.snr_db);
    data_dbl(data, "noise", "Noise", "%.1f dB", pulse.noise_db);
    char* json = data_print_jsons_dup(data);
    if (!json) return;
    size_t size = std::strlen(json);
    if (size <= 65536 && owner->pending_.size() < 256) {
      Event event{Result::message, {json, json + size}};
      owner->pending_.push_back(std::move(event));
    }
    std::free(json);
  }
  static void free_output(data_output_t* output) {
    delete reinterpret_cast<Output*>(output);
  }
  r_cfg_t* cfg_ = nullptr;
  std::vector<uint8_t> iq_;
  std::deque<Event> pending_;
};
} // namespace

std::unique_ptr<Decoder> create_rtl433() { return std::make_unique<Rtl433>(); }
} // namespace sdrcore::decoder
