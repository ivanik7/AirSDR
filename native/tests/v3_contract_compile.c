// SPDX-License-Identifier: GPL-3.0-or-later
// Header-only compile check. N2 symbols are NOT linked or exported by ABI 2.
#include "sdrcore_v3.h"

#include <stddef.h>
#include <stdio.h>

_Static_assert(SDR_V3_REVISION == 3u, "ABI revision");
_Static_assert(SDR_V3_MAX_FFT_WIDTH == 2048u, "bounded FFT width");
_Static_assert(sizeof(SdrV3Controls) == 72 &&
                   offsetof(SdrV3Controls, vfo_offset_hz) == 16 &&
                   offsetof(SdrV3Controls, reserved) == 64,
               "control wire layout (64-bit Linux/Android)");
_Static_assert(sizeof(SdrV3Display) == 24 &&
                   offsetof(SdrV3Display, width) == 20,
               "display wire layout");
_Static_assert(sizeof(SdrV3Snapshot) == 152 &&
                   offsetof(SdrV3Snapshot, stream_generation) == 72 &&
                   offsetof(SdrV3Snapshot, fft_overwrites) == 144,
               "snapshot wire layout");
_Static_assert(sizeof(SdrV3Fft) == 64 &&
                   offsetof(SdrV3Fft, sequence) == 8 &&
                   offsetof(SdrV3Fft, width) == 56,
               "FFT wire layout");
_Static_assert(SDR_V3_NO_DATA == 1 && SDR_V3_BUFFER_SMALL == -7,
               "poll result codes");
_Static_assert(SDR_V3_NFM == 0 && SDR_V3_WFM == 1 && SDR_V3_AM == 2 &&
                   SDR_V3_DSB == 3 && SDR_V3_USB == 4 && SDR_V3_CW == 5 &&
                   SDR_V3_LSB == 6 && SDR_V3_RAW == 7, "UI mode IDs");
_Static_assert(SDR_IDLE == 0 && SDR_OPEN == 1 && SDR_RUNNING == 2 &&
                   SDR_ERROR == 3, "v2 states retained");
_Static_assert(_Generic(&sdr_v3_set_controls,
                        int32_t (*)(SdrHandle*, const SdrV3Controls*): 1,
                        default: 0), "control signature");
_Static_assert(_Generic(&sdr_v3_set_display,
                        int32_t (*)(SdrHandle*, const SdrV3Display*): 1,
                        default: 0), "display signature");
_Static_assert(_Generic(&sdr_v3_set_audio_sink,
                        int32_t (*)(SdrHandle*, const char*, uint32_t): 1,
                        default: 0), "sink signature");
_Static_assert(_Generic(&sdr_v3_start,
                        int32_t (*)(SdrHandle*): 1,
                        default: 0), "start signature");
_Static_assert(_Generic(&sdr_v3_stop,
                        int32_t (*)(SdrHandle*): 1,
                        default: 0), "stop signature");
_Static_assert(_Generic(&sdr_v3_snapshot,
                        int32_t (*)(SdrHandle*, SdrV3Snapshot*): 1,
                        default: 0), "snapshot signature");
_Static_assert(_Generic(&sdr_v3_read_fft,
                        int32_t (*)(SdrHandle*, uint64_t, SdrV3Fft*, float*, uint32_t): 1,
                        default: 0), "FFT signature");
_Static_assert(_Generic(&sdr_v3_rtl_tuner_gains,
                        int32_t (*)(SdrHandle*, int32_t*, uint32_t, uint32_t*): 1,
                        default: 0), "RTL tuner gains signature");

// Build this as an object only; linking would falsely claim N2 implementation.
int sdrcore_v3_contract_compile_only(void) {
  return (int)(sizeof(SdrV3Controls) + sizeof(SdrV3Display) +
               sizeof(SdrV3Snapshot) + sizeof(SdrV3Fft) +
               offsetof(SdrV3Snapshot, fft_overwrites));
}
