// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef SDRCORE_DSP_RECEIVER_H
#define SDRCORE_DSP_RECEIVER_H

#include "sdrcore_v3.h"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

namespace sdrcore::decoder { class Decoder; }

namespace sdrcore {
namespace dsp {

// Internal, single-thread-owned DSP contract. CU8 IQ is centered at 127.5;
// HackRF CS8 is normalized to CU8 by the native ingress ring. The caller
// owns inputs and result; no IQ or PCM buffer is shared with Dart.
struct ProcessResult {
  std::vector<float> audio;  // Interleaved stereo 48 kHz, cleared per process.
  std::vector<float> fft;    // Latest complete row, empty if no new row.
  float signal_db = -100.0f;
  float squelch_threshold_db = -100.0f;
  bool squelch_ready = false;
  bool squelch_open = false;
};

class Receiver {
 public:
  virtual ~Receiver() = default;
  // Called by the DSP owner with no process() in flight. A new stream calls
  // reset() to discard filter/FFT/squelch history. In-band VFO and mode changes
  // may configure() without resetting the source or changing stream generation.
  virtual void configure(const SdrV3Controls& controls,
                         const SdrV3Display& display) = 0;
  // Called by the same DSP owner mutex as configure/process; no IQ restart.
  virtual void set_wfm_stereo(bool enabled) = 0;
  // Borrowed, DSP-lock protected. The branch is filtered and integer-decimated
  // to a complex 200-300 kS/s tuned VFO; zero means source rate is unsuitable.
  // Attach/detach, retune, rate and stream generation changes reset the branch.
  virtual uint32_t set_decoder(sdrcore::decoder::Decoder* decoder) = 0;
  virtual uint32_t decoder_rate_hz() const = 0;
  virtual void reset() = 0;
  // Live LO retune on a continuing stream: forgets what belonged to the old
  // station (FFT accumulation, squelch learning, WFM pilot lock) but keeps
  // the channel filters, audio resampler and deemphasis running, so the
  // audio stream continues without a reset gap or click.
  virtual void retune() = 0;
  virtual void process(const uint8_t* cu8, size_t bytes,
                       ProcessResult& result) = 0;
};

std::unique_ptr<Receiver> make_receiver();

}  // namespace dsp
}  // namespace sdrcore
#endif  // SDRCORE_DSP_RECEIVER_H
