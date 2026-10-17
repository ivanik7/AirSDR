// SPDX-License-Identifier: GPL-3.0-or-later
//
// Internal (non-exported) entry points shared by sdrcore.cpp and the desktop
// host layer (sdrcore_host.cpp). Not part of the C ABI.
#ifndef SDRCORE_INTERNAL_H
#define SDRCORE_INTERNAL_H

#include <stdint.h>

#include "sdrcore.h"

// Direct desktop open (sdr_host_open_usb_direct): claims the single native USB
// session and opens the driver at bus/address with libusb_open(). Arguments
// must already be validated. Returns SdrResult / SdrHostResult codes.
int32_t sdrcore_open_usb_bus_address(SdrHandle* handle, uint8_t bus,
                                     uint8_t address, uint32_t source);

// True while any handle in this process holds a native USB session.
bool sdrcore_native_usb_claim_active();

#endif  // SDRCORE_INTERNAL_H
