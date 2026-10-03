// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef SDRCORE_H
#define SDRCORE_H

#include <stdint.h>

#if defined(_WIN32)
#define SDRCORE_API __declspec(dllexport)
#else
#define SDRCORE_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// N0 ABI revision. Increment when an existing exported contract changes.
SDRCORE_API uint32_t sdr_version(void);

typedef struct SdrHandle SdrHandle;

// Allocates an inert engine handle. Returns NULL if allocation fails.
// No SDR device is opened and no reception is started.
SDRCORE_API SdrHandle* sdr_create(void);

// Releases a handle returned by sdr_create; NULL is accepted.
// Call only once per non-NULL handle, after all future native work has stopped.
SDRCORE_API void sdr_destroy(SdrHandle* handle);

#ifdef __cplusplus
}
#endif

#endif  // SDRCORE_H
