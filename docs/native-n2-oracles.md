# N2 host oracles and parity tests

Host acceptance oracles for the ABI v3 radio contract
(`native/include/sdrcore_v3.h`, `docs/native-n2-adr.md`). The C++ harness
`native/tests/n2/run_n2_oracles.sh`, its analytic fixtures and its hardware
soak are the native-only regression oracle. The former Dart reference receiver
and native-vs-Dart parity tests were removed with the Dart engine.

## Files

| Path | Role |
|---|---|
| `native/tests/n2/n2_oracle.cpp` | C++17 harness. `dlopen`s the library under test, so an ABI-2 build reports **MISSING hooks** instead of failing to link. Subcommands `suite`, `hw`, `demod-file`, `gen`. |
| `native/tests/n2/run_n2_oracles.sh` | Builds this tree's `libsdrcore.so` (or takes `--lib`), builds the harness, runs `suite`, and with `--hw` runs the `rtl_test` baseline and then the Blog V4 soak. Writes `build/n2-oracle/{suite,hw}.json`. |

Exit codes are 0 = all PASS (SKIP allowed), 1 = any FAIL, 2 = only MISSING, and 3 = setup error.
MISSING is not a pass. The expected values are never relaxed when a hook is absent.
`--allow-version-2` lets a worker branch that exports `sdr_v3_*` but still
returns `sdr_version()==2` run the cases, while `abi_version` stays MISSING.


```sh
native/tests/n2/run_n2_oracles.sh                      # this tree, suite only
native/tests/n2/run_n2_oracles.sh --lib X.so --allow-version-2   # worker branch probe
native/tests/n2/run_n2_oracles.sh --hw                 # + rtl_test 130 s + 600 s Blog V4 soak
```

## Fixtures

All fixtures are deterministic synthetic CU8 (`127.5 + 127.5·x`), generated
at run time by the harness or `n2_oracle gen`. Seeded
xorshift64 Gaussian noise keeps them reproducible, and no binary blobs are committed.
The multi-mode fixture at 1.024 MS/s, LO 100 MHz, contains:

| Offset | Signal | Expected audio |
|---|---|---|
| +250 kHz | WFM, 75 kHz deviation, 1 kHz | 1000 Hz |
| −150 kHz | NFM, 3 kHz deviation, 1250 Hz | 1250 Hz |
| +400 kHz | AM 60 %, 700 Hz | 700 Hz |
| +60 kHz | USB dial, +1500 Hz tone | 1500 Hz |
| −60 kHz | LSB dial, −1200 Hz tone | 1200 Hz |
| −300 kHz | CW carrier at dial | 800 Hz (SDR++ default CW tone) |

The other fixtures cover a 200.5 kHz carrier for the FFT, NFM only and noise only for
squelch and mute, a two-carrier file for the scanner, and a TCP socket stream with
an RST for detach. The WAV fixtures are the native `wav:` sink outputs, which are
parsed by the C++ harness.

## Cases and thresholds

`suite` covers host-only cases on synthetic, file and socket sources:

| Case | Asserts |
|---|---|
| abi_version | `sdr_version()==3` and all seven `sdr_v3_*` exported |
| struct_validation | size/revision mismatch → INVALID_ARGUMENT with output memory untouched; IDLE/OPEN guards; NULL handles |
| controls_validation | 24 invalid requests rejected; applied state, `control_sequence` and generation unchanged; stream keeps RUNNING; AGC is OK or UNSUPPORTED, never a silent no-op; display validation and sequence |
| ui_bandwidth_contract | every `RadioController.demodParams` min/default/max bandwidth and every auto-squelch mode is accepted |
| mode_tones | WFM/NFM/AM/USB/LSB/CW tone ±3 Hz; RMS in (0.02, 1.5); L=R; 48 kHz ±0.5 %; WAV frames == `audio_frames`; processed+dropped == input; file pacing ±10 % |
| wfm_mono_lr | mono WFM L==R (<1e-4). Stereo MPX is an **explicit gap**, not asserted |
| fft_spectrum | full-band peak within 1 column; ≥25 dB above the median floor; low/high metadata; zoomed view peak ±1 kHz with the new `control_sequence` |
| fft_rate_latest_wins | 15..30 rows/s; NO_DATA/BUFFER_SMALL leave outputs untouched (width only); ≥5 overwrites per 500 ms unpolled; `read(after=0)` returns the latest row |
| generation_semantics | VFO/mode/bandwidth/squelch/volume keep the generation; LO/gain/rate restart (+1); snapshot shows applied values; rows carry the new sequence within 1 s; input keeps flowing |
| mute_volume | muted and volume 0 give 0 non-silent frames but keep the frame clock; volume 0.5 → −12.04 dB ±1 (volume²); live unmute without restart |
| squelch | manual −30 dB and auto: noise ≤480 non-silent frames (one 5 ms ramp); signal ≥36000 of 48000; tone ±3 Hz |
| scan_simulation | sequential ChannelScanner steps: `squelch_ready` cleared on every tune; ready within 0.8 s dwell; open only on carriers; LO step restarts |
| lifecycle_restart | 20 start/stop cycles, double start/stop INVALID_STATE, sink locked while running, FFT invalid after stop, cumulative counters, stop drains; **fd Δ=0, thread Δ=0, RSS Δ≤1 MiB**; close and destroy while RUNNING; reopen resets counters |
| sink_selection | spec validation (empty, NUL, NULL, >1024, unknown); `aaudio` on Linux = UNSUPPORTED; an unwritable WAV fails start, leaves OPEN and is not a sticky error; spec copied |
| v2_coexistence | v2 diagnostic and v3 radio on two handles at once; cross-mode calls INVALID_STATE |
| concurrent_polling | snapshot/read_fft from a second thread during 30 start/control/display/stop cycles; 0 incoherent copies |
| detach_sticky_error | TCP RST mid-stream → ERROR with IO_ERROR/DEVICE_GONE within 2 s; commands rejected; error sticky across stop; cleared by the next open |
| file_eof_parity | after EOF the session loops or leaves RUNNING; restart replays |
| perf_2400k_wfm | 2.4 MS/s WFM + 30 Hz FFT poll: **CPU ≤0.5 core, 0 IQ drops, 0 sink drops, 48000±480 frames/s, input ±1 %, RSS ≤64 MiB, RSS growth ≤1 MiB, UI rows 15..30/s** |
| perf_detached_ui | no poller: RSS growth ≤256 KiB; overwrites ≥15/s (latest-wins, no queue) |

`hw` is the Linux-host acceptance override from the ADR. It needs the Blog V4 on this host:

- The soak (default 600 s) runs at 2.4 MS/s and cycles WFM → NFM → AM → USB → LSB → CW → a retune of −1 MHz with a gain change → WFM. It does one stop/restart halfway through and writes a short local-FM WFM WAV.
- A global claim check: a second handle cannot open the dongle.
- Thresholds:
  - every mode has non-silent frames;
  - no async error;
  - mean input within 2 % of 2.4 MS/s;
  - FFT at least 15 rows/s;
  - CPU at most 0.6 core;
  - RSS growth at most 2 MiB;
  - the native drop ratio is at most 2× the `rtl_test` lost-bytes ratio (or ≤1e-5 without a baseline).
- `hw_detach_reset`: `USBDEVFS_RESET` under a running session either surfaces a sticky DEVICE_GONE/IO_ERROR or keeps streaming. A frozen RUNNING session fails. The device must re-enumerate.
- Physical unplug, screenshots and audibility remain manual. Audibility is confirmed by listening.
