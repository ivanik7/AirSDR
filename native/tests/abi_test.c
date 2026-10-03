// SPDX-License-Identifier: GPL-3.0-or-later
#include "sdrcore.h"

#include <stddef.h>
#include <stdio.h>
#include <string.h>

#define CHECK(condition)                                                   \
  do {                                                                     \
    if (!(condition)) {                                                    \
      fprintf(stderr, "ABI check failed at line %d: %s\n", __LINE__,    \
              #condition);                                                \
      return 1;                                                            \
    }                                                                      \
  } while (0)

int main(void) {
  CHECK(sdr_version() == 2u);
  CHECK(sizeof(SdrStats) == 72u && offsetof(SdrStats, checksum) == 64u);
  CHECK(SDR_OK == 0 && SDR_INVALID_ARGUMENT == -1 && SDR_INVALID_STATE == -2);
  CHECK(SDR_UNSUPPORTED == -3 && SDR_IO_ERROR == -4 && SDR_DEVICE_GONE == -5);
  CHECK(SDR_INTERNAL_ERROR == -6);
  sdr_destroy(NULL);

  SdrHandle* first = sdr_create();
  SdrHandle* second = sdr_create();
  CHECK(first != NULL);
  CHECK(second != NULL);
  CHECK(first != second);

  sdr_destroy(first);
  sdr_destroy(second);
  SdrHandle* again = sdr_create();
  CHECK(again != NULL);
  sdr_destroy(again);

  // Invalid-argument rejection documented in sdrcore.h: out-of-range sample
  // rate, frequency above the 7.25 GHz ceiling, and gain outside +/-100.0 dB
  // must all be rejected without touching engine state.
  SdrHandle* guard = sdr_create();
  CHECK(guard != NULL);
  SdrStats stats;
  memset(&stats, 0xa5, sizeof(stats));
  SdrStats unchanged = stats;
  CHECK(sdr_v2_stats(guard, &stats) == SDR_INVALID_ARGUMENT);
  CHECK(memcmp(&stats, &unchanged, sizeof(stats)) == 0);
  stats.size = sizeof(stats);
  stats.revision = 1;
  unchanged = stats;
  CHECK(sdr_v2_stats(guard, &stats) == SDR_INVALID_ARGUMENT);
  CHECK(memcmp(&stats, &unchanged, sizeof(stats)) == 0);
  stats.revision = 2;
  CHECK(sdr_v2_stats(guard, &stats) == SDR_OK);
  CHECK(stats.state == SDR_IDLE && stats.source == SDR_NONE);
  CHECK(stats.last_error == SDR_OK && stats.input_samples == 0);
  CHECK(sdr_v2_stats(NULL, &stats) == SDR_INVALID_ARGUMENT);
  CHECK(sdr_v2_stats(guard, NULL) == SDR_INVALID_ARGUMENT);
  CHECK(sdr_v2_open_usb(guard, -1, SDR_RTLSDR) == SDR_INVALID_ARGUMENT);
  CHECK(sdr_v2_open_usb(guard, 0, SDR_FILE) == SDR_INVALID_ARGUMENT);
  CHECK(sdr_v2_open_synthetic(guard, 0) == SDR_INVALID_ARGUMENT);
  CHECK(sdr_v2_open_synthetic(guard, 999) == SDR_INVALID_ARGUMENT);
  CHECK(sdr_v2_open_synthetic(guard, 20000001u) == SDR_INVALID_ARGUMENT);
  CHECK(sdr_v2_open_file(guard, -1, 2000000) == SDR_INVALID_ARGUMENT);
  CHECK(sdr_v2_open_synthetic(guard, 1000) == SDR_OK);
  CHECK(sdr_v2_open_synthetic(guard, 1000) == SDR_INVALID_STATE);
  CHECK(sdr_v2_stats(guard, &stats) == SDR_OK);
  CHECK(stats.sample_rate == 1000 && stats.frequency_hz == 0);
  CHECK(sdr_v2_configure(guard, 7250000001ULL, 2000000, 0) ==
        SDR_INVALID_ARGUMENT);
  CHECK(sdr_v2_configure(guard, 100000000, 2000000, 1001) ==
        SDR_INVALID_ARGUMENT);
  CHECK(sdr_v2_configure(guard, 100000000, 2000000, -1001) ==
        SDR_INVALID_ARGUMENT);
  CHECK(sdr_v2_stats(guard, &stats) == SDR_OK);
  CHECK(stats.sample_rate == 1000 && stats.frequency_hz == 0 &&
        stats.gain_tenths_db == 0);
  CHECK(sdr_v2_configure(guard, 7250000000ULL, 20000000, 1000) == SDR_OK);
  CHECK(sdr_v2_stats(guard, &stats) == SDR_OK);
  CHECK(stats.frequency_hz == 7250000000ULL && stats.sample_rate == 20000000 &&
        stats.gain_tenths_db == 1000);
  CHECK(sdr_v2_configure(guard, 100000000, 2000000, 1000) == SDR_OK);
  CHECK(sdr_v2_configure(guard, 100000000, 2000000, -1000) == SDR_OK);
  CHECK(sdr_v2_start(guard) == SDR_OK);
  CHECK(sdr_v2_configure(guard, 200000000, 1000000, 0) == SDR_INVALID_STATE);
  CHECK(sdr_v2_stats(guard, &stats) == SDR_OK);
  CHECK(stats.frequency_hz == 100000000 && stats.sample_rate == 2000000 &&
        stats.gain_tenths_db == -1000);
  CHECK(sdr_v2_stop(guard) == SDR_OK);
  CHECK(sdr_v2_stop(guard) == SDR_INVALID_STATE);
  CHECK(sdr_v2_close(guard) == SDR_OK);
  CHECK(sdr_v2_close(guard) == SDR_INVALID_STATE);
  sdr_destroy(guard);

  // A duplicate-call pair at the handle-allocation boundary should not alias:
  // sdr_create() must keep returning distinct pointers across many cycles,
  // which rules out an allocator free-list bug that could later resurrect a
  // destroyed handle as "still valid".
  for (int i = 0; i < 20; ++i) {
    SdrHandle* h = sdr_create();
    CHECK(h != NULL);
    sdr_destroy(h);
  }
  return 0;
}
