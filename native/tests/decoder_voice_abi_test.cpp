// SPDX-License-Identifier: GPL-3.0-or-later
// White-box ABI test for decoder voice output (Decoder::provides_audio):
// synthetic source -> v3 DSP worker -> receiver replace stage -> sdrcore.cpp
// mute-while-decoding policy -> the real "wav:" AudioSink. A voice probe is
// registered in place of the production registry (like
// decoder_registry_stub.cpp). Checks the PCM that reaches the sink is the
// decoder's PCM * volume^2 and that it is NOT zeroed by the baseband-decoder
// mute policy; a non-voice baseband decoder stays muted as before.
#include "../src/sdrcore.cpp"

#include <cassert>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <thread>

namespace {

constexpr float kLevel = 0.5f;
constexpr float kVolume = 0.8f;

class VoiceProbe final : public sdrcore::decoder::Decoder {
 public:
  explicit VoiceProbe(bool voice) : voice_(voice) {}
  bool configure(std::string_view) override { return true; }
  void reset() override {}
  void process(const float*, size_t, uint32_t) override {}
  bool take_event(sdrcore::decoder::Event&) override { return false; }
  bool provides_audio() const override { return voice_; }
  size_t read_audio(float* mono, size_t max_frames) override {
    std::fill(mono, mono + max_frames, kLevel);
    return max_frames;
  }
 private:
  bool voice_;
};

}  // namespace

namespace sdrcore::decoder {
const std::vector<Registration>& registry() {
  static const std::vector<Registration> regs{
      {{"voiceprobe", Input::baseband, false, UINT32_MAX, 0, Result::message},
       [] { return std::unique_ptr<Decoder>(new VoiceProbe(true)); }},
      {{"dataprobe", Input::baseband, false, UINT32_MAX, 0, Result::message},
       [] { return std::unique_ptr<Decoder>(new VoiceProbe(false)); }},
  };
  return regs;
}
}  // namespace sdrcore::decoder

namespace {

std::vector<int16_t> run_session(const char* decoder_id, const std::string& wav) {
  SdrHandle* h = sdr_create();
  assert(h && sdr_v2_open_synthetic(h, 300000) == SDR_OK);
  SdrV3Controls c{};
  c.size = sizeof c;
  c.revision = SDR_V3_REVISION;
  c.center_frequency_hz = 446000000;
  c.sample_rate = 300000;
  c.mode = SDR_V3_NFM;
  c.bandwidth_hz = 12500;
  c.squelch = SDR_V3_SQUELCH_MANUAL;  // closed for the synthetic ramp: no gate on voice
  c.squelch_level_db = 0;
  c.volume = kVolume;
  assert(sdr_v3_set_controls(h, &c) == SDR_OK);
  SdrV3Display d{};
  d.size = sizeof d;
  d.revision = SDR_V3_REVISION;
  d.view_bandwidth_hz = 300000;
  d.width = 256;
  assert(sdr_v3_set_display(h, &d) == SDR_OK);
  const std::string spec = "wav:" + wav;
  assert(sdr_v3_set_audio_sink(h, spec.c_str(), static_cast<uint32_t>(spec.size())) == SDR_OK);
  assert(sdr_decoder_select(h, decoder_id, static_cast<uint32_t>(std::strlen(decoder_id)), "", 0) ==
         SDR_OK);
  assert(sdr_v3_start(h) == SDR_OK);
  std::this_thread::sleep_for(std::chrono::milliseconds(600));
  assert(sdr_v3_stop(h) == SDR_OK);
  assert(sdr_v2_close(h) == SDR_OK);
  sdr_destroy(h);
  std::ifstream f(wav, std::ios::binary);
  std::vector<char> bytes((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
  assert(bytes.size() > 44);
  std::vector<int16_t> pcm((bytes.size() - 44) / 2);
  std::memcpy(pcm.data(), bytes.data() + 44, pcm.size() * 2);
  return pcm;
}

}  // namespace

int main() {
  const char* tmp = std::getenv("TMPDIR");
  const std::string dir = tmp && *tmp ? tmp : "/tmp";
  const auto voice = run_session("voiceprobe", dir + "/sdrcore_voice_abi.wav");
  const int16_t want = static_cast<int16_t>(std::lround(kLevel * kVolume * kVolume * 32767.0f));
  size_t exact = 0;
  for (int16_t s : voice) exact += std::abs(s - want) <= 1;
  std::printf("voice decoder: %zu/%zu sink samples == %d\n", exact, voice.size(), want);
  assert(voice.size() > 9600 && exact == voice.size());
  const auto data = run_session("dataprobe", dir + "/sdrcore_data_abi.wav");
  size_t nonzero = 0;
  for (int16_t s : data) nonzero += s != 0;
  std::printf("non-voice baseband decoder: %zu/%zu nonzero sink samples\n", nonzero, data.size());
  assert(data.size() > 9600 && nonzero == 0);
  std::puts("decoder voice ABI checks passed");
  return 0;
}
