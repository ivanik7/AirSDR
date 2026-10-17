// SPDX-License-Identifier: GPL-3.0-or-later
//
// Checks of the desktop direct libusb open path (sdr_host_open_usb_direct,
// native/include/sdrcore_host.h): the only open path on macOS and Windows.
//
// Without hardware: argument validation, "no such device" for both drivers,
// and that a failed open never changes the handle state.
// With an RTL-SDR (0bda:2838 / 0bda:2832) attached: the direct path opens and
// streams through the same engine, holds the single native USB claim, and
// releases it so the Linux fd path works afterwards.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <time.h>
#endif

#include "sdrcore_host.h"

#define CHECK(c)                                                             \
  do {                                                                       \
    if (!(c)) {                                                              \
      fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #c); \
      return 1;                                                              \
    }                                                                        \
  } while (0)

static SdrStats stats_of(SdrHandle* h) {
  SdrStats s;
  memset(&s, 0, sizeof(s));
  s.size = sizeof(s);
  s.revision = 2;
  if (sdr_v2_stats(h, &s) != SDR_OK) s.state = 0xffffffffu;
  return s;
}

static void sleep_ms(int ms) {
#ifdef _WIN32
  Sleep((DWORD)ms);
#else
  struct timespec ts = {ms / 1000, (long)(ms % 1000) * 1000000L};
  nanosleep(&ts, NULL);
#endif
}

static int find_rtl(uint8_t* bus, uint8_t* address) {
  uint32_t count = 0;
  if (sdr_host_usb_list(NULL, 0, &count) != SDR_OK || count == 0) return 0;
  SdrHostUsbDevice* list = calloc(count, sizeof(*list));
  if (!list) return 0;
  for (uint32_t i = 0; i < count; ++i) list[i].size = sizeof(*list);
  uint32_t got = 0;
  int found = 0;
  if (sdr_host_usb_list(list, count, &got) == SDR_OK) {
    for (uint32_t i = 0; i < got && i < count; ++i) {
      if (list[i].vendor_id == 0x0bda &&
          (list[i].product_id == 0x2838 || list[i].product_id == 0x2832)) {
        *bus = list[i].bus;
        *address = list[i].address;
        found = 1;
        break;
      }
    }
  }
  free(list);
  return found;
}

static int hardware_checks(uint8_t bus, uint8_t address) {
  printf("hardware: RTL-SDR at bus %u address %u\n", bus, address);
  SdrHandle* h = sdr_create();
  SdrHandle* other = sdr_create();
  CHECK(h != NULL && other != NULL);
  int32_t rc = sdr_host_open_usb_direct(h, bus, address, SDR_RTLSDR);
  if (rc == SDR_HOST_BUSY || rc == SDR_HOST_ACCESS_DENIED) {
    printf("hardware: skipped, direct open returned %d (busy/denied)\n", rc);
    sdr_destroy(other);
    sdr_destroy(h);
    return 0;
  }
  CHECK(rc == SDR_OK);
  CHECK(stats_of(h).state == SDR_OPEN);
  CHECK(stats_of(h).source == SDR_RTLSDR);
  // One native USB session per process, whichever path opened it.
  CHECK(sdr_host_open_usb_direct(other, bus, address, SDR_RTLSDR) ==
        SDR_INVALID_STATE);
  CHECK(stats_of(other).state == SDR_IDLE);
  // The same handle cannot be opened twice.
  CHECK(sdr_host_open_usb_direct(h, bus, address, SDR_RTLSDR) ==
        SDR_INVALID_STATE);
  CHECK(sdr_v2_configure(h, 100500000ULL, 2400000u, 300) == SDR_OK);
  CHECK(sdr_v2_start(h) == SDR_OK);
  sleep_ms(2000);
  const SdrStats running = stats_of(h);
  CHECK(running.state == SDR_RUNNING);
  CHECK(running.input_samples > 0);
  printf("hardware: direct path streamed %llu IQ pairs in 2 s\n",
         (unsigned long long)running.input_samples);
  CHECK(sdr_v2_stop(h) == SDR_OK);
  CHECK(sdr_v2_close(h) == SDR_OK);
  CHECK(stats_of(h).state == SDR_IDLE);
  sdr_destroy(h);

  // The claim is released: the default host path opens again.
  rc = sdr_host_open_usb(other, bus, address, SDR_RTLSDR);
  CHECK(rc == SDR_OK);
  CHECK(stats_of(other).state == SDR_OPEN);
  CHECK(sdr_v2_close(other) == SDR_OK);
  sdr_destroy(other);
  return 0;
}

int main(void) {
  SdrHandle* h = sdr_create();
  CHECK(h != NULL);

  // Argument validation.
  CHECK(sdr_host_open_usb_direct(NULL, 1, 1, SDR_RTLSDR) == SDR_INVALID_ARGUMENT);
  CHECK(sdr_host_open_usb_direct(h, 0, 1, SDR_RTLSDR) == SDR_INVALID_ARGUMENT);
  CHECK(sdr_host_open_usb_direct(h, 1, 0, SDR_RTLSDR) == SDR_INVALID_ARGUMENT);
  CHECK(sdr_host_open_usb_direct(h, 1, 1, SDR_FILE) == SDR_INVALID_ARGUMENT);
  CHECK(sdr_host_open_usb_direct(h, 1, 1, SDR_SYNTHETIC) == SDR_INVALID_ARGUMENT);
  CHECK(stats_of(h).state == SDR_IDLE);

  // No device at bus 255 / address 255, for both drivers.
  CHECK(sdr_host_open_usb_direct(h, 255, 255, SDR_RTLSDR) == SDR_HOST_NOT_FOUND);
  CHECK(stats_of(h).state == SDR_IDLE);
  CHECK(sdr_host_open_usb_direct(h, 255, 255, SDR_HACKRF) == SDR_HOST_NOT_FOUND);
  CHECK(stats_of(h).state == SDR_IDLE);
  // Repeated failures must not leak the single native USB claim.
  for (int i = 0; i < 3; ++i)
    CHECK(sdr_host_open_usb_direct(h, 255, 255, SDR_RTLSDR) == SDR_HOST_NOT_FOUND);

  // A failed open of an OPEN handle leaves the session untouched.
  CHECK(sdr_v2_open_synthetic(h, 48000) == SDR_OK);
  const int32_t rc = sdr_host_open_usb_direct(h, 255, 255, SDR_RTLSDR);
  CHECK(rc == SDR_INVALID_STATE || rc == SDR_HOST_NOT_FOUND);
  CHECK(stats_of(h).state == SDR_OPEN);
  CHECK(stats_of(h).source == SDR_SYNTHETIC);
  CHECK(sdr_v2_close(h) == SDR_OK);
  sdr_destroy(h);

  // Enumeration keeps working alongside the direct path.
  uint32_t count = 0;
  CHECK(sdr_host_usb_list(NULL, 0, &count) == SDR_OK);

  uint8_t bus = 0, address = 0;
  if (find_rtl(&bus, &address)) {
    if (hardware_checks(bus, address) != 0) return 1;
  } else {
    printf("hardware: skipped, no RTL-SDR attached\n");
  }
  printf("host_usb_direct_test: ok (%u devices)\n", count);
  return 0;
}
