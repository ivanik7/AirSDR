// SPDX-License-Identifier: GPL-3.0-or-later
#include "dmr/channel.hpp"
#include "dmr/channel_filter.hpp"
#include <csdr/dcblock.hpp>
#include <digiham/gfsk_demodulator.hpp>
#include <digiham/rrc_filter.hpp>

#include <algorithm>
#include <cassert>
#include <cmath>
#include <complex>
#include <cstdint>
#include <cstdio>
#include <vector>

namespace {
// Upstream csdr selector start-up latency in 48 kS/s IF samples, plus the
// adapter's fixed input block (bounded exactly in dmr_channel_filter_test).
constexpr uint64_t kMaxIfDeficit =
    1200 + sdrcore::dmr::ChannelFilter::kBlockOutputSamples;
bool nominal_if(uint64_t actual, uint64_t ideal) {
  return actual <= ideal && actual + kMaxIfDeficit >= ideal;
}

struct Symbols : sdrcore::dmr::SymbolSink {
  std::vector<uint8_t> dibits;
  void on_symbols(const uint8_t* data, size_t n) override {
    dibits.insert(dibits.end(), data, data + n);
  }
};

// Drive the pinned digiham/csdr modules without Channel's reader/writer and
// RRC adapter. This checks adapter parity, not an independent RF oracle.
struct ReferenceReader final : Csdr::Reader<float> {
  std::vector<float> samples;
  size_t position = 0;
  size_t available() override { return samples.size() - position; }
  float* getReadPointer() override { return samples.data() + position; }
  void advance(size_t n) override { position += n; }
  void wait() override {}
  void unblock() override {}
};
struct ReferenceWriter final : Csdr::Writer<unsigned char> {
  std::vector<uint8_t> symbols;
  unsigned char next = 0;
  size_t writeable() override { return 1; }
  unsigned char* getWritePointer() override { return &next; }
  void advance(size_t n) override { if (n) symbols.push_back(next); }
};

std::vector<uint8_t> upstream_symbols(const std::vector<float>& discriminator) {
  Csdr::DcBlock dc;
  Digiham::RrcFilter::WideRrcFilter rrc;
  ReferenceReader reader;
  ReferenceWriter writer;
  for (float sample : discriminator) {
    float dc_out = 0, shaped = 0;
    dc.process(&sample, &dc_out, 1);
    rrc.process(&dc_out, &shaped, 1);
    reader.samples.push_back(shaped);
  }
  Digiham::Fsk::GfskDemodulator gfsk(10);
  gfsk.setReader(&reader);
  gfsk.setWriter(&writer);
  while (gfsk.canProcess()) gfsk.process();
  return writer.symbols;
}

void upstream_adapter_parity() {
  std::vector<float> samples;
  // Exercise DC state, RRC startup, level calibration and clock recovery.
  const float levels[] = {-0.75f, -0.25f, 0.25f, 0.75f};
  for (int symbol = 0; symbol < 620; ++symbol) {
    const float value = levels[(symbol * 7 + symbol / 11) % 4] +
                        (symbol < 310 ? 0.12f : -0.09f);
    for (int sample = 0; sample < 10; ++sample) samples.push_back(value);
  }
  const auto reference = upstream_symbols(samples);
  assert(reference.size() > 600);
  sdrcore::dmr::Channel channel;
  Symbols actual;
  for (size_t i = 0; i < samples.size(); i += 137)
    channel.process_demodulated(samples.data() + i,
        std::min<size_t>(137, samples.size() - i), actual);
  assert(actual.dibits == reference);
  channel.reset();
  actual.dibits.clear();
  channel.process_demodulated(samples.data(), samples.size(), actual);
  assert(actual.dibits == reference);
}

void symbol_decisions() {
  sdrcore::dmr::Channel channel;
  Symbols symbols;
  // Actual 48 kS/s discriminator domain, 10 samples/symbol. The first
  // hundred symbols fill upstream's adaptive 100-symbol calibration ring.
  const float levels[] = {-0.75f, -0.25f, 0.25f, 0.75f};
  const uint8_t expected[] = {3, 2, 0, 1};
  std::vector<float> samples;
  for (int i = 0; i < 804; ++i)
    for (int k = 0; k < 10; ++k) samples.push_back(levels[i % 4]);
  channel.process_demodulated(samples.data(), samples.size(), symbols);
  assert(symbols.dibits.size() >= 800 && symbols.dibits.size() <= 804);
  for (size_t i = 200; i + 1 < symbols.dibits.size(); ++i)
    assert(symbols.dibits[i] == expected[i % 4]);
  channel.reset();
  symbols.dibits.clear();
  channel.process_demodulated(samples.data(), samples.size(), symbols);
  assert(symbols.dibits.size() >= 800);
  for (size_t i = 200; i + 1 < symbols.dibits.size(); ++i)
    assert(symbols.dibits[i] == expected[i % 4]);
}

void rate_and_boundary(uint32_t rate) {
  sdrcore::dmr::Channel whole;
  sdrcore::dmr::Channel sliced;
  assert(whole.configure(rate));
  assert(sliced.configure(rate));
  Symbols a, b;
  std::vector<std::complex<float>> iq(rate / 2);
  for (size_t i = 0; i < iq.size(); ++i) {
    const double phase = 2.0 * 3.141592653589793 * 1200.0 * i / rate;
    iq[i] = std::polar(0.7f, static_cast<float>(phase));
  }
  whole.process(iq.data(), iq.size(), a);
  for (size_t offset = 0; offset < iq.size(); offset += 4096)
    sliced.process(iq.data() + offset, std::min<size_t>(4096, iq.size() - offset), b);
  assert(nominal_if(whole.if_samples(), 24000));
  assert(sliced.if_samples() == whole.if_samples());
  assert(a.dibits == b.dibits);
  std::fprintf(stderr, "DMR rate %u: IF=%llu symbols=%zu\n", rate,
      static_cast<unsigned long long>(whole.if_samples()), a.dibits.size());
  // GFSK samplesPerSymbol=10: 4800 symbols/s from the 48 kS/s IF.
  assert(a.dibits.size() * 10 <= whole.if_samples() &&
         a.dibits.size() * 10 + 120 >= whole.if_samples());
  // A reset must discard all FIR, DC and demodulator history.
  sliced.reset();
  Symbols c;
  sliced.process(iq.data(), iq.size(), c);
  assert(c.dibits == a.dibits);
}

void iq_four_level_decisions(uint32_t rate) {
  sdrcore::dmr::Channel channel;
  assert(channel.configure(rate));
  Symbols symbols;
  // Four 4FSK discriminator levels, 12 symbols per run so timing/filter
  // transients never determine the centre-symbol decision. No artificial
  // pre-decimation: this enters through the actual baseband tap rate.
  constexpr size_t groups = 180;
  const int frequencies[] = {-1800, -600, 600, 1800};
  const uint8_t expected[] = {3, 2, 0, 1};
  const size_t n = static_cast<size_t>(rate) * groups * 12 / 4800;
  std::vector<std::complex<float>> iq(n);
  double phase = 0;
  for (size_t i = 0; i < n; ++i) {
    const size_t group = (i * 4800 / rate) / 12;
    phase += 2 * 3.141592653589793 * frequencies[group % 4] / rate;
    iq[i] = std::polar(0.7f, static_cast<float>(phase));
  }
  for (size_t i = 0; i < n; i += 2048)
    channel.process(iq.data() + i, std::min<size_t>(2048, n - i), symbols);
  assert(nominal_if(channel.if_samples(), groups * 120));
  // Estimate fixed filter group delay and symbol sampler phase; compare
  // actual symbols, not merely a count or non-empty decoder output.
  size_t best = 0;
  for (size_t lag = 0; lag < 35; ++lag) {
    size_t matches = 0;
    for (size_t group = 10; group + 5 < groups; ++group) {
      const size_t at = group * 12 + 6 + lag;
      if (at < symbols.dibits.size() &&
          symbols.dibits[at] == expected[group % 4]) ++matches;
    }
    best = std::max(best, matches);
  }
  assert(best > (groups - 15) * 9 / 10);
}
}  // namespace

int main() {
  upstream_adapter_parity();
  symbol_decisions();
  rate_and_boundary(48000);
  rate_and_boundary(250000);
  rate_and_boundary(240000);
  rate_and_boundary(288000);
  rate_and_boundary(300000);
  iq_four_level_decisions(240000);
  iq_four_level_decisions(250000);
  iq_four_level_decisions(288000);
  sdrcore::dmr::Channel channel;
  assert(!channel.configure(0));
  assert(!channel.configure(47999));
}
