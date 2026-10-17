// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise the DMR front end through the sole receiver's native VFO tap.
#include "../src/dmr/channel_tap.hpp"
#include "../src/dsp/receiver.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

namespace {
constexpr double kPi = 3.14159265358979323846;
bool nominal_if_count(uint64_t samples) { return samples >= 9600 && samples <= 9601; }

struct Symbols final : sdrcore::dmr::SymbolSink {
  std::vector<uint8_t> dibits;
  void on_symbols(const uint8_t* data, size_t n) override {
    dibits.insert(dibits.end(), data, data + n);
  }
};

class DmrProbe final : public sdrcore::dmr::ChannelDecoder {
 public:
  bool configure(std::string_view) override { return true; }
  void reset() override { ChannelDecoder::reset(); ++resets; symbols.dibits.clear(); }
  void process(const float* iq, size_t count, uint32_t rate) override {
    ChannelDecoder::process(iq, count, rate);
    ++blocks;
  }
  void on_symbols(const uint8_t* data, size_t n) override {
    symbols.on_symbols(data, n);
  }
  bool take_event(sdrcore::decoder::Event&) override { return false; }
  Symbols symbols;
  const sdrcore::dmr::ChannelTap& tap = channel_tap();
  int resets = 0;
  int blocks = 0;
};

SdrV3Controls controls(uint32_t rate) {
  SdrV3Controls c{};
  c.size = sizeof c;
  c.revision = SDR_V3_REVISION;
  c.sample_rate = rate;
  c.center_frequency_hz = 446000000;
  c.bandwidth_hz = 12500;
  c.mode = SDR_V3_NFM;
  c.squelch = SDR_V3_SQUELCH_MANUAL;
  c.squelch_level_db = 0; // closed analog squelch must not gate DMR symbols
  c.muted = 1;
  c.volume = 0;
  return c;
}
SdrV3Display display() {
  SdrV3Display d{};
  d.size = sizeof d;
  d.revision = SDR_V3_REVISION;
  d.width = 0;
  return d;
}
std::vector<uint8_t> iq(uint32_t rate) {
  // Four-level FM symbol runs at 4800 baud. All samples enter the same CU8
  // receiver as normal reception, not a second, pre-decimated path.
  std::vector<uint8_t> result(rate / 5 * 2);
  const int levels[] = {-1800, -600, 600, 1800};
  double phase = 0;
  for (size_t i = 0; i < result.size() / 2; ++i) {
    phase += 2 * kPi * levels[((i * 4800 / rate) / 12) % 4] / rate;
    result[2 * i] = static_cast<uint8_t>(std::lround(127.5 + 90 * std::cos(phase)));
    result[2 * i + 1] = static_cast<uint8_t>(std::lround(127.5 + 90 * std::sin(phase)));
  }
  return result;
}
void feed(sdrcore::dsp::Receiver& rx, const std::vector<uint8_t>& source) {
  sdrcore::dsp::ProcessResult output;
  for (size_t pos = 0; pos < source.size(); pos += 16384)
    rx.process(source.data() + pos, std::min<size_t>(16384, source.size() - pos), output);
}
void check_rate(uint32_t device_rate, uint32_t tap_rate) {
  auto rx = sdrcore::dsp::make_receiver();
  rx->configure(controls(device_rate), display());
  DmrProbe probe;
  assert(rx->set_decoder(&probe) == tap_rate);
  const auto source = iq(device_rate);
  feed(*rx, source);
  std::fprintf(stderr, "device=%u tap=%u if=%llu symbols=%zu blocks=%d\n",
      device_rate, probe.tap.input_rate_hz(),
      static_cast<unsigned long long>(probe.tap.if_samples()),
      probe.symbols.dibits.size(), probe.blocks);
  assert(probe.tap.input_rate_hz() == tap_rate);
  // A finite fractional-rate block can include one extra phase-boundary sample.
  assert(nominal_if_count(probe.tap.if_samples()));
  assert(probe.symbols.dibits.size() > 900 && probe.symbols.dibits.size() <= 960);
  const auto first = probe.symbols.dibits;
  // Reset must clear the tap, the 48 kS/s IF, RRC, and symbol-clock history.
  rx->reset();
  assert(probe.symbols.dibits.empty());
  assert(probe.tap.if_samples() == 0);
  feed(*rx, source);
  assert(probe.symbols.dibits == first);
  // Without a selected decoder, no DSP work or symbols are produced.
  assert(rx->set_decoder(nullptr) == 0);
  feed(*rx, source);
  assert(probe.symbols.dibits == first);
}
void change_rate_and_retune() {
  auto rx = sdrcore::dsp::make_receiver();
  rx->configure(controls(2400000), display());
  DmrProbe probe;
  assert(rx->set_decoder(&probe) == 240000);
  feed(*rx, iq(2400000));
  auto changed = controls(2500000);
  rx->configure(changed, display());
  assert(probe.resets >= 2);
  assert(probe.symbols.dibits.empty());
  assert(rx->decoder_rate_hz() == 250000);
  feed(*rx, iq(2500000));
  assert(probe.tap.input_rate_hz() == 250000);
  assert(nominal_if_count(probe.tap.if_samples()));
  assert(probe.symbols.dibits.size() > 900);
  const int before = probe.resets;
  changed.vfo_offset_hz = 1000;
  rx->configure(changed, display());
  assert(probe.resets == before + 1);
  assert(probe.symbols.dibits.empty());
  rx->retune();
  assert(probe.resets == before + 2);
  assert(probe.tap.if_samples() == 0);
  feed(*rx, iq(2500000));
  assert(probe.tap.input_rate_hz() == 250000);
  assert(nominal_if_count(probe.tap.if_samples()));
}
void invalid_rate() {
  Symbols symbols;
  sdrcore::dmr::ChannelTap tap(symbols);
  const float sample[] = {1.0f, 0.0f};
  assert(!tap.process(sample, 1, 47999));
  assert(tap.process(sample, 1, 240000));
  assert(tap.input_rate_hz() == 240000);
  assert(!tap.process(sample, 1, 300001));
  assert(tap.input_rate_hz() == 0);
  assert(tap.process(sample, 1, 288000));
  assert(tap.input_rate_hz() == 288000);
}
} // namespace

int main() {
  check_rate(2400000, 240000);
  check_rate(2500000, 250000);
  check_rate(2880000, 240000);
  check_rate(576000, 288000);
  change_rate_and_retune();
  invalid_rate();
}
