// SPDX-License-Identifier: GPL-3.0-or-later
//
// Host regression test for sdr_v3_rtl_tuner_gains (native/include/sdrcore_v3.h)
// against a real, already-open RTL-SDR device via the Linux host USB layer
// (native/include/sdrcore_host.h). If no RTL-SDR (0bda:2838 Blog V4, or the
// legacy 0bda:2832) is attached, this prints a SKIP line and exits 0: it is
// deliberately non-blocking for hosts without hardware (CTest still runs
// native/tests/rtl_gain_list_test.cpp's white-box coverage unconditionally).
//
// What this proves that the synthetic white-box test cannot: the real ABI
// entry point reaches the real rtlsdr_dev_t through sdr_host_open_usb's
// already-claimed adapter, with no second USB claim (verified by failing a
// second handle's open of the same bus/address), and the real
// rtlsdr_get_tuner_gains() plumbing (count-only probe, full query,
// BUFFER_SMALL, ascending order) behaves per contract on genuine hardware.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sdrcore_host.h"
#include "sdrcore_v3.h"

#define CHECK(c)                                                           \
  do {                                                                     \
    if (!(c)) {                                                            \
      fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #c); \
      return 1;                                                            \
    }                                                                      \
  } while (0)

static int find_rtl(SdrHostUsbDevice* out) {
  SdrHostUsbDevice devs[32];
  for (int i = 0; i < 32; ++i) devs[i].size = sizeof(devs[i]);
  uint32_t count = 0;
  if (sdr_host_usb_list(devs, 32, &count) != SDR_OK) return 0;
  for (uint32_t i = 0; i < count && i < 32; ++i) {
    if (devs[i].vendor_id == 0x0bda &&
        (devs[i].product_id == 0x2838 || devs[i].product_id == 0x2832)) {
      *out = devs[i];
      return 1;
    }
  }
  return 0;
}

int main(void) {
  SdrHostUsbDevice dev;
  if (!find_rtl(&dev)) {
    printf("[skip] no RTL-SDR (0bda:2838/2832) attached; "
           "real-hardware gain-list query not exercised on this host\n");
    return 0;
  }
  printf("[info] device %s %04x:%04x '%s'\n", dev.path, dev.vendor_id,
         dev.product_id, dev.product);

  SdrHandle* h = sdr_create();
  CHECK(h != NULL);
  const int32_t open_rc = sdr_host_open_usb(h, dev.bus, dev.address, SDR_RTLSDR);
  CHECK(open_rc == SDR_OK);

  // Count-only probe.
  uint32_t count = 0;
  CHECK(sdr_v3_rtl_tuner_gains(h, NULL, 0, &count) == SDR_OK);
  CHECK(count > 0);  // Blog V4's R828D tuner has a non-empty gain table.
  printf("[info] tuner reports %u gain steps\n", count);

  // BUFFER_SMALL below the required count; array must stay untouched.
  if (count > 1) {
    int32_t small[1];
    small[0] = -999;
    uint32_t small_count = 0;
    const int32_t rc = sdr_v3_rtl_tuner_gains(h, small, count - 1, &small_count);
    CHECK(rc == SDR_V3_BUFFER_SMALL);
    CHECK(small_count == count);
    CHECK(small[0] == -999);
  }

  // Full query: exact capacity, ascending order, plausible tenths-of-dB range.
  int32_t* gains = calloc(count, sizeof(int32_t));
  CHECK(gains != NULL);
  uint32_t full_count = 0;
  CHECK(sdr_v3_rtl_tuner_gains(h, gains, count, &full_count) == SDR_OK);
  CHECK(full_count == count);
  for (uint32_t i = 0; i < count; ++i) {
    // R820T/R828D gain range per librtlsdr's r82xx_gains table.
    CHECK(gains[i] >= 0 && gains[i] <= 1000);
    if (i > 0) CHECK(gains[i - 1] <= gains[i]);  // sorted ascending
  }
  printf("[info] gains[0..%u) = [%d .. %d] tenths dB, ascending\n", count,
         gains[0], gains[count - 1]);
  free(gains);

  // A larger-than-needed capacity also succeeds and reports the same count.
  int32_t* over = calloc(count + 8, sizeof(int32_t));
  CHECK(over != NULL);
  uint32_t over_count = 0;
  CHECK(sdr_v3_rtl_tuner_gains(h, over, count + 8, &over_count) == SDR_OK);
  CHECK(over_count == count);
  free(over);

  // No second USB claim: a second handle opening the same bus/address must
  // fail while the first handle still owns it (global claim, same contract
  // enforced by sdr_v2_open_usb's g_native_usb_claim).
  {
    SdrHandle* second = sdr_create();
    CHECK(second != NULL);
    const int32_t rc = sdr_host_open_usb(second, dev.bus, dev.address, SDR_RTLSDR);
    CHECK(rc != SDR_OK);
    sdr_destroy(second);
  }

  // The query works equally in RUNNING, not only OPEN (configure briefly
  // and start a diagnostic v2 stream, matching the contract's "OPEN or
  // RUNNING" implicit state coverage via the existing v2 ABI).
  CHECK(sdr_v2_configure(h, 100000000, 2400000, 0) == SDR_OK);
  CHECK(sdr_v2_start(h) == SDR_OK);
  uint32_t running_count = 0;
  const int32_t running_rc = sdr_v3_rtl_tuner_gains(h, NULL, 0, &running_count);
  CHECK(running_rc == SDR_OK);
  CHECK(running_count == count);
  CHECK(sdr_v2_stop(h) == SDR_OK);

  CHECK(sdr_v2_close(h) == SDR_OK);
  sdr_destroy(h);
  printf("host_rtl_gain_test: ok (%u gain steps on %s)\n", count, dev.path);
  return 0;
}
