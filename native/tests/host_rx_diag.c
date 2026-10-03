// SPDX-License-Identifier: GPL-3.0-or-later
//
// Headless real-hardware RX diagnostic for the desktop host (L1).
// Drives the shared ABI 2 engine through the host USB layer and prints one
// JSON object per line (JSON Lines) to stdout; progress goes to stderr.
//
// Usage:
//   sdrcore_host_rx_diag [--seconds N] [--freq HZ] [--rate SPS] [--gain TENTHS]
//                        [--retune HZ] [--gain2 TENTHS] [--interval S]
//                        [--vid 0x0bda --pid 0x2838] [--source rtlsdr|hackrf]
//
// Scenario: list devices -> open the first matching one -> configure ->
// start -> stream N seconds with periodic stats -> stop -> configure retune
// and second gain -> restart -> stream max(5, N/10) seconds -> stop -> close.
// Each phase emits {"event": ...}. The final line is {"event":"summary",...}
// with totals; the exit status is 0 only if every command succeeded, the
// engine never entered ERROR, and the measured input rate stayed within 1 %
// of the configured rate. Ring drops (overflow of the native 8-slot ring) are
// reported; they are not USB transfer loss (see sdrcore.h).
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "sdrcore_host.h"

static double now_s(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static int get_stats(SdrHandle* h, SdrStats* s) {
  memset(s, 0, sizeof(*s));
  s->size = sizeof(*s);
  s->revision = 2;
  return sdr_v2_stats(h, s);
}

static void print_stats(const char* event, const SdrStats* s, double elapsed,
                        double rate) {
  printf("{\"event\":\"%s\",\"t\":%.3f,\"state\":%u,\"last_error\":%d,"
         "\"frequency_hz\":%" PRIu64 ",\"sample_rate\":%u,\"gain_tenths_db\":%d,"
         "\"input_samples\":%" PRIu64 ",\"processed_samples\":%" PRIu64
         ",\"dropped_samples\":%" PRIu64 ",\"input_rate\":%.1f}\n",
         event, elapsed, s->state, s->last_error, s->frequency_hz,
         s->sample_rate, s->gain_tenths_db, s->input_samples,
         s->processed_samples, s->dropped_samples, rate);
  fflush(stdout);
}

static int fail(const char* what, int rc) {
  printf("{\"event\":\"error\",\"command\":\"%s\",\"result\":%d}\n", what, rc);
  fflush(stdout);
  return 1;
}

typedef struct Phase {
  uint64_t input;
  uint64_t dropped;
  double seconds;
  int error;
} Phase;

// Streams for `seconds`, printing stats every `interval` seconds.
static Phase stream_for(SdrHandle* h, double seconds, double interval,
                        const char* label) {
  Phase p = {0, 0, 0, 0};
  SdrStats s0, s;
  get_stats(h, &s0);
  const double t0 = now_s();
  double last_t = t0;
  uint64_t last_in = s0.input_samples;
  while (now_s() - t0 < seconds) {
    struct timespec d = {0, 100 * 1000 * 1000};
    nanosleep(&d, NULL);
    const double t = now_s();
    if (t - last_t >= interval || t - t0 >= seconds) {
      get_stats(h, &s);
      const double rate = (double)(s.input_samples - last_in) / (t - last_t);
      print_stats(label, &s, t - t0, rate);
      fprintf(stderr, "[%s] t=%.0fs in=%" PRIu64 " drop=%" PRIu64 " rate=%.0f\n",
              label, t - t0, s.input_samples, s.dropped_samples, rate);
      last_t = t;
      last_in = s.input_samples;
      if (s.state == SDR_ERROR) {
        p.error = s.last_error ? s.last_error : -1;
        break;
      }
    }
  }
  get_stats(h, &s);
  p.seconds = now_s() - t0;
  p.input = s.input_samples - s0.input_samples;
  p.dropped = s.dropped_samples - s0.dropped_samples;
  return p;
}

int main(int argc, char** argv) {
  double seconds = 30, interval = 10;
  uint64_t freq = 101400000, retune = 99500000;
  uint32_t rate = 2400000;
  int32_t gain = 200, gain2 = 380;
  unsigned vid = 0x0bda, pid = 0x2838;
  uint32_t source = SDR_RTLSDR;
  for (int i = 1; i + 1 < argc; i += 2) {
    const char* k = argv[i];
    const char* v = argv[i + 1];
    if (!strcmp(k, "--seconds")) seconds = atof(v);
    else if (!strcmp(k, "--freq")) freq = strtoull(v, NULL, 0);
    else if (!strcmp(k, "--rate")) rate = (uint32_t)strtoul(v, NULL, 0);
    else if (!strcmp(k, "--gain")) gain = (int32_t)strtol(v, NULL, 0);
    else if (!strcmp(k, "--retune")) retune = strtoull(v, NULL, 0);
    else if (!strcmp(k, "--gain2")) gain2 = (int32_t)strtol(v, NULL, 0);
    else if (!strcmp(k, "--interval")) interval = atof(v);
    else if (!strcmp(k, "--vid")) vid = (unsigned)strtoul(v, NULL, 0);
    else if (!strcmp(k, "--pid")) pid = (unsigned)strtoul(v, NULL, 0);
    else if (!strcmp(k, "--source"))
      source = !strcmp(v, "hackrf") ? SDR_HACKRF : SDR_RTLSDR;
    else {
      fprintf(stderr, "unknown option %s\n", k);
      return 2;
    }
  }

  SdrHostUsbDevice list[32];
  for (int i = 0; i < 32; ++i) list[i].size = sizeof(list[i]);
  uint32_t count = 0;
  int rc = sdr_host_usb_list(list, 32, &count);
  if (rc != SDR_OK) return fail("sdr_host_usb_list", rc);
  int found = -1;
  for (uint32_t i = 0; i < count && i < 32; ++i) {
    if (list[i].vendor_id == vid && list[i].product_id == pid) {
      found = (int)i;
      break;
    }
  }
  if (found < 0) {
    printf("{\"event\":\"error\",\"command\":\"find\",\"result\":%d,"
           "\"devices\":%u}\n", SDR_HOST_NOT_FOUND, count);
    return 1;
  }
  const SdrHostUsbDevice* d = &list[found];
  printf("{\"event\":\"device\",\"path\":\"%s\",\"vid\":\"%04x\",\"pid\":\"%04x\","
         "\"manufacturer\":\"%s\",\"product\":\"%s\",\"serial\":\"%s\","
         "\"abi\":%u}\n", d->path, d->vendor_id, d->product_id, d->manufacturer,
         d->product, d->serial, sdr_version());

  SdrHandle* h = sdr_create();
  if (!h) return fail("sdr_create", SDR_INTERNAL_ERROR);
  int bad = 0;
  if ((rc = sdr_host_open_usb(h, d->bus, d->address, source)) != SDR_OK) {
    sdr_destroy(h);
    return fail("sdr_host_open_usb", rc);
  }
  if ((rc = sdr_v2_configure(h, freq, rate, gain)) != SDR_OK) {
    bad = fail("configure", rc);
    goto out;
  }
  if ((rc = sdr_v2_start(h)) != SDR_OK) {
    bad = fail("start", rc);
    goto out;
  }
  Phase a = stream_for(h, seconds, interval, "stats");
  if ((rc = sdr_v2_stop(h)) != SDR_OK) bad = fail("stop", rc);
  if (!bad && (rc = sdr_v2_configure(h, retune, rate, gain2)) != SDR_OK)
    bad = fail("configure_retune", rc);
  SdrStats s;
  get_stats(h, &s);
  print_stats("retuned", &s, 0, 0);
  Phase b = {0, 0, 0, 0};
  if (!bad && (rc = sdr_v2_start(h)) != SDR_OK) bad = fail("restart", rc);
  if (!bad) {
    const double second = seconds / 10 > 5 ? seconds / 10 : 5;
    b = stream_for(h, second, interval, "stats_restart");
    if ((rc = sdr_v2_stop(h)) != SDR_OK) bad = fail("stop_restart", rc);
  }
  {
    const double rate_a = a.seconds > 0 ? (double)a.input / a.seconds : 0;
    const double rate_b = b.seconds > 0 ? (double)b.input / b.seconds : 0;
    const int rate_ok = rate_a > rate * 0.99 && rate_a < rate * 1.01 &&
                        (b.seconds == 0 ||
                         (rate_b > rate * 0.99 && rate_b < rate * 1.01));
    if (a.error || b.error || !rate_ok) bad = 1;
    printf("{\"event\":\"summary\",\"ok\":%s,\"configured_rate\":%u,"
           "\"run1\":{\"seconds\":%.3f,\"input_samples\":%" PRIu64
           ",\"dropped_samples\":%" PRIu64 ",\"input_rate\":%.1f,\"error\":%d},"
           "\"run2\":{\"seconds\":%.3f,\"input_samples\":%" PRIu64
           ",\"dropped_samples\":%" PRIu64 ",\"input_rate\":%.1f,\"error\":%d}}\n",
           bad ? "false" : "true", rate, a.seconds, a.input, a.dropped, rate_a,
           a.error, b.seconds, b.input, b.dropped, rate_b, b.error);
  }
out:
  rc = sdr_v2_close(h);
  if (rc != SDR_OK) bad = fail("close", rc);
  sdr_destroy(h);
  return bad ? 1 : 0;
}
