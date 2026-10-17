# miniaudio desktop sink

`miniaudio_sink.cpp` implements the `AudioSink` contract (`audio_sink.h`) on
top of the vendored [miniaudio](../../third_party/miniaudio/PROVENANCE.md)
0.11.25. It is the playback path of the desktop builds that have no dedicated
sink: macOS and Windows.

## Why miniaudio

- One permissively licensed (public domain / MIT-0) C file with no build-time
  dependencies, covering CoreAudio (macOS), WASAPI (Windows),
  PulseAudio/ALSA/JACK (Linux) and a null backend for tests.
- Linux backends are dlopen()ed at run time: `libsdrcore.so` gains no new
  `DT_NEEDED`. On macOS the frameworks are linked at build time
  (`MA_NO_RUNTIME_LINKING`), as upstream recommends for notarized apps.
- Only the device layer is compiled (`miniaudio_config.h` disables decoding,
  encoding, generation, the resource manager, node graph and engine). It is
  compiled with hidden visibility, so libsdrcore still exports only `sdr_*`.

## Backends per OS

| Host    | Production sink        | miniaudio backend list (spec "miniaudio") |
|---------|------------------------|--------------------------------------------|
| Android | `aaudio`               | not built                                  |
| Linux   | `alsa` (unchanged)     | PulseAudio, ALSA, JACK (miniaudio default) |
| macOS   | `miniaudio`            | CoreAudio                                  |
| Windows | `miniaudio`            | WASAPI (then DirectSound, WinMM)           |

`miniaudio:null` uses only the null backend: a real-time paced callback
thread with no device, for offline tests (`tests/miniaudio_sink_test.cpp`)
and headless runs.

## Real-time model (same as AAudio)

- `write()` pushes into the SPSC `PcmRing` (`kPlaybackRingFrames` = 16384
  frames, about 340 ms at 48 kHz). It never blocks: the excess is dropped and
  counted in `frames_dropped`.
- The device callback pops from the ring without locks or allocation. It
  plays silence until `kPlaybackPrefillFrames` (60 ms) are queued, and
  re-primes the same way after an underflow. `underflows` and
  `zero_filled_frames` report both effects, pre-roll included.
- The stream format is f32 stereo at the DSP output rate. When the
  shared-mode device mixes at another rate, miniaudio's converter resamples
  inside the callback. The open log line prints the device's internal rate,
  channel count and period.
- An unexpected device stop (unplug, default device removed, audio service
  restart) sets `last_error` to -4.
- `close()` uninitialises the device, joining its callback thread, before
  freeing the ring. It is idempotent.

## Why ALSA and AAudio stay the Linux/Android defaults

They are the paths validated on the Blog V4 and the phone. miniaudio on a real
Linux sound card has not been compared against them yet: the dev VM has no
playback device, so only the null backend has been verified there. On Linux
the miniaudio sink can be selected for testing with
`SDR_AUDIO_SINK=miniaudio`, or `--sink miniaudio` in the host tools.
