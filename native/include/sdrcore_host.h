// SPDX-License-Identifier: GPL-3.0-or-later
//
// Desktop Linux platform layer of libsdrcore.so (L1 dev/test target).
//
// These symbols exist only in host (non-Android) builds. They are optional
// extensions of ABI 2, not a new ABI revision: sdr_version() still returns 2,
// and clients must probe for the symbols by name (Dart:
// DynamicLibrary.providesSymbol) before calling them. Android builds never
// export them; Android keeps the UsbManager fd handoff (sdr_v2_open_usb).
//
// The host layer replaces only what Android's UsbManager provides:
// enumeration and opening of /dev/bus/usb/BBB/DDD. Streaming, tuning and the
// drivers are the same shared code (sdr_v2_configure/start/stop/close/stats).
// No IQ or audio sample crosses this boundary either.
#ifndef SDRCORE_HOST_H
#define SDRCORE_HOST_H

#include <stdint.h>

#include "sdrcore.h"

#ifdef __cplusplus
extern "C" {
#endif

// Host-only result codes, in addition to enum SdrResult.
enum SdrHostResult {
  SDR_HOST_ACCESS_DENIED = -16,  // open(2) of the usbfs node failed: EACCES/EPERM
  SDR_HOST_NOT_FOUND = -17       // no such bus/address (unplugged or re-enumerated)
};

// One USB device as seen by libusb on the host. Strings come from sysfs
// (/sys/bus/usb/devices/<port path>/{manufacturer,product,serial}) so that
// listing never sends control transfers to a device that may be streaming.
// Strings are NUL-terminated, truncated to fit, and empty when unavailable.
// Caller sets size=sizeof(SdrHostUsbDevice) in every element it passes.
typedef struct SdrHostUsbDevice {
  uint32_t size;
  uint16_t vendor_id;
  uint16_t product_id;
  uint8_t bus;          // libusb_get_bus_number
  uint8_t address;      // libusb_get_device_address
  uint8_t reserved[2];  // zero
  char path[32];        // "/dev/bus/usb/BBB/DDD"
  char manufacturer[64];
  char product[64];
  char serial[64];
} SdrHostUsbDevice;

// Enumerates every non-hub USB device with libusb_get_device_list. Callers
// filter supported SDRs by VID:PID (the app uses isSupportedUsbSdr). Writes
// min(capacity, total) entries to out (out may be NULL when capacity is 0) and
// stores the total in *count. Each call uses a fresh libusb context, so it is
// safe to poll (e.g. once per second for hotplug) concurrently with a running
// handle. Returns SDR_OK, SDR_INVALID_ARGUMENT (NULL count, NULL out with
// capacity > 0, or a wrong size field) or SDR_IO_ERROR (libusb failure).
SDRCORE_API int32_t sdr_host_usb_list(SdrHostUsbDevice* out, uint32_t capacity,
                                      uint32_t* count);

// Opens /dev/bus/usb/<bus>/<address> read-write and hands the descriptor to
// the same driver path as sdr_v2_open_usb(handle, fd, source); source is
// SDR_RTLSDR or SDR_HACKRF. The adapter keeps its own dup, so this function
// closes its temporary descriptor before returning; nothing is left for the
// caller to own. State rules equal sdr_v2_open_usb (IDLE -> OPEN on success).
// Errors: SDR_INVALID_ARGUMENT, SDR_INVALID_STATE, SDR_HOST_NOT_FOUND,
// SDR_HOST_ACCESS_DENIED, SDR_IO_ERROR, or any driver open error.
// Unplugging a running device surfaces as state SDR_ERROR with last_error
// SDR_DEVICE_GONE (or SDR_IO_ERROR), exactly as on Android.
SDRCORE_API int32_t sdr_host_open_usb(SdrHandle* handle, uint8_t bus,
                                      uint8_t address, uint32_t source);

#ifdef __cplusplus
}
#endif

#endif  // SDRCORE_HOST_H
