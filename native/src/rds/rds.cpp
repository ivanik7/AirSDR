// SPDX-License-Identifier: GPL-3.0-or-later
#include "rds.h"

#include "src/channel.hh"
#include "src/dsp/liquid_wrappers.hh"
#include "src/dsp/subcarrier.hh"
#include "src/io/input.hh"
#include "src/options.hh"

#include <algorithm>
#include <array>
#include <cmath>
#include <deque>
#include <memory>
#include <sstream>
#include <stdexcept>

namespace sdrcore::rds {

struct Sink::State {
  uint32_t rate = 0;
  bool rbds = false;
  redsea::Options options;
  std::unique_ptr<redsea::Channel> channel;
  std::unique_ptr<redsea::SubcarrierSet> subcarrier;
  std::unique_ptr<liquid::Resampler> resampler;
  redsea::MPXBuffer input;
  std::ostringstream output;
  std::deque<std::string> groups;
  bool had_group = false;
};

Sink::Sink() : state_(std::make_unique<State>()) {}
Sink::~Sink() = default;

void Sink::configure(uint32_t input_rate_hz, bool rbds) {
  // A 57 kHz RDS subcarrier needs at least 114 kHz of passband; redsea's
  // input floor is 128 kHz. Narrow WFM is not silently widened.
  if (input_rate_hz < 128000 || input_rate_hz > 3000000) input_rate_hz = 0;
  if (state_->rate == input_rate_hz && state_->rbds == rbds) return;
  state_->rate = input_rate_hz;
  state_->rbds = rbds;
  state_->options = {};
  state_->options.rbds = rbds;
  state_->options.samplerate = 200000;
  state_->channel.reset();
  state_->subcarrier.reset();
  state_->resampler.reset();
  state_->groups.clear();
  state_->input.used_size = 0;
  state_->had_group = false;
  if (!input_rate_hz) return;
  state_->channel = std::make_unique<redsea::Channel>(state_->options, 0);
  state_->subcarrier = std::make_unique<redsea::SubcarrierSet>(200000);
  state_->resampler = std::make_unique<liquid::Resampler>(13);
  state_->resampler->setRatio(200000.f / input_rate_hz);
}

void Sink::reset() {
  // Channel owns block sync, PI error correction and station assembly; never
  // carry any of it across a stream/tune/mode/RBDS boundary. It is cheap to
  // rebuild (~2 us). The filter banks are not: constructing SubcarrierSet and
  // the liquid resampler designs every FIR/RRC bank again (~13 ms on the
  // Linux dev host, more on the phone). reset() runs on the DSP thread up to
  // four times per frequency switch (and on the caller's thread for every
  // VFO move), so a full rebuild here drained the 60 ms playback cushion and
  // punched an audible hole into the audio on every switch (t_8063d101).
  // Keep the filters and only restart their tracking state, exactly as
  // upstream redsea recovers from a lost carrier (subcarrier reset + new PI).
  // Residual FIR history (< 2 ms) cannot form a block: the syndrome check
  // needs consecutive valid blocks before Channel emits a group.
  state_->groups.clear();
  state_->input.used_size = 0;
  state_->had_group = false;
  state_->output.str("");
  state_->output.clear();
  if (!state_->channel) return;
  state_->channel = std::make_unique<redsea::Channel>(state_->options, 0);
  state_->subcarrier->reset();
}

void Sink::process(const float* mpx, size_t count) {
  if (!state_->channel || !mpx) return;
  auto flush = [this] {
    if (!state_->input.used_size) return;
    auto bits = state_->subcarrier->chunkToBits(state_->input, 1);
    state_->channel->processBits(bits, state_->output);
    if (state_->channel->getSecondsSinceCarrierLost() > 10.f &&
        state_->subcarrier->getSecondsSinceLastReset() > 5.f) {
      state_->subcarrier->reset();
      state_->channel->resetPI();
    }
    std::istringstream lines(state_->output.str());
    std::string line;
    while (std::getline(lines, line)) {
      if (line.empty()) continue;
      state_->had_group = true;
      if (state_->groups.size() == 128) state_->groups.pop_front();
      state_->groups.emplace_back(std::move(line));
    }
    state_->output.str("");
    state_->output.clear();
    state_->input.used_size = 0;
  };
  std::array<float, 2> output{};
  for (size_t i = 0; i < count; ++i) {
    // OpenWebRX+ writes signed 16-bit MPX to redsea. Reproduce that clipping
    // and quantization rather than passing unlimited discriminator floats.
    const auto pcm = static_cast<int16_t>(std::lrint(
        std::clamp(mpx[i], -1.f, 32767.f / 32768.f) * 32768.f));
    const uint32_t n = state_->resampler->execute(pcm / 32768.f, output);
    for (uint32_t j = 0; j < n; ++j) {
      state_->input.data[state_->input.used_size++] = output[j];
      if (state_->input.used_size == redsea::kInputChunkSize) flush();
    }
  }
  flush();
}

bool Sink::take_group(std::string& json) {
  if (state_->groups.empty()) return false;
  json = std::move(state_->groups.front());
  state_->groups.pop_front();
  return true;
}

bool Sink::synced() const {
  return state_->channel && state_->had_group &&
      state_->channel->getSecondsSinceCarrierLost() < 10.f;
}

}  // namespace sdrcore::rds
