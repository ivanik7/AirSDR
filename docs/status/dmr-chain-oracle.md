# DMR receive-chain oracle (OpenWebRX+ vs native)

Card t_371d403a. Host-only tooling in `tool/dmr_chain_oracle/` (plus the
existing `tool/dmr_voice_oracle/`); nothing in it is linked into the app.
CTest regression: `sdrcore_dmr_chain_fixture` with fixture
`native/tests/data/dmr_chain/`.

Result in one line: on identical input, the native chain (Channel + Framing +
VoiceOutput) produces the same AMBE frames, the same per-slot metadata and
bit-exact voice PCM as pristine OpenWebRX+ at 240 and 288 kS/s; at 250 kS/s
frame decisions differ in a few noisy frames (fractional resampler), with
equal metadata and equal error rates. All input is synthetic. No over-the-air
recording was compared (see "Gaps").

## Reference (oracle) builds
All pristine, pinned and checked clean by the build scripts:

| Component | Pin | License | Role |
|---|---|---|---|
| csdr-plus | f26b520 | GPL-3.0 | Selector (ShiftAddfast, FirDecimate, FractionalDecimator, FftBandPassFilter, Squelch), FmDemod, DcBlock, `csdr agc` |
| digiham-plus | beec7822 | GPL-3.0 | WideRrcFilter, GfskDemodulator(10), DmrDecoder (+ ICU charset), DigitalVoiceFilter |
| mbelib | 9a04ed5 | ISC | AMBE+2 synthesis |
| codecserver-softmbe | 66397fcf | GPL-3.0 | softmbe session (what codecserver hands mbelib), built against a protobuf-free shim |
| MMDVMHost (g4klx) | a819ae64 | GPL-2.0-or-later | transmitter side: BPTC(196,96), RS(12,9), Golay(20,8), QR(16,7), Hamming(16,11)+CRC-5 embedded LC, syncs |
| FFTW | 3.3.10 | GPL-2.0-or-later | csdr's FFT (oracle prefix build) |

codecserver itself (the daemon, protobuf transport) is not built: the
harness calls the unmodified softmbe session code directly. The module
graph follows OpenWebRX+ f1e0d1ac `csdr/chain/selector.py` +
`csdr/chain/digiham.py` (DMR: no squelch, level pinned at -150 dB).

## Test signal and provenance
No licensed public DMR IQ recording with an auditable license was found (the
public captures we know of have no license or contain third-party voice), so
the input is generated, and everything needed to regenerate it is in git:

- `dmr_tx_encode` (`encode.cpp`): a 4.8 s BS-sourced Tier II transmission,
  80 burst pairs, colour code 1. TS1: group call 2345678 -> TG 91, with
  voice LC header, 4 voice superframes carrying embedded LC, 8-bit talker
  alias `SDR-ORACLE` and GPS (51.503250, -0.125002), terminators, idle
  bursts. TS2: private call 1234567 -> 7654321. CACH TACT is ETSI
  Hamming(7,4). Burst coding uses the MMDVMHost classes above.
- AMBE+2 payloads: parameter-vector frames from
  `native/tests/dmr_ambe_test_encoder.hpp` (vocoder buzz, not speech: there
  is no open AMBE+2 speech encoder).
- `dmr_modulate` (`native/tests/dmr_fsk_modulator.hpp`): 4FSK, ETSI
  deviations +-648/+-1944 Hz, RRC (alpha 0.2) frequency pulse, AWGN given
  as C/N in 12.5 kHz, optional carrier offset; deterministic per seed.

## Method
`compare.py CHAIN_WORK VOICE_WORK OUT_DIR` runs every case on the same input
file for both chains and writes `report.json`.

- Symbols: each chain's decided-symbol stream is aligned to `tx.dibits` at
  the lag (0..2000 dibits) that maximises the match rate; SER = mismatches /
  overlap. The SER includes the start-up transient and the slot idle bursts,
  so it is a comparison metric between the chains, not an absolute BER.
- Frames: index-aligned identical AMBE frames; frames bit-equal to a
  transmitted frame.
