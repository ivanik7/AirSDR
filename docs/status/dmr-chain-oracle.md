# DMR receive-chain oracle (work in progress)

Branch `feat/dmr-oracle-chain`, card t_371d403a. Host-only tooling under
`tool/dmr_chain_oracle/`; nothing is linked into the app.

## What it compares
- `dmr_tx_encode`: synthetic BS-sourced DMR transmission (4.8 s, 80 burst
  pairs) encoded with the unmodified MMDVMHost a819ae64 DMR classes
  (GPL-2.0-or-later): voice LC headers (BPTC/RS(12,9)), 4 voice superframes per
  slot with embedded LC (Hamming(16,11)+CRC-5, QR(16,7) EMB), terminators, idle
  bursts, Hamming(7,4) TACT. TS1 group call 2345678 -> TG 91 with 8-bit
  talker alias `SDR-ORACLE` and GPS; TS2 private call 1234567 -> 7654321.
  AMBE payloads are parameter-vector frames from
  `native/tests/dmr_ambe_test_encoder.hpp` (no speech, no recording).
- `dmr_modulate`: 4FSK modulator, ETSI deviations +-648/+-1944 Hz, RRC alpha 0.2
  frequency pulse, AWGN as C/N in 12.5 kHz (`native/tests/dmr_fsk_modulator.hpp`).
- `owrx_chain`: OpenWebRX+ f1e0d1ac DMR chain from pristine csdr-plus f26b520 and
  digiham-plus beec7822 (Selector + FmDemod/DcBlock/WideRrc/Gfsk/DmrDecoder,
  ICU charset). `native_chain`: the app's `dmr::Channel` + `dmr::Framing`.

## Measured (2026-10-18, host, manual runs)
| Input | Metadata transitions per slot | AMBE frames (owrx/native) | Identical frames | Frames equal to transmitted (owrx/native) |
|---|---|---|---|---|
| dibits direct | equal | 102/102 | 102 | 102/102 |
| IQ 240 kS/s, C/N 15 dB | equal | 102/102 | 102 | 93/93 |
| IQ 250 kS/s, C/N 15 dB | equal | 102/102 | 97 | 94/95 |
| IQ 240 kS/s, C/N 200/20/12 dB | - | 102/102 | byte-exact | - |
| IQ 250 kS/s, C/N 200/20/12 dB | - | 102/102 | differ | - |

Pristine digiham reports the expected IDs, alias and GPS (51.503250,
-0.125002). Native emits more metadata events than digiham (it also reports
duration/CC changes), so raw event streams differ; per-slot content
transitions are identical. Decided-symbol streams differ in length and start
(native 23004 vs owrx 22800 at 240 kS/s): the native selector's fixed-block
start-up latency, documented in `dmr-symbol-verification.md`.

Only the first 102 of 144 transmitted frames come out on both chains: digiham
emits voice only for the first active slot (upstream behaviour).

## Not done yet
- Automated compare script/CTest and regression thresholds.
- Symbol-error-rate alignment and voice PCM correlation through the vocoder
  oracle (`tool/dmr_voice_oracle`, already 16/16 bit-exact on frames).
- Android emulator UI smoke test; merge to master.
