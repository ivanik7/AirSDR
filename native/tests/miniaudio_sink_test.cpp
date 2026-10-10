// SPDX-License-Identifier: GPL-3.0-or-later
//
// Offline checks of the miniaudio desktop sink on miniaudio's null backend
// ("miniaudio:null"): a real-time paced device callback without hardware.
// Verifies the AAudio-equivalent real-time model: nonblocking write into the
// SPSC PcmRing, 60 ms pre-roll, re-prime after an underflow, counted drops on
// overflow, idempotent close and reopen.
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

#include "audio_sink.h"
#include "pcm_ring.h"

namespace {

int g_failures = 0;

#define CHECK(cond)                                                       \
  do {                                                                    \
    if (!(cond)) {                                                        \
      std::fprintf(stderr, "CHECK failed at %s:%d: %s\n", __FILE__,       \
                   __LINE__, #cond);                                      \
      ++g_failures;                                                       \
    }                                                                     \
  } while (0)

using Clock = std::chrono::steady_clock;
using sdrcore::AudioSink;
using sdrcore::AudioSinkSpec;
using sdrcore::AudioSinkStats;

constexpr uint32_t kRate = 48000;
constexpr size_t kBlock = 480;  // 10 ms
constexpr float kAmplitude = 0.5f;

std::unique_ptr<AudioSink> make_null_backend_sink() {
  AudioSinkSpec spec;
  if (!sdrcore::parse_audio_sink_spec("miniaudio:null", &spec)) return nullptr;
  return sdrcore::make_audio_sink(spec);
}

// Writes `blocks` 10 ms sine blocks at real-time pace; returns frames pushed.
size_t write_realtime(AudioSink& sink, size_t blocks, double& phase) {
  std::vector<float> buf(kBlock * 2);
  size_t pushed = 0;
  auto next = Clock::now();
  for (size_t b = 0; b < blocks; ++b) {
    for (size_t i = 0; i < kBlock; ++i) {
      const float v = kAmplitude * static_cast<float>(std::sin(phase));
      phase += 2.0 * M_PI * 1000.0 / kRate;
      buf[i * 2] = v;
      buf[i * 2 + 1] = v;
    }
    pushed += kBlock;
    sink.write(buf.data(), kBlock);
    next += std::chrono::milliseconds(10);
    std::this_thread::sleep_until(next);
  }
  return pushed;
}

void TestRejectsBadRate() {
  auto sink = make_null_backend_sink();
  CHECK(sink != nullptr);
  if (!sink) return;
  CHECK(std::strcmp(sink->name(), "miniaudio") == 0);
  CHECK(sink->open(7999) == -1);
  CHECK(sink->open(192001) == -1);
  CHECK(sink->stats().sample_rate == 0);
  const float frame[2] = {0.1f, 0.1f};
  CHECK(sink->write(frame, 1) == 0);  // closed
  std::printf("[ok] miniaudio rejects invalid rates, closed write -> 0\n");
}

void TestRealtimePlayback() {
  auto sink = make_null_backend_sink();
  CHECK(sink != nullptr);
  if (!sink) return;
  CHECK(sink->open(kRate) == 0);
  AudioSinkStats s = sink->stats();
  CHECK(s.sample_rate == kRate);
  CHECK(s.last_error == 0);

  double phase = 0;
  const size_t pushed = write_realtime(*sink, 100, phase);  // 1 s
  s = sink->stats();
  CHECK(s.frames_written == pushed);
  CHECK(s.frames_dropped == 0);
  CHECK(s.peak > 0.49f && s.peak <= kAmplitude + 1e-4f);
  CHECK(s.nonsilent_frames >= pushed * 9 / 10);
  // The callback emitted the 60 ms pre-roll as silence before playing.
  CHECK(s.zero_filled_frames >= sdrcore::kPlaybackPrefillFrames / 2);
  CHECK(s.last_error == 0);
  const uint64_t underflows_before = s.underflows;
  const uint64_t zero_before = s.zero_filled_frames;
  std::printf("[info] after 1 s: written %llu, zero-filled %llu, underflows %llu\n",
              static_cast<unsigned long long>(s.frames_written),
              static_cast<unsigned long long>(s.zero_filled_frames),
              static_cast<unsigned long long>(s.underflows));
  // Steady paced writing must not starve the callback more than a few times.
  CHECK(s.underflows <= 3);

  // Starve the callback for 200 ms: it underflows and re-primes.
  std::this_thread::sleep_for(std::chrono::milliseconds(200));
  write_realtime(*sink, 1, phase);
  s = sink->stats();
  CHECK(s.underflows >= underflows_before + 1);
  CHECK(s.zero_filled_frames > zero_before + kRate / 10);

  // Playback resumes after the re-prime.
  const uint64_t written_before = s.frames_written;
  write_realtime(*sink, 30, phase);
  s = sink->stats();
  CHECK(s.frames_written == written_before + 30 * kBlock);
  CHECK(s.frames_dropped == 0);

  // A burst larger than the ring never blocks; the excess is dropped.
  std::vector<float> burst(sdrcore::kPlaybackRingFrames * 2 * 2, 0.25f);
  const auto t0 = Clock::now();
  const size_t accepted = sink->write(burst.data(), burst.size() / 2);
  const auto took = Clock::now() - t0;
  s = sink->stats();
  CHECK(accepted < burst.size() / 2);
  CHECK(accepted <= sdrcore::kPlaybackRingFrames);
  CHECK(s.frames_dropped == burst.size() / 2 - accepted);
  CHECK(took < std::chrono::milliseconds(5));

  sink->close();
  sink->close();  // idempotent
  CHECK(sink->stats().sample_rate == 0);
  const float frame[2] = {0.1f, 0.1f};
  CHECK(sink->write(frame, 1) == 0);
  std::printf("[ok] miniaudio null backend: pre-roll, re-prime, drops, close\n");

  // Reopen resets the stats and plays again.
  CHECK(sink->open(44100) == 0);
  s = sink->stats();
  CHECK(s.sample_rate == 44100);
  CHECK(s.frames_written == 0 && s.frames_dropped == 0);
  std::vector<float> one(kBlock * 2, 0.1f);
  CHECK(sink->write(one.data(), kBlock) == kBlock);
  sink->close();
  std::printf("[ok] miniaudio reopen\n");
}

void TestDestroyWhileOpen() {
  auto sink = make_null_backend_sink();
  CHECK(sink != nullptr);
  if (!sink) return;
  CHECK(sink->open(kRate) == 0);
  std::vector<float> buf(kBlock * 2, 0.2f);
  sink->write(buf.data(), kBlock);
  sink.reset();  // destructor must stop the device before freeing the ring
  std::printf("[ok] miniaudio destroy while open\n");
}

}  // namespace

int main() {
  TestRejectsBadRate();
  TestRealtimePlayback();
  TestDestroyWhileOpen();
  if (g_failures == 0) {
    std::printf("All miniaudio sink checks passed.\n");
    return 0;
  }
  std::fprintf(stderr, "%d check(s) failed.\n", g_failures);
  return 1;
}
