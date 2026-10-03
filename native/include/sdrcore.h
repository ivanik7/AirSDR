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

// ABI revision 2. The original three symbols retain their ABI 1 signatures.
SDRCORE_API uint32_t sdr_version(void);

typedef struct SdrHandle SdrHandle;

// Allocates an idle engine handle. Returns NULL if allocation fails.
SDRCORE_API SdrHandle* sdr_create(void);

// Releases a handle returned by sdr_create; NULL is accepted.
// Synchronously stops and joins native workers, then closes owned descriptors.
// Call exactly once per non-NULL handle. Calls on the same handle are serialized.
SDRCORE_API void sdr_destroy(SdrHandle* handle);

// All sample rates are complex samples/second; frequency is RF Hz, gain is
// tenths of a dB. File input is interleaved unsigned 8-bit IQ (CU8).
// ABI 2 deliberately does not expose raw IQ or audio through Dart.
enum SdrResult {
  SDR_OK = 0, SDR_INVALID_ARGUMENT = -1, SDR_INVALID_STATE = -2,
  SDR_UNSUPPORTED = -3, SDR_IO_ERROR = -4, SDR_DEVICE_GONE = -5,
  SDR_INTERNAL_ERROR = -6
};
enum SdrState { SDR_IDLE = 0, SDR_OPEN = 1, SDR_RUNNING = 2, SDR_ERROR = 3 };
enum SdrSource { SDR_NONE = 0, SDR_FILE = 1, SDR_SYNTHETIC = 2,
                 SDR_RTLSDR = 3, SDR_HACKRF = 4 };

// Caller sets size to sizeof(SdrStats). Unknown size/revision is rejected;
// result is a snapshot and may change immediately after return.
typedef struct SdrStats {
  uint32_t size;
  uint32_t revision;
  uint32_t state;
  uint32_t source;
  int32_t last_error;
  uint32_t sample_rate;
  uint64_t frequency_hz;
  int32_t gain_tenths_db;
  uint32_t reserved;
  uint64_t input_samples;
  uint64_t processed_samples;
  uint64_t dropped_samples;
  uint64_t checksum; // FNV-1a digest of consumed CU8 blocks (host diagnostics).
} SdrStats;

// fd remains owned by the caller; native duplicates it only after validation.
// Caller MUST keep the Java UsbDeviceConnection alive for a USB session; do not
// allow Dart and native to stream the same device simultaneously. Native USB
// requires a real usbfs fd and device permission; it is not the default path.
SDRCORE_API int32_t sdr_v2_open_file(SdrHandle* handle, int32_t fd,
                                      uint32_t samples_per_second);
SDRCORE_API int32_t sdr_v2_open_synthetic(SdrHandle* handle,
                                           uint32_t samples_per_second);
SDRCORE_API int32_t sdr_v2_open_usb(SdrHandle* handle, int32_t fd,
                                     uint32_t source);
// Retune/gain on file and synthetic sources changes metadata only; on a USB
// source it configures the device. USB must be configured before start.
SDRCORE_API int32_t sdr_v2_configure(SdrHandle* handle, uint64_t frequency_hz,
                                      uint32_t samples_per_second,
                                      int32_t gain_tenths_db);
SDRCORE_API int32_t sdr_v2_start(SdrHandle* handle);
SDRCORE_API int32_t sdr_v2_stop(SdrHandle* handle);
SDRCORE_API int32_t sdr_v2_close(SdrHandle* handle);
SDRCORE_API int32_t sdr_v2_stats(SdrHandle* handle, SdrStats* stats);

#ifdef __cplusplus
}
#endif

#endif  // SDRCORE_H
