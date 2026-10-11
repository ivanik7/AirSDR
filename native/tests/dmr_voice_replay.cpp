// SPDX-License-Identifier: GPL-3.0-or-later
// Host-only DMR voice replay for the OpenWebRX+ oracle comparison
// (tool/dmr_voice_oracle). Not linked into the app.
//
//   dmr_voice_replay corpus KIND N SEED   > frames.bin   (9-byte AMBE frames)
//   dmr_voice_replay synth SEED  < frames > pcm8k_s16    (AmbeSynthesizer only)
//   dmr_voice_replay chain SEED  < frames > pcm8k_s16    (synth+filter+AGC, capture_8k)
//   dmr_voice_replay out48 SEED  < frames > pcm48k_f32   (full VoiceOutput, mono float)
//
// KIND: clean | errors | special | random. SEED seeds rand() before the run
// (mbelib's unvoiced phases use rand(); the oracle seeds identically).
#include "dmr/vocoder.hpp"
#include "dmr_ambe_test_encoder.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <vector>

namespace {

std::vector<dmr_test::Frame9> corpus(const std::string& kind, int n, unsigned seed) {
  std::mt19937 rng(seed);
  std::vector<dmr_test::Frame9> out;
  for (int i = 0; i < n; ++i) {
    if (kind == "random") {
      dmr_test::Frame9 f;
      for (auto& b : f) b = static_cast<uint8_t>(rng());
      out.push_back(f);
      continue;
    }
    dmr_test::Params p = dmr_test::track(i + static_cast<int>(seed));
    if (kind == "special") {
      // Bursts of silence (124/125), erasure (120..123) and tone (126/127)
      // frames between voiced runs.
      const int phase = i % 30;
      if (phase >= 20 && phase < 23) p.b0 = 124 + (phase & 1);
      else if (phase >= 23 && phase < 25) p.b0 = 120 + (phase - 23);
      else if (phase == 25) p.b0 = 126;
    }
    auto f = dmr_test::encode(p);
    if (kind == "errors") {
      // 0..6 random channel bit flips per frame: exercises Golay correction,
      // repeat ('R') and mute ('M') paths.
      const int flips = static_cast<int>(rng() % 7);
      for (int k = 0; k < flips; ++k) dmr_test::flip(f, static_cast<int>(rng() % 72));
    }
    out.push_back(f);
  }
  return out;
}

std::vector<sdrcore::dmr::AmbeFrame> read_frames() {
  std::vector<sdrcore::dmr::AmbeFrame> frames;
  sdrcore::dmr::AmbeFrame f;
  while (std::fread(f.bits, 1, 9, stdin) == 9) frames.push_back(f);
  return frames;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: see header\n");
    return 2;
  }
  const std::string cmd = argv[1];
  if (cmd == "corpus") {
    if (argc < 5) return 2;
    for (const auto& f : corpus(argv[2], std::atoi(argv[3]), static_cast<unsigned>(std::atoi(argv[4]))))
      std::fwrite(f.data(), 1, 9, stdout);
    return 0;
  }
  std::srand(static_cast<unsigned>(std::atoi(argv[2])));
  const auto frames = read_frames();
  if (cmd == "synth") {
    sdrcore::dmr::AmbeSynthesizer synth;
    int16_t pcm[160];
    for (const auto& f : frames) {
      if (!synth.decode(f.bits, pcm)) return 3;
      std::fwrite(pcm, sizeof pcm[0], 160, stdout);
    }
    return 0;
  }
  sdrcore::dmr::VoiceOutput out;
  if (cmd == "chain") {
    std::vector<int16_t> cap;
    out.set_capture_8k(&cap);
    for (const auto& f : frames) out.on_ambe(f);
    std::fwrite(cap.data(), sizeof(int16_t), cap.size(), stdout);
    return 0;
  }
  if (cmd == "out48") {
    std::vector<float> buf(sdrcore::dmr::VoiceOutput::kCapacityFrames);
    for (const auto& f : frames) {
      out.on_ambe(f);
      size_t n;
      while ((n = out.read_audio(buf.data(), buf.size())) > 0) std::fwrite(buf.data(), sizeof(float), n, stdout);
    }
    return 0;
  }
  return 2;
}
