# Discrete frequency-switch audio continuity (Blog V4 host benchmark)

## Scope and result

On 2026-10-18, the Linux host captured 40 discrete LO switches in each of four runs: historical Dart WFM/NFM and current native C++ WFM/NFM. All used the USB-attached RTL-SDR Blog V4 at 2.4 MS/s, 10 frequencies per mode, with short steps and out-of-band jumps. The native WAV sink stayed at approximately 48,000 frames/s, reported zero dropped IQ/audio frames, and its **60 ms / 192-frame callback model** generated no zero-fill on any switch. Its measured request-to-reported-LO latency was no worse than the historical Dart *synchronous tune-call* latency in these runs. This is host evidence for the already-merged RDS reset fix, **not proof of gap-free Android playback**. Neither probe measured what a speaker emitted or identified the first RF sample from the new station.

Historical reference: `38fe976^` (`5a9cf7d`, before native-only removal after the history rewrite). Native reference: master `8119ae8` at capture time, containing `985ce4a` (RDS filter-bank preservation). The test probe itself was added only to a detached historical worktree; a copy is retained with the raw data, not imported into the production receiver.

| Host observation, 40 switches each | Dart WFM | Native WFM | Dart NFM | Native NFM |
| --- | ---: | ---: | ---: | ---: |
| Request to Dart tune-call return / native reported LO, p50 / p95 / max (ms) | 67.39 / 80.19 / 80.48 | 66.26 / 67.34 / 67.66 | 74.97 / 75.41 / 75.71 | 57.00 / 57.51 / 74.66 |
| Request to first sink write after the above, p50 / p95 / max (ms) | 68.18 / 80.97 / 81.38 | 66.40 / 68.50 / 69.05 | 75.46 / 76.09 / 76.55 | 57.83 / 58.77 / 75.37 |
| Sink-produced 2 ms-window RMS hole (<25% of preceding 50 ms), p50 / p95 / max (ms) | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |
| **Modeled**, not recorded, callback zero-fill per switch, p50 / p95 / max (ms) | 35.73 / 46.83 / 49.29 | 0 / 0 / 0 | 41.27 / 42.83 / 45.27 | 0 / 0 / 0 |
| **Modeled** zero frames total / underflow callbacks | 71,731 / 394 | 0 / 0 | 77,584 / 420 | 0 / 0 |
| `r82xx_set_freq: failed=-9` log lines | 40 | 20 | 40 | 1 |
| Native IQ drops / sink drops | n/a | 0 / 0 | n/a | 0 / 0 |

The two latency columns do not describe the same instrumentation: Dart returns from a synchronous `engine.tune()` and does not report hardware-applied time, while native polls a post-worker snapshot after asynchronous tuning (0.5 ms poll period). The "first write" can still contain queued/stale IQ; it is **not** time to first new-station audio. No RF station labels or recognizable modulation reference were captured, so that requested metric is unmeasured. The native schedule is fixed 350 ms between requests; the Dart schedule waits 350 ms *after* each blocking tune call. Avoid treating either as a matched device playback trace.

The synthetic callback model starts with a hypothetical 60 ms cushion at the first request, pulls 192 frames every 4 ms, consumes timestamped sink writes, and stops at the last captured producer write. `model-*.wav` is explicitly modeled mono output including the simulated zero-fill; `native-*.wav` and `dart-*.f32` are the actual *produced sink samples* and do not include playback-underflow samples. The historical Dart sink was a recording replacement for its `mp_audio_stream` output (which configures a 400 ms ring and 60 ms waiting threshold in `lib/runtime/audio_output.dart:90-115`); no real miniaudio callback or Android AAudio callback was read. The modeled Dart zero-fill conflicts with the user's earlier audible Dart experience and **cannot be described as an observed Dart audio dropout**. It is sensitive to host scheduling, the start cushion and which output backend is modeled. Native's own independent model (`host_retune_audio.c:96-126`) also found zero underflows at 60 ms, with a minimum cushion of 58.5 ms WFM / 58.9 ms NFM; its largest interval between *polled producer updates* was 2.8 / 2.4 ms.

RF and tuner limitations: every Dart switch logged a transient I2C `-9`; `rtl_sdr_source.dart:512-526` retries up to 10 times and the logs contain no `>1`-retry warnings, consistent with success on the next attempt, but the probe recorded no hardware readback. Native also encountered transient `-9` (20 WFM, 1 NFM); `usb_rtlsdr_adapter.cpp:75-88` retries and verifies the librtlsdr frequency getter, and the 40 native snapshot targets were reached without terminal error. A getter reflects the driver state, not an independent RF-frequency oracle. The post-switch RMS was near zero at one target in each native run, so station-dependent audio level does not prove correct tuning or continuity. Squelch was explicitly OFF; this test does not exercise auto-squelch closed/open transitions. No decoder was selected. WFM exercises the RDS reset path and stereo reacquisition, but these captures do not trace RDS group or pilot-lock events. The native host WAV sink never invokes AAudio or a real playback callback. Audible Android results require user listening; never use a physical phone as an automated test device.

