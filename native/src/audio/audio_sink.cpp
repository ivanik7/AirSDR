// SPDX-License-Identifier: GPL-3.0-or-later
#include "audio_sink.h"

#include <cstring>

#include "audio_internal.h"
#include "null_sink.h"
#include "wav_sink.h"
#ifdef SDRCORE_HAVE_ALSA
#include "alsa_sink.h"
#endif
#ifdef __ANDROID__
#include "aaudio_sink.h"
#endif

namespace sdrcore {

bool parse_audio_sink_spec(const char* spec, AudioSinkSpec* out) {
  const std::string s = (spec == nullptr) ? std::string() : std::string(spec);

  if (s.empty() || s == "null") {
    out->kind = AudioSinkKind::kNull;
    out->target.clear();
    return true;
  }
  if (s == "aaudio") {
    out->kind = AudioSinkKind::kAAudio;
    out->target.clear();
    return true;
  }
  if (s == "alsa") {
    out->kind = AudioSinkKind::kAlsa;
    out->target = "default";
    return true;
  }
  constexpr char kAlsaPrefix[] = "alsa:";
  constexpr size_t kAlsaPrefixLen = sizeof(kAlsaPrefix) - 1;
  if (s.compare(0, kAlsaPrefixLen, kAlsaPrefix) == 0) {
    std::string pcm = s.substr(kAlsaPrefixLen);
    if (pcm.empty()) return false;
    out->kind = AudioSinkKind::kAlsa;
    out->target = std::move(pcm);
    return true;
  }
  constexpr char kWavPrefix[] = "wav:";
  constexpr size_t kWavPrefixLen = sizeof(kWavPrefix) - 1;
  if (s.compare(0, kWavPrefixLen, kWavPrefix) == 0) {
    std::string path = s.substr(kWavPrefixLen);
    if (path.empty()) return false;
    out->kind = AudioSinkKind::kWav;
    out->target = std::move(path);
    return true;
  }
  return false;
}

std::unique_ptr<AudioSink> make_audio_sink(const AudioSinkSpec& spec) {
  switch (spec.kind) {
    case AudioSinkKind::kNull:
      return make_null_sink();
    case AudioSinkKind::kWav:
      return make_wav_sink(spec.target);
    case AudioSinkKind::kAlsa:
#ifdef SDRCORE_HAVE_ALSA
      return make_alsa_sink(spec.target.empty() ? "default" : spec.target);
#else
      // ALSA backend not compiled on this platform (e.g. Android).
      return nullptr;
#endif
    case AudioSinkKind::kAAudio:
#ifdef __ANDROID__
      return make_aaudio_sink();
#else
      return nullptr;
#endif
  }
  return nullptr;
}

}  // namespace sdrcore
