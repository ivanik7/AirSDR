// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <complex>
#include <cstddef>
#include <cstdint>
#include <memory>

namespace sdrcore::dmr {

struct SymbolSink {
  virtual ~SymbolSink() = default;
  // OpenWebRX/digiham dibit order: outer positive=1, inner positive=0,
  // inner negative=2, outer negative=3, at exactly 4800 symbols/s.
  virtual void on_symbols(const uint8_t* dibits, size_t n) = 0;
};

// One tuned complex-baseband tap, not a tuner or a second receiver. The caller
// owns the source-rate decimation from device IQ to the existing 200-300 kS/s
// tap. All state is worker-thread confined and reset at station boundaries.
class Channel {
 public:
  Channel();
  ~Channel();
  Channel(const Channel&) = delete;
  Channel& operator=(const Channel&) = delete;
  bool configure(uint32_t baseband_rate);
  void reset();
  void process(const std::complex<float>* iq, size_t n, SymbolSink& sink);
  // Discriminator-domain injection for symbol decisions and oracle fixtures;
  // same WideRrc/Gfsk path used by process(), at exactly 48000 S/s.
  void process_demodulated(const float* samples, size_t n, SymbolSink& sink);
  uint64_t if_samples() const;
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace sdrcore::dmr
