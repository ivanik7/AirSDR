# Meshtastic LoRa PHY (embedded lorarx)

The `meshtastic` decoder is now available. It runs OE5DXL's lorarx, the
LoRa demodulator OpenWebRX+ uses, inside the native DSP worker. It is fed by
the exact 1 MS/s complex tap of the single receiver VFO
(`docs/status/meshtastic-mode.md`). Each JSON line is passed to the native
`MeshtasticParser` port (`docs/status/meshtastic.md`), which emits `message`
events. No executable is launched and no file, pipe or socket is opened.

## Source and licence

- Author-site lorarx (dxlAPRS), GPL-2.0-or-later, vendored under
  `native/third_party/lorarx/`. Its sha256 values and the list of local edits
  are in `PROVENANCE.md`; `docs/lora-upstream-feasibility.md` records the
  licence and source decision.
- The local edits are all `#ifdef SDRCORE_LORARX_EMBED`. Without that macro
  the files compile to upstream lorarx, which the tests build as the oracle.
- `embed/` replaces the upstream OS layer: no IO, no console output, and
  aborts unwind instead of exiting. Algorithms, tables, FEC, option parsing
  and JSON formatting are upstream code paths that run unchanged.

## Native interface

`lorarx_embed.h`:

- `start(argc, argv)`: upstream `main()` up to the input open, plus the first
  demodulator pass.
- `block(iq, 4096)`: one turn of the read/demod loop. Each block is exactly
  4096 complex-f32 frames, the size upstream's `inreform()` reads.
- `clear()`: frees all state and restores every file-scope variable, so the
  next `start()` behaves like a fresh process.
- `lorarx_embed_emit()`: receives each JSON line that upstream would write
  to `-j`.

Backend: `native/src/decoder/meshtastic.cpp`.

- `configure()` takes `{"version":1,"settings":{"preset","region","channels"}}`
  and starts lorarx with the OpenWebRX+ `MeshtasticDemodulator` argv:
  `-i /dev/stdin -r 1000000 -f f32 -v -N -Q -H 5 -W 50 -b <bw> -s 7 -s 8 -s 9
  -s 10 -s 11 -j /dev/stdout`.
- `<bw>` is the bandwidth index: 6 = 62.5, 7 = 125, 8 = 250, 9 = 500 kHz.
- LongSlow (SF12) and the Tiny presets (15.6 kHz) are rejected, as they are
  outside the OpenWebRX+ chain.
- `reset()`: the receiver calls it on attach, retune, rate change and stream
  reset. It clears and restarts lorarx and the duplicate filter.
- `set_tuning()` stamps `freq`. Since this change, the receiver also calls
  `set_tuning()` before each baseband/raw-IQ decoder reset, not only for
  audio-tap decoders.
- Each JSON line maps into `phy`, the same way `owrx/meshtastic.py` does it:
  `crc, bw (Hz -> kHz), sf, cr, invers, preamb, duration, level, snr,
  nfloor, pknfloor, afc, fec`.
- `level` is lorarx's uncalibrated signal level, not RSSI in dBm, and the UI
  labels it that way.
- lorarx state is process-global. The backend that most recently configured
  owns the PHY. A superseded instance stays inert, and destroying it does not
  disturb the owner (`sdrcore_meshtastic_phy`).

## Evidence

- `sdrcore_lorarx_parity` (`native/tests/lorarx_parity.sh`) generates each
  fixture with the vendored upstream `loratx` (deterministic). It then decodes
  the fixture twice, once with the unmodified oracle `lorarx` and once with the
  embedded build (`sdrcore_lorarx_replay --restart`, which also proves restart
  equivalence). The two JSON outputs must be byte-identical. Each sent frame
  must also decode with the expected `net/crc/bw/sf/cr`. There are 20 cases:
  - 62.5/125/250/500 kHz at each preset SF, from SF7 to SF11;
  - CR 4/5–4/8 taken from the explicit header;
  - explicit header without payload CRC (`crc:-1`);
  - sync word 0x12 (`net:18`) vs Meshtastic 0x2B (`net:43`);
  - a frame damaged beyond FEC (`crc:0`);
  - white noise;
  - a +20 kHz carrier offset (AFC).
- `sdrcore_meshtastic_phy` runs the full host chain without USB. A u8
  2.4 MS/s LongFast capture, made by loratx from a real Meshtastic text frame
  at +200 kHz off the LO, goes through the Receiver VFO tap and the 1 MS/s
  resampler into the registry backend. The resulting `message` event must
  carry `src`/`dst`/`TEXT_MESSAGE_APP`/`"TestingCLU1234"`, `freq` 869525000,
  `phy.crc 1`, `sf 11`, `cr 5`, `bw 250`, and `level`/`snr`/`nfloor`. The test
  also checks reset/restart, the duplicate drop, and the ownership handover.
- `tool/lorarx_cross_check.sh <ndk> <out>` compiles the embed with NDK r28
  clang for arm64, armv7 and x86_64. Its only external symbols are
  libc/libm/setjmp plus the application sink.
- CPU, Linux host only (Ryzen 7 5700G): the embedded PHY took 4.5 s for 61 s of
  1 MS/s IQ at 250 kHz (about 7% of one core), and 3.5 s at 62.5 kHz.

## Gaps (unverified)

- No over-the-air Meshtastic reception has been tried yet: no known node was
  in range, so packets on air are unverified.
- Android CPU cost at 1 MS/s has not been measured.
- Android and Windows builds were not linked in this change. The C sources
  were cross-compiled with the NDK, and llvm-mingw is left to CI.
- The comparison is against the vendored author-site source, not a
  sample-for-sample replay through a running OpenWebRX+ instance.
