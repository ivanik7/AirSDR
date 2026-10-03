// SPDX-License-Identifier: GPL-3.0-or-later
// Inject failure at the libusb initialization boundary of the pinned
// librtlsdr C source. Link against the source-built static libraries with
// --wrap=libusb_init; do not confuse this with hardware USB acceptance.
#include "rtl-sdr.h"
#include "libusb.h"

#include <assert.h>
#include <stdint.h>
#include <stdio.h>

// rtlsdr_create_device is deliberately not a public sdrcore symbol.
int rtlsdr_create_device(rtlsdr_dev_t** dev);

static int init_calls;
int __wrap_libusb_init(libusb_context** context) {
  ++init_calls;
  *context = NULL;
  return LIBUSB_ERROR_NO_MEM;
}

int main(void) {
  rtlsdr_dev_t* dev = (rtlsdr_dev_t*)(uintptr_t)1;
  assert(rtlsdr_create_device(&dev) == LIBUSB_ERROR_NO_MEM);
  assert(init_calls == 1);
  assert(dev == NULL);  // The failed allocation is released, not returned.
  puts("[ok] RTL-SDR libusb init failure releases device and clears pointer");
  return 0;
}
