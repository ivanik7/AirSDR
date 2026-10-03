// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef SDRCORE_AUDIO_NULL_SINK_H
#define SDRCORE_AUDIO_NULL_SINK_H

#include <memory>

#include "audio_sink.h"

namespace sdrcore {

// Discards audio while still counting frames/peaks; used headlessly and as
// the default/fallback backend. Always available on every platform.
std::unique_ptr<AudioSink> make_null_sink();

}  // namespace sdrcore

#endif  // SDRCORE_AUDIO_NULL_SINK_H
