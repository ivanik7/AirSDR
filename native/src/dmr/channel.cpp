// SPDX-License-Identifier: GPL-3.0-or-later
#include "channel.hpp"
#include "channel_filter.hpp"

#include <csdr/dcblock.hpp>
#include <csdr/fmdemod.hpp>
#include <digiham/gfsk_demodulator.hpp>

#include <algorithm>
#include <vector>

namespace sdrcore::dmr {
namespace {
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
}  // namespace

struct Channel::Impl {
  ChannelFilter filter;
  std::vector<std::complex<float>> if_buffer;
  Csdr::FmDemod fm;
  Csdr::DcBlock dc;
  RrcPulseFilter rrc{RrcPulseFilter::Preset::wide};
  Digiham::Fsk::GfskDemodulator gfsk{10};
  FloatReader reader;
  ByteWriter writer;

  Impl() {
    gfsk.setReader(&reader);
    gfsk.setWriter(&writer);
  }

  void feed_if(const std::complex<float>& iq, SymbolSink& sink) {
    Csdr::complex<float> input(iq);
    float demod = 0;
    fm.process(&input, &demod, 1);
    feed_audio(&demod, 1, sink);
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
};

Channel::Channel() : impl_(std::make_unique<Impl>()) {}
Channel::~Channel() = default;
bool Channel::configure(uint32_t rate) {
  if (rate < ChannelFilter::kMinInputRate || rate > ChannelFilter::kMaxInputRate)
    return false;
  impl_ = std::make_unique<Impl>();
  return impl_->filter.configure(rate);
}
void Channel::reset() {
  const auto rate = impl_->filter.input_rate();
  impl_ = std::make_unique<Impl>();
  if (rate) impl_->filter.configure(rate);
}
void Channel::process(const std::complex<float>* iq, size_t n, SymbolSink& sink) {
  impl_->if_buffer.clear();
  impl_->filter.process(iq, n, impl_->if_buffer);
  for (const auto& sample : impl_->if_buffer) impl_->feed_if(sample, sink);
}
void Channel::process_demodulated(const float* samples, size_t n, SymbolSink& sink) {
  if (samples) impl_->feed_audio(samples, n, sink);
}
uint64_t Channel::if_samples() const { return impl_->filter.output_samples(); }
}  // namespace sdrcore::dmr
