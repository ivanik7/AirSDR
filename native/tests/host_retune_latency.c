// SPDX-License-Identifier: GPL-3.0-or-later
//
// Real-hardware retune latency diagnostic (kanban t_c364ac15).
//
// Opens the first host RTL-SDR through the v3 API, streams WFM at 2.4 MS/s,
// then performs N LO retunes and reports, per retune:
//   call_us  wall time of sdr_v3_set_controls on the calling thread (the
//            Flutter UI thread on the phone);
//   apply_ms time until the snapshot reports the new LO (tuner I2C done);
//   fft_ms   time until the first FFT row of the new control_sequence.
// Plus p50/p95/max of each and the audio frame counter across the run (an
// audio-sink restart or DSP reset gap shows up as a frame-rate dip).
//
// Usage: sdrcore_host_retune_latency [--count N] [--freq HZ] [--step HZ]
//                                    [--interval-ms MS] [--gain TENTHS]
#include <inttypes.h>
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

static void sleep_ms(double ms) {
  struct timespec ts;
  ts.tv_sec = (time_t)(ms / 1000);
  ts.tv_nsec = (long)((ms - (double)ts.tv_sec * 1000) * 1e6);
  nanosleep(&ts, NULL);
}

static int snap(SdrHandle* h, SdrV3Snapshot* s) {
  memset(s, 0, sizeof(*s));
  s->size = sizeof(*s);
  s->revision = SDR_V3_REVISION;
  return sdr_v3_snapshot(h, s);
}

static int cmp(const void* a, const void* b) {
  const double x = *(const double*)a, y = *(const double*)b;
  return x < y ? -1 : x > y;
}

static void stats(const char* label, double* v, int n) {
  if (n <= 0) { printf("%s: no samples\n", label); return; }
  qsort(v, (size_t)n, sizeof(double), cmp);
  printf("%s: n=%d p50=%.3f p95=%.3f max=%.3f\n", label, n, v[n / 2],
         v[(int)(0.95 * (n - 1) + 0.5)], v[n - 1]);
}

static SdrV3Controls make_controls(uint64_t f, int32_t gain) {
  SdrV3Controls c;
  memset(&c, 0, sizeof(c));
  c.size = sizeof(c);
  c.revision = SDR_V3_REVISION;
  c.center_frequency_hz = f;
  c.sample_rate = 2400000;
  c.mode = SDR_V3_WFM;
  c.bandwidth_hz = 200000;
  c.gain_tenths_db = gain;
  c.squelch_level_db = -50;
  c.volume = 1;
  c.muted = 1;
  return c;
}

int main(int argc, char** argv) {
  int count = 40, interval = 250;
  uint64_t freq = 100000000, step = 200000;
  int32_t gain = 280;
  for (int i = 1; i + 1 < argc; i += 2) {
    if (!strcmp(argv[i], "--count")) count = atoi(argv[i + 1]);
    else if (!strcmp(argv[i], "--freq")) freq = strtoull(argv[i + 1], NULL, 10);
    else if (!strcmp(argv[i], "--step")) step = strtoull(argv[i + 1], NULL, 10);
    else if (!strcmp(argv[i], "--interval-ms")) interval = atoi(argv[i + 1]);
    else if (!strcmp(argv[i], "--gain")) gain = atoi(argv[i + 1]);
  }
  if (count < 1 || count > 1000) count = 40;
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
  fprintf(stderr, "opened %s %s [%s]\n", list[found].manufacturer,
          list[found].product, list[found].serial);
  SdrV3Controls c = make_controls(freq, gain);
  if ((rc = sdr_v3_set_controls(h, &c)) != SDR_OK) { fprintf(stderr, "controls %d\n", rc); return 1; }
  if ((rc = sdr_v3_start(h)) != SDR_OK) { fprintf(stderr, "start %d\n", rc); return 1; }
  sleep_ms(1000);
  SdrV3Snapshot s0, s;
  snap(h, &s0);
  const double t_start = now_ms();
  double* call = calloc((size_t)count, sizeof(double));
  double* apply = calloc((size_t)count, sizeof(double));
  double* fft = calloc((size_t)count, sizeof(double));
  int napply = 0, nfft = 0, errors = 0;
  float* bins = calloc(SDR_V3_MAX_FFT_WIDTH, sizeof(float));
  uint64_t last_row = 0;
  for (int i = 0; i < count; ++i) {
    const uint64_t target = freq + step * (uint64_t)((i % 2) ? 0 : 1);
    c = make_controls(target, gain);
    const double t0 = now_ms();
    rc = sdr_v3_set_controls(h, &c);
    call[i] = (now_ms() - t0) * 1000.0;  // microseconds
    if (rc != SDR_OK) { ++errors; fprintf(stderr, "retune %d rc=%d\n", i, rc); continue; }
    snap(h, &s);
    const uint64_t seq = s.control_sequence;
    double applied = -1, row = -1;
    while (now_ms() - t0 < interval) {
      snap(h, &s);
      if (s.state != SDR_RUNNING) break;
      if (applied < 0 && s.center_frequency_hz == target) applied = now_ms() - t0;
      if (row < 0) {
        SdrV3Fft m;
        memset(&m, 0, sizeof(m));
        m.size = sizeof(m);
        m.revision = SDR_V3_REVISION;
        if (sdr_v3_read_fft(h, last_row, &m, bins, SDR_V3_MAX_FFT_WIDTH) == SDR_OK) {
          last_row = m.sequence;
          if (m.control_sequence == seq) row = now_ms() - t0;
        }
      }
      sleep_ms(0.5);
    }
    if (applied >= 0) apply[napply++] = applied;
    if (row >= 0) fft[nfft++] = row;
    printf("{\"retune\":%d,\"freq\":%" PRIu64 ",\"call_us\":%.1f,\"apply_ms\":%.2f,\"fft_ms\":%.2f}\n",
           i, target, call[i], applied, row);
  }
  const double elapsed = now_ms() - t_start;
  snap(h, &s);
  printf("state=%u last_error=%d generation %" PRIu64 "->%" PRIu64 "\n", s.state,
         s.last_error, s0.stream_generation, s.stream_generation);
  printf("audio frames/s during retunes: %.0f (expected 48000)\n",
         (double)(s.audio_frames - s0.audio_frames) * 1000.0 / elapsed);
  printf("ring drops during retunes: %" PRIu64 "\n", s.dropped_samples - s0.dropped_samples);
  stats("set_controls call (us)", call, count);
  stats("tune applied (ms)", apply, napply);
  stats("first new-tune FFT row (ms)", fft, nfft);
  sdr_v3_stop(h);
  sdr_v2_close(h);
  sdr_destroy(h);
  free(call); free(apply); free(fft); free(bins);
  return errors || s.state != SDR_RUNNING || nfft != count ? 2 : 0;
}
