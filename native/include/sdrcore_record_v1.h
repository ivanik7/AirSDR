// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef SDRCORE_RECORD_V1_H
#define SDRCORE_RECORD_V1_H

#include "sdrcore_v3.h"

#ifdef __cplusplus
extern "C" {
#endif

// Additive recording extension to a v3 radio handle (GitHub issue #1).
// Never modifies v3 or decoder v1 structs. Discover it with
// sdr_record_version()==SDR_RECORD_REVISION; missing symbols mean the core
// cannot record. Dataflow, file formats and thread ownership are specified
// in docs/status/recording-contract.md; this header is the binary authority.
//
// Only commands, a folder locator string and a fixed-size status cross FFI.
// IQ, PCM and decoder payload bytes stay native. The DSP consumer offers
// bounded blocks to one native writer per session without waiting for I/O.
// stop (also receiver shutdown) joins that writer and finalizes files.
#define SDR_RECORD_REVISION 1u
#define SDR_RECORD_MAX_FOLDER_BYTES 4096u
#define SDR_RECORD_MAX_LOG_IDS_BYTES 512u
#define SDR_RECORD_MAX_LOG_IDS 16u
#define SDR_RECORD_MAX_NAME_BYTES 255u

// Recording-specific negative results. They never overlap SdrResult (-1..-6)
// or the v3 poll/network codes (-7..-10).
#define SDR_RECORD_EXISTS -20             // Provider: display name taken.
#define SDR_RECORD_NO_SPACE -21           // ENOSPC/EDQUOT/EFBIG.
#define SDR_RECORD_FOLDER_UNAVAILABLE -22 // Removed, unmounted, revoked.
#define SDR_RECORD_NOT_SEEKABLE -23       // fd cannot lseek (pipe, cloud).
#define SDR_RECORD_NAME_EXHAUSTED -24     // _2.._99 suffixes all taken.

// Bitmask of requested outputs; any nonzero combination is legal.
enum SdrRecordStream {
  SDR_RECORD_IQ = 1u,            // Raw CU8 SigMF pair (.sigmf-data/.sigmf-meta).
  SDR_RECORD_AUDIO = 2u,         // One continuous audio file per session.
  SDR_RECORD_SQUELCH_AUDIO = 4u, // One audio file per squelch opening.
  SDR_RECORD_DECODER_LOG = 8u    // One JSON Lines file per selected log id.
};
#define SDR_RECORD_STREAM_MASK 15u

enum SdrRecordFormat {
  SDR_RECORD_FORMAT_NONE = 0, // Only valid when no audio stream is requested.
  SDR_RECORD_WAV = 1,         // RIFF/WAVE 16-bit signed little-endian PCM.
  SDR_RECORD_FLAC = 2,
  SDR_RECORD_MP3 = 3,
  SDR_RECORD_OPUS = 4         // Ogg Opus.
};

enum SdrRecordState {
  SDR_RECORD_IDLE = 0,   // No session; status keeps the last session's values.
  SDR_RECORD_ACTIVE = 1, // Writer running (including initial file creation).
  SDR_RECORD_FAILED = 2  // Session ended by an error; files finalized if possible.
};

enum SdrRecordStopReason {
  SDR_RECORD_STOP_NONE = 0,     // Never recorded or still active.
  SDR_RECORD_STOP_USER = 1,     // sdr_record_stop.
  SDR_RECORD_STOP_RECEIVER = 2, // sdr_v3_stop/v2 close/destroy/async error.
  SDR_RECORD_STOP_ERROR = 3     // File error; see last_error/error_stream.
};

// Caller zero-initializes, sets size=sizeof and revision=SDR_RECORD_REVISION.
// Native copies every field before sdr_record_start returns.
typedef struct SdrRecordConfig {
  uint32_t size;
  uint32_t revision;
  uint32_t streams;            // SdrRecordStream mask, 1..SDR_RECORD_STREAM_MASK.
  uint32_t audio_format;       // SdrRecordFormat; NONE iff no audio stream.
  uint32_t audio_bitrate_kbps; // MP3 32..320, Opus 6..256; otherwise 0.
  int32_t utc_offset_minutes;  // Local offset for file names, -840..840.
  int64_t start_unix_ms;       // Wall clock of the Record press, > 0.
  uint32_t reserved[4];        // Must be zero.
} SdrRecordConfig;

// Atomic caller-owned copy. Counters are cumulative for the current or last
// session and reset only by the next successful sdr_record_start.
typedef struct SdrRecordStatus {
  uint32_t size;
  uint32_t revision;
  uint32_t state;                // SdrRecordState.
  uint32_t stop_reason;          // SdrRecordStopReason.
  int32_t last_error;            // First session error (0, SdrResult, SDR_RECORD_*).
  uint32_t error_stream;         // SdrRecordStream bit that failed, 0 if none.
  uint32_t streams;              // Session stream mask, 0 before any session.
  uint32_t audio_format;         // Session SdrRecordFormat.
  uint32_t audio_sample_rate;    // Rate of the current/last audio file, 0 none.
  uint32_t audio_channels;       // 1 or 2 of the current/last audio file, 0 none.
  uint32_t squelch_segment_open; // 0/1: a per-squelch file is open now.
  uint32_t reserved;             // Always zero.
  uint64_t session_id;           // Monotonic per handle; 0 before any session.
  uint64_t elapsed_ms;           // Monotonic time since start; frozen at end.
  uint64_t bytes_written;        // Actual file lengths: all headers, metadata,
                                 // encoded payload, including header rewrites
                                 // exactly once. Updated after successful I/O.
  uint64_t files_created;        // Files created (a SigMF pair counts as two).
  uint64_t segments_completed;   // Per-squelch files finalized.
  uint64_t iq_samples_written;   // Complex IQ pairs in .sigmf-data files.
  uint64_t audio_frames_written; // Frames in continuous audio files.
  uint64_t iq_dropped_samples;   // Pairs lost to the bounded IQ queue.
  uint64_t audio_dropped_frames; // Frames lost to the bounded audio queue.
  uint64_t log_events_written;   // JSON lines written.
  uint64_t log_dropped_events;   // Decoder events lost to the log queue.
} SdrRecordStatus;

// Platform folder provider: creates one new file named display_name (UTF-8,
// no path separators, extension included) inside `folder` and returns an
// owned, seekable, read/write file descriptor in *out_fd. Native takes
// ownership and closes it (POSIX close / Windows _close). Returns SDR_OK,
// SDR_RECORD_EXISTS (native retries with a numeric suffix), or
// SDR_RECORD_FOLDER_UNAVAILABLE / SDR_RECORD_NO_SPACE / SDR_IO_ERROR. It is
// called only on the native recorder writer thread, never on the DSP
// thread or the Dart UI isolate; provider calls are serialized process-wide.
// The provider must return an fd opened exclusively for this name and must
// never truncate an existing file. On failure it must not leak an fd or
// retain any borrowed pointer. An Android JNI provider attaches that thread
// to the VM and obtains the fd via ContentResolver/DocumentFile. fd offsets
// must support seek for WAV/FLAC/MP3/Ogg finalization; reject pipes instead
// of emitting invalid output. Removing a partially created file is best effort
// (the fd bridge cannot promise provider-atomic rollback).
// mime_type is e.g. "audio/wav", "application/octet-stream".
typedef int32_t (*SdrRecordCreateFile)(void* context, const char* folder,
                                       uint32_t folder_bytes,
                                       const char* display_name,
                                       uint32_t name_bytes,
                                       const char* mime_type, int32_t* out_fd);

// Optional low-rate notification of an ACTIVE -> IDLE/FAILED transition.
// Called once per transition on the writer thread AFTER status is published,
// without a handle or provider lock held. `status` is a borrowed snapshot:
// copy it before returning. Context and function must remain alive until
// sdr_record_set_notify(NULL) or destroy returns; those calls wait for any
// in-flight callback. Callback must not call a command or destroy on the same
// handle. Dart must poll status or use a NativeCallable.listener, NEVER a
// synchronous Dart FFI callback from the native writer thread.
typedef void (*SdrRecordNotify)(void* context, const SdrRecordStatus* status);

SDRCORE_API uint32_t sdr_record_version(void);

// Writes the SdrRecordStream / (1u << SdrRecordFormat) masks this build can
// actually produce. A bit is set only when a real writer/encoder is linked;
// an unsupported request is never accepted. Either pointer may be NULL.
SDRCORE_API int32_t sdr_record_capabilities(uint32_t* streams,
                                            uint32_t* formats);

// Registers the provider for locators "<scheme>:..." (1..16 bytes of
// [a-z0-9+.-], first a letter, no ':'). Replaces an earlier registration;
// fn==NULL unregisters. After return no call of a replaced provider is in
// flight. "file" is built in (absolute native path after "file:", POSIX
// open(O_CREAT|O_EXCL) / Windows _wopen) and cannot be replaced. Android
// registers "content" from its JNI layer (DocumentsContract + detachFd);
// a SAF tree URI is never treated as a filesystem path.
SDRCORE_API int32_t sdr_record_set_provider(const char* scheme,
                                            uint32_t scheme_bytes,
                                            SdrRecordCreateFile fn,
                                            void* context);
SDRCORE_API int32_t sdr_record_set_notify(SdrHandle* handle,
                                          SdrRecordNotify fn, void* context);

// Starts a session on a RUNNING v3 handle. folder: 1..4096 UTF-8 bytes, no
// NUL, "file:<absolute path>" or "<registered scheme>:...". log_ids: for
// DECODER_LOG only, comma-separated available decoder ids or "rds", 1..16
// unique ids, at most 512 bytes; otherwise NULL/0. Result order:
// INVALID_ARGUMENT (malformed config/folder/ids), INVALID_STATE (handle not
// RUNNING or a session ACTIVE), UNSUPPORTED (stream/format/scheme not in
// capabilities). The first file is created asynchronously: creation errors
// surface as status FAILED, never by blocking this call. Retune, mode, VFO,
// squelch, mute, volume, WFM stereo and decoder selection changes keep the
// session running. Commands are serialized with v3/decoder commands.
SDRCORE_API int32_t sdr_record_start(SdrHandle* handle,
                                     const SdrRecordConfig* config,
                                     const char* folder, uint32_t folder_bytes,
                                     const char* log_ids,
                                     uint32_t log_ids_bytes);

// ACTIVE -> IDLE: drains queued data, finalizes and closes every file and
// joins the writer before returning (bounded by the queues). A FAILED
// session is already finalized; stop acknowledges it (FAILED -> IDLE) and
// keeps its counters/error. IDLE returns SDR_INVALID_STATE.
// sdr_v3_stop, sdr_v2_close and sdr_destroy end a session the same way with
// stop_reason RECEIVER.
SDRCORE_API int32_t sdr_record_stop(SdrHandle* handle);

// Caller initializes size/revision. May run concurrently with commands and
// with sdr_v3_snapshot/read_fft polls, but not with destroy.
SDRCORE_API int32_t sdr_record_status(SdrHandle* handle,
                                      SdrRecordStatus* status);

#ifdef __cplusplus
}
#endif
#endif
