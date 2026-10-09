// SPDX-License-Identifier: GPL-3.0-or-later
#include "channel.hpp"

#include <csdr/dcblock.hpp>
#include <csdr/fmdemod.hpp>
#include <digiham/gfsk_demodulator.hpp>
#include <digiham/rrc_filter.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <deque>
#include <vector>

namespace sdrcore::dmr {
namespace {
constexpr double kPi = 3.14159265358979323846;
constexpr size_t kDecimTaps = 127;
constexpr size_t kChannelTaps = 161;
constexpr size_t kPhases = 64;
constexpr uint32_t kIfRate = 48000;

class FloatReader final : public Csdr::Reader<float> {
 public:
  std::vector<float> values;
  size_t offset = 0;
  size_t available() override { return values.size() - offset; }
  float* getReadPointer() override { return values.data() + offset; }
  void advance(size_t count) override { offset += count; }
  void wait() override {}
  void unblock() override {}
  void compact() {
    values.erase(values.begin(), values.begin() + offset);
    offset = 0;
  }
};
class ByteWriter final : public Csdr::Writer<unsigned char> {
 public:
  std::vector<uint8_t> values;
  unsigned char value = 0;
  size_t writeable() override { return 1; }
  unsigned char* getWritePointer() override { return &value; }
  void advance(size_t count) override { if (count) values.push_back(value); }
};

double sinc(double x) {
  return std::abs(x) < 1e-12 ? 1.0 : std::sin(kPi * x) / (kPi * x);
}
}  // namespace

struct Channel::Impl {
  uint32_t input_rate = 0;
  unsigned decim = 1;
  double stage_rate = kIfRate;
  std::array<float, kDecimTaps> decim_taps{};
  std::array<std::complex<float>, kDecimTaps> history{};
  size_t history_pos = 0;
  unsigned decim_phase = 0;
  std::array<std::array<float, kChannelTaps>, kPhases> channel_taps{};
  std::deque<std::complex<float>> channel_history;
  int64_t channel_start = 0;
  int64_t stage_count = 0;
  // Nominal position of next output in stage-1 sample units. An 80-sample
  // startup delay makes the 161-tap symmetric FIR causal, without a rate gap.
  double next_time = -80.0;
  uint64_t if_count = 0;
  Csdr::FmDemod fm;
  Csdr::DcBlock dc;
  Digiham::RrcFilter::WideRrcFilter rrc;
  Digiham::Fsk::GfskDemodulator gfsk{10};
  FloatReader reader;
  ByteWriter writer;

  Impl() {
    gfsk.setReader(&reader);
    gfsk.setWriter(&writer);
  }

  void set_rate(uint32_t rate) {
    input_rate = rate;
    decim = std::max(1u, static_cast<unsigned>(std::lround(rate / 48000.0)));
    stage_rate = static_cast<double>(rate) / decim;
    // Stage 1 anti-alias before integer decimation. Stage 2 is the explicit
    // 12.5 kHz channel bandpass at the actual tap rate, NOT the tuner rate.
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
    // Fractional polyphase resampling at exactly 48 kS/s, with the 6250 Hz
    // cutoff measured against stage_rate (48-60 kS/s). 161 Blackman taps.
    const double channel_fc = 6250.0 / stage_rate;
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

  void feed_if(const std::complex<float>& iq, SymbolSink& sink) {
    Csdr::complex<float> input(iq);
    float demod = 0;
    fm.process(&input, &demod, 1);
    feed_audio(&demod, 1, sink);
    ++if_count;
  }

  void feed_audio(const float* samples, size_t n, SymbolSink& sink) {
    if (!n) return;
    // Do not apply squelch: OpenWebRX+ DMR has squelch=False.
    writer.values.clear();
    reader.values.reserve(reader.values.size() + n);
    for (size_t i = 0; i < n; ++i) {
      float dc_out, shaped;
      float in = samples[i];
      dc.process(&in, &dc_out, 1);
      rrc.process(&dc_out, &shaped, 1);
      reader.values.push_back(shaped);
    }
    while (gfsk.canProcess()) gfsk.process();
    reader.compact();
    if (!writer.values.empty()) sink.on_symbols(writer.values.data(), writer.values.size());
  }

  void feed_stage(const std::complex<float>& sample, SymbolSink& sink) {
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
      feed_if(sum, sink);
      next_time += stage_rate / kIfRate;
    }
    // Do not keep the entire stream: only 161 stage-rate samples are needed.
    const int64_t discard_before = static_cast<int64_t>(std::floor(next_time)) - 80;
    while (channel_start < discard_before && !channel_history.empty()) {
      channel_history.pop_front();
      ++channel_start;
    }
  }

  void feed(const std::complex<float>& sample, SymbolSink& sink) {
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
    feed_stage(filtered, sink);
  }
};

Channel::Channel() : impl_(std::make_unique<Impl>()) {}
Channel::~Channel() = default;
bool Channel::configure(uint32_t rate) {
  if (rate < kIfRate || rate > 300000) return false;
  impl_ = std::make_unique<Impl>();
  impl_->set_rate(rate);
  return true;
}
void Channel::reset() {
  const auto rate = impl_->input_rate;
  impl_ = std::make_unique<Impl>();
  if (rate) impl_->set_rate(rate);
}
void Channel::process(const std::complex<float>* iq, size_t n, SymbolSink& sink) {
  if (!impl_->input_rate || !iq) return;
  for (size_t i = 0; i < n; ++i) impl_->feed(iq[i], sink);
}
void Channel::process_demodulated(const float* samples, size_t n, SymbolSink& sink) {
  if (samples) impl_->feed_audio(samples, n, sink);
}
uint64_t Channel::if_samples() const { return impl_->if_count; }
}  // namespace sdrcore::dmr
