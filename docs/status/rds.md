# WFM RDS validation (Linux host)

## Scope and evidence

The production WFM path taps the pre-audio FM discriminator MPX, quantizes it to S16, resamples to 200 kS/s, and invokes vendored redsea 1.3.1 (liquid-dsp 1.6.0). OpenWebRX+ uses the same upstream redsea `Channel`/`SubcarrierSet` after a 200 kS/s MPX tap and an S16 conversion. The host-only `sdrcore_rds_mpx_oracle` runs those original classes with default `--input mpx --samplerate RATE [--rbds]` semantics on raw signed S16 PCM (it is **not** the OpenWebRX+ process or redsea's external CLI). `sdrcore_rds_mpx_receiver` FM-remodulates the *same* S16 input to CU8 at 192 kS/s and runs the production channel FIR, discriminator, RDS sink and stereo audio. This comparison is stronger than independent smoke tests, but it does not exercise the USB device, the OpenWebRX+ application parser process, or Android audio.

Recordings: windytan/redsea commit `7555c9f6259d50718697ee8c9f218ea012c6892c`, `test/resources/rds2-minirds-192k.flac` (192 kS/s, 345,600 mono samples) and `mpx-testfile-yksi.flac` (192 kS/s, 134,400 mono samples). The checkout contains 131-byte Git-LFS pointers; actual FLAC files were retrieved from `media.githubusercontent.com/media/windytan/redsea/<commit>/test/resources/` into the per-profile scratch directory. The converted S16 files and the upstream FLAC bytes are not committed. This is upstream fixture provenance, not a redistribution or recording of a local station.

Reproduce (substitute a different scratch path if needed):

```sh
S=${TMPDIR:-/tmp}/rds-validate; mkdir -p "$S"
REV=7555c9f6259d50718697ee8c9f218ea012c6892c
for name in rds2-minirds-192k mpx-testfile-yksi; do
  curl -fL "https://media.githubusercontent.com/media/windytan/redsea/$REV/test/resources/$name.flac" -o "$S/$name.flac"
  uv run --with soundfile python native/tests/rds_fixture_prepare.py "$S/$name.flac" "$S/$name.s16"
done
cmake -S native -B "$S/rds-validate-build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$S/rds-validate-build" -j3
python3 native/tests/rds_parity.py "$S/rds-validate-build/sdrcore_rds_mpx_oracle" "$S/rds-validate-build/sdrcore_rds_mpx_receiver" "$S/rds2-minirds-192k.s16"
"$S/rds-validate-build/sdrcore_rds_mpx_oracle" redsea "$S/mpx-testfile-yksi.s16" 192000 0
"$S/rds-validate-build/sdrcore_rds_mpx_oracle" embedded "$S/mpx-testfile-yksi.s16" 192000 0
"$S/rds-validate-build/sdrcore_rds_mpx_receiver" "$S/mpx-testfile-yksi.s16" 0
ctest --test-dir "$S/rds-validate-build" --output-on-failure
"$S/rds-validate-build/sdrcore_rds_wfm_bench" off
"$S/rds-validate-build/sdrcore_rds_wfm_bench" on
flutter analyze && flutter test --concurrency=1 --reporter compact
flutter build linux --debug && flutter build apk --debug
```

Results on this host:

| Fixture / mode | Original redsea groups | Embedded groups | Full WFM groups | Observations |
| --- | ---: | ---: | ---: | --- |
| MiniRDS, RDS | 17 + 1 EOF-only PI flush | 17 | 17 | JSON of all 17 complete groups identical at each stage; PI `0x1000`, PS `MiniRDS `, `No PTY`, TP/TA false, `di` bits and ODA `Enhanced RadioText (eRT)` preserved. |
| MiniRDS, RBDS | 17 + 1 EOF-only PI flush | 17 | 17 | Same 17 groups identical; `callsign_uncertain: KAAA` remains marked uncertain. |
| Yksi, RDS | 2 | 3 | 1 | All report PI `0x6201` and `Serious classical`; upstream 0A/1A, adapter 0A/14A/0A, full WFM 0A. Initial acquisition/group-count discrepancy on this short 0.7 s recording: adapter's 192→200 kS/s filter and receiver's FIR/quantized FM demod differ from direct 192 kS/s redsea. Do not assert per-group parity for this short capture. |
| Yksi, RBDS | 2 | 3 | 1 | PI `0x6201`, verified callsign `WFBL`, PTY changes to `Jazz`; same acquisition mismatch. |

MiniRDS produces PS but **not** a completed RadioText, AF list or CT in these short fixtures. Those fields, noisy/weak-signal BLER, RT+ and group-loss/update timing have *not* been demonstrated against upstream on a suitable long MPX capture. The core's redsea tables are vendored but that alone is not an end-to-end field-parity result. OpenWebRX+'s `RdsParser` shallow-merges group deltas, clears on PI/frequency changes, and removes `group`; our native events are bounded accumulated snapshots and the Dart station model clears on PI changes. The WFM user interface is thus not byte-for-byte equivalent to OpenWebRX+'s event cadence; native coalesces changes to at most 4 states/s and has explicit reset/sync events, while the OpenWebRX+ panel hides old metadata after ten seconds. No independent OpenWebRX+ web UI session was run.

## Stereo and host CPU

The repeatable benchmark feeds **identical** synthetic 2.4 MS/s CU8 stereo-FM IQ to the optimized native `Receiver` for 8 s per run. WFM bandwidth is 150 kHz, stereo is enabled and RDS is alternately processed or suspended; no input generation parameters, bandwidth, receiver mode or audio setting change between runs. Off/on CPU time (DSP **plus generation**): 2.36530/2.58058 s, then 2.35258/2.57511 s. Maximum observed DSP block time: off 1.236/1.079 ms, on 1.466/1.407 ms versus a 6.827 ms sample-time budget for each 16,384-sample block. Stereo output: 384,000 interleaved L/R frames in every run, exactly the 8 s × 48 kHz expectation, no missing frames. The 192 kS/s full WFM MiniRDS replay also returned 86,400 stereo frames for 1.8 s in RDS and RBDS mode. CTest's independent stereo DSP, PCM-ring jitter/audio-sink, audio continuity, RDS ABI, and live-retune tests pass. This bounds *synthetic host DSP* performance, not actual USB transport, ALSA/AAudio underrun counters, or audible sound; no receiver hardware was attached for the latter checks.

## Boundaries, gates and remaining acceptance

`sdrcore_rds_mpx_receiver` asserts that retune immediately drops queued groups/sync and that switching to AM never emits RDS groups; the ABI RDS test asserts generation, RBDS, retune and mode reset events. Flutter RDS station/UI regression tests cover stale station clearing on PI, frequency, mode, generation and stop; the full suite ran. `lsusb` during validation showed only QEMU/root hubs: **no RTL-SDR Blog V4 (`0bda:2838`)**. Therefore no real local station PI/PS/RT, USB drop count, audio-sink underrun measurement, or Linux screenshot/WAV was obtained; Android behaviour on real hardware is unverified. Live reception, subjective stereo quality and bandwidth behavior on the actual Blog V4 remain unverified, not passed.

Host native Release build and CTest: **23/23 passed**. `flutter analyze`: no issues. `flutter test --concurrency=1 --reporter compact`: **430 passed, 14 skipped**. Linux debug and Android debug APK builds passed. The APK was built only after checking that no other Gradle build was active; an attempted `flock` command was rejected by this headless terminal's nested-executable security check. No arm64 release build was run in this validation (upstream native integration already passed Android debug). No app production code or native ABI changed here; only host-only parity/benchmark harnesses and this documentation were added.

No new license incompatibility was found: redsea repository MIT plus preserved source-file ISC-style notices; liquid-dsp and nlohmann/json MIT, project GPL-3.0-or-later (see `native/third_party/RDS-PROVENANCE.md`). There is no observed *device bandwidth* blocker because the device is absent; WFM narrower than 120 kHz or MPX below 128 kS/s intentionally disables RDS without widening a user-selected channel. A suitable longer RDS/RBDS recording with RT/AF/CT and real host hardware reception are the two missing fidelity/acceptance inputs. The short Yksi acquisition discrepancy warrants further investigation only with a longer same-MPX capture and exact 200 kS/s rate matching; it is not grounds to fabricate decoded fields.

## Root integration check

On merged master `d5e61f3`, `flutter analyze` reported no issues, `flutter test --concurrency=1 --reporter compact` passed 430 tests with 14 environment/hardware skips, and a fresh host Release CMake build passed 23/23 CTests. A locked `flutter build apk --release --target-platform android-arm64` completed; the APK contains `lib/arm64-v8a/libsdrcore.so` (2,129,968 uncompressed bytes). The release APK is 20,857,147 bytes. A freshly built pre-native-RDS baseline at `00917a4`, using the same Flutter/Android toolchain and arm64 release options, is 20,129,083 bytes: **+728,064 bytes**. This commit-range size delta also includes concurrent Meshtastic, DMR documentation and UI changes, and must not be attributed solely to RDS. The previous release artifact in master was stale, so it was not used as the baseline. An older uncommitted prototype was left untouched; the four completed child tasks are already merged into master.
