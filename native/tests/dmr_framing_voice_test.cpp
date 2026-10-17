// SPDX-License-Identifier: GPL-3.0-or-later
// Framing -> AMBE+2 voice output integration (t_5b101746).
// Digiham's DmrDecoder (sdrcore::dmr::Framing) feeds codecserver-softmbe's
// mbelib synthesis + DigitalVoiceFilter + Agc (sdrcore::dmr::VoiceOutput)
// exactly like OpenWebRX+'s DmrDecoder -> MbeSynthesizer chain. Bursts are
// built from the digiham sync/CACH tables; their payload is three synthetic
// AMBE+2 channel frames (dmr_ambe_test_encoder.hpp; vocoder buzz, not speech).
#include "dmr/framing.hpp"
#include "dmr/vocoder.hpp"
#include "dmr_ambe_test_encoder.hpp"

extern "C" {
#include "hamming_7_4.h"
}

#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
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

using sdrcore::dmr::AmbeFrame;
using sdrcore::dmr::Framing;
using sdrcore::dmr::SlotMeta;
using sdrcore::dmr::VoiceOutput;
using Burst = std::vector<uint8_t>;

// digiham dmr_phase.hpp dmr_bs_voice_sync.
constexpr std::array<uint8_t, 24> kBsVoice = {1, 3, 1, 1, 1, 1, 3, 3, 3, 1, 1, 3,
                                              3, 1, 3, 3, 1, 3, 1, 1, 3, 3, 1, 3};

// One 144-dibit burst: CACH TACT (Hamming 7,4) for `slot`, BS voice sync, and
// the 27-byte payload (three 9-byte AMBE frames) placed exactly where
// digiham's FramePhase extracts it (54 dibits before, 54 after the sync).
Burst burst(unsigned slot, const std::array<dmr_test::Frame9, 3>& frames) {
  Burst out(144, 0);
  const int pos[] = {0, 4, 8, 12, 14, 18, 22};
  uint8_t tact = 0;
  for (unsigned i = 0; i < 128; ++i) {
    auto candidate = static_cast<uint8_t>(i);
    if (hamming_7_4_parity(&candidate) == 0 && ((i >> 5) & 1) == slot) {
      tact = static_cast<uint8_t>(i);
      break;
    }
  }
  for (int i = 0; i < 7; ++i) {
    const int bit = (tact >> (6 - i)) & 1;
    out[pos[i] / 2] |= static_cast<uint8_t>(bit << (1 - pos[i] % 2));
  }
  uint8_t payload[27];
  for (int f = 0; f < 3; ++f) std::memcpy(payload + 9 * f, frames[f].data(), 9);
  for (int i = 0; i < 108; ++i) {
    const uint8_t dibit = (payload[i / 4] >> (6 - 2 * (i % 4))) & 3;
    out[(i < 54 ? 12 + i : 90 + (i - 54))] = dibit;
  }
  for (size_t i = 0; i < kBsVoice.size(); ++i) out[66 + i] = kBsVoice[i];
  return out;
}

void feed(Framing& f, const Burst& b) {
  // Split across sync/burst boundaries like a real symbol stream.
  for (size_t i = 0; i < b.size(); i += 17) f.on_symbols(b.data() + i, std::min<size_t>(17, b.size() - i));
}

std::array<dmr_test::Frame9, 3> frames_for(int burst_index, int salt) {
  std::array<dmr_test::Frame9, 3> fr;
  for (int k = 0; k < 3; ++k) fr[k] = dmr_test::encode(dmr_test::track(salt + 3 * burst_index + k));
  return fr;
}

std::vector<float> drain(VoiceOutput& v) {
  std::vector<float> out, block(480);
  for (;;) {
    const size_t got = v.read_audio(block.data(), block.size());
    if (!got) break;
    out.insert(out.end(), block.begin(), block.begin() + got);
  }
  return out;
}

// Two interleaved TS1/TS2 voice calls through Framing into VoiceOutput, and a
// reference VoiceOutput fed directly with the frames the selected slot carried.
struct Run {
  std::vector<AmbeFrame> forwarded;
  std::vector<int16_t> pcm8k, ref8k;
  std::vector<float> pcm48k, ref48k;
  uint64_t decoded = 0, dropped = 0;
  int last_sync[2] = {-1, -1};
};

