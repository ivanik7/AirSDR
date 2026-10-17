// SPDX-License-Identifier: GPL-3.0-or-later
#include "dmr/channel_filter.hpp"
#include <digiham/rrc_filter.hpp>

#include <algorithm>
#include <cassert>
#include <cmath>
#include <complex>
#include <cstdint>
#include <vector>

namespace {
constexpr double kPi = 3.14159265358979323846;
using Complex = std::complex<float>;

void rates_and_boundaries(uint32_t rate) {
  sdrcore::dmr::ChannelFilter whole, chunks;
  assert(whole.configure(rate));
  assert(chunks.configure(rate));
  assert(whole.input_rate() == rate);
  std::vector<Complex> iq(rate / 2, {1.0f, 0.0f});
  std::vector<Complex> a, b;
  whole.process(iq.data(), iq.size(), a);
  for (size_t i = 0; i < iq.size(); i += 1021) {
    chunks.process(iq.data() + i, std::min<size_t>(1021, iq.size() - i), b);
  }
  assert(a.size() == 24000);
  assert(a == b);
  assert(whole.output_samples() == a.size());
  chunks.reset();
  std::vector<Complex> restarted;
  chunks.process(iq.data(), iq.size(), restarted);
  assert(a == restarted);
}

double tone_amplitude(uint32_t rate, double hz) {
  sdrcore::dmr::ChannelFilter filter;
  assert(filter.configure(rate));
  std::vector<Complex> iq(rate / 4), out;
  for (size_t i = 0; i < iq.size(); ++i) {
    iq[i] = std::polar(1.0f, static_cast<float>(2 * kPi * hz * i / rate));
  }
  filter.process(iq.data(), iq.size(), out);
  double power = 0;
  for (size_t i = 4000; i < out.size(); ++i) power += std::norm(out[i]);
  return std::sqrt(power / (out.size() - 4000));
}

void bandpass_at_actual_rate(uint32_t rate) {
  // Positive and negative frequencies must see the same 12.5-kHz channel.
  assert(tone_amplitude(rate, 3000) > 0.8);
  assert(tone_amplitude(rate, -3000) > 0.8);
  assert(tone_amplitude(rate, 13000) < 0.08);
  assert(tone_amplitude(rate, -13000) < 0.08);
}

void upstream_rrc_presets() {
  for (auto preset : {sdrcore::dmr::RrcPulseFilter::Preset::wide,
                      sdrcore::dmr::RrcPulseFilter::Preset::narrow}) {
    sdrcore::dmr::RrcPulseFilter filter(preset);
    std::vector<float> impulse(250, 0), actual(250), reference(250), again(250);
    impulse[0] = 1;
    if (preset == sdrcore::dmr::RrcPulseFilter::Preset::wide) {
      Digiham::RrcFilter::WideRrcFilter upstream;
      upstream.process(impulse.data(), reference.data(), impulse.size());
      assert(reference[40] > 0);
      assert(reference[80] != 0);
      assert(reference[81] == 0);
    } else {
      Digiham::RrcFilter::NarrowRrcFilter upstream;
      upstream.process(impulse.data(), reference.data(), impulse.size());
      assert(reference[80] > 0);
      assert(reference[160] != 0);
      assert(reference[161] == 0);
    }
    filter.process(impulse.data(), actual.data(), 33);
    filter.process(impulse.data() + 33, actual.data() + 33, impulse.size() - 33);
    assert(actual == reference);
    filter.reset();
    filter.process(impulse.data(), again.data(), impulse.size());
    assert(again == reference);
  }
}
}  // namespace

int main() {
  upstream_rrc_presets();
  sdrcore::dmr::ChannelFilter filter;
  assert(!filter.configure(0));
  assert(!filter.configure(47999));
  assert(!filter.configure(300001));
  for (uint32_t rate : {48000u, 240000u, 250000u, 288000u, 300000u}) {
    rates_and_boundaries(rate);
    bandpass_at_actual_rate(rate);
  }
}
