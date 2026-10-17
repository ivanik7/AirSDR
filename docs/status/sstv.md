# Native SSTV backend status (csdr-plus SstvDecoder)

Card `t_b20604db`. This card covers the native side only: the vendored
upstream decoder, the adapter, the receiver's 24 kHz audio tap and the C ABI
selection rules. The Dart panel/gallery/save work belongs to `t_68a23f96`.
The pysstv/OpenWebRX+ oracle comparison and the live-air check belong to
`t_9165cc6e`. The source audit and the frozen v1 event contract are in
`docs/status/sstv-audit.md`.

## What is in the tree

- `native/third_party/csdr_sstv/`: csdr-plus `f26b520` `sstv.hpp`/`sstv.cpp`
  (BSD-3) and the GPL-3 Module/Source/Sink/Reader/Writer glue they inherit.
  The glue is verbatim. `sstv.hpp`/`sstv.cpp` carry five documented patches,
  listed in `PROVENANCE.md`; `sdr_flutter.patch` is the exact `diff -u`
  against the pinned upstream files:
  1. PD-290 line buffer size (`MAX_LINE_WIDTH` 640 -> 800).
  2. The `decodeLine` output-capacity guard (x3).
  3. Removal of the VLA initializer that clang/NDK rejects.
  4. `vsnprintf`.
  5. Read-only `onRowWritten`/`onFinishFrame` observation hooks.

  The VIS table, timing constants, FFT-based tone detection, sync search,
  line decoding and colour conversion are unchanged.
- `native/third_party/fftw-3.3.10/` + `fftw.cmake`: FFTW 3.3.10 built from
  source as scalar single precision for host and NDK. See
  `FFTW-PROVENANCE.md`.
- `native/src/decoder/sstv.cpp`: the adapter (`create_sstv`). It does the
  following:
  - Feeds 24 kHz mono floats into `SstvDecoder<float>(24000, 0)`.
  - Parses the upstream BGR BMP byte stream after each upstream `process()`.
  - Emits v1 events: `start`, one `line` per decoded or padded row, and
    `image_complete`.
  - Validates settings `{"version":1,"settings":{"mode":"auto","underlying":
    "usb|lsb|nfm"}}`. Forced picture modes are rejected because upstream has
    no forced-mode option.
- `native/src/dsp/receiver.cpp`: the `Input::audio` tap. It works as follows:
  - Demodulated USB/LSB/NFM audio is taken before volume/mute.
  - The NFM tap follows csdr-plus's chain (Limit, then the 201-tap
    24 kHz deemphasis FIR).
  - A dedicated band-limited resampler converts it to exactly 24000 S/s.
  - The tap is gated by squelch and by `accepts_mode()`.
  - The decoder is reset only on a tuned-frequency, mode or sample-rate
    change, or on retune/reset. A bandwidth change or LO recenter does not
    reset it.
  - Voice audio is bit-identical with or without the tap.
- `native/src/sdrcore.cpp`: `sdr_decoder_select("sstv")` behaves as follows:
  - It validates the config first, so a missing or invalid config returns
    `SDR_INVALID_ARGUMENT`.
  - It then requires that the applied v3 mode is accepted (USB/LSB/NFM, or
    the pinned `underlying`); otherwise it returns `SDR_UNSUPPORTED`.
  - Selection never changes the tuner or the mode.
  - Audio-tap decoders do not mute voice audio, matching OpenWebRX+.

## Verification on debian-ai (2026-10-11)

| Command | Result |
|---|---|
| `cmake -S native -B build/native-host -DCMAKE_BUILD_TYPE=Debug && cmake --build build/native-host -j3` | OK |
| `ctest --test-dir build/native-host -j2` | 26/26 passed |
| ASan+UBSan build (`build/native-asan`): `sdrcore_sstv_test` (full, incl. PD-290), `sdrcore_audio_tap_test`, `sdrcore_decoder_abi_test` | all pass, no sanitizer reports |
| `SDRCORE_HOST_LIBRARY=build/native-host/libsdrcore.so flutter test test/native/` | 111 passed, 6 skipped (pre-existing skips) |

`sdrcore_sstv_test` (in `native/tests/sstv_test.cpp`) generates its
signals with `native/tests/sstv_test_encoder.hpp`. That is a standalone
phase-continuous encoder using the published mode timings: VIS with parity,
then per-line sync/porch/pixel tones on an ideal time line. It checks:

- **Per mode** (Robot 36, Martin 1, Scottie 1, PD-90, PD-290; `--quick`
  skips PD-290):
  - Exactly one frame is detected, with the upstream VIS id, name and
    dimensions.
  - `start` is stamped with frequency and underlying mode; `frame_id` is
    decimal and timestamps are UTC.
  - Rows arrive in order as exact `width*3` BGR, with metadata repeated on
    every row.
  - `image_complete` reports `complete/end` with zero padded rows.
  - Every payload is at most 64 KiB.
  - **The emitted rows are byte-identical to an upstream
    `SstvDecoder<float>` run directly on the same audio** (BMP stream
    minus the 54-byte header).
