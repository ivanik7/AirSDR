// SPDX-License-Identifier: GPL-3.0-or-later
//
// Real-hardware audio continuity diagnostic for retunes (kanban t_c364ac15,
// "audio dropouts while scrolling").
//
// Streams the first host RTL-SDR through the public v3 API with an audio sink
// (default WAV) and replays the UI's tuning pattern:
//   --mode none  no control changes (baseline);
//   --mode lo    an LO retune every --interval-ms, alternating the LO by
//                --step while the VFO offset keeps the same station tuned;
//   --mode drag  the legacy waterfall drag: in-band VFO offset changes every
//                --move-ms (offset random walk, +-max 5 kHz), and every
//                --interval-ms the drag timer recenters (LO := tuned, offset 0)
//                exactly like CenteredReceiver._startDragTimer.
// The station stays tuned in every mode, so any audio level dip is an
// artifact of the retune path, not of the RF content.
//
// Prints one JSON line per control change with the audio frame position at
// that moment ({"event":"lo"|"vfo","frame":N}) for tool/retune_jank/
// wav_gaps.py, and a summary of IQ ring drops / audio frame rate.
//
// Real-time sink model: a poller thread samples snapshot.audio_frames (the
// frames the DSP thread has handed to the sink) every 0.5 ms. Afterwards the
// timeline is replayed against a callback consumer that pulls --burst frames
// every burst/48 ms, like the AAudio LOW_LATENCY callback over the zero-
// prefilled PcmRing (pop() zero-fills what is missing). It reports the
// zero-filled frames and the minimum ring level for several start prefills,
// so a producer stall during retunes shows up as underflow even though the
// host has no real-time audio device.
//
// Usage: sdrcore_host_retune_audio [--sink SPEC] [--mode none|lo|drag]
//          [--seconds S] [--freq HZ] [--step HZ] [--interval-ms MS]
//          [--move-ms MS] [--gain TENTHS] [--stereo 0|1] [--bandwidth HZ]
//          [--burst FRAMES]
#include <inttypes.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "sdrcore_host.h"
#include "sdrcore_v3.h"

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1e3 + (double)ts.tv_nsec / 1e6;
}

static void sleep_until_ms(double t) {
  for (;;) {
    const double left = t - now_ms();
    if (left <= 0) return;
    struct timespec ts;
    ts.tv_sec = (time_t)(left / 1000);
    ts.tv_nsec = (long)((left - (double)ts.tv_sec * 1000) * 1e6);
    nanosleep(&ts, NULL);
  }
}

static int snap(SdrHandle* h, SdrV3Snapshot* s) {
  memset(s, 0, sizeof(*s));
  s->size = sizeof(*s);
  s->revision = SDR_V3_REVISION;
  return sdr_v3_snapshot(h, s);
}

// Production timeline: (time ms, frames written) samples.
enum { kMaxSamples = 1 << 20 };
static double* tl_t;
static uint64_t* tl_frames;
static long tl_n;
static atomic_int poll_quit;

static void* poller(void* arg) {
  SdrHandle* h = (SdrHandle*)arg;
  SdrV3Snapshot s;
  while (!atomic_load(&poll_quit) && tl_n < kMaxSamples) {
    snap(h, &s);
    tl_t[tl_n] = now_ms();
    tl_frames[tl_n] = s.audio_frames;
    ++tl_n;
    struct timespec ts = {0, 500000};
    nanosleep(&ts, NULL);
  }
  return NULL;
}

// Replays the production timeline from t0 against a consumer pulling
// `burst` frames every burst/rate seconds, with `prefill` ms of audio
// buffered at t0 (fill above it is discarded as if it had been played
// earlier: the model starts at the prefill level). Prints zero-filled
// frames, the number of underflow callbacks and the minimum level.
static void model_ring(double t0, double t1, double prefill_ms, int burst) {
  const double rate = 48000;
  long k = 0;
  while (k < tl_n && tl_t[k] < t0) ++k;
  if (k >= tl_n) return;
  const uint64_t base = tl_frames[k];
  double level = prefill_ms * rate / 1000;  // frames buffered
  uint64_t produced_seen = base;
  double min_level = level, zero = 0;
  long underflows = 0, callbacks = 0;
  const double period = burst / rate * 1000;
  for (double t = t0 + period; t < t1; t += period) {
    while (k + 1 < tl_n && tl_t[k + 1] <= t) ++k;
    level += (double)(tl_frames[k] - produced_seen);
    produced_seen = tl_frames[k];
    ++callbacks;
    if (level >= burst) {
      level -= burst;
    } else {
      zero += burst - level;
      level = 0;
      ++underflows;
    }
    if (level < min_level) min_level = level;
  }
  fprintf(stderr,
          "ring model burst=%d prefill=%.0fms: zero-filled %.0f frames (%.1f ms), "
          "underflow callbacks %ld/%ld, min level %.1f ms\n",
          burst, prefill_ms, zero, zero * 1000 / rate, underflows, callbacks,
          min_level * 1000 / rate);
}

