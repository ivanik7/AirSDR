// SPDX-License-Identifier: GPL-3.0-or-later
//
// Real-hardware probe (kanban t_c364ac15, audio dropouts on retune): does
// bulk IQ delivery through rtlsdr_read_async stall while a live tuner
// retune (rtlsdr_set_center_freq over I2C control transfers) runs on
// another thread? Mirrors the core: 16 x 8 KiB async transfers at
// 2.4 MS/s, retunes from a separate thread every --interval-ms.
//
// Prints per retune: set_center_freq wall time, attempts (PIPE retries),
// and the largest gap between async callbacks within 300 ms of the retune
// start; plus the same gap statistic over quiet windows (no retune) and the
// achieved IQ rate. An IQ gap longer than the audio sink's buffered audio is
// an audible dropout.
//
// Usage: sdrcore_host_retune_iq_gaps <bus> <address> [--count N]
//        [--interval-ms MS] [--freq HZ] [--step HZ] [--gain TENTHS]
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "rtl-sdr.h"

enum { kMaxCallbacks = 1 << 20 };
static rtlsdr_dev_t* dev;
static double* stamp;  // callback arrival times (ms)
static atomic_long ncb;
static atomic_llong bytes;

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1e3 + (double)ts.tv_nsec / 1e6;
}

static void cb(unsigned char* buf, uint32_t len, void* ctx) {
  (void)buf;
  (void)ctx;
  const long i = atomic_load(&ncb);
  if (i < kMaxCallbacks) stamp[i] = now_ms();
  atomic_store(&ncb, i + 1);
  atomic_fetch_add(&bytes, len);
}

static void* reader(void* arg) {
  (void)arg;
  rtlsdr_read_async(dev, cb, NULL, 16, 8192);
  return NULL;
}

static void sleep_ms(double ms) {
  struct timespec ts;
  ts.tv_sec = (time_t)(ms / 1000);
  ts.tv_nsec = (long)((ms - (double)ts.tv_sec * 1000) * 1e6);
  nanosleep(&ts, NULL);
}

// Largest gap between consecutive callbacks with arrival in [t0, t1].
static double max_gap(double t0, double t1) {
  const long n = atomic_load(&ncb);
  double worst = 0;
  for (long i = 1; i < n && i < kMaxCallbacks; ++i) {
    if (stamp[i] < t0 || stamp[i] > t1) continue;
    const double g = stamp[i] - stamp[i - 1];
    if (g > worst) worst = g;
  }
  return worst;
}

static int cmp(const void* a, const void* b) {
  const double x = *(const double*)a, y = *(const double*)b;
  return x < y ? -1 : x > y;
}

static void stats(const char* label, double* v, int n) {
  if (n <= 0) return;
  qsort(v, (size_t)n, sizeof(double), cmp);
  printf("%s: n=%d p50=%.2f p95=%.2f max=%.2f\n", label, n, v[n / 2],
         v[(int)(0.95 * (n - 1) + 0.5)], v[n - 1]);
}

int main(int argc, char** argv) {
  if (argc < 3) { fprintf(stderr, "usage: %s bus address ...\n", argv[0]); return 1; }
  int count = 40, gain = 280;
  double interval = 250;
  uint32_t freq = 100000000, step = 200000;
  for (int i = 3; i + 1 < argc; i += 2) {
    if (!strcmp(argv[i], "--count")) count = atoi(argv[i + 1]);
    else if (!strcmp(argv[i], "--interval-ms")) interval = atof(argv[i + 1]);
    else if (!strcmp(argv[i], "--freq")) freq = (uint32_t)strtoul(argv[i + 1], NULL, 10);
    else if (!strcmp(argv[i], "--step")) step = (uint32_t)strtoul(argv[i + 1], NULL, 10);
    else if (!strcmp(argv[i], "--gain")) gain = atoi(argv[i + 1]);
  }
  stamp = calloc(kMaxCallbacks, sizeof(double));
  char path[64];
  snprintf(path, sizeof(path), "/dev/bus/usb/%03d/%03d", atoi(argv[1]), atoi(argv[2]));
  const int fd = open(path, O_RDWR | O_CLOEXEC);
  if (fd < 0 || rtlsdr_open_sys_dev(&dev, fd) != 0) { fprintf(stderr, "open failed\n"); return 1; }
  rtlsdr_set_sample_rate(dev, 2400000);
  rtlsdr_set_center_freq(dev, freq);
  rtlsdr_set_tuner_gain_mode(dev, 1);
  rtlsdr_set_tuner_gain(dev, gain);
  rtlsdr_reset_buffer(dev);
  pthread_t t;
  pthread_create(&t, NULL, reader, NULL);
  sleep_ms(1000);

  // Baseline: no retunes for the same number of windows.
  double* quiet = calloc((size_t)count, sizeof(double));
  for (int i = 0; i < count; ++i) {
    const double t0 = now_ms();
    sleep_ms(interval);
    quiet[i] = max_gap(t0, now_ms());
  }
  const long long b0 = atomic_load(&bytes);
  const double tb0 = now_ms();
  double* call = calloc((size_t)count, sizeof(double));
  double* gap = calloc((size_t)count, sizeof(double));
  int retries = 0, failures = 0;
  for (int r = 0; r < count; ++r) {
    const uint32_t f = freq + ((r % 2) ? 0 : step);
    const double t0 = now_ms();
    int attempts = 0, ok = 0;
    while (attempts < 10 && !ok) {
      ++attempts;
      ok = rtlsdr_set_center_freq(dev, f) == 0 && rtlsdr_get_center_freq(dev) == f;
    }
    call[r] = now_ms() - t0;
    retries += attempts - 1;
    failures += !ok;
    const double left = interval - call[r];
    if (left > 0) sleep_ms(left);
    gap[r] = max_gap(t0, now_ms());
    printf("{\"retune\":%d,\"freq\":%u,\"i2c_ms\":%.2f,\"attempts\":%d,\"max_iq_gap_ms\":%.2f}\n",
           r, f, call[r], attempts, gap[r]);
  }
  const double rate = (double)(atomic_load(&bytes) - b0) / 2 / (now_ms() - tb0) * 1000;
  rtlsdr_cancel_async(dev);
  pthread_join(t, NULL);
  rtlsdr_close(dev);
  close(fd);
  printf("IQ rate during retunes: %.0f S/s (expected 2400000)\n", rate);
  printf("PIPE retries: %d, failed retunes: %d\n", retries, failures);
  stats("set_center_freq wall (ms)", call, count);
  stats("max IQ callback gap, retune windows (ms)", gap, count);
  stats("max IQ callback gap, quiet windows (ms)", quiet, count);
  return 0;
}