- **PSNR against the source image**:
  - Flat-area PSNR is 27.6–28.8 dB clean; the floor is 25 dB.
  - Whole-image PSNR is also reported, with per-mode floors 2–3 dB below
    the measured values.
  - Flat-area PSNR excludes pixels within one upstream FFT window of a
    hard edge. Upstream estimates each pixel's tone from a window
    `WINDOW_FACTOR` pixel-times wide (7.7 px for Robot 36), so a sharp bar
    edge is smeared by design. Whole-image PSNR measures that smear, not
    decoder error.
- **Noise and offset**: Robot 36 at 10 dB SNR decodes fully, with
  flat-area PSNR 20.1 dB (floor 17). A +40 Hz audio offset still decodes.
- **VIS rejects**: odd parity produces no frame. AVT-90 (VIS 68, disabled
  upstream) is not decoded.
- **Sync/slant (upstream behaviour)**: Martin 1 and Scottie 1 are encoded
  with a ±500 ppm sample-clock error. Upstream re-finds the sync every line,
  so a vertical edge stays within 2 px top to bottom (measured drift
  <0.03 px). The rows are byte-identical to upstream. Upstream has no
  explicit slant correction, and none was added.
- **Scottie start-sync timeout**: VIS is received but the start sync never
  arrives. The announced frame closes `partial/sync_lost` with 0 rows, and
  upstream itself wrote only the BMP header.
- **Truncated transmission**: Robot 36 is cut at half the image and followed
  by 25 s of silence. Upstream keeps decoding nominal-timing scanlines from
  the trailing audio until `LINE_COUNT` and ends the frame naturally. The
  adapter reproduces this exactly: one frame, 240 rows byte-identical to
  upstream, `reason=end`. It does not invent an early stop.
- **Reset**: retune, mode change and stop each close an open frame
  `partial` with `reason` `retune`/`mode`/`stop`. No stale rows follow, and
  the next transmission decodes as a new frame with a higher `frame_id`.
  A reset with no open frame emits nothing.
- **Through the receiver**: Robot 36 is modulated onto IQ and decoded via
  the 24 kHz tap in USB, LSB and NFM, with flat-area PSNR about 28 dB.
  Receiver plus decoder use 3.3% (SSB) or 4.3% (NFM) of real time on one
  host core.
- **Through the receiver, reset rules**: a VFO retune or a USB->LSB change
  mid-frame closes the frame `partial` with the matching reason. A
  bandwidth-only change and an LO recenter at the same tuned frequency do
  not reset.

`sdrcore_audio_tap_test` checks the tap itself:

- Exact 24000 S/s output from 250k/1.024M/2.048M/2.4M input.
- Tone accuracy within ±0.02 Hz and THD+N below -49 dB for USB/LSB.
- The NFM deemphasis table matches csdr-plus.
- Squelch and mode gating.
- Voice bit-identity with and without the tap.

## Exact parity gaps (documented, not hidden)

- **Test signals are generated by our own encoder, not by pysstv or a
  real station.** Decoder parity is exact because the rows are compared
  byte for byte with the upstream engine. Fidelity against the source
  image is measured only with this encoder. Comparing against the
  OpenWebRX+ `csdr sstv` chain on pysstv recordings is the job of
  `t_9165cc6e`.
- **dbgTime=0** instead of OpenWebRX+'s 300000. It affects only debug text
  interleaved in the byte stream, not image bytes (`PROVENANCE.md`).
- **Patches 1–4 change behaviour only where upstream is broken**:
  - Patch 1: PD-290 overflowed `linebuf` upstream.
  - Patch 2: the capacity guard under-counted the bytes it guards.
  - Patch 3: the VLA initializer did not compile under clang.
  - Patch 4: the unbounded `vsprintf` is unreachable with dbgTime=0.

  All other modes produce identical bytes.
- **No forced-mode setting** because upstream has none. Native rejects
  anything but `auto`; since `t_68a23f96` the Dart catalog allows only
  `auto` and normalizes stored `martin_m1`/`scottie_s1` to it.
- **Audio path differs structurally from OpenWebRX+**. OpenWebRX+
  channel-filters to 24 kS/s before demodulation. This app demodulates at
  the receiver IF rate and band-limits during the 24 kHz conversion. The
  SSTV band (1100–2300 Hz) is flat, as the tone accuracy and THD+N
  results show.

## Not done here

- Live-air SSTV reception. An RTL-SDR Blog V4 is attached to debian-ai
  (`0bda:2838`), but no on-air SSTV decode was attempted on this card; it
  belongs to `t_9165cc6e`.
- Android build/run of the new native code. No Gradle build was run on this
  card. A direct NDK r28 CMake build of `libsdrcore.so` (arm64-v8a,
  android-24, Release) compiles and links the vendored SSTV/FFTW sources;
  the APK and on-device behaviour are unverified.
- Dart UI for images (panel, gallery, save): done in `t_68a23f96`, see
  `docs/status/sstv-ui.md`.
