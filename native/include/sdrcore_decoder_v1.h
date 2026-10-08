// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef SDRCORE_DECODER_V1_H
#define SDRCORE_DECODER_V1_H

#include "sdrcore_v3.h"

#ifdef __cplusplus
extern "C" {
#endif

// Additive decoder extension to a v3 radio handle. Never modify v3 structs.
// Discover support with sdr_decoder_version()==1; missing symbols mean no
// decoder extension (voice demodulation remains fully functional).
#define SDR_DECODER_REVISION 1u
#define SDR_DECODER_MAX_PAYLOAD 65536u
#define SDR_DECODER_QUEUE_CAPACITY 256u
#define SDR_DECODER_NO_DATA 1
#define SDR_DECODER_BUFFER_SMALL -7

enum SdrDecoderInput { SDR_DECODER_AUDIO = 1, SDR_DECODER_MPX = 2,
                       SDR_DECODER_BASEBAND = 3, SDR_DECODER_RAW_IQ = 4 };
enum SdrDecoderResult { SDR_DECODER_MESSAGE = 1, SDR_DECODER_IMAGE_PROGRESS = 2,
                        SDR_DECODER_IMAGE_COMPLETE = 3, SDR_DECODER_AIRCRAFT = 4 };

typedef struct SdrDecoderDescriptor {
  uint32_t size;                  // sizeof(SdrDecoderDescriptor)
  uint32_t revision;              // 1
  char id[32];                    // NUL-terminated stable ASCII ID
  uint32_t input;                 // SdrDecoderInput
  uint32_t exclusive_receiver;    // 0/1, full-band modes require 1
  uint32_t required_mode;         // SdrV3Mode, UINT32_MAX if independent
  uint32_t required_rate_hz;      // 0 if determined by backend
  uint32_t result;                // SdrDecoderResult
  uint32_t available;             // 1 only when a real backend is installed
} SdrDecoderDescriptor;

typedef struct SdrDecoderEvent {
  uint32_t size;                  // sizeof(SdrDecoderEvent)
  uint32_t revision;              // 1
  uint64_t sequence;              // Monotonic per handle; never zero
  uint64_t stream_generation;     // v3 generation, for stale-result rejection
  uint32_t kind;                  // SdrDecoderResult
  uint32_t payload_bytes;         // Required UTF-8 JSON bytes or image bytes
  uint64_t dropped_events;        // Cumulative FIFO overflow since selection
} SdrDecoderEvent;

SDRCORE_API uint32_t sdr_decoder_version(void);
// Count-only: index >= count returns SDR_INVALID_ARGUMENT. Caller initializes
// size/revision and zeroes the whole descriptor; failure leaves it unchanged.
SDRCORE_API int32_t sdr_decoder_count(uint32_t* count);
SDRCORE_API int32_t sdr_decoder_descriptor(uint32_t index,
                                           SdrDecoderDescriptor* descriptor);
// Only installed backends can be selected. NULL/empty ID deselects. Config
// is UTF-8 JSON, schema versioned by decoder ID; copied before return.
// Serialise commands with v3 start/stop/controls on this handle. A failed
// select (including unavailable/exclusive while listening) leaves receiver,
// audio, prior decoder and tuning unchanged. No second USB claim. Selection
// never starts the receiver and never mutes voice audio implicitly.
SDRCORE_API int32_t sdr_decoder_select(SdrHandle* handle, const char* id,
                                       uint32_t id_bytes, const char* config,
                                       uint32_t config_bytes);
// OLDEST queued event newer than after_sequence. A bounded 256-entry FIFO
// drops oldest on overflow and reports a cumulative dropped_events counter.
// Poll on UI thread only for low-rate
// results. NO_DATA leaves outputs unchanged; BUFFER_SMALL writes only
// event.payload_bytes. On success outputs are coherent copies, never retained.
// Stop/deselect/retune/generation change/close/destroy invalidate events.
// No IQ/PCM crosses this boundary.
SDRCORE_API int32_t sdr_decoder_poll(SdrHandle* handle, uint64_t after_sequence,
                                     SdrDecoderEvent* event, uint8_t* payload,
                                     uint32_t capacity);

#ifdef __cplusplus
}
#endif
#endif