- Metadata: per-slot transition lists (consecutive duplicates removed),
  compared per slot; plus "every line of truth.txt is decoded".
- Voice: each chain's own frames through its own voice chain (oracle:
  softmbe -> DigitalVoiceFilter -> `csdr agc -m 30 -i 3`; native:
  VoiceOutput 8 kHz capture), `srand(1)` on both. Alignment: lag in whole
  20 ms frames (k*160 samples, |k| <= 3) maximising normalised correlation.
  Reported: correlation, bit-exact 20 ms blocks, max|d|.
- Voice fidelity: each chain's PCM vs the reference PCM (oracle chain on the
  error-free frames). mbelib takes unvoiced phases from `rand()`, so one
  differing frame shifts every later noise sample and waveform correlation
  collapses even when all later frames are identical. The threshold is
  therefore the mean log-spectral distance (16 bands of 250 Hz, Hann
  window, 20 ms blocks, dB): native LSD may exceed the oracle's by <= 1.5 dB.
- FFTW: csdr's FftFilter plans with FFTW_MEASURE on x86, which made repeated
  oracle runs differ in the last float bits (and occasionally in one data
  burst decision). Both harnesses import/export FFTW wisdom
  (`DMR_FFTW_WISDOM`), which makes reruns repeatable.

Thresholds (`CASES` in `compare.py`):

| Case | Required |
|---|---|
| dibits, dibits_err, iq240 clean / C/N 20 | AMBE identical, PCM bit-exact, metadata equal |
| other IQ cases | >= 95 % (C/N 12 and 250k C/N 15: >= 90 %) identical frames, metadata equal, native SER <= oracle SER + 0.5 % (1 %), native LSD <= oracle LSD + 1.5 dB |

## Measured (2026-10-18, host, `compare.py` exit 0)

| Case | Frames o/n | Identical | = transmitted o/n | Meta | SER o/n | PCM corr | Exact 20 ms blocks | LSD o/n dB |
|---|---|---|---|---|---|---|---|---|
| dibits | 102/102 | 102 | 102/102 | equal | - | 1.0000 | 101/101 | 0.00/0.00 |
| dibits_err (1 symbol error per ~50) | 102/102 | 102 | 32/32 | equal | - | 1.0000 | 101/101 | 3.19/3.19 |
| iq240 clean | 102/102 | 102 | 102/102 | equal | 6.53/6.57 % | 1.0000 | 101/101 | 0.00/0.00 |
| iq240 C/N 20 | 102/102 | 102 | 101/101 | equal | 4.92/4.72 % | 1.0000 | 101/101 | 0.00/0.00 |
| iq240 C/N 15 | 102/102 | 102 | 95/95 | equal | 3.96/3.92 % | 1.0000 | 101/101 | 0.07/0.07 |
| iq240 C/N 12 | 102/102 | 102 | 72/72 | equal | 4.43/4.50 % | 1.0000 | 101/101 | 1.31/1.31 |
| iq240 +300 Hz, C/N 20 | 102/102 | 102 | 100/100 | equal | 4.77/4.67 % | 1.0000 | 101/101 | 0.09/0.09 |
| iq250 clean | 102/102 | 101 | 101/102 | equal | 6.95/7.03 % | 0.9868 | 95/101 | 0.17/0.00 |
| iq250 C/N 15 | 102/102 | 94 | 97/97 | equal | 3.48/3.23 % | 0.6116 | 64/101 | 0.08/0.95 |
| iq288 C/N 20 | 102/102 | 102 | 101/101 | equal | 4.71/4.71 % | 1.0000 | 101/101 | 0.17/0.17 |

Every case decodes all of `truth.txt` on both chains (IDs, call types,
alias, GPS) except dibits_err, where the injected errors exceed the
embedded-LC FEC on both chains identically. Only 102 of the 144 transmitted
frames come out of either chain: digiham passes voice only for the first
active slot (TS1), which the port keeps.

