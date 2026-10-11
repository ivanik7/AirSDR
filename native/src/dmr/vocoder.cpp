// SPDX-License-Identifier: GPL-3.0-or-later
// DMR AMBE+2 synthesis + voice output stage. See vocoder.hpp for the chain.
#include "vocoder.hpp"

#include <algorithm>
#include <array>
#include <climits>
#include <cmath>
#include <cstring>
#include <deque>
#include <vector>

#include <csdr/agc.hpp>
#include <csdr/reader.hpp>
#include <csdr/writer.hpp>
#include <digiham/digitalvoice_filter.hpp>

#if SDRCORE_ENABLE_MBELIB
extern "C" {
#include <mbelib.h>
}
// Verbatim upstream table (codecserver-softmbe 66397fcf). Only the DMR
// permutation is used; the D-STAR/YSF tables are unused here.
#include <softmbe/interleaver_permutations_const.hpp>
#endif

namespace sdrcore::dmr {
namespace {

constexpr double kPi = 3.14159265358979323846;

// Minimal csdr Reader/Writer adapters over std::vector so the vendored
// upstream Module code (Agc<short>) runs unchanged without csdr's mmap
// Ringbuffer or threads. Same semantics: available/advance, writeable/advance.
class VecReader final : public Csdr::Reader<short> {
 public:
  std::vector<short> data;
  size_t offset = 0;
  size_t available() override { return data.size() - offset; }
  short* getReadPointer() override { return data.data() + offset; }
  void advance(size_t n) override { offset += n; }
  void wait() override {}
  void unblock() override {}
  void compact() {
    if (offset == 0) return;
    data.erase(data.begin(), data.begin() + static_cast<std::ptrdiff_t>(offset));
    offset = 0;
  }
  void clear() { data.clear(); offset = 0; }
};

class VecWriter final : public Csdr::Writer<short> {
 public:
  static constexpr size_t kChunk = 1024;
  std::vector<short> out;
  size_t writeable() override { return kChunk; }
  short* getWritePointer() override { return scratch_; }
  void advance(size_t n) override { out.insert(out.end(), scratch_, scratch_ + n); }
 private:
  short scratch_[kChunk] = {};
};

// x6 polyphase interpolator, 8 kHz -> 48 kHz. Kaiser-windowed sinc, 240 taps
// (40 per phase), cutoff 4 kHz, beta 8 (~80 dB image rejection beyond 4.5 kHz
// at 48 kHz). OpenWebRX+ instead resamples in its client Converter with
// libsamplerate SINC_MEDIUM; this is the documented native equivalent.
class Upsampler6 {
 public:
  static constexpr size_t kL = VoiceOutput::kInterpolation;
  static constexpr size_t kTapsPerPhase = 40;
  static constexpr size_t kTaps = kL * kTapsPerPhase;