static uint32_t bandwidth = 200000;

static SdrV3Controls make_controls(uint64_t center, int64_t offset, int32_t gain) {
  SdrV3Controls c;
  memset(&c, 0, sizeof(c));
  c.size = sizeof(c);
  c.revision = SDR_V3_REVISION;
  c.center_frequency_hz = center;
  c.vfo_offset_hz = offset;
  c.sample_rate = 2400000;
  c.mode = SDR_V3_WFM;
  c.bandwidth_hz = bandwidth;
  c.gain_tenths_db = gain;
  c.squelch = SDR_V3_SQUELCH_OFF;
  c.squelch_level_db = -50;
  c.volume = 1;
  c.muted = 0;
  return c;
}

static int apply(SdrHandle* h, uint64_t center, int64_t offset, int32_t gain,
                 const char* kind) {
  SdrV3Controls c = make_controls(center, offset, gain);
  SdrV3Snapshot s;
  snap(h, &s);
  const int rc = sdr_v3_set_controls(h, &c);
  printf("{\"event\":\"%s\",\"frame\":%" PRIu64 ",\"center\":%" PRIu64
         ",\"offset\":%" PRId64 ",\"rc\":%d}\n",
         kind, s.audio_frames, center, offset, rc);
  return rc;
}

int main(int argc, char** argv) {
  const char* sink = "wav:retune_audio.wav";
  const char* mode = "drag";
  double seconds = 20, interval = 250, move = 8;
  uint64_t freq = 101800000, step = 200000;
  int32_t gain = 280;
  int stereo = 1;
  int burst = 192;  // AAudio LOW_LATENCY burst on many devices (4 ms)
  for (int i = 1; i + 1 < argc; i += 2) {
    if (!strcmp(argv[i], "--sink")) sink = argv[i + 1];
    else if (!strcmp(argv[i], "--mode")) mode = argv[i + 1];
    else if (!strcmp(argv[i], "--seconds")) seconds = atof(argv[i + 1]);
    else if (!strcmp(argv[i], "--freq")) freq = strtoull(argv[i + 1], NULL, 10);
    else if (!strcmp(argv[i], "--step")) step = strtoull(argv[i + 1], NULL, 10);
    else if (!strcmp(argv[i], "--interval-ms")) interval = atof(argv[i + 1]);
    else if (!strcmp(argv[i], "--move-ms")) move = atof(argv[i + 1]);
    else if (!strcmp(argv[i], "--gain")) gain = atoi(argv[i + 1]);
    else if (!strcmp(argv[i], "--stereo")) stereo = atoi(argv[i + 1]);
    else if (!strcmp(argv[i], "--bandwidth")) bandwidth = (uint32_t)atoi(argv[i + 1]);
    else if (!strcmp(argv[i], "--burst")) burst = atoi(argv[i + 1]);
  }
  tl_t = calloc(kMaxSamples, sizeof(double));
  tl_frames = calloc(kMaxSamples, sizeof(uint64_t));
  SdrHostUsbDevice list[16];
  uint32_t n = 0;
  for (int i = 0; i < 16; ++i) list[i].size = sizeof(SdrHostUsbDevice);
  int rc = sdr_host_usb_list(list, 16, &n);
  if (rc != SDR_OK) { fprintf(stderr, "usb_list %d\n", rc); return 1; }
  int found = -1;
  for (uint32_t i = 0; i < n && i < 16; ++i)
    if (list[i].vendor_id == 0x0bda) { found = (int)i; break; }
  if (found < 0) { fprintf(stderr, "no RTL-SDR\n"); return 1; }
  SdrHandle* h = sdr_create();
  rc = sdr_host_open_usb(h, list[found].bus, list[found].address, SDR_RTLSDR);
  if (rc != SDR_OK) { fprintf(stderr, "open %d\n", rc); return 1; }
  if ((rc = sdr_v3_set_audio_sink(h, sink, (uint32_t)strlen(sink))) != SDR_OK) {
    fprintf(stderr, "sink %d\n", rc);
    return 1;
  }
  uint64_t center = freq;
  int64_t offset = 0;
  SdrV3Controls c = make_controls(center, offset, gain);
  if ((rc = sdr_v3_set_controls(h, &c)) != SDR_OK) { fprintf(stderr, "controls %d\n", rc); return 1; }
  if ((rc = sdr_v3_set_wfm_stereo(h, (uint32_t)stereo)) != SDR_OK) { fprintf(stderr, "stereo %d\n", rc); return 1; }
  if ((rc = sdr_v3_start(h)) != SDR_OK) { fprintf(stderr, "start %d\n", rc); return 1; }
  const double t_begin = now_ms();
  pthread_t poll_thread;
  pthread_create(&poll_thread, NULL, poller, h);
  sleep_until_ms(t_begin + 1500);  // settle: pilot lock, filters, sink
  SdrV3Snapshot s0, s;
  snap(h, &s0);
  printf("{\"event\":\"begin\",\"frame\":%" PRIu64 "}\n", s0.audio_frames);
  const double t0 = now_ms();
  double next_lo = t0 + interval, next_move = t0 + move;
  int errors = 0, lo_count = 0, vfo_count = 0, flip = 0;
  uint32_t rng = 12345;
  int64_t walk = 0;  // tuned offset from the station, Hz
  while (now_ms() - t0 < seconds * 1000) {
    if (!strcmp(mode, "none")) {
      sleep_until_ms(t0 + seconds * 1000);
      break;
    }
    if (!strcmp(mode, "lo")) {
      sleep_until_ms(next_lo);
      next_lo += interval;
      flip ^= 1;
      center = freq + (flip ? step : 0);
      offset = (int64_t)freq - (int64_t)center;
      errors += apply(h, center, offset, gain, "lo") != SDR_OK;
      ++lo_count;
      continue;
    }
    // drag
    const double t = next_move < next_lo ? next_move : next_lo;
    sleep_until_ms(t);
    if (t == next_lo) {
      next_lo += interval;
      if (offset != 0) {
        center = (uint64_t)((int64_t)center + offset);
        offset = 0;
        errors += apply(h, center, offset, gain, "lo") != SDR_OK;
        ++lo_count;
      }
    } else {
      next_move += move;
      rng = rng * 1103515245u + 12345u;
      walk += ((rng >> 16) % 3 == 0) ? -1000 : ((rng >> 16) % 3 == 1 ? 1000 : 0);
      if (walk > 5000) walk = 5000;
      if (walk < -5000) walk = -5000;
      const int64_t want = (int64_t)freq + walk - (int64_t)center;
      if (want != offset) {
        offset = want;
        errors += apply(h, center, offset, gain, "vfo") != SDR_OK;
        ++vfo_count;
      }
    }
  }
  const double elapsed = now_ms() - t0;
  snap(h, &s);
  printf("{\"event\":\"end\",\"frame\":%" PRIu64 "}\n", s.audio_frames);
  atomic_store(&poll_quit, 1);
  pthread_join(poll_thread, NULL);
  fprintf(stderr,
          "mode=%s lo=%d vfo=%d errors=%d state=%u last_error=%d generation %" PRIu64
          "->%" PRIu64 " audio %.0f frames/s, sink dropped %" PRIu64
          ", IQ ring drops %" PRIu64 "\n",
          mode, lo_count, vfo_count, errors, s.state, s.last_error, s0.stream_generation,
          s.stream_generation, (double)(s.audio_frames - s0.audio_frames) * 1000.0 / elapsed,
          s.audio_dropped_frames - s0.audio_dropped_frames,
          s.dropped_samples - s0.dropped_samples);
  // Producer burstiness: largest gap between audio_frames increments.
  double worst_gap = 0;
  long last_change = -1;
  for (long k = 1; k < tl_n; ++k) {
    if (tl_t[k] < t0) continue;
    if (tl_frames[k] != tl_frames[k - 1]) {
      if (last_change >= 0 && tl_t[k] - tl_t[last_change] > worst_gap)
        worst_gap = tl_t[k] - tl_t[last_change];
      last_change = k;
    }
  }
  fprintf(stderr, "poller samples %ld, largest gap between audio pushes %.1f ms\n", tl_n,
          worst_gap);
  const double prefills[] = {0, 5, 10, 20, 60};
  for (size_t i = 0; i < sizeof(prefills) / sizeof(prefills[0]); ++i)
    model_ring(t0, t0 + elapsed, prefills[i], burst);
  sdr_v3_stop(h);
  sdr_v2_close(h);
  sdr_destroy(h);
  return errors || s.state != SDR_RUNNING ? 2 : 0;
}
