// SPDX-License-Identifier: GPL-3.0-or-later
#include "../src/dsp/receiver.h"
#include "decoder.hpp"
#include <cassert>
#include <cmath>
#include <complex>
#include <cstdint>
#include <vector>

class Probe final : public sdrcore::decoder::Decoder {
 public:
  bool configure(std::string_view) override { return true; }
  void reset() override { ++resets; frames = 0; sum = {}; nonzero = 0; }
  void process(const float* iq, size_t n, uint32_t rate) override {
    assert(rate == 1000000);
    frames += n;
    for (size_t i = 0; i < n; ++i) {
      const std::complex<double> value{iq[2*i], iq[2*i+1]};
      sum += value;
      if (std::abs(value) > 0.1) ++nonzero;
    }
  }
  bool take_event(sdrcore::decoder::Event&) override { return false; }
  size_t frames = 0, nonzero = 0;
  int resets = 0;
  std::complex<double> sum{};
};

int main() {
  auto rx = sdrcore::dsp::make_receiver();
  Probe probe;
  SdrV3Controls c{};
  c.size = sizeof c; c.revision = SDR_V3_REVISION;
  c.sample_rate = 2400000; c.center_frequency_hz = 869525000;
  c.bandwidth_hz = 12000; c.mode = SDR_V3_NFM; c.volume = 1;
  c.vfo_offset_hz = 100000;
  SdrV3Display d{};
  d.size = sizeof d; d.revision = SDR_V3_REVISION;
  d.width = 256; d.view_bandwidth_hz = c.sample_rate;
  rx->configure(c, d);
  assert(rx->set_decoder(&probe, sdrcore::decoder::Input::baseband, 1000000) == 1000000);
  sdrcore::dsp::ProcessResult result;
  std::vector<uint8_t> iq(48000);
  for (int block = 0; block < 10; ++block) {
    for (size_t i = 0; i < iq.size()/2; ++i) {
      const double phase = 2 * 3.141592653589793 * 100000 *
          (i + static_cast<size_t>(block) * iq.size()/2) / c.sample_rate;
      iq[2*i] = static_cast<uint8_t>(std::lround(127.5 + 70 * std::cos(phase)));
      iq[2*i+1] = static_cast<uint8_t>(std::lround(127.5 + 70 * std::sin(phase)));
    }
    rx->process(iq.data(), iq.size(), result);
  }
  assert(probe.frames >= 99990 && probe.frames <= 100010);
  assert(std::abs(probe.sum) / probe.frames > 0.4);
  const int resets = probe.resets;
  c.vfo_offset_hz = -100000;
  rx->configure(c, d);
  assert(probe.resets > resets);
  rx->process(iq.data(), iq.size(), result);
  assert(probe.frames > 9900 && probe.frames < 10100);
  assert(std::abs(probe.sum) / probe.frames < 0.02);
  c.vfo_offset_hz = 0;
  for (const auto rate : {1000000u, 1024000u, 2000000u, 2400000u}) {
    c.sample_rate = rate; d.view_bandwidth_hz = rate;
    rx->configure(c, d);
    assert(rx->decoder_rate_hz() == 1000000);
  }
  c.sample_rate = 960000; d.view_bandwidth_hz = c.sample_rate;
  rx->configure(c, d);
  assert(rx->decoder_rate_hz() == 0); // Never silently upsample.
  c.sample_rate = 1000000; c.vfo_offset_hz = 200000;
  rx->configure(c, d);
  assert(rx->decoder_rate_hz() == 0); // +/-500 kHz window cannot fit.
  c.vfo_offset_hz = 0;
  rx->configure(c, d);
  assert(rx->decoder_rate_hz() == 1000000);

  // Manual IQ squelch has a 62,500-sample measurement window, 125k hang,
  // and 312.5k flush before it stops feeding a silent decoder.
  c.squelch = SDR_V3_SQUELCH_MANUAL;
  c.squelch_level_db = -15;
  rx->configure(c, d);
  std::vector<uint8_t> strong(20000, 227);
  for (int i = 0; i < 14; ++i) rx->process(strong.data(), strong.size(), result);
  assert(probe.nonzero > 0);
  std::vector<uint8_t> quiet(20000, 128);
  for (int i = 0; i < 85; ++i) rx->process(quiet.data(), quiet.size(), result);
  const size_t stopped = probe.frames;
  for (int i = 0; i < 8; ++i) rx->process(quiet.data(), quiet.size(), result);
  assert(probe.frames == stopped);
  assert(stopped > 125000 && stopped < 850000);
  rx->retune();
  assert(probe.frames == 0);
  rx->set_decoder(nullptr);
  assert(rx->decoder_rate_hz() == 0);
}
