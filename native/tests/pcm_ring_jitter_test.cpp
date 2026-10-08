// SPDX-License-Identifier: GPL-3.0-or-later
//
// Regression test for audio dropouts while scrolling (kanban t_c364ac15).
//
// The AAudio callback pops a fixed burst from PcmRing at the device clock;
// the DSP thread pushes ~82 frames per 8 KiB IQ block (1.7 ms at 2.4 MS/s).
// The ring used to start playing as soon as one frame was queued and
// zero-filled every shortfall, so in steady state it ran with a margin of
// about one burst: any producer delay longer than that (DSP thread preempted
// while the UI renders a drag on the phone, a USB hiccup) became a hole in
// the audio, and the next stall did it again. The old Dart output kept a
// 60 ms pre-roll (audio_output.dart: waitingMs=60) and never showed that.
//
// Deterministic simulated time, no threads: a producer with one 30 ms stall
// per 250 ms (a retune or a busy UI frame), a consumer pulling 192-frame
// bursts every 4 ms.
#include <cstdio>
#include <vector>

#include "pcm_ring.h"

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

struct Result {
  size_t zero_frames_after_start = 0;  // zero-filled once audio has begun
  size_t holes = 0;                    // callbacks with any zero after start
  size_t first_audio_us = 0;
  size_t played = 0;
};

// Simulates `seconds` in 100 us ticks. The producer emits `block` frames
// every `block_us`, except that it is stalled for `stall_us` at the start
// of every `stall_every_us` window; frames it would have produced while
// stalled are delivered at once when it resumes (the IQ waited in the USB
// queue / sample ring). The consumer pops `burst` frames every `burst_us`.
Result simulate(sdrcore::PcmRing& ring, double seconds, size_t stall_us,
                size_t stall_every_us) {
  constexpr size_t kTick = 100, block = 82, block_us = 1700, burst = 192,
                   burst_us = 4000;
  Result r;
  std::vector<float> in(block * 2, 0.5f), out(burst * 2);
  size_t backlog = 0;
  bool started = false;
  const size_t end = static_cast<size_t>(seconds * 1e6);
  for (size_t t = 0; t < end; t += kTick) {
    if (t % block_us == 0) ++backlog;
    const bool stalled = stall_us && t > 500000 && (t % stall_every_us) < stall_us;
    while (!stalled && backlog) {
      ring.push(in.data(), block);
      --backlog;
    }
    if (t % burst_us == 0) {
      const size_t got = ring.pop(out.data(), burst);
      if (got && !started) {
        started = true;
        r.first_audio_us = t;
      }
      if (started && got < burst) {
        r.zero_frames_after_start += burst - got;
        ++r.holes;
      }
      r.played += got;
    }
  }
  return r;
}

void test_no_holes_under_producer_stalls() {
  // Same sizing as the AAudio sink.
  sdrcore::PcmRing ring(sdrcore::kPlaybackRingFrames, sdrcore::kPlaybackPrefillFrames);
  const Result r = simulate(ring, 10, 30000, 250000);
  CHECK(r.played > 400000, "audio plays (%zu frames in 10 s)", r.played);
  CHECK(r.zero_frames_after_start == 0,
        "30 ms producer stalls every 250 ms: %zu zero-filled frames in %zu callbacks "
        "after audio started",
        r.zero_frames_after_start, r.holes);
}

void test_start_latency_is_bounded() {
  sdrcore::PcmRing ring(sdrcore::kPlaybackRingFrames, sdrcore::kPlaybackPrefillFrames);
  const Result r = simulate(ring, 2, 0, 1);
  CHECK(r.first_audio_us <= 100000, "first audio after %zu us (<= 100 ms)", r.first_audio_us);
  CHECK(r.zero_frames_after_start == 0, "steady producer: %zu zero-filled frames",
        r.zero_frames_after_start);
}

// A real starvation (producer gone for longer than the pre-roll) must
// re-prime instead of crackling: after the outage there is exactly one hole
// run, then continuous audio again.
void test_reprime_after_outage() {
  sdrcore::PcmRing ring(sdrcore::kPlaybackRingFrames, sdrcore::kPlaybackPrefillFrames);
  std::vector<float> in(82 * 2, 0.5f), out(192 * 2);
  size_t holes_after_recovery = 0;
  bool recovered = false;
  for (size_t t = 0, produced = 0; t < 3000000; t += 100) {
    const bool outage = t >= 1000000 && t < 1300000;
    if (t % 1700 == 0 && !outage) {
      ring.push(in.data(), 82);
      ++produced;
    }
    if (t % 4000 == 0) {
      const size_t got = ring.pop(out.data(), 192);
      if (t > 1300000 && got == 192) recovered = true;
      if (recovered && got < 192) ++holes_after_recovery;
    }
  }
  CHECK(recovered && holes_after_recovery == 0,
        "after a 300 ms outage: recovered=%d, %zu holes after recovery", recovered,
        holes_after_recovery);
  const auto s = ring.stats();
  CHECK(s.underflows >= 1 && s.zero_frames > 0,
        "underflow counters: %llu underflows, %llu zero frames",
        static_cast<unsigned long long>(s.underflows),
        static_cast<unsigned long long>(s.zero_frames));
}

}  // namespace

int main() {
  test_no_holes_under_producer_stalls();
  test_start_latency_is_bounded();
  test_reprime_after_outage();
  if (failures) {
    std::fprintf(stderr, "%d failure(s)\n", failures);
    return 1;
  }
  std::printf("pcm ring jitter: all passed\n");
  return 0;
}
