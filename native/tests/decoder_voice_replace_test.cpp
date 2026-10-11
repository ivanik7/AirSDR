// SPDX-License-Identifier: GPL-3.0-or-later
// Receiver-level tests for Decoder::provides_audio()/read_audio() (DMR voice
// output, decoder.hpp): decoder PCM REPLACES the demodulator block (no mix),
// gets volume*volume and mute, ignores the squelch gate, and underruns are
// silence. Driven through the public sdrcore::dsp::Receiver only.
#include "../src/dsp/receiver.h"
#include "decoder.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>

namespace {

int failures = 0;
#define CHECK(cond, ...)                                        \
  do {                                                          \
    if (!(cond)) {                                              \
      std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
      std::fprintf(stderr, __VA_ARGS__);                        \
      std::fprintf(stderr, "\n");                               \
      ++failures;                                               \
    } else {                                                    \
      std::printf("[ok] ");                                     \
      std::printf(__VA_ARGS__);                                 \
      std::printf("\n");                                        \
    }                                                           \
  } while (0)

constexpr uint32_t kRate = 240000;

// Voice backend stand-in: hands out a deterministic ramp, `budget` frames
// at most per call (budget < 0: unlimited), and records requested sizes.
class VoiceProbe final : public sdrcore::decoder::Decoder {
 public:
  bool configure(std::string_view) override { return true; }
  void reset() override {}
  void process(const float*, size_t frames, uint32_t) override { baseband_frames += frames; }
  bool take_event(sdrcore::decoder::Event&) override { return false; }
  bool provides_audio() const override { return voice; }
  size_t read_audio(float* mono, size_t max_frames) override {
    requested.push_back(max_frames);
    size_t n = budget < 0 ? max_frames : std::min<size_t>(max_frames, static_cast<size_t>(budget));
    for (size_t i = 0; i < n; ++i) mono[i] = value(next++);
    return n;
  }
  static float value(size_t k) { return 0.8f * static_cast<float>((k % 97) + 1) / 97.0f; }
  bool voice = true;
  long budget = -1;
  size_t next = 0;
  size_t baseband_frames = 0;
  std::vector<size_t> requested;
};

SdrV3Controls controls(float volume, bool muted, uint32_t squelch, float level_db) {
  SdrV3Controls c{};
  c.size = sizeof c;
  c.revision = SDR_V3_REVISION;
  c.center_frequency_hz = 446000000;
  c.sample_rate = kRate;
  c.mode = SDR_V3_NFM;
  c.bandwidth_hz = 12500;
  c.gain_tenths_db = 200;
  c.squelch = squelch;
  c.squelch_level_db = level_db;
  c.volume = volume;
  c.muted = muted ? 1 : 0;
  return c;
}
SdrV3Display display() {
  SdrV3Display d{};
  d.size = sizeof d;
  d.revision = SDR_V3_REVISION;
  d.view_bandwidth_hz = kRate;
  d.width = 0;
  return d;
}

// FM carrier with a 1 kHz tone: the analog path produces loud audio that
// must NOT leak into the replaced block.
std::vector<uint8_t> fm_iq(double seconds) {
  const size_t pairs = static_cast<size_t>(seconds * kRate);
  std::vector<uint8_t> out(2 * pairs);
  double phase = 0;
  for (size_t n = 0; n < pairs; ++n) {
    const double f = 2500 * std::sin(2 * M_PI * 1000.0 * n / kRate);
    phase = std::fmod(phase + 2 * M_PI * f / kRate, 2 * M_PI);
    out[2 * n] = static_cast<uint8_t>(std::lround(127.5 + 40 * std::cos(phase)));
    out[2 * n + 1] = static_cast<uint8_t>(std::lround(127.5 + 40 * std::sin(phase)));
  }
  return out;
}

struct Run {
  std::vector<float> audio;  // interleaved stereo
  size_t blocks = 0;
};
Run run(sdrcore::dsp::Receiver& rx, const std::vector<uint8_t>& iq, size_t block_bytes = 24000) {
  Run r;
  sdrcore::dsp::ProcessResult res;
  for (size_t off = 0; off < iq.size(); off += block_bytes) {
    rx.process(iq.data() + off, std::min(block_bytes, iq.size() - off), res);
    r.audio.insert(r.audio.end(), res.audio.begin(), res.audio.end());
    ++r.blocks;
  }
  return r;
}

void test_replace_volume_and_exact_requests() {
  auto rx = sdrcore::dsp::make_receiver();
  rx->configure(controls(0.5f, false, SDR_V3_SQUELCH_OFF, -50), display());
  VoiceProbe probe;
  rx->set_decoder(&probe, sdrcore::decoder::Input::baseband);
  const auto iq = fm_iq(0.5);
  const auto r = run(*rx, iq);
  size_t requested = 0;
  for (size_t n : probe.requested) requested += n;
  CHECK(requested == r.audio.size() / 2 && probe.requested.size() == r.blocks,
        "read_audio asked for exactly the emitted frames (%zu in %zu blocks)", requested, r.blocks);
  size_t bad = 0;
  for (size_t i = 0; i < r.audio.size() / 2; ++i) {
    const float want = 0.25f * VoiceProbe::value(i);
    if (std::abs(r.audio[2 * i] - want) > 1e-6f || r.audio[2 * i + 1] != r.audio[2 * i]) ++bad;
  }
  CHECK(bad == 0 && !r.audio.empty(),
        "output == decoder PCM * volume^2 on both channels, analog tone not mixed (%zu bad)", bad);
  CHECK(probe.baseband_frames > 0, "baseband branch still feeds the decoder (%zu samples)",
        probe.baseband_frames);
}

void test_underrun_is_silence() {
  auto rx = sdrcore::dsp::make_receiver();
  rx->configure(controls(1.0f, false, SDR_V3_SQUELCH_OFF, -50), display());
  VoiceProbe probe;
  probe.budget = 100;
  rx->set_decoder(&probe, sdrcore::decoder::Input::baseband);
  const auto r = run(*rx, fm_iq(0.3));
  // Every block: first 100 frames from the decoder, the rest exact zeros.
  size_t frame = 0, bad = 0, k = 0;
  sdrcore::dsp::ProcessResult res;
  (void)res;
  for (size_t b = 0; b < probe.requested.size(); ++b) {
    for (size_t i = 0; i < probe.requested[b]; ++i, ++frame) {
      const float got = r.audio[2 * frame];
      const float want = i < 100 ? VoiceProbe::value(k++) : 0.0f;
      if (std::abs(got - want) > 1e-6f) ++bad;
    }
  }
  CHECK(bad == 0, "short read_audio: remainder of each block is silence, never analog audio (%zu bad)", bad);
}

void test_mute_and_squelch() {
  {
    auto rx = sdrcore::dsp::make_receiver();
    rx->configure(controls(1.0f, true, SDR_V3_SQUELCH_OFF, -50), display());
    VoiceProbe probe;
    rx->set_decoder(&probe, sdrcore::decoder::Input::baseband);
    const auto r = run(*rx, fm_iq(0.2));
    const bool silent = std::all_of(r.audio.begin(), r.audio.end(), [](float v) { return v == 0.0f; });
    CHECK(silent && probe.next > 0, "muted: decoder PCM consumed but output silent");
  }
  {
    // Manual squelch far above the signal: the analog gate is closed, yet
    // DMR voice still plays (OpenWebRX+ DMR supportsSquelch() = False).
    auto rx = sdrcore::dsp::make_receiver();
    rx->configure(controls(1.0f, false, SDR_V3_SQUELCH_MANUAL, 0), display());
    VoiceProbe probe;
    rx->set_decoder(&probe, sdrcore::decoder::Input::baseband);
    const auto r = run(*rx, fm_iq(0.3));
    double energy = 0;
    for (float v : r.audio) energy += v * v;
    CHECK(energy > 1.0, "closed squelch does not gate decoder voice (energy %.1f)", energy);
  }
}

void test_non_voice_decoder_unchanged() {
  auto rx = sdrcore::dsp::make_receiver();
  rx->configure(controls(1.0f, false, SDR_V3_SQUELCH_OFF, -50), display());
  VoiceProbe probe;
  probe.voice = false;
  rx->set_decoder(&probe, sdrcore::decoder::Input::baseband);
  const auto r = run(*rx, fm_iq(0.3));
  double energy = 0;
  for (float v : r.audio) energy += v * v;
  CHECK(probe.requested.empty() && energy > 1.0,
        "provides_audio()=false: read_audio never called, demodulator audio kept (energy %.1f)", energy);
}

}  // namespace

int main() {
  test_replace_volume_and_exact_requests();
  test_underrun_is_silence();
  test_mute_and_squelch();
  test_non_voice_decoder_unchanged();
  if (failures) {
    std::fprintf(stderr, "%d failure(s)\n", failures);
    return 1;
  }
  std::puts("decoder voice replace tests passed");
  return 0;
}
