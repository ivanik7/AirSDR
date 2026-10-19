// SPDX-License-Identifier: GPL-3.0-or-later
// Generated IQ only: verify the 48 kHz pre-playback tap and frame-aligned edges.
#include "../src/dsp/receiver.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

using sdrcore::dsp::ProcessResult;
using sdrcore::dsp::Receiver;

namespace {
constexpr uint32_t kRate = 240000;
void check(bool ok, const char* message) {
  if (!ok) { std::fprintf(stderr, "FAIL: %s\n", message); std::exit(1); }
}
SdrV3Controls controls(uint32_t squelch = SDR_V3_SQUELCH_OFF) {
  SdrV3Controls c{};
  c.size = sizeof c;
  c.revision = SDR_V3_REVISION;
  c.center_frequency_hz = 446000000;
  c.sample_rate = kRate;
  c.mode = SDR_V3_NFM;
  c.bandwidth_hz = 12500;
  c.squelch = squelch;
  c.squelch_level_db = -20;
  c.volume = 1;
  return c;
}
SdrV3Display display() {
  SdrV3Display d{};
  d.size = sizeof d;
  d.revision = SDR_V3_REVISION;
  d.view_bandwidth_hz = kRate;
  return d;
}
std::vector<uint8_t> fm_iq(double seconds, double amplitude = 65) {
  const size_t count = static_cast<size_t>(seconds * kRate);
  std::vector<uint8_t> data(2 * count);
  double phase = 0;
  for (size_t i = 0; i < count; ++i) {
    phase += 2 * 3.141592653589793 * (2200 * std::sin(2 * 3.141592653589793 * 1000 * i / kRate)) / kRate;
    data[2 * i] = static_cast<uint8_t>(std::lround(127.5 + amplitude * std::cos(phase)));
    data[2 * i + 1] = static_cast<uint8_t>(std::lround(127.5 + amplitude * std::sin(phase)));
  }
  return data;
}
class VoiceProbe final : public sdrcore::decoder::Decoder {
 public:
  bool configure(std::string_view) override { return true; }
  void reset() override {}
  void process(const float*, size_t, uint32_t) override {}
  bool take_event(sdrcore::decoder::Event&) override { return false; }
  bool provides_audio() const override { return true; }
  size_t read_audio(float* mono, size_t count) override {
    for (size_t i = 0; i < count; ++i) mono[i] = 0.25f;
    return count;
  }
};
void test_pre_playback_and_off() {
  auto rx = sdrcore::dsp::make_receiver();
  auto c = controls();
  c.muted = 1;
  c.volume = 0;
  rx->configure(c, display());
  const auto iq = fm_iq(0.1);
  ProcessResult out;
  rx->process(iq.data(), iq.size(), out);
  check(out.recording_channels == 1 && out.recording_pcm.size() == out.audio.size() / 2,
        "mono tap has exactly one sample per playback frame");
  check(out.recording_squelch_edges.size() == 1 &&
        out.recording_squelch_edges[0].frame_offset == 0 && out.recording_squelch_edges[0].open,
        "squelch disabled opens at first output frame");
  check(std::all_of(out.audio.begin(), out.audio.end(), [](float x) { return x == 0; }),
        "playback stays muted");
  check(std::any_of(out.recording_pcm.begin(), out.recording_pcm.end(),
                    [](float x) { return std::abs(x) > 0.001f; }), "tap carries audible signal through mute");
  rx->process(iq.data(), iq.size(), out);
  check(out.recording_squelch_edges.empty(), "open state continues across blocks without duplicate edge");
  c.muted = 0;
  c.volume = 0.5f;
  rx->configure(c, display());
  rx->process(iq.data(), iq.size(), out);
  check(std::all_of(out.recording_pcm.begin(), out.recording_pcm.end(),
                    [](float x) { return std::abs(x) <= 1; }), "recording tap is bounded PCM");
  bool playback_matches = true;
  for (size_t i = 0; i < out.recording_pcm.size(); ++i)
    playback_matches &= std::abs(out.audio[2 * i] - 0.25f * out.recording_pcm[i]) < 1e-6f;
  check(playback_matches, "volume affects playback but not recording tap");
  c.squelch = SDR_V3_SQUELCH_MANUAL;
  c.squelch_level_db = 0;
  rx->configure(c, display());
  rx->process(iq.data(), iq.size(), out);
  check(out.recording_squelch_edges.size() == 1 &&
        out.recording_squelch_edges[0].frame_offset == 0 && !out.recording_squelch_edges[0].open,
        "leaving OFF closes at first output frame when detector is closed");
  c.squelch = SDR_V3_SQUELCH_OFF;
  rx->configure(c, display());
  rx->process(iq.data(), iq.size(), out);
  check(out.recording_squelch_edges.size() == 1 &&
        out.recording_squelch_edges[0].frame_offset == 0 && out.recording_squelch_edges[0].open,
        "switching OFF reopens at first output frame");
}
void test_edges_independent_of_iq_blocks() {
  auto rx = sdrcore::dsp::make_receiver();
  rx->configure(controls(SDR_V3_SQUELCH_MANUAL), display());
  auto iq = fm_iq(0.15);
  const auto quiet = fm_iq(0.40, 3.0);
  iq.insert(iq.end(), quiet.begin(), quiet.end());
  const auto loud = fm_iq(0.15);
  iq.insert(iq.end(), loud.begin(), loud.end());
  iq.insert(iq.end(), quiet.begin(), quiet.end());
  ProcessResult whole;
  rx->process(iq.data(), iq.size(), whole);
  check(whole.recording_channels == 1 && whole.recording_pcm.size() == whole.audio.size() / 2,
        "one output frame per PCM tap frame");
  check(whole.recording_squelch_edges.size() >= 4, "multiple short openings and closings survive one IQ block");
  check(whole.recording_squelch_edges[0].open &&
        whole.recording_squelch_edges[0].frame_offset >= 0 &&
        whole.recording_squelch_edges[0].frame_offset < 7200,
        "detector opens after settling within first loud interval");
  check(!whole.recording_squelch_edges[1].open &&
        whole.recording_squelch_edges[1].frame_offset > 7200 &&
        whole.recording_squelch_edges[1].frame_offset < 26400,
        "detector closes after the first quiet interval begins");
  auto chunked = sdrcore::dsp::make_receiver();
  chunked->configure(controls(SDR_V3_SQUELCH_MANUAL), display());
  size_t total_frames = 0, edge_index = 0;
  std::vector<float> chunked_pcm, chunked_playback;
  ProcessResult part;
  for (size_t pos = 0; pos < iq.size(); pos += 4800) {
    chunked->process(iq.data() + pos, std::min<size_t>(4800, iq.size() - pos), part);
    check(part.recording_pcm.size() == part.audio.size() / 2, "chunked tap frame count");
    for (const auto& edge : part.recording_squelch_edges) {
      check(edge.frame_offset < part.audio.size() / 2, "edge identifies an actual PCM frame");
      check(edge_index < whole.recording_squelch_edges.size() &&
            whole.recording_squelch_edges[edge_index].frame_offset == total_frames + edge.frame_offset &&
            whole.recording_squelch_edges[edge_index].open == edge.open,
            "absolute edge offset matches independent block partition");
      ++edge_index;
    }
    chunked_pcm.insert(chunked_pcm.end(), part.recording_pcm.begin(), part.recording_pcm.end());
    chunked_playback.insert(chunked_playback.end(), part.audio.begin(), part.audio.end());
    total_frames += part.audio.size() / 2;
  }
  check(edge_index == whole.recording_squelch_edges.size() && total_frames == whole.audio.size() / 2,
        "all detector edges and output frames accounted for");
  check(chunked_pcm == whole.recording_pcm && chunked_playback == whole.audio,
        "PCM and playback invariant under IQ block partition");
  check(std::any_of(whole.recording_pcm.begin() + 12000, whole.recording_pcm.begin() + 16000,
                    [](float x) { return std::abs(x) > 0.0001f; }),
        "closed-frame recording PCM remains ungated");
}
void test_voice_bypass_and_stereo_layout() {
  auto rx = sdrcore::dsp::make_receiver();
  auto c = controls(SDR_V3_SQUELCH_MANUAL);
  c.squelch_level_db = 0;
  c.volume = 0.5f;
  c.muted = 1;
  rx->configure(c, display());
  auto iq = fm_iq(0.1);
  ProcessResult out;
  rx->process(iq.data(), iq.size(), out);
  check(out.recording_squelch_edges.empty(), "closed detector has no open edge");
  VoiceProbe voice;
  rx->set_decoder(&voice, sdrcore::decoder::Input::baseband);
  rx->process(iq.data(), iq.size(), out);
  check(out.recording_channels == 1 && out.recording_pcm.size() == out.audio.size() / 2,
        "voice replacement is mono recording");
  check(out.recording_squelch_edges.size() == 1 && out.recording_squelch_edges[0].frame_offset == 0 &&
        out.recording_squelch_edges[0].open, "decoder voice opens recording despite analog detector closed");
  check(std::all_of(out.recording_pcm.begin(), out.recording_pcm.end(),
                    [](float x) { return x == 0.25f; }), "tap contains raw decoded PCM, not analog or muted PCM");
  check(std::all_of(out.audio.begin(), out.audio.end(), [](float x) { return x == 0; }),
        "decoder playback remains muted");
  rx->set_decoder(nullptr);
  rx->process(iq.data(), iq.size(), out);
  check(out.recording_squelch_edges.size() == 1 && out.recording_squelch_edges[0].frame_offset == 0 &&
        !out.recording_squelch_edges[0].open, "leaving voice decoder returns to detector state");
  c.mode = SDR_V3_WFM;
  c.bandwidth_hz = 180000;
  c.squelch = SDR_V3_SQUELCH_OFF;
  rx->configure(c, display());
  rx->set_wfm_stereo(true);
  rx->process(iq.data(), iq.size(), out);
  check(out.recording_channels == 2 && out.recording_pcm.size() == out.audio.size(),
        "WFM preference selects two-channel tap even before pilot lock");
  rx->set_wfm_stereo(false);
  rx->process(iq.data(), iq.size(), out);
  check(out.recording_channels == 1 && out.recording_pcm.size() == out.audio.size() / 2,
        "WFM mono preference selects one-channel tap");
}
}  // namespace
int main() {
  test_pre_playback_and_off();
  test_edges_independent_of_iq_blocks();
  test_voice_bypass_and_stereo_layout();
  std::puts("record DSP tests passed");
}
