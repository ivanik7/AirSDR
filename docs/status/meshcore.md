# STATUS — MeshCore decoder (receive-only)

Contract: [`meshcore-contract.md`](meshcore-contract.md). Branch
`feat/meshcore-native-decoder`.

## What OpenWebRX+ does, and what we add

OpenWebRX+ (`f1e0d1a`) `csdr/chain/lora.py::MeshcoreDemodulator` runs
`lorarx -i /dev/stdin -r 1000000 -f f32 -v -N -Q -H 5 -W 50 -b <meshcore_bw>
-s 7 -s 8 -j /dev/stdout`, and the generic `owrx/lora.py::LoraParser` only
adds `mode`/`freq`. It does **not** interpret MeshCore packets. The app
reproduces that PHY chain exactly and adds a packet interpreter written
against MeshCore firmware `81dbae5` (MIT): `Packet::readFrom`,
`Mesh::onRecvPacket`, `Utils::MACThenDecrypt`, `BaseChatMesh` channels.

## Pieces

- PHY: the same embedded OE5DXL lorarx that Meshtastic uses. There is no second
  LoRa demodulator. lorarx keeps process-global state, so one shared owner
  (`native/src/decoder/lorarx_session.{hpp,cpp}`) now provides the mutex, the
  owner pointer and the single `lorarx_embed_emit` callback for both backends.
  Switching Meshtastic to MeshCore (or back) configures the new owner before
  the old one is destroyed, and the old instance can no longer clear or
  receive the new owner's frames.
- Backend: `native/src/decoder/meshcore.cpp`, registry id `meshcore`, input
  baseband, exact 1 MS/s tuned-VFO tap, result `message`, non-exclusive.
  Strict base64 parsing; FIFO of 256 with oldest-drop counting; events ≤64 KiB;
  `reset()` on retune, rate or generation restarts lorarx and drops pending events.
- Packet layer: `native/src/meshcore/` (`PacketParser`). It covers header
  version/route/type, transport codes, path hash size 1–3, and the bounds
  `path ≤64 B` and `payload ≤184 B`. Payloads: ADVERT (Ed25519 over
  `pubkey‖timestamp‖appdata`; lat/lon, feature words and name are exposed only
  when the signature verifies); ACK checksum; GRP_TXT/GRP_DATA (2-byte
  HMAC-SHA256 checked before AES-128-ECB decryption, using the Public channel
  plus up to 8 user channels with 16/32-byte hex secrets);
  REQ/RESPONSE/TXT_MSG/PATH/ANON_REQ are reported as encrypted with their
  hashes; other types are reported as raw hex. Crypto is portable vendored
  source (Monocypher 4.0.2 Ed25519, Brad Conte SHA-256/AES); the runtime does
  not use OpenSSL. Provenance: `native/src/meshcore/README.md`.
- Dart: one catalog row `meshcore`, a selected-only panel
  (`lib/ui/decoders/meshcore_*.dart`) with a bandwidth picker (62.5/125/250/500
  kHz), an obscured channel-key editor, a packet log with full-JSON detail, a node
  list built only from verified ADVERTs, and channel messages only after MAC
  verification. Quick-tune (869.618 MHz, EU/UK narrow) goes through
  `CenteredReceiver.tune`. Secrets persist with presets but are scrubbed from
  the detail JSON and UI.

## Verification (this branch)

| Check | Result |
|---|---|
| `ctest` (Release host build) | **46/46 passed** |
| `sdrcore_meshcore_packet` (firmware-derived vectors; independent OpenSSL AES/HMAC/SHA-256/Ed25519) | passed; also under ASan+UBSan |
| `sdrcore_meshcore_iq` same-IQ oracle | `loratx` SF8/CR8/62.5 kHz/sync 0x12 ACK → unmodified upstream `lorarx` CLI with the OpenWebRX+ argv **and** the app registry backend on the same file: identical payload, SF/CR/BW, ACK checksum |
| `sdrcore_decoder_abi` | `meshcore` descriptor: baseband, 1 MS/s, message, non-exclusive |
| Meshtastic regression (`meshtastic_phy`, `lorarx_parity`, `meshtastic_tap`) after the shared-owner refactor | passed |
| `flutter analyze` | no issues |
| `flutter test --concurrency=2` | **+546 ~17**, all passed (17 opt-in hardware/library skips) |
| `flutter build linux --debug` + 25 s `xvfb-run` | built; Blog V4 detected; no Dart exception |
| `flutter build apk --debug` | built, 166,114,925 B |
| `flutter build apk --release --split-per-abi --target-platform android-arm64` | built, 22,223,115 B |

Live air on the host Blog V4 through the app's v3 + decoder ABI
(`sdrcore_host_meshtastic_live --decoder meshcore`, 869.618 MHz, 2.4 MS/s,
gain 40 dB): 300 s, **0 packets**, 0 dropped samples/events, voice audio fully
silent (0 non-silent frames; the no-decoder baseline had 2.86 M). No MeshCore
node was heard. This does not show that over-the-air decoding works.

Host CPU (Ryzen 5700G VM): no decoder 6.87 CPU-s per 60 s (0.115 core);
MeshCore 78.74 CPU-s per 300 s (0.262 core), so about +15 % of one core.

## Not verified / gaps

- Over-the-air MeshCore reception: no packet was heard. A keyed node (for
  example Ivan's Heltec on MeshCore firmware) is needed.
- Firmware `Packet.cpp`/`Utils.cpp` were not compiled as a second oracle
  (they need Arduino and rweather/Crypto). Vectors reproduce the firmware
  layout and crypto independently through OpenSSL.
- Same-IQ oracle covers ACK only at SF8/62.5 kHz. ADVERT/GRP_TXT over IQ
  were not round-tripped (parser-level vectors only).
- Android emulator behaviour and Android CPU: not checked. No phone was used.
- APK size delta against a same-config master baseline: not measured.
  Debug was 165,809,817 B on the Meshtastic card versus 166,114,925 B here
  (+305 KB, different build times; indicative only).
- Quick-tune lands on 869.6125 MHz, not 869.618. The normal tuning path
  snaps to the 12.5 kHz step grid (covered by `test/ui/meshcore_test.dart`).
  That leaves a 5.5 kHz offset inside the 62.5 kHz LoRa channel. Whether
  lorarx tolerates it over the air is unverified; the same-IQ oracle was
  centred.
- Regional MeshCore presets other than EU/UK narrow (for example for Kazakhstan)
  were not verified against the current MeshCore app config; only
  869.618 MHz is offered as quick-tune.
- Private TXT_MSG/REQ/RESPONSE stay encrypted by design. A listener has no
  node identity key.
