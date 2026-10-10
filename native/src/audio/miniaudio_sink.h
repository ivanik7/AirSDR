// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef SDRCORE_MINIAUDIO_SINK_H
#define SDRCORE_MINIAUDIO_SINK_H

#include <memory>
#include <string>

#include "audio_sink.h"

namespace sdrcore {
// target "" = the system default output device on the platform's default
// backend list (CoreAudio, WASAPI, PulseAudio/ALSA); "null" = miniaudio's
// null backend (real-time paced callback, no device). Desktop builds only.
std::unique_ptr<AudioSink> make_miniaudio_sink(std::string target);
}  // namespace sdrcore

#endif  // SDRCORE_MINIAUDIO_SINK_H