Run run(uint8_t slot_filter, int bursts_per_slot, bool voice_enabled = true) {
  Run r;
  VoiceOutput voice, reference;
  voice.set_enabled(voice_enabled);
  voice.set_capture_8k(&r.pcm8k);
  reference.set_capture_8k(&r.ref8k);
  const auto to_voice = sdrcore::dmr::framing_voice_sink(voice);
  // mbelib's unvoiced synthesis draws from the global rand(); seed both runs
  // identically so PCM is comparable bit for bit.
  std::srand(1);
  Framing framing(
      [&](const AmbeFrame& f) {
        r.forwarded.push_back(f);
        to_voice(f);
      },
      [&](const SlotMeta& m) { r.last_sync[m.slot & 1] = m.sync; });
  framing.set_slot_filter(slot_filter);
  for (int b = 0; b < bursts_per_slot; ++b) {
    const auto ts1 = frames_for(b, 0);
    const auto ts2 = frames_for(b, 1000);
    feed(framing, burst(0, ts1));
    feed(framing, burst(1, ts2));
  }
  // Expected: every burst of the selected slot, all three frames, in order.
  std::srand(1);
  for (const auto& f : r.forwarded) {
    AmbeFrame copy = f;
    reference.on_ambe(copy);
  }
  r.pcm48k = drain(voice);
  r.ref48k = drain(reference);
  r.decoded = voice.frames_decoded();
  r.dropped = voice.frames_dropped();
  return r;
}

bool frames_equal(const std::vector<AmbeFrame>& got, unsigned slot, int salt, int bursts) {
  if (got.size() != static_cast<size_t>(3 * bursts)) return false;
  for (int b = 0; b < bursts; ++b) {
    const auto exp = frames_for(b, salt);
    for (int k = 0; k < 3; ++k) {
      const AmbeFrame& f = got[3 * b + k];
      if (f.slot != slot || std::memcmp(f.bits, exp[k].data(), 9) != 0) return false;
    }
  }
  return true;
}

}  // namespace

int main() {
  constexpr int kBursts = 12;  // 12 x 60 ms of TS1 voice = 36 AMBE frames

  {
    Run r = run(3, kBursts);
    CHECK(frames_equal(r.forwarded, 0, 0, kBursts),
          "slot filter 3: framing forwards all %d TS1 frames bit-exactly (TS2 muted, first slot wins)",
          3 * kBursts);
    CHECK(r.last_sync[0] == 2, "TS1 metadata reports voice sync");
    if (sdrcore::dmr::vocoder_available()) {
      CHECK(r.decoded == 3u * kBursts && r.dropped == 0, "VoiceOutput synthesized %llu frames",
            static_cast<unsigned long long>(r.decoded));
      // First frame: 60 samples (AGC 100-sample look-ahead), then 160 per frame.
      CHECK(r.pcm8k.size() == 160u * 3 * kBursts - 100, "8 kHz stream length %zu", r.pcm8k.size());
      CHECK(r.pcm8k == r.ref8k, "8 kHz PCM via framing == direct VoiceOutput reference (bit-exact)");
      CHECK(r.pcm48k.size() == 6 * r.pcm8k.size() && r.pcm48k == r.ref48k,
            "48 kHz output via framing == reference (%zu samples)", r.pcm48k.size());
      double energy = 0;
      for (float s : r.pcm48k) energy += double(s) * s;
      CHECK(energy > 0, "synthesized audio is non-silent");
    } else {
      CHECK(r.decoded == 0 && r.dropped == 3u * kBursts && r.pcm48k.empty(),
            "vocoder disabled at build time: frames counted as dropped, no PCM");
    }
  }
  {
    Run r = run(2, kBursts);
    CHECK(frames_equal(r.forwarded, 1, 1000, kBursts), "slot filter 2: only TS2 frames reach the vocoder");
    if (sdrcore::dmr::vocoder_available())
      CHECK(!r.pcm8k.empty() && r.pcm8k == r.ref8k, "TS2 PCM bit-exact vs reference");
  }
  {
    Run r = run(3, kBursts, /*voice_enabled=*/false);
    CHECK(r.forwarded.size() == 3u * kBursts && r.decoded == 0 && r.dropped == 3u * kBursts &&
              r.pcm48k.empty() && r.pcm8k.empty(),
          "{\"voice\":false}: frames decoded by framing, dropped by the vocoder, no PCM");
  }

  std::printf("%s (%d failures)\n", failures ? "FAILED" : "dmr framing->voice OK", failures);
  return failures ? 1 : 0;
}
