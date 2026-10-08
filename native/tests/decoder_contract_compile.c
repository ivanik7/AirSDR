// SPDX-License-Identifier: GPL-3.0-or-later
// Header-only compile check for the additive decoder extension ABI
// (native/include/sdrcore_decoder_v1.h). Mirrors v3_contract_compile.c: build
// as an OBJECT only, never link, so this file can never be mistaken for a
// decoder engine implementation.
#include "sdrcore_decoder_v1.h"

#include <stddef.h>
#include <stdint.h>

_Static_assert(SDR_DECODER_REVISION == 1u, "decoder ABI revision");
_Static_assert(SDR_DECODER_MAX_PAYLOAD == 65536u, "bounded payload");
_Static_assert(SDR_DECODER_NO_DATA == 1 && SDR_DECODER_BUFFER_SMALL == -7,
               "decoder poll result codes shared with v3 FFT poll codes");
_Static_assert(SDR_DECODER_AUDIO == 1 && SDR_DECODER_MPX == 2 &&
                   SDR_DECODER_BASEBAND == 3 && SDR_DECODER_RAW_IQ == 4,
               "decoder input enum");
_Static_assert(SDR_DECODER_MESSAGE == 1 && SDR_DECODER_IMAGE_PROGRESS == 2 &&
                   SDR_DECODER_IMAGE_COMPLETE == 3 && SDR_DECODER_AIRCRAFT == 4,
               "decoder result enum");
_Static_assert(sizeof(SdrDecoderDescriptor) == 64 &&
                   offsetof(SdrDecoderDescriptor, id) == 8 &&
                   offsetof(SdrDecoderDescriptor, input) == 40 &&
                   offsetof(SdrDecoderDescriptor, available) == 60,
               "decoder descriptor wire layout");
_Static_assert(sizeof(SdrDecoderEvent) == 32 &&
                   offsetof(SdrDecoderEvent, sequence) == 8 &&
                   offsetof(SdrDecoderEvent, kind) == 24,
               "decoder event wire layout");
_Static_assert(_Generic(&sdr_decoder_version,
                        uint32_t (*)(void): 1,
                        default: 0), "version signature");
_Static_assert(_Generic(&sdr_decoder_count,
                        int32_t (*)(uint32_t*): 1,
                        default: 0), "count signature");
_Static_assert(_Generic(&sdr_decoder_descriptor,
                        int32_t (*)(uint32_t, SdrDecoderDescriptor*): 1,
                        default: 0), "descriptor signature");
_Static_assert(_Generic(&sdr_decoder_select,
                        int32_t (*)(SdrHandle*, const char*, uint32_t,
                                    const char*, uint32_t): 1,
                        default: 0), "select signature");
_Static_assert(_Generic(&sdr_decoder_poll,
                        int32_t (*)(SdrHandle*, uint64_t, SdrDecoderEvent*,
                                    uint8_t*, uint32_t): 1,
                        default: 0), "poll signature");

// Build this as an object only; linking would falsely claim implementation.
int sdrcore_decoder_v1_contract_compile_only(void) {
  return (int)(sizeof(SdrDecoderDescriptor) + sizeof(SdrDecoderEvent));
}
