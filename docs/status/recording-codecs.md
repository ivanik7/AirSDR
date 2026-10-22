# Native recording codecs (issue #1)

The native recorder supports continuous audio, squelch-segmented audio, or
both, in WAV (PCM16), FLAC (PCM16), MP3 (LAME CBR), and Ogg Opus (libopus +
libogg). The codec sources and their archive hashes/licenses are documented in
`native/third_party/NOTICE.md`; all are statically built from the vendored
source on the target platform. `sdrcore_record_v1.h` is unchanged. Capability
bits are returned for all four linked formats; the decoder-log bit remains
unavailable until its separate implementation lands.

The producer copies pre-playback 48 kHz PCM into the existing bounded 2 MiB
queue. The writer thread alone creates files, encodes, flushes and closes them;
no codec operation or provider I/O runs on the DSP/audio producer. Mono modes
retain one channel and stereo WFM retains two. The format and bitrate are
copied at session start, so later setting changes apply only to a new session.
WAV and FLAC take bitrate zero; MP3 accepts standard MPEG-1 Layer III CBR
choices 32–320 kb/s (32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192,
224, 256, 320); Opus accepts 6–256 kb/s. The UI/settings card owns voice/WFM
default selection and persistence, not this native writer. All encoders use
48 kHz PCM directly; no sample-rate conversion is necessary. FLAC metadata is
seek-finalized, Opus uses its lookahead/preskip and exact final granule
position, and LAME flushes on close. Filenames and MIME types follow the
container; bytes_written counts final file length even if FLAC revisits its
header. Worker errors retain the first stream-specific status error and
attempt finalization; I/O failures can leave a partial file.

## Verification on Linux host

- `native/tests/run_host_tests.sh build/native-host-tests`: 55/55 CTests,
  fd/lifecycle, checksum and pinned rtl-sdr oracle all passed. The bounded
  queue overrun tests report dropped samples/frames and stream-specific errors.
- `ctest --test-dir build/native-host-tests --output-on-failure -R
  'sdrcore_record_(codec_matrix|writer|abi|dsp)'`: 4/4 after the final
  short-clip and already-open squelch regressions.
- The codec matrix exercises 24 format × channel × segmentation configurations,
  producing 48 files, plus eight very short mono clips. Independent ffprobe
  validates actual codec/container, 48 kHz, mono/stereo, and duration. ffmpeg
  decoding is compared to quantized reference PCM for WAV/FLAC; for lossy
  formats, decoded duration, amplitude, tone identity and stereo isolation are
  checked. MP3 padding is allowed within two MPEG frames; Opus granule trimming
  is checked by decoded duration.
- `flutter analyze --no-pub`: no issues.
- `SDRCORE_HOST_LIBRARY=$PWD/build/native-host-tests/libsdrcore.so flutter test
  --no-pub --concurrency=1`: all passed (574, with 10 environment/hardware
  skips). No live RF was used.
- `flutter build apk --debug --no-pub`: succeeded; the APK contains source-built
  `libsdrcore.so` in arm64-v8a, armeabi-v7a and x86_64.

## Remaining cross-platform verification

Native codec playback/recording was exercised with generated PCM on Linux
only. Android codec output and SAF readback on an emulator, macOS universal
build/runtime, Windows llvm-mingw build/runtime, device playback continuity,
user-audible sound, and UI bitrate persistence are not verified by this card.
The integration/QA card must confirm the platform CI builds and any runtime
claims; a successful debug APK build is not proof of Android file output.
No real phone or live over-the-air receiver tests are permitted.