## Why the migration caused a gap, and what is already fixed

- Historical Dart: `lib/runtime/dsp_engine.dart:507-534` calls `sourceManager.tune()` synchronously, preserves the running source and sink, and relearns auto-squelch. `rtl_sdr_source.dart:512-526` retries tuner writes in place. `flushInputBuffer()` is in start/stop (`dsp_engine.dart:460,502`), not in `tune()`. It had no native RDS filter-bank rebuild.
- Native: `native/src/sdrcore.cpp:873-910` queues the live LO request to an off-UI-thread, latest-wins tuner; only sample-rate changes restart. `sdrcore.cpp:435-495` applies hardware control and marks queued and in-flight IQ as stale. `sdrcore.cpp:514-581` still processes and writes audio for stale blocks while withholding stale decoder/RDS/FFT state; `receiver.cpp:674-700` resets station-specific squelch and pilot on a new station (without restarting the audio sink). A 16 x 8192-byte in-flight allowance is set in `usb_rtlsdr_adapter.h:41-49`.
- Exact previously diagnosed regression: old `rds::Sink::reset()` repeatedly reconstructed redsea's `SubcarrierSet` and liquid resampler on the DSP/control path, spending about 13 ms per rebuild and exhausting the 60 ms ring cushion on WFM LO switches. The merged fix in `native/src/rds/rds.cpp:59-80` retains designed filter banks, rebuilds only the station assembly `Channel`, and resets the subcarrier tracking state. The historical Dart engine did not perform these RDS rebuilds. The existing `native/tests/retune_switch_gap_test.cpp` was RED before that fix and GREEN afterward (prior task run); current CTest includes it and is green. This capture does not isolate the old unfixed C++ code on hardware, so no before/after *hardware* ratio is claimed.

## Reproduction and evidence

All raw and derived data: `/home/ivan/prj/docs/retune-gap/` (outside the repository). Each `switches-{dart,native}-{wfm,nfm}.csv` contains all 40 requested centers, request timestamps, producer frame positions, per-switch tune timing, modeled zero-fill and produced-sample RMS holes. The corresponding `.jsonl` stores raw switch/write/applied events; native `*-timeline.csv` stores 0.5 ms snapshot-poller samples. Four sink recordings (`dart-*.f32`: stereo Float32LE, `native-*.wav`: stereo PCM16) and four clearly named `model-*.wav` files are retained, along with `comparison.txt`, command logs, and `dart-reference-probe.dart`.

```sh
# Historical detached worktree at 38fe976^ (Blog V4 USB fd; use current path)
source ~/prj/env.sh
SDR_HW_TEST=1 SDR_RETUNE_DIR=/home/ivan/prj/docs/retune-gap SDR_RETUNE_MODE=wfm \
  flutter test --no-pub test/native/retune_gap_reference_hw_test.dart --reporter expanded
# Repeat with SDR_RETUNE_MODE=nfm.

# Current native worktree (build host test first)
cmake -S native -B build/retune-gap-host -DCMAKE_BUILD_TYPE=Release
cmake --build build/retune-gap-host -j4 --target sdrcore_host_retune_audio
build/retune-gap-host/sdrcore_host_retune_audio \
  --sink wav:/home/ivan/prj/docs/retune-gap/native-wfm.wav \
  --mode switch --seconds 14.1 --interval-ms 350 --freq 101800000 \
  --stereo 1 --timeline /home/ivan/prj/docs/retune-gap/native-wfm-timeline.csv
# For NFM: --demod nfm --freq 145500000 --stereo 0, corresponding NFM files.
python3 tool/retune_gap/analyze.py /home/ivan/prj/docs/retune-gap \
  > /home/ivan/prj/docs/retune-gap/comparison.txt
```

Host gates in the benchmark worktree: `cmake --build build/retune-gap-host -j4 && ctest --test-dir build/retune-gap-host --output-on-failure` (all tests passed); `flutter analyze` (no issues); `flutter test --concurrency=1` (all passed); `flutter build apk --debug` and `flutter build apk --release --split-per-abi --target-platform android-arm64` (both built). The historical probe's `dart analyze` and both real-hardware `flutter test` runs passed. The benchmarks used the Blog V4 exclusively, then released it for the LoRa task. No Android emulator playback measurement or phone-listening acceptance was performed. The reported zero modeled native underflows is not a guarantee against gaps on a real audio device.
