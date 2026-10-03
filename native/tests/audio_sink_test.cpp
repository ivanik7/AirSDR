// SPDX-License-Identifier: GPL-3.0-or-later
//
// Host test for the audio sink backends (null/WAV/ALSA) behind audio_sink.h.
// Plain asserts via CHECK (prints file:line on failure); no external test
// framework, mirroring native/tests/*.cpp. Returns 0 on success, nonzero on
// first failure.
#include "../src/audio/audio_sink.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

using sdrcore::AudioSink;
using sdrcore::AudioSinkKind;
using sdrcore::AudioSinkSpec;
using sdrcore::AudioSinkStats;
using sdrcore::make_audio_sink;
using sdrcore::parse_audio_sink_spec;

namespace {

int g_failures = 0;

#define CHECK(cond)                                                       \
  do {                                                                    \
    if (!(cond)) {                                                        \
      std::fprintf(stderr, "CHECK failed at %s:%d: %s\n", __FILE__,       \
                   __LINE__, #cond);                                      \
      g_failures++;                                                       \
    }                                                                     \
  } while (0)

std::string TempPath(const char* name) {
  const char* tmpdir = std::getenv("TMPDIR");
  std::string dir = (tmpdir && *tmpdir) ? tmpdir : "/tmp";
  return dir + "/" + name;
}

// --- Spec parsing table ---------------------------------------------------
void TestParseSpec() {
  AudioSinkSpec spec;

  CHECK(parse_audio_sink_spec(nullptr, &spec));
  CHECK(spec.kind == AudioSinkKind::kNull);

  spec = AudioSinkSpec{};
  CHECK(parse_audio_sink_spec("", &spec));
  CHECK(spec.kind == AudioSinkKind::kNull);

  spec = AudioSinkSpec{};
  CHECK(parse_audio_sink_spec("null", &spec));
  CHECK(spec.kind == AudioSinkKind::kNull);

  spec = AudioSinkSpec{};
  CHECK(parse_audio_sink_spec("wav:/tmp/out.wav", &spec));
  CHECK(spec.kind == AudioSinkKind::kWav);
  CHECK(spec.target == "/tmp/out.wav");

  spec = AudioSinkSpec{};
  CHECK(parse_audio_sink_spec("alsa", &spec));
  CHECK(spec.kind == AudioSinkKind::kAlsa);
  CHECK(spec.target == "default");

  spec = AudioSinkSpec{};
  CHECK(parse_audio_sink_spec("alsa:hw:0,0", &spec));
  CHECK(spec.kind == AudioSinkKind::kAlsa);
  CHECK(spec.target == "hw:0,0");

  // Malformed/unknown specs: out must be left untouched.
  spec = AudioSinkSpec{};
  spec.kind = AudioSinkKind::kWav;
  spec.target = "sentinel";
  CHECK(!parse_audio_sink_spec("wav:", &spec));
  CHECK(spec.kind == AudioSinkKind::kWav && spec.target == "sentinel");

  CHECK(!parse_audio_sink_spec("pulse", &spec));
  CHECK(spec.kind == AudioSinkKind::kWav && spec.target == "sentinel");

  CHECK(!parse_audio_sink_spec("alsa:", &spec));
  CHECK(spec.kind == AudioSinkKind::kWav && spec.target == "sentinel");

  std::printf("[ok] parse_audio_sink_spec\n");
}

// --- Null sink: counting and sample-rate validation -----------------------
void TestNullSink() {
  AudioSinkSpec spec;
  CHECK(parse_audio_sink_spec("null", &spec));
  auto sink = make_audio_sink(spec);
  CHECK(sink != nullptr);
  CHECK(std::strcmp(sink->name(), "null") == 0);

  // Invalid sample rates rejected, sink stays closed.
  CHECK(sink->open(7999) == -1);
  CHECK(sink->open(192001) == -1);
  AudioSinkStats closed_stats = sink->stats();
  CHECK(closed_stats.sample_rate == 0);

  // write() while closed returns 0.
  float silent_frame[2] = {0.0f, 0.0f};
  CHECK(sink->write(silent_frame, 1) == 0);

  CHECK(sink->open(48000) == 0);
  AudioSinkStats s = sink->stats();
  CHECK(s.sample_rate == 48000);
  CHECK(s.frames_written == 0);

  // 100 silent frames.
  std::vector<float> silence(2 * 100, 0.0f);
  CHECK(sink->write(silence.data(), 100) == 100);
  s = sink->stats();
  CHECK(s.frames_written == 100);
  CHECK(s.nonsilent_frames == 0);
  CHECK(s.peak == 0.0f);

  // 100 frames of a loud sine (amplitude 0.5) -> all nonsilent.
  std::vector<float> sine(2 * 100);
  for (int i = 0; i < 100; ++i) {
    float v = 0.5f * std::sin(2.0f * 3.14159265f * i / 20.0f);
    sine[2 * i] = v;
    sine[2 * i + 1] = -v;
  }
  CHECK(sink->write(sine.data(), 100) == 100);
  s = sink->stats();
  CHECK(s.frames_written == 200);
  CHECK(s.nonsilent_frames >= 90);  // allow a couple of near-zero-crossing frames
  CHECK(s.peak > 0.49f && s.peak <= 0.5001f);

  sink->close();
  s = sink->stats();
  CHECK(s.sample_rate == 0);
  CHECK(sink->write(silence.data(), 1) == 0);  // closed -> 0

  std::printf("[ok] null sink counting\n");
}

// --- WAV file helpers ------------------------------------------------------
uint32_t ReadU32LE(const uint8_t* p) {
  return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16) |
         (static_cast<uint32_t>(p[3]) << 24);
}

uint16_t ReadU16LE(const uint8_t* p) {
  return static_cast<uint16_t>(p[0] | (p[1] << 8));
}

int16_t ReadS16LE(const uint8_t* p) {
  return static_cast<int16_t>(ReadU16LE(p));
}

struct WavFile {
  std::vector<uint8_t> bytes;
  uint32_t riff_size = 0;
  uint32_t fmt_pcm = 0;
  uint16_t channels = 0;
  uint32_t rate = 0;
  uint32_t byte_rate = 0;
  uint16_t block_align = 0;
  uint16_t bits = 0;
  uint32_t data_size = 0;
  const uint8_t* data = nullptr;
};

bool ReadWav(const std::string& path, WavFile* out) {
  std::ifstream f(path, std::ios::binary);
  if (!f) return false;
  out->bytes.assign(std::istreambuf_iterator<char>(f),
                     std::istreambuf_iterator<char>());
  const auto& b = out->bytes;
  if (b.size() < 44) return false;
  if (std::memcmp(b.data(), "RIFF", 4) != 0) return false;
  out->riff_size = ReadU32LE(&b[4]);
  if (std::memcmp(&b[8], "WAVE", 4) != 0) return false;
  if (std::memcmp(&b[12], "fmt ", 4) != 0) return false;
  out->fmt_pcm = ReadU16LE(&b[20]);
  out->channels = ReadU16LE(&b[22]);
  out->rate = ReadU32LE(&b[24]);
  out->byte_rate = ReadU32LE(&b[28]);
  out->block_align = ReadU16LE(&b[32]);
  out->bits = ReadU16LE(&b[34]);
  if (std::memcmp(&b[36], "data", 4) != 0) return false;
  out->data_size = ReadU32LE(&b[40]);
  out->data = b.data() + 44;
  return true;
}

// --- WAV sink: write sine, verify header/content/clipping -----------------
void TestWavSink() {
  const std::string path = TempPath("audio_sink_test.wav");
  std::remove(path.c_str());

  AudioSinkSpec spec;
  CHECK(parse_audio_sink_spec(("wav:" + path).c_str(), &spec));
  auto sink = make_audio_sink(spec);
  CHECK(sink != nullptr);
  CHECK(std::strcmp(sink->name(), "wav") == 0);

  const uint32_t kRate = 48000;
  CHECK(sink->open(kRate) == 0);

  const int kTotalFrames = kRate / 2;  // 0.5 s
  std::vector<float> all_l(kTotalFrames), all_r(kTotalFrames);
  for (int i = 0; i < kTotalFrames; ++i) {
    float s = std::sin(2.0f * 3.14159265f * 1000.0 * i / kRate);
    all_l[i] = 0.5f * s;
    all_r[i] = -0.5f * s;
  }

  // Write in several chunks of uneven size.
  int written_total = 0;
  const int chunk_sizes[] = {1000, 4000, 777, 10000};
  int chunk_idx = 0;
  while (written_total < kTotalFrames) {
    int n = chunk_sizes[chunk_idx % 4];
    chunk_idx++;
    if (written_total + n > kTotalFrames) n = kTotalFrames - written_total;
    std::vector<float> buf(2 * n);
    for (int i = 0; i < n; ++i) {
      buf[2 * i] = all_l[written_total + i];
      buf[2 * i + 1] = all_r[written_total + i];
    }
    size_t accepted = sink->write(buf.data(), n);
    CHECK(static_cast<int>(accepted) == n);
    written_total += n;

    // Mid-stream: header should already be valid (periodic flush every
    // ~1s of audio; here 0.5s total so check after a few chunks that the
    // file is at least structurally parseable with a sane (<= final) size).
    WavFile mid;
    if (ReadWav(path, &mid)) {
      CHECK(mid.fmt_pcm == 1);
      CHECK(mid.channels == 2);
      CHECK(mid.rate == kRate);
    }
  }
  CHECK(written_total == kTotalFrames);

  AudioSinkStats s = sink->stats();
  CHECK(s.frames_written == static_cast<uint64_t>(kTotalFrames));

  sink->close();
  // Idempotent close.
  sink->close();

  WavFile wav;
  CHECK(ReadWav(path, &wav));
  CHECK(wav.fmt_pcm == 1);
  CHECK(wav.channels == 2);
  CHECK(wav.rate == kRate);
  CHECK(wav.byte_rate == kRate * 4);
  CHECK(wav.block_align == 4);
  CHECK(wav.bits == 16);
  const uint32_t expected_data_size =
      static_cast<uint32_t>(kTotalFrames) * 4;
  CHECK(wav.data_size == expected_data_size);
  CHECK(wav.riff_size == 36 + expected_data_size);
  CHECK(wav.bytes.size() == 44 + expected_data_size);

  // Sample values within +-1 LSB of round(x * 32767).
  int max_diff = 0;
  for (int i = 0; i < kTotalFrames; ++i) {
    int16_t got_l = ReadS16LE(wav.data + i * 4);
    int16_t got_r = ReadS16LE(wav.data + i * 4 + 2);
    int expect_l = static_cast<int>(std::lround(all_l[i] * 32767.0f));
    int expect_r = static_cast<int>(std::lround(all_r[i] * 32767.0f));
    int diff_l = std::abs(static_cast<int>(got_l) - expect_l);
    int diff_r = std::abs(static_cast<int>(got_r) - expect_r);
    if (diff_l > max_diff) max_diff = diff_l;
    if (diff_r > max_diff) max_diff = diff_r;
  }
  CHECK(max_diff <= 1);

  std::remove(path.c_str());
  std::printf("[ok] wav sink content\n");

  // --- Clipping: +1.5 -> 32767, -1.5 -> -32768 ---
  const std::string clip_path = TempPath("audio_sink_clip_test.wav");
  std::remove(clip_path.c_str());
  AudioSinkSpec clip_spec;
  CHECK(parse_audio_sink_spec(("wav:" + clip_path).c_str(), &clip_spec));
  auto clip_sink = make_audio_sink(clip_spec);
  CHECK(clip_sink->open(48000) == 0);
  float clip_frame[2] = {1.5f, -1.5f};
  CHECK(clip_sink->write(clip_frame, 1) == 1);
  clip_sink->close();

  WavFile clip_wav;
  CHECK(ReadWav(clip_path, &clip_wav));
  int16_t clip_l = ReadS16LE(clip_wav.data);
  int16_t clip_r = ReadS16LE(clip_wav.data + 2);
  CHECK(clip_l == 32767);
  CHECK(clip_r == -32768);  // Documented choice: full negative extreme.
  std::remove(clip_path.c_str());
  std::printf("[ok] wav sink clipping (+1.5->32767, -1.5->-32768)\n");

  // --- Unwritable path fails with SDR_IO_ERROR (-4) ---
  AudioSinkSpec bad_spec;
  CHECK(parse_audio_sink_spec("wav:/nonexistent_dir/x.wav", &bad_spec));
  auto bad_sink = make_audio_sink(bad_spec);
  CHECK(bad_sink != nullptr);
  CHECK(bad_sink->open(48000) == -4);
  AudioSinkStats bad_stats = bad_sink->stats();
  CHECK(bad_stats.last_error == -4);
  CHECK(bad_sink->write(clip_frame, 1) == 0);  // closed -> 0
  std::printf("[ok] wav sink unwritable path -> -4\n");
}

// --- ALSA sink: build-conditional, never requires real playback -----------
#ifdef SDRCORE_HAVE_ALSA
void TestAlsaSink() {
  // Opening a PCM name that cannot possibly exist must fail cleanly with
  // -4 and leave the sink closed; writes afterward return 0. No crash.
  AudioSinkSpec spec;
  CHECK(parse_audio_sink_spec("alsa:sdrcore_no_such_pcm_xyz", &spec));
  auto sink = make_audio_sink(spec);
  CHECK(sink != nullptr);
  CHECK(std::strcmp(sink->name(), "alsa") == 0);
  int rc = sink->open(48000);
  CHECK(rc == -4);
  AudioSinkStats s = sink->stats();
  CHECK(s.sample_rate == 0);
  CHECK(s.last_error == -4);
  float frame[2] = {0.1f, -0.1f};
  CHECK(sink->write(frame, 1) == 0);
  sink->close();  // idempotent, must not crash
  std::printf("[ok] alsa sink: bogus PCM fails open cleanly with -4\n");

  // Opening "default" may succeed or fail depending on host ALSA config
  // (this VM has a sound card but lists no playback PCM). Either outcome
  // is acceptable; we only verify the sink never crashes or blocks, and we
  // never claim audibility.
  AudioSinkSpec default_spec;
  CHECK(parse_audio_sink_spec("alsa", &default_spec));
  auto default_sink = make_audio_sink(default_spec);
  CHECK(default_sink != nullptr);
  int default_rc = default_sink->open(48000);
  if (default_rc == 0) {
    std::vector<float> buf(2 * 480, 0.0f);  // 10ms of silence at 48kHz
    default_sink->write(buf.data(), 480);
    default_sink->close();
    std::printf(
        "[ok] alsa sink: 'default' opened on this host; wrote silence and "
        "closed (no audibility claimed)\n");
  } else {
    CHECK(default_rc == -4);
    std::printf(
        "[ok] alsa sink: 'default' failed to open on this host (expected: "
        "no playback PCM available), handled as -4\n");
  }
}
#endif  // SDRCORE_HAVE_ALSA

}  // namespace

int main() {
  TestParseSpec();
  TestNullSink();
  TestWavSink();
#ifdef SDRCORE_HAVE_ALSA
  TestAlsaSink();
#else
  std::printf("[skip] alsa sink tests (ALSA not found at configure time)\n");
#endif
  if (g_failures == 0) {
    std::printf("All audio sink checks passed.\n");
    return 0;
  }
  std::fprintf(stderr, "%d check(s) failed.\n", g_failures);
  return 1;
}
