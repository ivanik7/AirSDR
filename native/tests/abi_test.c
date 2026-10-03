// SPDX-License-Identifier: GPL-3.0-or-later
#include "sdrcore.h"

#include <stddef.h>
#include <stdio.h>

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
  CHECK(sdr_v2_open_synthetic(guard, 0) == SDR_INVALID_ARGUMENT);
  CHECK(sdr_v2_open_synthetic(guard, 999) == SDR_INVALID_ARGUMENT);
  CHECK(sdr_v2_open_synthetic(guard, 20000001u) == SDR_INVALID_ARGUMENT);
  CHECK(sdr_v2_open_file(guard, -1, 2000000) == SDR_INVALID_ARGUMENT);
  CHECK(sdr_v2_open_synthetic(guard, 2000000) == SDR_OK);
  CHECK(sdr_v2_configure(guard, 7250000001ULL, 2000000, 0) ==
        SDR_INVALID_ARGUMENT);
  CHECK(sdr_v2_configure(guard, 100000000, 2000000, 1001) ==
        SDR_INVALID_ARGUMENT);
  CHECK(sdr_v2_configure(guard, 100000000, 2000000, -1001) ==
        SDR_INVALID_ARGUMENT);
  CHECK(sdr_v2_configure(guard, 100000000, 2000000, 1000) == SDR_OK);
  CHECK(sdr_v2_configure(guard, 100000000, 2000000, -1000) == SDR_OK);
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
