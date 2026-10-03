// SPDX-License-Identifier: GPL-3.0-or-later
#include "sdrcore.h"

#include <new>

struct SdrHandle {};

extern "C" uint32_t sdr_version(void) { return 1u; }

extern "C" SdrHandle* sdr_create(void) {
  return new (std::nothrow) SdrHandle;
}

extern "C" void sdr_destroy(SdrHandle* handle) { delete handle; }
