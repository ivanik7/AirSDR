// SPDX-License-Identifier: GPL-3.0-or-later
#include "dmr/channel_filter.hpp"
#include <csdr/fftfilter.hpp>
#include <csdr/filter.hpp>
#include <csdr/firdecimate.hpp>
#include <csdr/fractionaldecimator.hpp>
#include <csdr/window.hpp>
#include <digiham/rrc_filter.hpp>

#include <algorithm>
#include <cassert>
#include <cmath>
#include <complex>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <random>
#include <vector>

namespace {
constexpr double kPi = 3.14159265358979323846;
using Complex = std::complex<float>;
using CsdrComplex = Csdr::complex<float>;

// Output deficit bound at 48 kS/s: FirDecimate holds one filter length, the
// Lagrange interpolator 12 points, the FFT bandpass emits whole blocks once
// it has one block plus its overhead, and the adapter's fixed input block.
constexpr size_t kMaxLatencySamples =
    1200 + sdrcore::dmr::ChannelFilter::kBlockOutputSamples;

float max_difference(const std::vector<Complex>& a, const std::vector<Complex>& b) {
  assert(a.size() == b.size());
  float worst = 0;
  for (size_t i = 0; i < a.size(); ++i) worst = std::max(worst, std::abs(a[i] - b[i]));
  return worst;
}

// --- Independent driver of the pinned csdr-plus modules -------------------
// One-shot run over the whole signal with OpenWebRX+ f1e0d1ac
// csdr/chain/selector.py parameters: Decimator = FirDecimate(d,
// 0.15*out/in, 0.5*d/(in/out)) then FractionalDecimator(12 points, no
// prefilter) when needed; Bandpass(transition=320/out, use_fft=True) set
// to ±6250 Hz / out. pycsdr's FirDecimate and Bandpass use HammingWindow.
template <typename T>
struct Store {
  std::vector<T> data;
  size_t read = 0;
  size_t write = 0;
};
template <typename T>
struct StoreReader final : Csdr::Reader<T> {
  explicit StoreReader(Store<T>& s) : s(s) {}
  Store<T>& s;
  size_t available() override { return s.write - s.read; }
  T* getReadPointer() override { return s.data.data() + s.read; }
  void advance(size_t n) override { s.read += n; }
  void wait() override {}
  void unblock() override {}
};
template <typename T>
struct StoreWriter final : Csdr::Writer<T> {
  explicit StoreWriter(Store<T>& s) : s(s) {}
  Store<T>& s;
  size_t writeable() override {
    if (s.data.size() < s.write + (1u << 20)) s.data.resize(s.write + (1u << 20));
    return s.data.size() - s.write;
  }
  T* getWritePointer() override { return s.data.data() + s.write; }
  void advance(size_t n) override { s.write += n; }
};

std::vector<Complex> upstream_selector(uint32_t rate, const std::vector<Complex>& iq,
                                       size_t block) {
  const double out = 48000;
  const auto d = static_cast<unsigned>(rate / out);
  const double fraction = static_cast<double>(rate) / d / out;
  Store<CsdrComplex> in, decimated, resampled, filtered;
  in.data.assign(iq.begin(), iq.end());
  StoreReader<CsdrComplex> r0(in), r1(decimated), r2(resampled);
  StoreWriter<CsdrComplex> w1(decimated), w2(resampled), w3(filtered);
  Csdr::HammingWindow window;
  Csdr::FirDecimate fir(d, static_cast<float>(0.15 * out / rate), &window,
                        static_cast<float>(0.5 * d / (rate / out)));
  fir.setReader(&r0);
  fir.setWriter(&w1);
  Csdr::Reader<CsdrComplex>* bandpass_input = &r1;
  std::unique_ptr<Csdr::FractionalDecimator<CsdrComplex>> frac;
  if (fraction != 1.0) {
    frac = std::make_unique<Csdr::FractionalDecimator<CsdrComplex>>(
        static_cast<float>(fraction), 12);
    frac->setReader(&r1);
    frac->setWriter(&w2);
    bandpass_input = &r2;
  }
  Csdr::FilterModule<CsdrComplex> bandpass(new Csdr::FftBandPassFilter(
      static_cast<float>(-6250.0 / out), static_cast<float>(6250.0 / out),
      static_cast<float>(320.0 / out), &window));
  bandpass.setReader(bandpass_input);
  bandpass.setWriter(&w3);
  // Input arrives in fixed whole blocks, as from a pycsdr buffer.
  while (in.write + block <= iq.size()) {
    in.write += block;
    while (fir.canProcess()) fir.process();
    if (frac) while (frac->canProcess()) frac->process();
    while (bandpass.canProcess()) bandpass.process();
  }
  return {filtered.data.begin(), filtered.data.begin() + filtered.write};
}

std::vector<Complex> test_signal(uint32_t rate, size_t n) {
  // 4FSK-like in-band tones, an adjacent-channel tone and noise: exercises
  // pass band, stop band and the decimator's anti-alias filter at once.
  std::mt19937 rng(7);
  std::normal_distribution<float> noise(0.0f, 0.05f);
  std::vector<Complex> iq(n);
  for (size_t i = 0; i < n; ++i) {
    const double t = static_cast<double>(i) / rate;
    const double f = (i * 4800 / rate) % 2 ? 1800.0 : -600.0;
    iq[i] = std::polar(0.6f, static_cast<float>(2 * kPi * f * t)) +
            std::polar(0.3f, static_cast<float>(2 * kPi * 12500.0 * t)) +
            Complex(noise(rng), noise(rng));
  }
  return iq;
}

std::vector<Complex> run_chunked(sdrcore::dmr::ChannelFilter& filter,
                                 const std::vector<Complex>& iq) {
  // Irregular chunks, as delivered by the receiver's tap.
  std::vector<Complex> out;
  const size_t steps[] = {1, 977, 4096, 13, 16384, 333};
  size_t pos = 0, step = 0;
  while (pos < iq.size()) {
    const size_t n = std::min(steps[step++ % 6], iq.size() - pos);
    filter.process(iq.data() + pos, n, out);
    pos += n;
  }
  return out;
}

// The native selector must reproduce OpenWebRX+'s module chain, sample for
// sample, at every actual tap rate: identical algorithms, tables, latency.
// The reference is pumped with the adapter's fixed block size (csdr's
// FractionalDecimator output depends on block size; see channel_filter.hpp),
// while the adapter itself is fed irregular chunks.
void upstream_selector_parity(uint32_t rate) {
  const auto iq = test_signal(rate, rate / 2);
  const size_t block = (rate / 48000) * sdrcore::dmr::ChannelFilter::kBlockOutputSamples;
  const auto reference = upstream_selector(rate, iq, block);
  sdrcore::dmr::ChannelFilter filter;
  assert(filter.configure(rate));
  const auto actual = run_chunked(filter, iq);
  // Only whole blocks have been released on both sides.
  assert(actual.size() == reference.size());
  const float diff = max_difference(actual, reference);
  std::fprintf(stderr, "selector rate %u: upstream=%zu native=%zu max|d|=%g\n",
               rate, reference.size(), actual.size(), diff);
  assert(reference.size() <= 24000 && reference.size() + kMaxLatencySamples >= 24000);
  assert(diff == 0.0f);
}

void rates_and_boundaries(uint32_t rate) {
  sdrcore::dmr::ChannelFilter whole, chunks;
  assert(whole.configure(rate));
  assert(chunks.configure(rate));
  assert(whole.input_rate() == rate);
  const auto iq = test_signal(rate, rate / 2);
  std::vector<Complex> a;
  whole.process(iq.data(), iq.size(), a);
  const auto b = run_chunked(chunks, iq);
  assert(a.size() == b.size());
  assert(a.size() <= 24000 && a.size() + kMaxLatencySamples >= 24000);
  assert(a == b);
  assert(whole.output_samples() == a.size());
  chunks.reset();
  assert(chunks.output_samples() == 0);
  assert(chunks.input_rate() == rate);
  std::vector<Complex> restarted;
  chunks.process(iq.data(), iq.size(), restarted);
  assert(a == restarted);
  // Ten seconds: no drift from 48 kS/s beyond the fixed start-up latency.
  sdrcore::dmr::ChannelFilter longer;
  assert(longer.configure(rate));
  std::vector<Complex> sink;
  for (int block = 0; block < 20; ++block) {
    sink.clear();
    longer.process(iq.data(), iq.size(), sink);
  }
  assert(longer.output_samples() <= 480000 &&
         longer.output_samples() + kMaxLatencySamples >= 480000);
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
  for (double hz : {0.0, 3000.0, 5000.0, 6000.0}) {
    assert(tone_amplitude(rate, hz) > 0.8);
    assert(tone_amplitude(rate, -hz) > 0.8);
  }
  // OpenWebRX+'s 320-Hz transition band: outside ±(6250+320) Hz is gone.
  for (double hz : {6700.0, 9000.0, 13000.0}) {
    assert(tone_amplitude(rate, hz) < 0.03);
    assert(tone_amplitude(rate, -hz) < 0.03);
  }
  // When input is decimated, reject a tone that would fold into the
  // ±6250 Hz channel after integer decimation.
  if (rate >= 96000) {
    const double stage_rate = static_cast<double>(rate) / (rate / 48000);
    assert(tone_amplitude(rate, stage_rate - 3000) < 0.03);
  }
}

void unconfigured_filter_is_inert() {
  sdrcore::dmr::ChannelFilter filter;
  assert(filter.input_rate() == 0);
  Complex sample{1.0f, 0.0f};
  std::vector<Complex> out;
  filter.process(&sample, 1, out);
  filter.reset();
  assert(out.empty() && filter.output_samples() == 0);
  assert(!filter.configure(0));
  assert(!filter.configure(47999));
  assert(!filter.configure(300001));
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
  unconfigured_filter_is_inert();
  for (uint32_t rate : {48000u, 240000u, 250000u, 288000u, 300000u}) {
    upstream_selector_parity(rate);
    rates_and_boundaries(rate);
    bandpass_at_actual_rate(rate);
  }
}
