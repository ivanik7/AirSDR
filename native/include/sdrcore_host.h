// SPDX-License-Identifier: GPL-3.0-or-later
//
// Desktop host platform layer of libsdrcore (Linux .so, macOS .dylib,
// Windows .dll).
//
// These symbols exist only in host (non-Android) builds. They are optional
// extensions of ABI 2, not a new ABI revision: sdr_version() still returns 2,
// and clients must probe for the symbols by name (Dart:
// DynamicLibrary.providesSymbol) before calling them. Android builds never
// export them; Android keeps the UsbManager fd handoff (sdr_v2_open_usb).
//
// The host layer replaces only what Android's UsbManager provides:
// enumeration and opening of a USB device. Streaming, tuning and the drivers
// are the same shared code (sdr_v2_configure/start/stop/close/stats). No IQ
// or audio sample crosses this boundary either.
//
// Two open paths exist:
//   fd path      (Linux only) opens /dev/bus/usb/BBB/DDD and hands the
//                descriptor to sdr_v2_open_usb, like Android's UsbManager fd.
//   direct path  (every host) the vendored driver itself calls libusb_open()
//                on the device enumerated at bus/address. macOS (IOKit) and
//                Windows (WinUSB) have no usbfs descriptors, so this is their
//                only path.
// sdr_host_open_usb() picks the fd path on Linux and the direct path
// elsewhere; sdr_host_open_usb_direct() always takes the direct path.
#ifndef SDRCORE_HOST_H
#define SDRCORE_HOST_H

#include <stdint.h>

#include "sdrcore.h"

#ifdef __cplusplus
extern "C" {
#endif

// Host-only result codes, in addition to enum SdrResult.
enum SdrHostResult {
  // open(2) of the usbfs node failed with EACCES/EPERM, or libusb_open()
  // returned LIBUSB_ERROR_ACCESS (Linux udev rules, macOS entitlement).
  SDR_HOST_ACCESS_DENIED = -16,
  // No such bus/address (unplugged or re-enumerated), or LIBUSB_ERROR_NO_DEVICE.
  SDR_HOST_NOT_FOUND = -17,
  // The OS driver bound to the device cannot be used by libusb
  // (LIBUSB_ERROR_NOT_SUPPORTED). On Windows: the RTL-SDR/HackRF is not bound
  // to WinUSB; install WinUSB for it with Zadig.
  SDR_HOST_DRIVER_UNSUPPORTED = -18,
  // The device is held by another process or an OS kernel driver
  // (LIBUSB_ERROR_BUSY on claim, or a kernel driver active on interface 0).
  SDR_HOST_BUSY = -19
};

// One USB device as seen by libusb on the host.
//
// Strings: on Linux they come from sysfs
// (/sys/bus/usb/devices/<port path>/{manufacturer,product,serial}), so listing
// never sends control transfers to a device that may be streaming. Other hosts
// have no sysfs: there the strings are read once with libusb string
// descriptors, only for supported SDR VID:PIDs, only while this process holds
// no USB device open, and cached per (bus, address, VID, PID). When they are
// unavailable the fields are empty and clients fall back to their VID:PID
// catalog name.
// Strings are NUL-terminated, truncated to fit, and empty when unavailable.
// Caller sets size=sizeof(SdrHostUsbDevice) in every element it passes.
typedef struct SdrHostUsbDevice {
  uint32_t size;
  uint16_t vendor_id;
  uint16_t product_id;
  uint8_t bus;          // libusb_get_bus_number
  uint8_t address;      // libusb_get_device_address
  uint8_t reserved[2];  // zero
  char path[32];        // Linux "/dev/bus/usb/BBB/DDD"; elsewhere "usb:BBB/DDD"
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

// Opens the device at bus/address for source SDR_RTLSDR or SDR_HACKRF.
// Linux: opens /dev/bus/usb/<bus>/<address> read-write and hands the
// descriptor to the same driver path as sdr_v2_open_usb(handle, fd, source).
// The adapter keeps its own dup, so this function closes its temporary
// descriptor before returning; nothing is left for the caller to own.
// Other hosts: identical to sdr_host_open_usb_direct().
// State rules equal sdr_v2_open_usb (IDLE -> OPEN on success).
// Errors: SDR_INVALID_ARGUMENT, SDR_INVALID_STATE, SDR_HOST_NOT_FOUND,
// SDR_HOST_ACCESS_DENIED, SDR_HOST_DRIVER_UNSUPPORTED, SDR_HOST_BUSY,
// SDR_IO_ERROR, or any driver open error.
// Unplugging a running device surfaces as state SDR_ERROR with last_error
// SDR_DEVICE_GONE (or SDR_IO_ERROR), exactly as on Android.
SDRCORE_API int32_t sdr_host_open_usb(SdrHandle* handle, uint8_t bus,
                                      uint8_t address, uint32_t source);

// Direct path, available on every host build (including Linux, where it is
// used for tests and as a fallback): the vendored driver (librtlsdr or
// libhackrf) finds the device at bus/address in its own libusb context and
// opens it with libusb_open(); no file descriptor is involved. Same argument,
// state and ownership rules as sdr_host_open_usb. When the driver cannot open
// the device, the libusb error is classified as SDR_HOST_NOT_FOUND,
// SDR_HOST_ACCESS_DENIED, SDR_HOST_DRIVER_UNSUPPORTED or SDR_HOST_BUSY when
// possible, otherwise SDR_DEVICE_GONE / SDR_IO_ERROR. The handle is never
// left half-open: on error it stays in its previous state.
SDRCORE_API int32_t sdr_host_open_usb_direct(SdrHandle* handle, uint8_t bus,
                                             uint8_t address, uint32_t source);

#ifdef __cplusplus
}
#endif

#endif  // SDRCORE_HOST_H
