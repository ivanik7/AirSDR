// SPDX-License-Identifier: GPL-3.0-or-later
// ABI marshalling fixture ONLY: no disk, audio, IQ or production recorder.
#include "sdrcore_record_v1.h"
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default")))
#endif

_Static_assert(sizeof(SdrRecordConfig) == 48, "record config layout changed");
_Static_assert(offsetof(SdrRecordConfig, start_unix_ms) == 24, "start offset");
_Static_assert(offsetof(SdrRecordStatus, session_id) == 48, "status offset");
_Static_assert(sizeof(SdrRecordStatus) == 136, "record status layout changed");

static SdrRecordStatus snapshot;
static SdrRecordNotify notify;
static void* notify_context;
static uint32_t notifications;
static SdrRecordCreateFile provider;
static void* provider_context;
static char captured_folder[4097];
static char captured_ids[513];

EXPORT uint32_t sdr_record_version(void) { return SDR_RECORD_REVISION; }
EXPORT int32_t sdr_record_capabilities(uint32_t* streams, uint32_t* formats) {
  if (streams) *streams = SDR_RECORD_STREAM_MASK;
  if (formats) *formats = (1u << SDR_RECORD_WAV);
  return SDR_OK;
}
EXPORT int32_t sdr_record_set_provider(const char* scheme, uint32_t len,
                                       SdrRecordCreateFile fn, void* context) {
  if (!scheme || len != 7 || memcmp(scheme, "content", 7)) return SDR_INVALID_ARGUMENT;
  provider = fn;
  provider_context = context;
  return SDR_OK;
}
EXPORT int32_t sdr_record_set_notify(SdrHandle* h, SdrRecordNotify fn, void* context) {
  if (!h) return SDR_INVALID_ARGUMENT;
  notify = fn;
  notify_context = context;
  return SDR_OK;
}
EXPORT int32_t sdr_record_start(SdrHandle* h, const SdrRecordConfig* c,
                                const char* folder, uint32_t folder_len,
                                const char* ids, uint32_t ids_len) {
  if (!h || !c || !folder || folder_len > 4096 || ids_len > 512 ||
      (ids_len && !ids) || c->size != sizeof(*c) ||
      c->revision != SDR_RECORD_REVISION) return SDR_INVALID_ARGUMENT;
  memcpy(captured_folder, folder, folder_len);
  captured_folder[folder_len] = 0;
  if (ids_len) memcpy(captured_ids, ids, ids_len);
  captured_ids[ids_len] = 0;
  memset(&snapshot, 0, sizeof(snapshot));
  snapshot.size = sizeof(snapshot);
  snapshot.revision = SDR_RECORD_REVISION;
  snapshot.state = SDR_RECORD_ACTIVE;
  snapshot.streams = c->streams;
  snapshot.audio_format = c->audio_format;
  snapshot.session_id = (uint64_t)c->start_unix_ms;
  snapshot.elapsed_ms = (uint64_t)c->utc_offset_minutes;
  snapshot.bytes_written = (uint64_t)c->audio_bitrate_kbps;
  // Allow a fixture-only provider callback to exercise the native signature.
  if (provider && folder_len >= 8 && !memcmp(folder, "content:", 8)) {
    int32_t fd = -1;
    int32_t rc = provider(provider_context, folder, folder_len,
                          "record.wav", 10, "audio/wav", &fd);
    if (rc != SDR_OK) {
      snapshot.state = SDR_RECORD_FAILED;
      snapshot.stop_reason = SDR_RECORD_STOP_ERROR;
      snapshot.last_error = rc;
      snapshot.error_stream = SDR_RECORD_AUDIO;
      if (notify) { ++notifications; notify(notify_context, &snapshot); }
    }
  }
  return SDR_OK;
}
EXPORT int32_t sdr_record_stop(SdrHandle* h) {
  if (!h) return SDR_INVALID_ARGUMENT;
  if (snapshot.state == SDR_RECORD_IDLE) return SDR_INVALID_STATE;
  if (snapshot.state == SDR_RECORD_ACTIVE) {
    snapshot.stop_reason = SDR_RECORD_STOP_USER;
    snapshot.state = SDR_RECORD_IDLE;
    if (notify) { ++notifications; notify(notify_context, &snapshot); }
  } else {
    snapshot.state = SDR_RECORD_IDLE;
  }
  return SDR_OK;
}
EXPORT int32_t sdr_record_status(SdrHandle* h, SdrRecordStatus* out) {
  if (!h || !out || out->size != sizeof(*out) ||
      out->revision != SDR_RECORD_REVISION) return SDR_INVALID_ARGUMENT;
  memcpy(out, &snapshot, sizeof(*out));
  return SDR_OK;
}
EXPORT const char* sdr_record_test_folder(void) { return captured_folder; }
EXPORT const char* sdr_record_test_ids(void) { return captured_ids; }
EXPORT uint32_t sdr_record_test_notifications(void) { return notifications; }
