// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include "channel.hpp"
#include "decoder.hpp"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace sdrcore::dmr {

// Adapter from Decoder::process()'s interleaved CF32 baseband to the DMR
// channel. Attach a Decoder owning this tap with Input::baseband on the sole
// Receiver; forward its reset() and process() calls here. No tuner control or
// decoder registry entry is created by this component.
class ChannelTap {
 public:
  explicit ChannelTap(SymbolSink& sink);
  void reset();
  // false means the supplied rate/span cannot feed the 48 kS/s IF. The
  // receiver supplies the actual rate after its own VFO shift/decimation.
  bool process(const float* interleaved_iq, size_t pairs, uint32_t rate_hz);
  uint32_t input_rate_hz() const { return input_rate_hz_; }
  uint64_t if_samples() const { return channel_.if_samples(); }

 private:
  SymbolSink& sink_;
  Channel channel_;
  uint32_t input_rate_hz_ = 0;
  std::vector<std::complex<float>> iq_;
};

// Reusable Decoder input stage for the full DMR backend. Derive from this,
// implement on_symbols() (e.g. forward to Framing), configure() and
// take_event(). Receiver::set_decoder(..., Input::baseband) supplies the one
// tuned, integer-decimated tap and calls reset on stream/tune boundaries.
// There is intentionally no factory/registry entry until framing, metadata
// and the voice backend are attached by the DMR integration card.
class ChannelDecoder : public decoder::Decoder, public SymbolSink {
 public:
  ChannelDecoder();
  void reset() override;
  void process(const float* iq, size_t pairs, uint32_t rate_hz) override;
  const ChannelTap& channel_tap() const { return tap_; }

 private:
  ChannelTap tap_;
};

}  // namespace sdrcore::dmr
