// SPDX-License-Identifier: GPL-3.0-or-later
#include "../src/dsp/receiver.h"
#include "decoder.hpp"
#include <algorithm>
#include <cassert>
#include <cmath>
#include <complex>
#include <cstdint>
#include <vector>

namespace {
class Probe final : public sdrcore::decoder::Decoder {
 public:
  bool configure(std::string_view) override { return true; }
  void reset() override { ++resets; frames = 0; sum = {}; matched = {}; }
  void process(const float* iq, size_t n, uint32_t rate) override {
    assert(rate == 2400000);
    frames += n;
    for (size_t i = 0; i < n; ++i) {
      const std::complex<double> value(iq[2*i], iq[2*i+1]);
      sum += value;
      const double phase = -2 * 3.141592653589793 * 400000 * (frames - n + i) / rate;
      matched += value * std::polar(1.0, phase);
    }
  }
  bool take_event(sdrcore::decoder::Event&) override { return false; }
  int resets = 0;
  size_t frames = 0;
  std::complex<double> sum{};
  std::complex<double> matched{};
};
void feed(sdrcore::dsp::Receiver& rx, uint32_t rate, uint32_t tone, size_t samples) {
  sdrcore::dsp::ProcessResult result;
  constexpr double pi = 3.141592653589793;
  // Odd block sizes must not change the output rate or lose phase.
  for (size_t start = 0; start < samples;) {
    const size_t n = std::min<size_t>(4093, samples - start);
    std::vector<uint8_t> data(n * 2);
    for (size_t i = 0; i < n; ++i) {
      const double phase = 2 * pi * tone * (start + i) / rate;
      data[2*i] = static_cast<uint8_t>(std::lround(127.5 + 70 * std::cos(phase)));
      data[2*i+1] = static_cast<uint8_t>(std::lround(127.5 + 70 * std::sin(phase)));
    }
    rx.process(data.data(), data.size(), result);
    start += n;
  }
}
} // namespace

int main() {
  auto rx = sdrcore::dsp::make_receiver();
  Probe probe;
  SdrV3Controls c{};
  c.size = sizeof c; c.revision = SDR_V3_REVISION;
  c.sample_rate = 2400000; c.bandwidth_hz = 12000;
  c.mode = SDR_V3_NFM; c.volume = 1;
  SdrV3Display d{};
  d.size = sizeof d; d.revision = SDR_V3_REVISION;
  d.width = 256; d.view_bandwidth_hz = c.sample_rate;
  rx->configure(c, d);
  assert(rx->set_decoder(&probe, sdrcore::decoder::Input::raw_iq) == 2400000);
  feed(*rx, c.sample_rate, 0, 24000);
  assert(probe.frames == 24000); // Direct tap: no integer decimation.
  assert(std::abs(probe.sum) / probe.frames > 0.4);

  c.sample_rate = 2500000; d.view_bandwidth_hz = c.sample_rate;
  c.vfo_offset_hz = 25000;
  rx->configure(c, d);
  assert(probe.resets > 1);
  assert(rx->decoder_rate_hz() == 2400000);
  feed(*rx, c.sample_rate, 25000, 250000);
  assert(probe.frames >= 239999 && probe.frames <= 240001);
  assert(std::abs(probe.sum) / probe.frames > 0.35);

  // Large rational steps must use the integer AND fractional sample delay;
  // matching only the fractional part distorts a high-rate source's tones.
  c.sample_rate = 8000000; c.vfo_offset_hz = 0;
  d.view_bandwidth_hz = c.sample_rate;
  rx->configure(c, d);
  assert(rx->decoder_rate_hz() == 2400000);
  feed(*rx, c.sample_rate, 400000, 80000);
  assert(probe.frames >= 23999 && probe.frames <= 24001);
  assert(std::abs(probe.matched) / probe.frames > 0.35);

  c.sample_rate = 2500000; c.vfo_offset_hz = 25000;
  d.view_bandwidth_hz = c.sample_rate;
  rx->configure(c, d);

  rx->retune();
  assert(probe.frames == 0);
  feed(*rx, c.sample_rate, 25000, 25000);
  assert(probe.frames >= 23999 && probe.frames <= 24001);

  const int before_mode = probe.resets;
  c.mode = SDR_V3_AM;
  rx->configure(c, d);
  assert(probe.resets > before_mode && probe.frames == 0);

  // The current tuned frequency must have the full +/-1.2 MHz capture window.
  c.vfo_offset_hz = 60000;
  rx->configure(c, d);
  assert(rx->decoder_rate_hz() == 0);
  probe.frames = 0;
  feed(*rx, c.sample_rate, 60000, 25000);
  assert(probe.frames == 0);

  c.vfo_offset_hz = 0;
  c.sample_rate = 2200000; d.view_bandwidth_hz = c.sample_rate;
  rx->configure(c, d);
  assert(rx->decoder_rate_hz() == 0);
  c.sample_rate = 2400000; d.view_bandwidth_hz = c.sample_rate;
  rx->configure(c, d);
  assert(rx->decoder_rate_hz() == 2400000);
  rx->set_decoder(nullptr);
  assert(rx->decoder_rate_hz() == 0);
}