### Measured differences
- 250 kS/s: the native ChannelFilter runs the csdr modules on fixed input
  blocks after a VFO tap (no full-rate Shift), so its FractionalDecimator
  sees a different phase than OpenWebRX+'s. In the noisy cases a few frames
  land on the other side of a decision: at C/N 15, 8 frames differ by 1-4
  bits; the native chain matched the transmitted frame in 4 of them and the
  oracle in the other 4 (one further frame is decoded identically wrong by
  both). At 250k clean, one frame differs by 2 bits and the native one is
  the transmitted frame. SER, metadata and voice fidelity are
  within the thresholds; the low waveform correlation is the `rand()`
  desynchronisation described above, not a level or spectrum difference.
- Symbol streams: native starts later and is longer (240k: 23004 vs 22800
  symbols, same alignment lag 33): the fixed-block selector latency
  documented in `dmr-symbol-verification.md`.
- Raw metadata events: native emits extra events (colour code, duration), so
  raw streams differ; per-slot transitions of the compared fields are equal.

## Regression fixtures (CTest `sdrcore_dmr_chain_fixture`)
`compare.py ... --golden native/tests/data/dmr_chain` stores the oracle
outputs (`tx.dibits`, `truth.txt`, AMBE + per-slot metadata for 4 cases,
oracle 8 kHz PCM). The CTest runs only native code:

| Check | Covers |
|---|---|
| dibits: 102/102 frames, metadata, truth | sync, CACH/TACT slotting, burst framing, BPTC/RS LC, embedded LC, alias, GPS |
| dibits_err: frames + metadata vs oracle | Golay/Hamming/QR/BPTC error correction under symbol errors |
| voice: 16220 samples bit-exact | Framing -> VoiceOutput vs softmbe + DigitalVoiceFilter + csdr agc |
| iq240_cn15 >= 101/102, iq250_cn15 >= 92/102 frames, metadata, truth | 4FSK Channel (selector, FM, RRC, GFSK(10)) |

The IQ is regenerated in the test from `tx.dibits` with the same modulator
and seed; its noise uses libstdc++'s `normal_distribution`, so the IQ cases
assume the Linux host toolchain. Mutation checks (one change at a time,
rebuilt): disabling Golay(20,8) correction fails dibits_err; dropping GPS
latitude fails dibits/iq metadata and truth; widening the bandpass
transition from 320 to 2000 Hz fails iq240_cn15 (98/102).

## Rebuilding the oracle
```
CSDR_BUILD=<sstv oracle work>/csdr-build tool/dmr_voice_oracle/build_oracle.sh VWORK
CSDR_BUILD=<sstv oracle work>/csdr-build tool/dmr_chain_oracle/build_oracle.sh CWORK
python3 tool/dmr_chain_oracle/compare.py CWORK VWORK OUT [--golden native/tests/data/dmr_chain]
```
`CSDR_BUILD` comes from `tool/sstv_oracle/build_oracle.sh` (same csdr pin
with its FFTW/libsamplerate prefix). Sources default to
`~/prj/ref/openwebrx/{csdr-plus,digiham-plus,ext/MMDVMHost,ext/mbelib,ext/codecserver-softmbe}`.

## Gaps (not verified)
- No over-the-air or licensed public DMR recording; all IQ is from the test
  modulator, so real-world impairments (multipath, PA distortion, drift,
  tuner IQ imbalance) are not compared. A Blog V4 capture of a local
  repeater would close this; none was available (no RTL-SDR attached to the
  host during this card).
- No speech: AMBE payloads are parameter vectors. Voice parity is shown on
  the decoder chain, not on intelligibility.
- Only BS-sourced (repeater) bursts; MS-sourced/direct-mode syncs, data
  calls, privacy-flagged calls and non-8-bit alias charsets are not in the
  signal.
- Running OpenWebRX+ itself (Python threads, real ring-buffer chunking) is
  not used; the harness pumps the same modules in a single thread.
- Android: the `dmr` native decoder is not registered yet (card
  t_bc6f9eeb), so there is no on-device DMR decode or DMR audio to smoke-test;
  see the emulator note in `docs/status/dmr.md` section 13.
