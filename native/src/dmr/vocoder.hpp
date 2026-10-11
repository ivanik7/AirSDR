// SPDX-License-Identifier: GPL-3.0-or-later
// DMR AMBE+2 voice synthesis and output staging (t_5b101746).
//
// Upstream chain (OpenWebRX+ csdr/chain/digiham.py DigihamChain, DmrMode):
//   DmrDecoder -> MbeSynthesizer(TableMode(33), codecserver) -> int16 @ 8 kHz
//   -> DigitalVoiceFilter -> Agc(SHORT, maxGain 30, initialGain 3)
//   -> fixed audio rate 8000 -> client AudioResampler.
// codecserver's softmbe driver turns each 9-byte frame into 160 samples with
// mbelib (decode_ambe_3600x2450, uvquality 3). Here the same steps run in
// process on the DSP worker (no codecserver, no socket, no subprocess), and
// the 8 kHz result is interpolated x6 to the receiver's 48 kHz output rate.
// See STATUS-dmr.md and native/src/dmr/README-vocoder.md.
#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

namespace sdrcore::dmr {

// One 72-bit AMBE+2 (3600x2450) channel frame, still DMR-interleaved,
// MSB-first, exactly as digiham's DmrDecoder emits it (its 27-byte voice
// burst split into three consecutive 9-byte frames). STATUS-dmr.md §7.3.
struct AmbeFrame {
  uint8_t slot = 0;  // 0 = TS1, 1 = TS2 (informational; upstream ignores it)
  uint8_t bits[9] = {};
};

// Frame consumer offered to the framing decoder (t_0c6cc09e). Called on the
// DSP worker, in channel order.
struct VoiceSink {
  virtual ~VoiceSink() = default;
  virtual void on_ambe(const AmbeFrame& frame) = 0;
};

// True when this build contains the mbelib vocoder (CMake option
// SDRCORE_ENABLE_MBELIB). When false, frames are counted and dropped and no
// PCM is ever produced: DMR stays metadata-only and must report
// "voice":"unavailable" rather than inventing audio.
bool vocoder_available();

// Per-frame decode statistics from mbelib (errs = C0 Golay corrections,
// errs2 = C0 + C1 corrections; mbelib repeats the previous frame when
// errs2 > 3 and mutes after 3 repeats).
struct FrameStats {
  int errs = 0;
  int errs2 = 0;
  char err_str[64] = {};
};

// Exactly codecserver-softmbe softmbeSession::decode_ambe_3600x2450 without
// the queue: unpack MSB-first, deinterleave with dmr_interleave_permutation,
// split into ambe_fr c0..c3 and run mbe_processAmbe3600x2450Frame
// (uvquality 3) with persistent mbe_parms. Produces 160 int16 at 8 kHz.
class AmbeSynthesizer {
 public:
  AmbeSynthesizer();
  ~AmbeSynthesizer();
  AmbeSynthesizer(const AmbeSynthesizer&) = delete;
  AmbeSynthesizer& operator=(const AmbeSynthesizer&) = delete;
  // mbe_initMbeParms, as softmbe does when a session (re)negotiates.
  void reset();
  // Returns false (out untouched) when the vocoder is not built in.
  bool decode(const uint8_t bits[9], int16_t out[160], FrameStats* stats = nullptr);
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

// Full voice output stage owned by the DMR decoder backend:
//   on_ambe -> AmbeSynthesizer -> DigitalVoiceFilter -> Agc<short>(30, 3)
//   -> x6 polyphase interpolation to 48 kHz float -> bounded jitter buffer.
// read_audio() implements Decoder::read_audio(): it never blocks, returns at
// most what is buffered (the receiver fills underruns with silence) and holds
// output back until kPrebufferFrames are queued so 60 ms DMR voice bursts do
// not chop against small receiver blocks.
class VoiceOutput final : public VoiceSink {
 public:
  static constexpr uint32_t kOutputRate = 48000;
  static constexpr uint32_t kVocoderRate = 8000;
  static constexpr size_t kInterpolation = kOutputRate / kVocoderRate;  // 6
  static constexpr size_t kFrameSamples = 160;                         // 20 ms @ 8 kHz
  static constexpr size_t kPrebufferFrames = 4800;    // 100 ms @ 48 kHz
  static constexpr size_t kCapacityFrames = 48000;    // 1 s bound, oldest dropped

  VoiceOutput();
  ~VoiceOutput() override;
  VoiceOutput(const VoiceOutput&) = delete;
  VoiceOutput& operator=(const VoiceOutput&) = delete;

  void on_ambe(const AmbeFrame& frame) override;
  size_t read_audio(float* mono, size_t max_frames);
  // Retune / stop / slot-filter change: drop queued PCM and all filter, AGC,
  // interpolator and mbelib state.
  void reset();
  // Voice enable from the decoder config ({"voice":false} => frames dropped).
  void set_enabled(bool enabled);
  bool enabled() const;

  size_t buffered_frames() const;
  uint64_t frames_decoded() const;    // AMBE frames synthesized
  uint64_t frames_dropped() const;    // AMBE frames dropped (disabled / no vocoder)
  uint64_t samples_overflowed() const;  // 48 kHz samples discarded at capacity
  // Oracle/test hook: append the post-AGC 8 kHz int16 stream (OpenWebRX+'s
  // fixed-audio-rate output, before the client resampler) to *sink.
  void set_capture_8k(std::vector<int16_t>* sink);
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace sdrcore::dmr
