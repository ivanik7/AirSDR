// SPDX-License-Identifier: GPL-3.0-or-later
//
// Maps libusb errors of the desktop direct open path (libusb_open and
// claiming interface 0, see UsbRxAdapter::open_bus_address) to the public
// SdrResult / SdrHostResult codes of native/include/sdrcore_host.h.
// Internal; not part of the ABI. The numeric values are those of the
// vendored libusb.h (enum libusb_error), which never change upstream.
#ifndef SDRCORE_USB_HOST_ERRORS_H
#define SDRCORE_USB_HOST_ERRORS_H

#include "sdrcore.h"

namespace sdrcore {

// Mirrors of SdrHostResult, kept here so that the adapters do not depend on
// the host-only header (they are also compiled for Android).
inline constexpr int kHostAccessDenied = -16;
inline constexpr int kHostNotFound = -17;
inline constexpr int kHostDriverUnsupported = -18;
inline constexpr int kHostBusy = -19;

inline int map_libusb_open_error(int libusb_error) {
  switch (libusb_error) {
    case -3:   // LIBUSB_ERROR_ACCESS
      return kHostAccessDenied;
    case -4:   // LIBUSB_ERROR_NO_DEVICE
    case -5:   // LIBUSB_ERROR_NOT_FOUND
      return kHostNotFound;
    case -6:   // LIBUSB_ERROR_BUSY
      return kHostBusy;
    case -12:  // LIBUSB_ERROR_NOT_SUPPORTED (e.g. Windows without WinUSB)
      return kHostDriverUnsupported;
    case -1:   // LIBUSB_ERROR_IO
      return SDR_IO_ERROR;
    default:
      return SDR_DEVICE_GONE;
  }
}

}  // namespace sdrcore

#endif  // SDRCORE_USB_HOST_ERRORS_H
