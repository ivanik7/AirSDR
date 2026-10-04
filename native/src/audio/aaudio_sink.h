// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef SDRCORE_AAUDIO_SINK_H
#define SDRCORE_AAUDIO_SINK_H

#include <memory>
#include "audio_sink.h"

namespace sdrcore {
std::unique_ptr<AudioSink> make_aaudio_sink();
}  // namespace sdrcore

#endif  // SDRCORE_AAUDIO_SINK_H
