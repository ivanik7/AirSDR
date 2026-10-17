// SPDX-License-Identifier: GPL-3.0-or-later
//
// The single translation unit holding the vendored miniaudio implementation
// (third_party/miniaudio, public domain / MIT-0). Playback devices only; the
// decoding/encoding/engine layers are compiled out. Built with hidden
// visibility (audio.cmake), so no ma_* symbol is exported from libsdrcore.
// Backend options are set by audio.cmake (see MINIAUDIO.md).
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio_config.h"
#include "miniaudio.h"