  Upsampler6() {
    const double beta = 8.0;
    const double fc = 4000.0 / 48000.0;
    const auto bessel_i0 = [](double x) {
      double sum = 1, term = 1;
      for (int k = 1; k < 50; ++k) {
        term *= (x / (2 * k)) * (x / (2 * k));
        sum += term;
      }
      return sum;
    };
    std::vector<double> h(kTaps);
    const double mid = (kTaps - 1) / 2.0;
    double dc = 0;
    for (size_t n = 0; n < kTaps; ++n) {
      const double x = n - mid;
      const double sinc = std::abs(x) < 1e-12 ? 1.0 : std::sin(2 * kPi * fc * x) / (kPi * x * 2 * fc);
      const double r = x / mid;
      const double w = bessel_i0(beta * std::sqrt(std::max(0.0, 1 - r * r))) / bessel_i0(beta);
      h[n] = 2 * fc * sinc * w;
      dc += h[n];
    }
    // Unity passband gain after zero-stuffing: each phase sums to ~1.
    for (size_t n = 0; n < kTaps; ++n)
      phases_[n % kL][n / kL] = static_cast<float>(h[n] * kL / dc);
    reset();
  }
  void reset() {
    history_.fill(0.0f);
    pos_ = 0;
  }
  // One 8 kHz input sample in, kL 48 kHz samples out.
  void put(float x, float* out) {
    pos_ = (pos_ + kTapsPerPhase - 1) % kTapsPerPhase;
    history_[pos_] = x;
    for (size_t p = 0; p < kL; ++p) {
      float acc = 0;
      size_t idx = pos_;
      const auto& taps = phases_[p];
      for (size_t k = 0; k < kTapsPerPhase; ++k) {
        acc += taps[k] * history_[idx];
        idx = idx + 1 == kTapsPerPhase ? 0 : idx + 1;
      }
      out[p] = acc;
    }
  }
 private:
  std::array<std::array<float, kTapsPerPhase>, kL> phases_{};
  std::array<float, kTapsPerPhase> history_{};
  size_t pos_ = 0;
};

}  // namespace

bool vocoder_available() {
#if SDRCORE_ENABLE_MBELIB
  return true;
#else
  return false;
#endif
}

// ---------------------------------------------------------------- synthesizer

struct AmbeSynthesizer::Impl {
#if SDRCORE_ENABLE_MBELIB
  mbe_parms cur_mp{}, prev_mp{}, prev_mp_enhanced{};
#endif
};

AmbeSynthesizer::AmbeSynthesizer() : impl_(std::make_unique<Impl>()) { reset(); }
AmbeSynthesizer::~AmbeSynthesizer() = default;

void AmbeSynthesizer::reset() {
#if SDRCORE_ENABLE_MBELIB
  mbe_initMbeParms(&impl_->cur_mp, &impl_->prev_mp, &impl_->prev_mp_enhanced);
#endif
}

bool AmbeSynthesizer::decode(const uint8_t bits[9], int16_t out[160], FrameStats* stats) {
#if SDRCORE_ENABLE_MBELIB
  // softmbeSession::decode_ambe_3600x2450 (codecserver-softmbe 66397fcf),
  // kept step for step: unpack MSB-first, deinterleave, split c0..c3.
  char mbe_packet_interleaved[72];
  for (int i = 0; i < 72; i++) mbe_packet_interleaved[i] = (bits[i / 8] >> (7 - i % 8)) & 0x01;
  char mbe_packet_deinterleaved[72];
  for (int i = 0; i < 72; i++)
    mbe_packet_deinterleaved[i] = mbe_packet_interleaved[dmr_interleave_permutation[i]];
  char ambe_fr[4][24] = {{0}};
  for (int i = 0, j = 0; i < 24; i++, j++) ambe_fr[0][j] = mbe_packet_deinterleaved[i];  // c0
  for (int i = 24, j = 0; i < 47; i++, j++) ambe_fr[1][j] = mbe_packet_deinterleaved[i];  // c1
  for (int i = 47, j = 0; i < 58; i++, j++) ambe_fr[2][j] = mbe_packet_deinterleaved[i];  // c2
  for (int i = 58, j = 0; i < 72; i++, j++) ambe_fr[3][j] = mbe_packet_deinterleaved[i];  // c3
  int errs = 0, errs2 = 0;
  char err_str[64] = {0};
  char ambe_d[49] = {0};
  static_assert(sizeof(short) == sizeof(int16_t), "mbelib writes short PCM");
  mbe_processAmbe3600x2450Frame(reinterpret_cast<short*>(out), &errs, &errs2, err_str, ambe_fr,
                                ambe_d, &impl_->cur_mp, &impl_->prev_mp,
                                &impl_->prev_mp_enhanced, 3);
  if (stats) {
    stats->errs = errs;
    stats->errs2 = errs2;
    std::memcpy(stats->err_str, err_str, sizeof err_str);
  }
  return true;
#else
  (void)bits;
  (void)out;
  (void)stats;
  return false;
#endif
}

// ---------------------------------------------------------------- output stage

struct VoiceOutput::Impl {
  AmbeSynthesizer synth;
  std::unique_ptr<Digiham::DigitalVoice::DigitalVoiceFilter> filter;
  std::unique_ptr<Csdr::Agc<short>> agc;
  VecReader agc_in;
  VecWriter agc_out;
  Upsampler6 upsampler;
  std::deque<float> queue;
  bool playing = false;
  bool enabled = true;
  uint64_t decoded = 0, dropped = 0, overflowed = 0;
  std::vector<int16_t>* capture_8k = nullptr;

