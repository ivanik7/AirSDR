// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef SDRCORE_AUDIO_WAV_SINK_H
#define SDRCORE_AUDIO_WAV_SINK_H

#include <memory>
#include <string>

#include "audio_sink.h"

namespace sdrcore {

// Writes a 16-bit PCM stereo RIFF/WAVE file at `path`. The file is created
// (truncated) on open(); open() fails with SDR_IO_ERROR if the path cannot
// be opened for writing.
std::unique_ptr<AudioSink> make_wav_sink(std::string path);

}  // namespace sdrcore

#endif  // SDRCORE_AUDIO_WAV_SINK_H
