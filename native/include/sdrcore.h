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

// ABI revision 2. Clients must check sdr_version() before using v2 symbols.
// The original three symbols retain their ABI 1 signatures and ownership rules.
SDRCORE_API uint32_t sdr_version(void);

typedef struct SdrHandle SdrHandle;

// Allocates an idle engine handle. Returns NULL if allocation fails.
SDRCORE_API SdrHandle* sdr_create(void);

// Releases a handle returned by sdr_create; NULL is accepted.
// Synchronously stops and joins native workers, then closes owned descriptors.
// Call exactly once per non-NULL handle; callers serialize all commands including
// destroy and wait for outstanding stats calls before destroying the handle.
SDRCORE_API void sdr_destroy(SdrHandle* handle);

// Rates: 1000..20000000 complex IQ pairs/second; RF: 0..7250000000 Hz;
// gain: -1000..1000 tenths of a dB. USB hardware may reject a valid ABI
// value as unsupported. File input is interleaved unsigned 8-bit IQ (CU8).
// ABI 2 exposes neither raw IQ nor audio through Dart/JNI.
enum SdrResult {
  SDR_OK = 0, SDR_INVALID_ARGUMENT = -1, SDR_INVALID_STATE = -2,
  SDR_UNSUPPORTED = -3, SDR_IO_ERROR = -4, SDR_DEVICE_GONE = -5,
  SDR_INTERNAL_ERROR = -6
};
enum SdrState { SDR_IDLE = 0, SDR_OPEN = 1, SDR_RUNNING = 2, SDR_ERROR = 3 };
enum SdrSource { SDR_NONE = 0, SDR_FILE = 1, SDR_SYNTHETIC = 2,
                 SDR_RTLSDR = 3, SDR_HACKRF = 4 };

// Caller initializes size=sizeof(SdrStats), revision=2. Mismatches return
// SDR_INVALID_ARGUMENT without writing the struct. Other fields are output;
// the snapshot is atomic with respect to native counter updates.
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
  uint64_t input_samples;      // Complete complex IQ pairs accepted at ingress.
  uint64_t processed_samples;  // Pairs consumed by the native diagnostic sink.
  uint64_t dropped_samples;    // Pairs discarded on ring overflow (not USB loss).
  uint64_t checksum; // FNV-1a digest of consumed CU8 blocks (host diagnostics).
} SdrStats;

// Commands on one handle are serialized by the caller. NULL handle, invalid fd,
// or out-of-range parameters return SDR_INVALID_ARGUMENT; wrong state returns
// SDR_INVALID_STATE. Failed open leaves IDLE; failed configure does not commit
// metadata. Each successful open resets counters, last_error and checksum.
// File/USB fd is borrowed: native duplicates it and closes only its duplicate.
// File callers may close the original immediately after open returns. USB
// callers MUST keep the Java UsbDeviceConnection/original fd alive until native
// close/destroy returns, even after stop, and grant exclusive native access:
// Dart and native must never stream the same USB device concurrently.
SDRCORE_API int32_t sdr_v2_open_file(SdrHandle* handle, int32_t fd,
                                      uint32_t samples_per_second);
SDRCORE_API int32_t sdr_v2_open_synthetic(SdrHandle* handle,
                                           uint32_t samples_per_second);
SDRCORE_API int32_t sdr_v2_open_usb(SdrHandle* handle, int32_t fd,
                                     uint32_t source);
// Configure only in OPEN, including between stop and restart; USB must be
// configured before start. File/synthetic changes metadata only. No live retune.
SDRCORE_API int32_t sdr_v2_configure(SdrHandle* handle, uint64_t frequency_hz,
                                      uint32_t samples_per_second,
                                      int32_t gain_tenths_db);
// start: OPEN -> RUNNING; an asynchronous reader failure yields ERROR and
// last_error until stop. stop: RUNNING/ERROR -> OPEN, joins/drains workers and
// preserves counters/last_error. close: OPEN/RUNNING/ERROR -> IDLE, joins workers
// and releases native fd; a second close in IDLE is INVALID_STATE. destroy
// performs stop/close if needed. After stop, input=processed+dropped for complete
// IQ pairs. The bounded eight-slot, 8192-byte/slot native ring drops *new* pairs
// on overflow; no FFI callback or Dart object ever owns its IQ buffers.
SDRCORE_API int32_t sdr_v2_start(SdrHandle* handle);
SDRCORE_API int32_t sdr_v2_stop(SdrHandle* handle);
SDRCORE_API int32_t sdr_v2_close(SdrHandle* handle);
SDRCORE_API int32_t sdr_v2_stats(SdrHandle* handle, SdrStats* stats);

#ifdef __cplusplus
}
#endif

#endif  // SDRCORE_H
