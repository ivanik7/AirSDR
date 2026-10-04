// SPDX-License-Identifier: GPL-3.0-or-later
//
// Internal audio sink contract of libsdrcore (L1). Not part of the public C
// ABI (native/include/sdrcore.h) and not exported from libsdrcore.so.
//
// N2 plugs its demodulator output into this interface; L1 provides the
// backends and their tests only. No audio sample ever crosses into Dart.
//
// Format: interleaved stereo float32 frames (L, R) in [-1, 1] at the sample
// rate given to open(). Values outside the range are clipped by backends
// that need integers (WAV/ALSA write signed 16-bit little endian).
//
// Backends (selected at runtime from a spec string, see parse_audio_sink_spec):
//   "null"              discards audio, counts frames/peaks (headless tests).
//   "wav:<path>"        writes a 16-bit PCM stereo RIFF/WAVE file; the header
//                        sizes are finalized on close() (and kept valid after
//                        each flush so a killed process leaves a readable file).
//   "alsa" / "alsa:<pcm>"  ALSA playback (default PCM "default"), Linux only.
//                        Non-blocking: when the device buffer is full the
//                        block is dropped and counted, never blocking DSP.
//   ""/nullptr           same as "null".
//   "aaudio"            Android API 26+ output, nonblocking SPSC callback.
//                        Fails explicitly on API 24/25 (no libaaudio).
//
// Threading: one producer thread calls write(); open/close are called by the
// owner while no write() is in flight. stats() may be called from any thread.
#ifndef SDRCORE_AUDIO_SINK_H
#define SDRCORE_AUDIO_SINK_H

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

namespace sdrcore {

enum class AudioSinkKind { kNull = 0, kWav = 1, kAlsa = 2, kAAudio = 3 };

struct AudioSinkSpec {
  AudioSinkKind kind = AudioSinkKind::kNull;
  std::string target;  // WAV path or ALSA PCM name ("default" if empty)
};

// Returns false for an unknown/malformed spec (e.g. "wav:" without a path,
// "pulse"); `out` is untouched in that case.
bool parse_audio_sink_spec(const char* spec, AudioSinkSpec* out);

struct AudioSinkStats {
  uint64_t frames_written = 0;  // frames accepted by the backend
  uint64_t frames_dropped = 0;  // frames rejected (device full / I/O error)
  uint64_t nonsilent_frames = 0;  // frames with |L| or |R| > 1/32768
  float peak = 0.0f;              // max |sample| seen since open()
  uint32_t sample_rate = 0;       // 0 while closed
  int32_t last_error = 0;         // 0 or negative SdrResult-compatible code
};

class AudioSink {
 public:
  virtual ~AudioSink() = default;
  virtual const char* name() const = 0;  // "null", "wav", "alsa"
  // Opens the backend for stereo float frames at sample_rate (8000..192000).
  // Returns 0 or a negative SdrResult-compatible code; resets stats on success.
  virtual int open(uint32_t sample_rate) = 0;
  // Pushes `frames` interleaved stereo frames (2*frames floats). Never blocks
  // on a full device. Returns the number of frames accepted (0 when dropped
  // or closed).
  virtual size_t write(const float* interleaved, size_t frames) = 0;
  // Flushes and releases the backend; idempotent.
  virtual void close() = 0;
  virtual AudioSinkStats stats() const = 0;
};

// Creates an unopened sink for the spec; nullptr if the backend is not built
// on this platform (e.g. ALSA on Android).
std::unique_ptr<AudioSink> make_audio_sink(const AudioSinkSpec& spec);

}  // namespace sdrcore

#endif  // SDRCORE_AUDIO_SINK_H
