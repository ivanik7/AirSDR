// SPDX-License-Identifier: GPL-3.0-or-later
//
// Real-hardware probe (kanban t_c364ac15): how much pre-retune IQ still
// arrives through rtlsdr_read_async after rtlsdr_set_center_freq returns?
// The core discards UsbRxAdapter::retune_settle_bytes() after a live retune;
// too little shows the old station, too much is an audio gap.
//
// Alternates the LO between a busy frequency (--busy, e.g. a strong FM
// station band) and a quiet one (--quiet) while streaming 8 KiB transfers,
// and prints the wideband power of every block from the retune on, so the
// switch point (in bytes after set_center_freq returned) is visible.
//
// Usage: sdrcore_host_retune_settle <bus> <address> [--busy HZ] [--quiet HZ]
//        [--gain TENTHS] [--count N]
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "rtl-sdr.h"

enum { kBlocks = 4096, kBlockBytes = 8192 };
static rtlsdr_dev_t* dev;
static double power[kBlocks];
static atomic_long blocks;
static atomic_long mark = -1;  // block index when the retune returned
static int narrow = 0;  // 1: power of a ~37 kHz boxcar around DC instead
static double t_block[kBlocks];

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1e3 + (double)ts.tv_nsec / 1e6;
}

static void cb(unsigned char* buf, uint32_t len, void* ctx) {
  (void)ctx;
  long i = atomic_load(&blocks);
  if (i >= kBlocks) { rtlsdr_cancel_async(dev); return; }
  double p = 0;
  if (narrow) {
    // Mean of 64 complex samples = boxcar lowpass (~37 kHz at 2.4 MS/s):
    // high when a strong carrier sits at the LO, low when it is far away.
    uint32_t chunks = 0;
    for (uint32_t k = 0; k + 128 <= len; k += 128, ++chunks) {
      double re = 0, im = 0;
      for (uint32_t j = k; j < k + 128; j += 2) { re += buf[j] - 127.5; im += buf[j + 1] - 127.5; }
      p += (re * re + im * im) / (64.0 * 64.0);
    }
    power[i] = 10 * log10(p / (chunks ? chunks : 1) + 1e-9);
  } else {
    for (uint32_t k = 0; k < len; ++k) {
      const double v = buf[k] - 127.5;
      p += v * v;
    }
    power[i] = 10 * log10(p / len + 1e-9);
  }
  t_block[i] = now_ms();
  atomic_store(&blocks, i + 1);
}

static void* reader(void* arg) {
  (void)arg;
  rtlsdr_read_async(dev, cb, NULL, 16, kBlockBytes);
  return NULL;
}

static void sleep_ms(int ms) {
  struct timespec ts = {ms / 1000, (long)(ms % 1000) * 1000000L};
  nanosleep(&ts, NULL);
}

int main(int argc, char** argv) {
  if (argc < 3) { fprintf(stderr, "usage: %s bus address ...\n", argv[0]); return 1; }
  uint32_t busy = 98000000, quiet = 400000000;
  int gain = 280, count = 6;
  for (int i = 3; i + 1 < argc; i += 2) {
    if (!strcmp(argv[i], "--busy")) busy = (uint32_t)strtoul(argv[i + 1], NULL, 10);
    else if (!strcmp(argv[i], "--quiet")) quiet = (uint32_t)strtoul(argv[i + 1], NULL, 10);
    else if (!strcmp(argv[i], "--gain")) gain = atoi(argv[i + 1]);
    else if (!strcmp(argv[i], "--count")) count = atoi(argv[i + 1]);
    else if (!strcmp(argv[i], "--narrow")) narrow = atoi(argv[i + 1]);
  }
  char path[64];
  snprintf(path, sizeof(path), "/dev/bus/usb/%03d/%03d", atoi(argv[1]), atoi(argv[2]));
  const int fd = open(path, O_RDWR | O_CLOEXEC);
  if (fd < 0 || rtlsdr_open_sys_dev(&dev, fd) != 0) { fprintf(stderr, "open failed\n"); return 1; }
  rtlsdr_set_sample_rate(dev, 2400000);
  rtlsdr_set_center_freq(dev, quiet);
  rtlsdr_set_tuner_gain_mode(dev, 1);
  rtlsdr_set_tuner_gain(dev, gain);
  rtlsdr_reset_buffer(dev);
  pthread_t t;
  pthread_create(&t, NULL, reader, NULL);
  sleep_ms(500);
  for (int r = 0; r < count; ++r) {
    const uint32_t f = (r % 2 == 0) ? busy : quiet;
    const long s = atomic_load(&blocks);
    const double t_call = now_ms();
    int attempts = 0;
    do { ++attempts; } while ((rtlsdr_set_center_freq(dev, f) != 0 ||
                               rtlsdr_get_center_freq(dev) != f) && attempts < 10);
    const long m = atomic_load(&blocks);
    const double t_ret = now_ms();
    sleep_ms(150);
    const long end = atomic_load(&blocks);
    printf("retune %d -> %u Hz (%d attempt%s, %.1f ms), call at block %ld, returned at block %ld:",
           r, f, attempts, attempts == 1 ? "" : "s", t_ret - t_call, s, m);
    for (long i = s - 2; i < end && i < m + 24; ++i) {
      if (i == s) printf(" [");
      if (i == m) printf(" |");
      printf(" %.1f", power[i]);
    }
    printf("\n");
    // First block after the call whose level is within 3 dB of the final
    // level (mean of blocks m+30..m+50): how many blocks after the call
    // start / return the new tune is really in the stream.
    double fin = 0;
    int nf = 0;
    for (long i = m + 30; i < end && i < m + 50; ++i, ++nf) fin += power[i];
    if (nf) {
      fin /= nf;
      long settled = -1;
      for (long i = s; i < end; ++i) {
        int ok = 1;
        for (long j = i; j < i + 5 && j < end; ++j) if (fabs(power[j] - fin) > 3) ok = 0;
        if (ok) { settled = i; break; }
      }
      if (settled >= 0)
        printf("  settled at block %ld: %+ld blocks vs call, %+ld vs return; arrival %+.1f ms vs call, %+.1f ms vs return\n",
               settled, settled - s, settled - m, t_block[settled] - t_call, t_block[settled] - t_ret);
    }
    sleep_ms(250);
  }
  rtlsdr_cancel_async(dev);
  pthread_join(t, NULL);
  rtlsdr_close(dev);
  close(fd);
  return 0;
}
