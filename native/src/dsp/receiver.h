// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef SDRCORE_DSP_RECEIVER_H
#define SDRCORE_DSP_RECEIVER_H

#include "sdrcore_v3.h"
#include "decoder.hpp"
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace sdrcore {
namespace dsp {

// Internal, single-thread-owned DSP contract. CU8 IQ is centered at 127.5;
// HackRF CS8 is normalized to CU8 by the native ingress ring. The caller
// owns inputs and result; no IQ or PCM buffer is shared with Dart.
struct RecordingSquelchEdge {
  size_t frame_offset = 0;  // First 48 kHz PCM frame with this effective state.
  bool open = false;
};

struct ProcessResult {
  std::vector<float> audio;  // Interleaved stereo 48 kHz, cleared per process.
  // 48 kHz, before the analog squelch gate, volume and mute. Mono modes use
  // one sample per frame; WFM stereo preference uses interleaved L/R even
  // before pilot acquisition. Decoder voice replaces analog PCM at this tap.
  std::vector<float> recording_pcm;
  uint32_t recording_channels = 1;
  // Ordered state changes relative to recording_pcm frames, including the
  // initial open edge at frame 0 when squelch is OFF. No duplicate edges.
  std::vector<RecordingSquelchEdge> recording_squelch_edges;
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
  // Internal WFM metadata sink, independent of the selected data decoder.
  // Suspend during stale USB slots: they still feed audio, never metadata.
  virtual void set_rds_rbds(bool enabled) = 0;
  virtual void set_rds_suspended(bool suspended) = 0;
  virtual bool take_rds_group(std::string& json) = 0;
  virtual bool rds_synced() const = 0;
  // Borrowed, DSP-lock protected. Input::baseband: required_rate_hz=0 is
  // the rtl_433 200-300 kS/s VFO; 1000000 selects the exact-rate Meshtastic
  // complex VFO branch. Zero means source rate/window unsuitable. Attach,
  // retune, rate and stream changes reset the branch.
  // Input::raw_iq: tuned full-band 2.4 MS/s, native-resampled when feasible;
  // zero means the source rate or tuned +/-1.2 MHz window is insufficient.
  // Input::audio: real mono demodulator output (USB/LSB real part, NFM
  // discriminator + csdr 24 kHz NFM deemphasis FIR) band-limited and resampled
  // to exactly 24000 S/s, tapped before AGC/squelch gate/volume/mute; fed only
  // while the squelch is open (or off) and decoder->accepts_mode(mode).
  // Reset on tuned-frequency (center+offset) change, mode change, sample-rate
  // change, attach, retune() and stream reset; NOT on a bandwidth change.
  // Before every decoder reset() (any input kind) the receiver calls
  // decoder->set_tuning() with the applied tuned frequency and mode
  // (see decoder.hpp).
  // Returns the tap rate: 24000 for audio (0 when not attached).
  virtual uint32_t set_decoder(sdrcore::decoder::Decoder* decoder,
                               sdrcore::decoder::Input input =
                                   sdrcore::decoder::Input::baseband,
                               uint32_t required_rate_hz = 0) = 0;
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
