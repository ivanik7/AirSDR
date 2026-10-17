// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <complex>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

namespace sdrcore::dmr {

// Complex channel selector, before the digiham discriminator/RRC/4FSK chain.
// One VFO-centred baseband tap in, exactly 48 kS/s complex IF out. Neither
// retunes the source nor applies a squelch. Confined to the DSP worker thread.
class ChannelFilter {
 public:
  static constexpr uint32_t kOutputRate = 48000;
  static constexpr uint32_t kMinInputRate = 48000;
  static constexpr uint32_t kMaxInputRate = 300000;
  static constexpr float kLowCutHz = -6250.0f;
  static constexpr float kHighCutHz = 6250.0f;

  ChannelFilter();
  ~ChannelFilter();
  ChannelFilter(const ChannelFilter&) = delete;
  ChannelFilter& operator=(const ChannelFilter&) = delete;
  // Reconfiguration clears decimator, bandpass and fractional-rate history.
  bool configure(uint32_t baseband_rate);
  uint32_t input_rate() const;
  void reset();
  // Appends the IF samples produced by this block; output length varies with
  // fractional rate, but the long-term rate is exactly kOutputRate.
  void process(const std::complex<float>* iq, size_t n,
               std::vector<std::complex<float>>& output);
  uint64_t output_samples() const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

// Digiham's original pulse-shaping tables, applied to 48 kS/s FM
// discriminator samples. DMR uses Wide (81 taps); Narrow (161 taps) is
// provided for the modes that request it, not selected for DMR.
class RrcPulseFilter {
 public:
  enum class Preset { wide, narrow };
  static constexpr uint32_t kInputRate = 48000;
  static constexpr uint32_t kOutputRate = 48000;
  explicit RrcPulseFilter(Preset preset);
  ~RrcPulseFilter();
  RrcPulseFilter(const RrcPulseFilter&) = delete;
  RrcPulseFilter& operator=(const RrcPulseFilter&) = delete;
  void reset();
  void process(const float* samples, float* output, size_t n);
  Preset preset() const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace sdrcore::dmr
