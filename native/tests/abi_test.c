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
  CHECK(sdr_version() == 1u);
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
  return 0;
}
