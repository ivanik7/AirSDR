// SPDX-License-Identifier: GPL-3.0-or-later
// Hardware-independent checks of the desktop host USB layer
// (native/include/sdrcore_host.h): argument validation, enumeration
// consistency, and open failures that must not change handle state.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sdrcore_host.h"

#define CHECK(c)                                                    \
  do {                                                              \
    if (!(c)) {                                                     \
      fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #c); \
      return 1;                                                     \
    }                                                               \
  } while (0)

static int state_of(SdrHandle* h) {
  SdrStats s;
  memset(&s, 0, sizeof(s));
  s.size = sizeof(s);
  s.revision = 2;
  if (sdr_v2_stats(h, &s) != SDR_OK) return -1;
  return (int)s.state;
}

int main(void) {
  uint32_t count = 123;
  // Argument validation.
  CHECK(sdr_host_usb_list(NULL, 0, NULL) == SDR_INVALID_ARGUMENT);
  CHECK(sdr_host_usb_list(NULL, 1, &count) == SDR_INVALID_ARGUMENT);
  SdrHostUsbDevice bad;
  memset(&bad, 0, sizeof(bad));
  bad.size = sizeof(bad) - 1;
  CHECK(sdr_host_usb_list(&bad, 1, &count) == SDR_INVALID_ARGUMENT);

  // Count-only query, then a full listing: totals agree and entries are sane.
  CHECK(sdr_host_usb_list(NULL, 0, &count) == SDR_OK);
  const uint32_t total = count;
  SdrHostUsbDevice* list = calloc(total + 1, sizeof(*list));
  CHECK(list != NULL);
  for (uint32_t i = 0; i <= total; ++i) list[i].size = sizeof(*list);
  uint32_t again = 0;
  CHECK(sdr_host_usb_list(list, total + 1, &again) == SDR_OK);
  // Hotplug between the calls could change the total; tolerate +-1.
  CHECK(again + 1 >= total && again <= total + 1);
  for (uint32_t i = 0; i < again && i < total + 1; ++i) {
    CHECK(list[i].size == sizeof(*list));
    CHECK(list[i].bus > 0 && list[i].address > 0);
    CHECK(strncmp(list[i].path, "/dev/bus/usb/", 13) == 0);
    CHECK(memchr(list[i].product, '\0', sizeof(list[i].product)) != NULL);
    printf("usb %s %04x:%04x '%s' '%s' '%s'\n", list[i].path,
           list[i].vendor_id, list[i].product_id, list[i].manufacturer,
           list[i].product, list[i].serial);
  }
  free(list);

  SdrHandle* h = sdr_create();
  CHECK(h != NULL);
  CHECK(sdr_host_open_usb(NULL, 1, 1, SDR_RTLSDR) == SDR_INVALID_ARGUMENT);
  CHECK(sdr_host_open_usb(h, 0, 1, SDR_RTLSDR) == SDR_INVALID_ARGUMENT);
  CHECK(sdr_host_open_usb(h, 1, 0, SDR_RTLSDR) == SDR_INVALID_ARGUMENT);
  CHECK(sdr_host_open_usb(h, 1, 1, SDR_FILE) == SDR_INVALID_ARGUMENT);
  // Bus 255 / address 255 never exists on a normal host.
  CHECK(sdr_host_open_usb(h, 255, 255, SDR_RTLSDR) == SDR_HOST_NOT_FOUND);
  CHECK(state_of(h) == SDR_IDLE);
  // A failed open in OPEN state must leave the current session untouched.
  CHECK(sdr_v2_open_synthetic(h, 48000) == SDR_OK);
  const int32_t rc = sdr_host_open_usb(h, 255, 255, SDR_RTLSDR);
  CHECK(rc == SDR_HOST_NOT_FOUND || rc == SDR_INVALID_STATE);
  CHECK(state_of(h) == SDR_OPEN);
  CHECK(sdr_v2_close(h) == SDR_OK);
  sdr_destroy(h);
  printf("host_usb_test: ok (%u devices)\n", total);
  return 0;
}
