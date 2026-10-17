// SPDX-License-Identifier: GPL-3.0-or-later
#include "channel_tap.hpp"
#include "channel_filter.hpp"

#include <algorithm>

namespace sdrcore::dmr {

ChannelTap::ChannelTap(SymbolSink& sink) : sink_(sink) {}

void ChannelTap::reset() { channel_.reset(); }

bool ChannelTap::process(const float* iq, size_t pairs, uint32_t rate_hz) {
  if (rate_hz < ChannelFilter::kMinInputRate ||
      rate_hz > ChannelFilter::kMaxInputRate || (pairs && !iq)) {
    channel_.reset();
    input_rate_hz_ = 0;
    return false;
  }
  if (rate_hz != input_rate_hz_) {
    if (!channel_.configure(rate_hz)) return false;
    input_rate_hz_ = rate_hz;
  }
  // Copy instead of aliasing float[] as complex<float>[]: those types have
  // different object lifetimes. Bound the temporary regardless of block size.
  constexpr size_t kChunk = 4096;
  iq_.resize(std::min(pairs, kChunk));
  for (size_t pos = 0; pos < pairs; pos += kChunk) {
    const size_t n = std::min(kChunk, pairs - pos);
    for (size_t i = 0; i < n; ++i)
      iq_[i] = {iq[2 * (pos + i)], iq[2 * (pos + i) + 1]};
    channel_.process(iq_.data(), n, sink_);
  }
  return true;
}

ChannelDecoder::ChannelDecoder() : tap_(*this) {}
void ChannelDecoder::reset() { tap_.reset(); }
void ChannelDecoder::process(const float* iq, size_t pairs, uint32_t rate_hz) {
  tap_.process(iq, pairs, rate_hz);
}

}  // namespace sdrcore::dmr
