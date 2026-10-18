// SPDX-License-Identifier: GPL-3.0-or-later
//
// Manual live-air Meshtastic check on the desktop host (needs an attached
// RTL-SDR; not a ctest). Drives the same path as the app: one v3 session on
// the single receiver, normal tuned controls (VFO centred, offset 0), then
// sdr_decoder_select("meshtastic") on that running handle and FIFO polling.
// Prints one JSON object per line: every decoder `message` event verbatim,
// periodic receiver stats, and a final summary. The decoder config may hold
// channel keys, so it is never printed.
//
// Usage:
//   sdrcore_host_meshtastic_live [--freq HZ] [--rate SPS] [--gain TENTHS]
//       [--seconds N] [--preset LongFast] [--region EU_868]
//       [--squelch off|manual] [--squelch-db DB]
//       [--decoder meshtastic|meshcore|none]
// `--decoder none` runs the same session without selecting the decoder, as a
// CPU baseline for the tap + decoder cost.
//
// Exit status: 0 when the session ran without a native error for the full
// duration (whether or not any packet was heard), 1 on a command/runtime
// failure. Packet count is reported, never inferred.
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "sdrcore_decoder_v1.h"
#include "sdrcore_host.h"
#include "sdrcore_v3.h"

static double now_s(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static int snap(SdrHandle* h, SdrV3Snapshot* s) {
  memset(s, 0, sizeof(*s));
  s->size = sizeof(*s);
  s->revision = SDR_V3_REVISION;
  return sdr_v3_snapshot(h, s);
}

static int fail(const char* what, int rc) {
  printf("{\"event\":\"error\",\"command\":\"%s\",\"result\":%d}\n", what, rc);
  fflush(stdout);
  return 1;
}

int main(int argc, char** argv) {
  uint64_t freq = 869525000;
  uint32_t rate = 2400000;
  int32_t gain = 400;
  double seconds = 120;
  const char* preset = "LongFast";
  const char* region = "EU_868";
  uint32_t squelch = SDR_V3_SQUELCH_OFF;
  float squelch_db = -50;
  const char* decoder = "meshtastic";
  for (int i = 1; i + 1 < argc; i += 2) {
    const char* k = argv[i];
    const char* v = argv[i + 1];
    if (!strcmp(k, "--freq")) freq = strtoull(v, NULL, 10);
    else if (!strcmp(k, "--rate")) rate = (uint32_t)strtoul(v, NULL, 10);
    else if (!strcmp(k, "--gain")) gain = (int32_t)strtol(v, NULL, 10);
    else if (!strcmp(k, "--seconds")) seconds = atof(v);
    else if (!strcmp(k, "--preset")) preset = v;
    else if (!strcmp(k, "--region")) region = v;
    else if (!strcmp(k, "--squelch"))
      squelch = !strcmp(v, "manual") ? SDR_V3_SQUELCH_MANUAL : SDR_V3_SQUELCH_OFF;
    else if (!strcmp(k, "--squelch-db")) squelch_db = (float)atof(v);
    else if (!strcmp(k, "--decoder")) {
      if (strcmp(v, "meshtastic") && strcmp(v, "meshcore") && strcmp(v, "none")) {
        fprintf(stderr, "unknown decoder %s\n", v);
        return 2;
      }
      decoder = v;
    }
    else {
      fprintf(stderr, "unknown option %s\n", k);
      return 2;
    }
  }
  if (sdr_version() != 3 || sdr_decoder_version() != 1) return fail("version", -1);

  SdrHostUsbDevice list[16];
  for (int i = 0; i < 16; ++i) list[i].size = sizeof(list[i]);
  uint32_t count = 0;
  int rc = sdr_host_usb_list(list, 16, &count);
  if (rc != SDR_OK) return fail("sdr_host_usb_list", rc);
  int found = -1;
  for (uint32_t i = 0; i < count && i < 16; ++i)
    if (list[i].vendor_id == 0x0bda && list[i].product_id == 0x2838) {
      found = (int)i;
      break;
    }
  if (found < 0) return fail("find_rtlsdr", SDR_HOST_NOT_FOUND);
  printf("{\"event\":\"device\",\"path\":\"%s\",\"product\":\"%s\"}\n", list[found].path,
         list[found].product);

  SdrHandle* h = sdr_create();
  if (!h) return fail("sdr_create", SDR_INTERNAL_ERROR);
  int bad = 0;
  if ((rc = sdr_host_open_usb(h, list[found].bus, list[found].address, SDR_RTLSDR)) != SDR_OK) {
    sdr_destroy(h);
    return fail("sdr_host_open_usb", rc);
  }
  if ((rc = sdr_v3_set_audio_sink(h, "null", 4)) != SDR_OK) {
    bad = fail("set_audio_sink", rc);
    goto out;
  }
  {
    SdrV3Controls c;
    memset(&c, 0, sizeof(c));
    c.size = sizeof(c);
    c.revision = SDR_V3_REVISION;
    c.center_frequency_hz = freq;  // at rest: centre == tuned, offset 0
    c.vfo_offset_hz = 0;
    c.sample_rate = rate;
    c.mode = SDR_V3_NFM;
    c.bandwidth_hz = 12500;
    c.gain_tenths_db = gain;
    c.squelch = squelch;
    c.squelch_level_db = squelch_db;
    c.volume = 1;
    if ((rc = sdr_v3_set_controls(h, &c)) != SDR_OK) {
      bad = fail("set_controls", rc);
      goto out;
    }
  }
  if ((rc = sdr_v3_start(h)) != SDR_OK) {
    bad = fail("start", rc);
    goto out;
  }
  const int select_decoder = strcmp(decoder, "none") != 0;
  if (select_decoder) {
    char config[256];
    // MeshCore: OpenWebRX+ default bandwidth index 6 (62.5 kHz) and the
    // built-in Public channel only; Meshtastic: preset/region as before.
    const int n = !strcmp(decoder, "meshcore")
        ? snprintf(config, sizeof config,
                   "{\"version\":1,\"settings\":{\"bandwidth\":\"6\",\"channels\":[]}}")
        : snprintf(config, sizeof config,
                   "{\"version\":1,\"settings\":{\"preset\":\"%s\",\"region\":\"%s\","
                   "\"channels\":[]}}",
                   preset, region);
    if ((rc = sdr_decoder_select(h, decoder, (uint32_t)strlen(decoder), config,
                                 (uint32_t)n)) != SDR_OK) {
      bad = fail("decoder_select", rc);
      goto stop;
    }
  }
  printf("{\"event\":\"listening\",\"freq\":%" PRIu64 ",\"rate\":%u,\"gain_tenths_db\":%d,"
         "\"preset\":\"%s\",\"region\":\"%s\",\"squelch\":%u,\"seconds\":%.0f,"
         "\"decoder\":\"%s\"}\n",
         freq, rate, gain, preset, region, squelch, seconds,
         decoder);
  fflush(stdout);
  {
    static uint8_t payload[SDR_DECODER_MAX_PAYLOAD + 1];
    uint64_t cursor = 0, messages = 0, dropped = 0;
    SdrV3Snapshot s0, s;
    snap(h, &s0);
    const double t0 = now_s();
    double next_stats = t0 + 10;
    while (now_s() - t0 < seconds) {
      SdrDecoderEvent ev;
      memset(&ev, 0, sizeof ev);
      ev.size = sizeof ev;
      ev.revision = SDR_DECODER_REVISION;
      rc = sdr_decoder_poll(h, cursor, &ev, payload, SDR_DECODER_MAX_PAYLOAD);
      if (rc == SDR_OK) {
        cursor = ev.sequence;
        dropped = ev.dropped_events;
        if (ev.kind == SDR_DECODER_MESSAGE) {
          ++messages;
          payload[ev.payload_bytes] = 0;
          printf("{\"event\":\"message\",\"t\":%.3f,\"generation\":%" PRIu64 ",\"payload\":%s}\n",
                 now_s() - t0, ev.stream_generation, (const char*)payload);
          fflush(stdout);
        }
        continue;
      }
      if (rc != SDR_DECODER_NO_DATA) {
        bad = fail("decoder_poll", rc);
        break;
      }
      struct timespec d = {0, 50 * 1000 * 1000};
      nanosleep(&d, NULL);
      if (now_s() >= next_stats) {
        next_stats += 10;
        snap(h, &s);
        printf("{\"event\":\"stats\",\"t\":%.1f,\"state\":%u,\"last_error\":%d,"
               "\"input_samples\":%" PRIu64 ",\"processed_samples\":%" PRIu64
               ",\"dropped_samples\":%" PRIu64 ",\"audio_nonsilent_frames\":%" PRIu64
               ",\"messages\":%" PRIu64 "}\n",
               now_s() - t0, s.state, s.last_error, s.input_samples - s0.input_samples,
               s.processed_samples - s0.processed_samples,
               s.dropped_samples - s0.dropped_samples,
               s.audio_nonsilent_frames - s0.audio_nonsilent_frames, messages);
        fflush(stdout);
        if (s.state == SDR_ERROR) {
          bad = fail("runtime", s.last_error);
          break;
        }
      }
    }
    const double elapsed = now_s() - t0;
    clock_t cpu = clock();
    snap(h, &s);
    printf("{\"event\":\"summary\",\"ok\":%s,\"seconds\":%.1f,\"messages\":%" PRIu64
           ",\"dropped_events\":%" PRIu64 ",\"input_rate\":%.0f,\"dropped_samples\":%" PRIu64
           ",\"audio_nonsilent_frames\":%" PRIu64 ",\"process_cpu_s\":%.2f,\"state\":%u}\n",
           bad ? "false" : "true", elapsed, messages, dropped,
           (double)(s.input_samples - s0.input_samples) / elapsed,
           s.dropped_samples - s0.dropped_samples,
           s.audio_nonsilent_frames - s0.audio_nonsilent_frames,
           (double)cpu / CLOCKS_PER_SEC, s.state);
    fflush(stdout);
  }
stop:
  sdr_decoder_select(h, NULL, 0, NULL, 0);
  if ((rc = sdr_v3_stop(h)) != SDR_OK) bad = fail("stop", rc);
out:
  sdr_v2_close(h);
  sdr_destroy(h);
  return bad ? 1 : 0;
}
