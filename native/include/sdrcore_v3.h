// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef SDRCORE_V3_H
#define SDRCORE_V3_H

#include "sdrcore.h"

#ifdef __cplusplus
extern "C" {
#endif

// N2 radio API, implemented when sdr_version() returns 3.
// Existing ABI-1/2 signatures, SdrStats layout, enums and host-only
// sdr_host_* extension remain unchanged. Clients MUST check sdr_version()==3
// before resolving any sdr_v3_* symbol or creating a production controller.
#define SDR_V3_REVISION 3u
#define SDR_V3_MAX_FFT_WIDTH 2048u
#define SDR_V3_MAX_SINK_SPEC_BYTES 1024u

// Additional result values used only by v3 pollers (v2 values remain stable).
#define SDR_V3_NO_DATA 1       // No newer FFT row; no output buffer modified.
#define SDR_V3_BUFFER_SMALL -7 // Metadata.width gives required bin capacity.
// Network-only failures in the asynchronous snapshot (never USB errors).
#define SDR_V3_TCP_TIMEOUT -8
#define SDR_V3_TCP_REFUSED -9
#define SDR_V3_TCP_PROTOCOL -10

enum SdrV3Mode {
  SDR_V3_NFM = 0, SDR_V3_WFM = 1, SDR_V3_AM = 2, SDR_V3_DSB = 3,
  SDR_V3_USB = 4, SDR_V3_CW = 5, SDR_V3_LSB = 6, SDR_V3_RAW = 7
};
enum SdrV3Squelch {
  SDR_V3_SQUELCH_OFF = 0, SDR_V3_SQUELCH_MANUAL = 1,
  SDR_V3_SQUELCH_AUTO = 2
};

// All structures use their exact sizeof and revision=3. All reserved input
// fields and padding bytes must be zero; nonzero reserved fields are invalid.
// A size or revision mismatch
// is SDR_INVALID_ARGUMENT without changing native state or output memory.
// Caller owns each input structure until the synchronous call returns; native
// copies its values, never retains the pointer. All frequencies/rates are Hz.
typedef struct SdrV3Controls {
  uint32_t size;
  uint32_t revision;
  uint64_t center_frequency_hz; // Hardware LO, range of ABI 2 configure.
  int64_t vfo_offset_hz;         // Reference-point displacement from LO.
  uint32_t sample_rate;          // Complex IQ pairs/s, 1000..20000000.
  uint32_t mode;                 // SdrV3Mode (SDR++ DemodMode ids).
  uint32_t bandwidth_hz;         // Channel filter width, within mode limits.
  int32_t gain_tenths_db;        // ABI 2 range; ignored by hardware if AGC on.
  uint32_t agc;                 // 0/1 hardware gain AGC (if device supports it).
  uint32_t squelch;             // SdrV3Squelch; auto only on supported modes.
  float squelch_level_db;        // Manual power threshold [-100, 0] dBFS.
  float auto_squelch_offset_db;  // Auto threshold adjustment [-10, 20] dB.
  float volume;                 // [0, 1], applied as volume*volume to PCM.
  uint32_t muted;               // 0/1; independent of volume, cold start muted.
  uint32_t reserved;            // Must be zero.
} SdrV3Controls;

typedef struct SdrV3Display {
  uint32_t size;
  uint32_t revision;
  int64_t view_offset_hz;  // Offset of displayed band's center from LO.
  uint32_t view_bandwidth_hz; // >0, <= sample_rate; must fit IQ passband.
  uint32_t width;             // 1..SDR_V3_MAX_FFT_WIDTH; FFT max-decimated.
} SdrV3Display;

// Snapshot is authoritative for asynchronous state and applied configuration.
// Counters are cumulative since the last successful open (except generation).
// audio_* count stereo PCM frames at the selected sink, not input IQ pairs.
// last_error is the first async failure since successful open, sticky across
// stop; error_sequence increments on every distinct async failure. Command
// validation errors return synchronously and do not change last_error.
typedef struct SdrV3Snapshot {
  uint32_t size;
  uint32_t revision;
  uint32_t state;               // SdrState IDLE/OPEN/RUNNING/ERROR.
  uint32_t source;              // SdrSource.
  int32_t last_error;           // SdrResult, 0 if none.
  uint32_t sample_rate;
  uint64_t center_frequency_hz; // Last applied LO; not requested UI tune.
  int64_t vfo_offset_hz;        // Last applied reference offset.
  uint32_t mode;                // SdrV3Mode, 0 if not configured.
  uint32_t bandwidth_hz;
  int32_t gain_tenths_db;
  uint32_t squelch_open;        // 0/1, measured in this stream generation.
  uint32_t squelch_ready;       // 0 until the detector has learnt threshold.
  uint32_t reserved;            // Always zero.
  float squelch_metric_db;      // Only valid when squelch_ready == 1.
  float squelch_threshold_db;   // Only valid when squelch_ready == 1.
  uint64_t stream_generation;   // Advances at every successful v3 start.
  uint64_t control_sequence;    // Advances on successful controls/display/stereo.
  uint64_t error_sequence;      // Advances on every async error.
  uint64_t input_samples;       // Complex IQ pairs accepted at ingress.
  uint64_t processed_samples;   // Complex IQ pairs consumed by DSP.
  uint64_t dropped_samples;     // Native IQ ring overflow, NOT USB losses.
  uint64_t audio_frames;        // Stereo frames accepted by the audio sink.
  uint64_t audio_dropped_frames; // Stereo frames lost by the sink.
  uint64_t audio_nonsilent_frames;
  uint64_t fft_overwrites;      // Replaced rows before a poller read them.
} SdrV3Snapshot;

// Metadata only; bins are supplied separately. dBFS power and max-decimation
// match RadioController.FftRow. Bin i spans [low_hz+i*w,low_hz+(i+1)*w),
// w=(high_hz-low_hz)/width. Timestamp uses CLOCK_MONOTONIC nanoseconds.
typedef struct SdrV3Fft {
  uint32_t size;
  uint32_t revision;
  uint64_t sequence;            // Monotonic per handle; 0 is no row.
  uint64_t stream_generation;
  uint64_t control_sequence;
  uint64_t monotonic_ns;
  int64_t low_hz;
  int64_t high_hz;
  uint32_t width;               // 1..2048, required capacity on BUFFER_SMALL.
  uint32_t reserved;            // Always zero.
} SdrV3Fft;

// Reuse sdr_create, v2 open_file/open_synthetic/open_usb or sdr_host_open_usb.
// The v2 open functions still duplicate borrowed fds. Exactly one handle may
// claim a physical USB device.
// Network endpoint: IDLE -> OPEN without DNS, connection or USB claim. Copies
// 1..255 UTF-8 host bytes (no NUL) and port 1..65535. The v3 producer resolves,
// connects and validates the RTL0 handshake asynchronously after v3_start;
// a finite connect/handshake deadline and v3_stop cancel it. No silent fallback.
// On restart, the endpoint and last accepted controls are reapplied. The
// rtl_tcp source supports RTL rates 225001..300000 or 900001..3200000 S/s,
// 32-bit RF Hz, manual gain; AGC and extended server controls are unsupported.
SDRCORE_API int32_t sdr_v3_open_rtl_tcp(SdrHandle* handle,
                                         const char* host, uint32_t host_bytes,
                                         uint16_t port);
// Only for an OPEN/RUNNING RTL_TCP handle: 0=connecting/not started,
// 1=header validated and IQ stream active. Negative SdrResult on wrong
// handle/state; connection failures are in snapshot.last_error/state=ERROR.
SDRCORE_API int32_t sdr_v3_rtl_tcp_link(SdrHandle* handle);
// set_controls: OPEN or RUNNING; validates all fields before committing. With
// unchanged LO/rate/gain, a RUNNING VFO/mode/bandwidth/squelch/audio change
// reconfigures DSP without USB retune. On a RUNNING session whose USB driver
// tunes while streaming (RTL-SDR), an LO and/or gain change with an unchanged
// sample rate is applied live: the stream, audio sink and stream_generation
// are kept and queued pre-retune IQ is discarded. Such a live change is only
// ACCEPTED synchronously (control_sequence advances before return, no USB
// control transfer on the calling thread); a native tuner worker applies the
// newest accepted request (latest wins, intermediate requests may be
// skipped). snapshot.center_frequency_hz/gain_tenths_db switch when the tuner
// has really been reprogrammed, and FFT rows carrying the new control_sequence
// are computed only from IQ captured after that. A failed live retune is an
// async SDR_ERROR (error_sequence advances). stop/close/destroy wait for an
// in-flight tuner write and drop requests not yet applied.
// Other hardware changes (sample rate; LO/gain on HackRF and non-USB sources)
// serialize an internal stop -> configure -> restart before returning. On
// failure report the error;
// snapshot reflects actual applied state, never a fictitious requested tune.
// Any unrecoverable partial hardware change leaves SDR_ERROR, not RUNNING.
SDRCORE_API int32_t sdr_v3_set_controls(SdrHandle* handle,
                                          const SdrV3Controls* controls);
// OPEN or RUNNING. Does not retune hardware; affects subsequent FFT rows.
SDRCORE_API int32_t sdr_v3_set_display(SdrHandle* handle,
                                         const SdrV3Display* display);
// OPEN (after accepted v3 controls) or RUNNING v3 session. enabled is strictly
// 0/1; default 0 on every open. Preference remains set in non-WFM modes but
// only affects WFM DSP. Applies in-place without hardware retune or stream
// generation change. Success (including an unchanged value) advances
// control_sequence and invalidates the latest FFT row, like set_display;
// rejection changes neither epoch nor audio state. Caller serializes commands.
SDRCORE_API int32_t sdr_v3_set_wfm_stereo(SdrHandle* handle, uint32_t enabled);
// OPEN only. Copies exactly byte_count UTF-8 bytes, no trailing NUL and no
// embedded NUL. 1..1024 bytes; native owns the copy. Specs: "null", "wav:<path>",
// "alsa[:<pcm>]" (Linux), "aaudio" (Android). Unsupported backend returns
// SDR_UNSUPPORTED, and no old sink is replaced on failure. Default: Linux
// "null" (headless), Android "aaudio". Does not pass PCM over FFI.
SDRCORE_API int32_t sdr_v3_set_audio_sink(SdrHandle* handle,
                                            const char* spec, uint32_t byte_count);
// start: OPEN -> RUNNING; requires accepted controls, audio sink/focus and
// foreground permission on Android. Synchronous success means audio/USB/DSP
// workers started. Async failures become sticky snapshot SDR_ERROR. stop:
// RUNNING/ERROR -> OPEN, synchronously joins USB/DSP/audio and drains slots;
// second stop is INVALID_STATE. v2 diagnostic start/stop must NOT operate on
// an active v3 session. v2 close and sdr_destroy synchronously tear down either
// session, release all fds and audio, and invalidate FFT before returning.
SDRCORE_API int32_t sdr_v3_start(SdrHandle* handle);
SDRCORE_API int32_t sdr_v3_stop(SdrHandle* handle);
// Caller initializes size/revision. Atomic snapshot; may be polled alongside
// serialized commands, but must finish before destroy. No Dart callbacks.
SDRCORE_API int32_t sdr_v3_snapshot(SdrHandle* handle,
                                      SdrV3Snapshot* snapshot);
// Poll only the latest completed FFT row newer than after_sequence. Caller
// initializes metadata.size/revision and owns `bins` (float[capacity]); native
// copies into both outputs before return and never retains either pointer.
// NO_DATA leaves both outputs unchanged. BUFFER_SMALL writes only metadata.width
// with the required capacity; bins and other metadata stay unchanged. Other
// failures leave both outputs unchanged. On success bins[0..width) and all
// metadata are a coherent row. max width 2048, at most 30 rows/s; no queue.
// stop/close/error invalidate the row; old rows must not survive restart.
SDRCORE_API int32_t sdr_v3_read_fft(SdrHandle* handle,
                                      uint64_t after_sequence,
                                      SdrV3Fft* metadata,
                                      float* bins, uint32_t capacity);

// Returns the RTL-SDR tuner's supported gain values in tenths of a dB,
// sorted ascending, exactly matching the old Dart engine's
// `RtlSdrDev.getTunerGains()..sort()` table and index order. Requires the
// handle to already be OPEN/RUNNING on a native SDR_RTLSDR USB session
// (sdr_v2_open_usb/sdr_host_open_usb with source=SDR_RTLSDR, or the v3
// equivalent once set_controls has committed the hardware claim); this call
// never performs a second USB device claim, only queries the existing
// open rtlsdr handle. `capacity`==0 with `gains`==NULL is a valid
// count-only probe: `count` receives the required capacity and the call
// returns SDR_OK without touching `gains`. Insufficient nonzero capacity
// returns SDR_V3_BUFFER_SMALL, `count` still receives the required
// capacity, and `gains` is left unmodified. A non-RTL-SDR source (file,
// synthetic, HackRF) or unknown/undiscoverable tuner returns
// SDR_UNSUPPORTED with `count`=0. NULL handle or NULL `count` returns
// SDR_INVALID_ARGUMENT; wrong state (e.g. IDLE, no USB claim) returns
// SDR_INVALID_STATE. Thread-safe and serialized with the rest of the v3
// control lifecycle: like other v3 commands, callers serialize this call
// with set_controls/start/stop/close on the same handle; it does not race
// destroy.
SDRCORE_API int32_t sdr_v3_rtl_tuner_gains(SdrHandle* handle, int32_t* gains,
                                             uint32_t capacity,
                                             uint32_t* count);

#ifdef __cplusplus
}
#endif

#endif  // SDRCORE_V3_H
