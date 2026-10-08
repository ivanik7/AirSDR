// SPDX-License-Identifier: GPL-3.0-or-later
#include "../src/dsp/receiver.h"
#include "decoder.hpp"
#include <cassert>
#include <complex>
#include <cmath>
#include <cstdint>
#include <vector>

class Probe final : public sdrcore::decoder::Decoder {
 public:
  bool configure(std::string_view) override { return true; }
  void reset() override { ++resets; frames = 0; sum = {0, 0}; } 
  void process(const float* iq, size_t n, uint32_t rate) override {
    assert(rate >= 200000 && rate <= 300000);
    frames += n;
    for (size_t i = 0; i < n; ++i) sum += std::complex<double>(iq[2*i], iq[2*i+1]);
  }
  bool take_event(sdrcore::decoder::Event&) override { return false; }
  int resets = 0;
  size_t frames = 0;
  std::complex<double> sum{};
};
int main() {
  auto rx = sdrcore::dsp::make_receiver();
  Probe probe;
  SdrV3Controls c{};
  c.size = sizeof c; c.revision = SDR_V3_REVISION;
  c.sample_rate = 2400000; c.bandwidth_hz = 12000;
  c.mode = SDR_V3_NFM; c.volume = 1;
  c.vfo_offset_hz = 60000;
  SdrV3Display d{};
  d.size = sizeof d; d.revision = SDR_V3_REVISION;
  d.width = 256; d.view_bandwidth_hz = c.sample_rate;
  rx->configure(c, d);
  assert(rx->decoder_rate_hz() == 0);
  assert(rx->set_decoder(&probe) >= 200000);
  assert(rx->decoder_rate_hz() <= 300000);
  assert(probe.resets > 0);
  // A station at +60 kHz from the RF center must mix down to near DC.
  std::vector<uint8_t> iq(240000);
  for (size_t i = 0; i < iq.size()/2; ++i) {
    double phase = 2 * 3.141592653589793 * 60000 * i / c.sample_rate;
    iq[2*i] = static_cast<uint8_t>(std::lround(127.5 + 70 * std::cos(phase)));
    iq[2*i+1] = static_cast<uint8_t>(std::lround(127.5 + 70 * std::sin(phase)));
  }
  sdrcore::dsp::ProcessResult result;
  rx->process(iq.data(), iq.size(), result);
  assert(probe.frames > 10000);
  assert(std::abs(probe.sum) / probe.frames > 0.4);
  const int resets = probe.resets;
  c.vfo_offset_hz = -60000;
  rx->configure(c, d);
  assert(probe.resets > resets);
  rx->process(iq.data(), iq.size(), result);
  assert(probe.frames > 10000);
  assert(std::abs(probe.sum) / probe.frames < 0.02);
  rx->retune();
  assert(probe.frames == 0);
  rx->set_decoder(nullptr);
  assert(rx->decoder_rate_hz() == 0);
  c.sample_rate = 192000; d.view_bandwidth_hz = c.sample_rate;
  rx->configure(c, d);
  assert(rx->set_decoder(&probe) == 0);
  assert(rx->decoder_rate_hz() == 0);
}
