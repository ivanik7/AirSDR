# DMR receive-chain oracle

Compares the app's native DMR chain (`sdrcore::dmr::Channel` + `Framing` +
`VoiceOutput`) with the unmodified OpenWebRX+ modules on identical input.
Host-only; nothing here ships in the app. Results, method, thresholds,
provenance and gaps: `docs/status/dmr-chain-oracle.md`.

- `encode.cpp` -> `dmr_tx_encode OUT_DIR`: synthetic BS-sourced DMR
  (MMDVMHost a819ae64 encoders): `tx.dibits`, `tx_ts{1,2}.ambe`, `truth.txt`.
- `modulate.cpp` -> `dmr_modulate RATE OFFSET_HZ CNR_DB SEED < dibits > cf32`.
- `chain.cpp` -> `owrx_chain` (pristine csdr-plus/digiham-plus) and
  `native_chain` (app libraries): `iq RATE PREFIX` or `dibits PREFIX`,
  stdin input, writes `PREFIX.{sym,ambe,meta}`.
- `compare.py CHAIN_WORK VOICE_WORK OUT_DIR [--golden DIR]`: runs all cases,
  applies thresholds, writes `report.json`; `--golden` refreshes the CTest
  fixture `native/tests/data/dmr_chain` (CTest `sdrcore_dmr_chain_fixture`).

```
CSDR_BUILD=<sstv oracle work>/csdr-build tool/dmr_voice_oracle/build_oracle.sh VWORK
CSDR_BUILD=<sstv oracle work>/csdr-build tool/dmr_chain_oracle/build_oracle.sh CWORK
python3 tool/dmr_chain_oracle/compare.py CWORK VWORK OUT
```
