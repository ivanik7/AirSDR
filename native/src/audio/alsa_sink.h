// SPDX-License-Identifier: GPL-3.0-or-later
//
// Declaration only; safe to include unconditionally (it drags in no ALSA
// headers). Only compiled/linked when SDRCORE_HAVE_ALSA is defined (Linux
// host build with ALSA found; see audio.cmake). Android never defines it.
#ifndef SDRCORE_AUDIO_ALSA_SINK_H
#define SDRCORE_AUDIO_ALSA_SINK_H

#include <memory>
#include <string>

#include "audio_sink.h"

namespace sdrcore {

// ALSA playback sink targeting PCM device `pcm_name` (e.g. "default").
// Never blocks: a full device buffer drops the block instead of waiting.
std::unique_ptr<AudioSink> make_alsa_sink(std::string pcm_name);

}  // namespace sdrcore

#endif  // SDRCORE_AUDIO_ALSA_SINK_H