  Impl() { make_modules(); }
  void make_modules() {
    // csdr Modules own a mutex and are not assignable; recreate on reset.
    filter = std::make_unique<Digiham::DigitalVoice::DigitalVoiceFilter>();
    // DigihamChain: Agc(Format.SHORT); setMaxGain(30); setInitialGain(3).
    // All other parameters are csdr defaults (reference 0.8, attack 0.1,
    // decay 0.001, hang 200, ahead 100), as in OpenWebRX+.
    agc = std::make_unique<Csdr::Agc<short>>();
    agc->setReader(&agc_in);
    agc->setWriter(&agc_out);
    agc->setMaxGain(30);
    agc->setInitialGain(3);
  }
  void reset() {
    synth.reset();
    agc_in.clear();
    agc_out.out.clear();
    make_modules();
    upsampler.reset();
    queue.clear();
    playing = false;
  }
};

VoiceOutput::VoiceOutput() : impl_(std::make_unique<Impl>()) {}
VoiceOutput::~VoiceOutput() = default;

void VoiceOutput::on_ambe(const AmbeFrame& frame) {
  Impl& s = *impl_;
  if (!s.enabled || !vocoder_available()) {
    ++s.dropped;
    return;
  }
  int16_t pcm[kFrameSamples];
  if (!s.synth.decode(frame.bits, pcm)) {
    ++s.dropped;
    return;
  }
  ++s.decoded;
  // DigitalVoiceFilter (short -> short), then Agc<short>, in upstream order.
  short filtered[kFrameSamples];
  s.filter->process(reinterpret_cast<short*>(pcm), filtered, kFrameSamples);
  s.agc_in.data.insert(s.agc_in.data.end(), filtered, filtered + kFrameSamples);
  while (s.agc->canProcess()) s.agc->process();
  s.agc_in.compact();
  // After the first frame exactly 160 samples leave the AGC per frame; its
  // 100-sample look-ahead stays buffered inside, as upstream.
  if (s.capture_8k)
    s.capture_8k->insert(s.capture_8k->end(), s.agc_out.out.begin(), s.agc_out.out.end());
  float up[kInterpolation];
  for (short v : s.agc_out.out) {
    s.upsampler.put(static_cast<float>(v) / 32768.0f, up);
    s.queue.insert(s.queue.end(), up, up + kInterpolation);
  }
  s.agc_out.out.clear();
  if (s.queue.size() > kCapacityFrames) {
    const size_t excess = s.queue.size() - kCapacityFrames;
    s.queue.erase(s.queue.begin(), s.queue.begin() + static_cast<std::ptrdiff_t>(excess));
    s.overflowed += excess;
  }
}

size_t VoiceOutput::read_audio(float* mono, size_t max_frames) {
  Impl& s = *impl_;
  if (!s.playing) {
    if (s.queue.size() < kPrebufferFrames) return 0;
    s.playing = true;
  }
  const size_t n = std::min(max_frames, s.queue.size());
  std::copy_n(s.queue.begin(), n, mono);
  s.queue.erase(s.queue.begin(), s.queue.begin() + static_cast<std::ptrdiff_t>(n));
  if (s.queue.empty()) s.playing = false;
  return n;
}

void VoiceOutput::reset() { impl_->reset(); }
void VoiceOutput::set_enabled(bool enabled) {
  if (impl_->enabled && !enabled) impl_->reset();
  impl_->enabled = enabled;
}
bool VoiceOutput::enabled() const { return impl_->enabled; }
size_t VoiceOutput::buffered_frames() const { return impl_->queue.size(); }
uint64_t VoiceOutput::frames_decoded() const { return impl_->decoded; }
uint64_t VoiceOutput::frames_dropped() const { return impl_->dropped; }
uint64_t VoiceOutput::samples_overflowed() const { return impl_->overflowed; }
void VoiceOutput::set_capture_8k(std::vector<int16_t>* sink) { impl_->capture_8k = sink; }

}  // namespace sdrcore::dmr
