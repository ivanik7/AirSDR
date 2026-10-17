// SPDX-License-Identifier: GPL-3.0-or-later
#include "channel_filter.hpp"
#include <digiham/rrc_filter.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <deque>

namespace sdrcore::dmr {
namespace {
constexpr double kPi = 3.14159265358979323846;
constexpr size_t kDecimTaps = 127;
constexpr size_t kChannelTaps = 161;
constexpr size_t kPhases = 64;

double sinc(double x) {
  return std::abs(x) < 1e-12 ? 1.0 : std::sin(kPi * x) / (kPi * x);
}
}  // namespace

struct ChannelFilter::Impl {
  uint32_t input_rate = 0;
  unsigned decim = 1;
  double stage_rate = kOutputRate;
  std::array<float, kDecimTaps> decim_taps{};
  std::array<std::complex<float>, kDecimTaps> history{};
  size_t history_pos = 0;
  unsigned decim_phase = 0;
  std::array<std::array<float, kChannelTaps>, kPhases> channel_taps{};
  std::deque<std::complex<float>> channel_history;
  int64_t channel_start = 0;
  int64_t stage_count = 0;
  // 80 samples of causal startup delay for the symmetric 161-tap FIR.
  double next_time = -80.0;
  uint64_t if_count = 0;

  void set_rate(uint32_t rate) {
    input_rate = rate;
    decim = std::max(1u, static_cast<unsigned>(std::lround(rate / 48000.0)));
    stage_rate = static_cast<double>(rate) / decim;
    // Anti-alias at the actual tap rate, before integer decimation.
    const double fc = std::min(10000.0, stage_rate * 0.40) / rate;
    double gain = 0;
    for (size_t i = 0; i < kDecimTaps; ++i) {
      const double x = static_cast<double>(i) - 63;
      const double window = 0.42 - 0.5 * std::cos(2 * kPi * i / 126) +
                            0.08 * std::cos(4 * kPi * i / 126);
      decim_taps[i] = static_cast<float>(2 * fc * sinc(2 * fc * x) * window);
      gain += decim_taps[i];
    }
    for (auto& tap : decim_taps) tap = static_cast<float>(tap / gain);
    // The ±6250 Hz bandpass is measured against the post-decimation rate.
    // Fractional polyphase interpolation yields exactly 48 kS/s IF.
    const double channel_fc = kHighCutHz / stage_rate;
    for (size_t phase = 0; phase < kPhases; ++phase) {
      const double fraction = static_cast<double>(phase) / kPhases;
      double sum = 0;
      for (size_t i = 0; i < kChannelTaps; ++i) {
        const double x = static_cast<double>(i) - 80 - fraction;
        const double window = 0.42 - 0.5 * std::cos(2 * kPi * i / 160) +
                              0.08 * std::cos(4 * kPi * i / 160);
        channel_taps[phase][i] = static_cast<float>(2 * channel_fc *
            sinc(2 * channel_fc * x) * window);
        sum += channel_taps[phase][i];
      }
      for (auto& tap : channel_taps[phase]) tap = static_cast<float>(tap / sum);
    }
  }

  void feed_stage(const std::complex<float>& sample,
                  std::vector<std::complex<float>>& output) {
    channel_history.push_back(sample);
    ++stage_count;
    while (std::floor(next_time) + 80 < stage_count) {
      const auto center = static_cast<int64_t>(std::floor(next_time));
      const double fraction = next_time - center;
      const size_t phase = std::min(kPhases - 1,
          static_cast<size_t>(fraction * kPhases));
      std::complex<float> sum{};
      for (size_t i = 0; i < kChannelTaps; ++i) {
        const int64_t idx = center + static_cast<int64_t>(i) - 80;
        if (idx >= channel_start && idx < stage_count)
          sum += channel_history[static_cast<size_t>(idx - channel_start)] *
                 channel_taps[phase][i];
      }
      output.push_back(sum);
      ++if_count;
      next_time += stage_rate / kOutputRate;
    }
    const int64_t discard_before = static_cast<int64_t>(std::floor(next_time)) - 80;
    while (channel_start < discard_before && !channel_history.empty()) {
      channel_history.pop_front();
      ++channel_start;
    }
  }

  void feed(const std::complex<float>& sample,
            std::vector<std::complex<float>>& output) {
    history[history_pos] = sample;
    history_pos = (history_pos + 1) % kDecimTaps;
    if (++decim_phase != decim) return;
    decim_phase = 0;
    std::complex<float> filtered{};
    size_t pos = (history_pos + kDecimTaps - 1) % kDecimTaps;
    for (float tap : decim_taps) {
      filtered += history[pos] * tap;
      pos = (pos + kDecimTaps - 1) % kDecimTaps;
    }
    feed_stage(filtered, output);
  }
};

ChannelFilter::ChannelFilter() : impl_(std::make_unique<Impl>()) {}
ChannelFilter::~ChannelFilter() = default;
bool ChannelFilter::configure(uint32_t rate) {
  if (rate < kMinInputRate || rate > kMaxInputRate) return false;
  impl_ = std::make_unique<Impl>();
  impl_->set_rate(rate);
  return true;
}
uint32_t ChannelFilter::input_rate() const { return impl_->input_rate; }
void ChannelFilter::reset() {
  const auto rate = impl_->input_rate;
  impl_ = std::make_unique<Impl>();
  if (rate) impl_->set_rate(rate);
}
void ChannelFilter::process(const std::complex<float>* iq, size_t n,
                            std::vector<std::complex<float>>& output) {
  if (!impl_->input_rate || !iq) return;
  for (size_t i = 0; i < n; ++i) impl_->feed(iq[i], output);
}
uint64_t ChannelFilter::output_samples() const { return impl_->if_count; }

struct RrcPulseFilter::Impl {
  explicit Impl(Preset selected) : preset(selected) {
    if (preset == Preset::wide)
      filter = std::make_unique<Digiham::RrcFilter::WideRrcFilter>();
    else
      filter = std::make_unique<Digiham::RrcFilter::NarrowRrcFilter>();
  }
  Preset preset;
  std::unique_ptr<Digiham::RrcFilter::RrcFilter> filter;
  std::vector<float> input;
};

RrcPulseFilter::RrcPulseFilter(Preset preset) : impl_(std::make_unique<Impl>(preset)) {}
RrcPulseFilter::~RrcPulseFilter() = default;
void RrcPulseFilter::reset() { impl_ = std::make_unique<Impl>(impl_->preset); }
void RrcPulseFilter::process(const float* samples, float* output, size_t n) {
  if (!samples || !output || !n) return;
  // Digiham's process signature takes mutable input although it only reads it.
  impl_->input.assign(samples, samples + n);
  impl_->filter->process(impl_->input.data(), output, n);
}
RrcPulseFilter::Preset RrcPulseFilter::preset() const { return impl_->preset; }
}  // namespace sdrcore::dmr
