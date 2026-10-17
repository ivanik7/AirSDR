# STATUS — Meshtastic packet layer (native)

Pure C++ library `sdrcore_meshtastic`
(`native/src/meshtastic/`). It turns one LoRa payload plus PHY metadata into
a UTF-8 JSON event. There is no LoRa PHY, decoder-backend wiring or UI yet;
those are separate pieces of work (LoRa demod, backend/ABI, UI). The library is
linked into `libsdrcore`, but no code path calls it yet, so `--gc-sections`
removes it from the shipped `.so` until the backend wires it.

## Interface (`native/src/meshtastic/meshtastic.h`)

```
PacketParser p;
p.configure(cfg /* ParserConfig */, &err);     // or parse_config_json()
std::optional<std::string> ev = p.parse(bytes, len, PhyMeta{...}, &drop);
p.reset();        // retune / stream restart: clears duplicate state
p.clear_nodes();  // forget learned node names/positions
```

- `PhyMeta` follows lorarx's JSON fields (dxlAPRS `src/lorarx.c`
  `sendjson`), which is what OpenWebRX+ feeds `MeshtasticParser`: `crc`
  (1 ok / 0 bad / -1 none), `bw` kHz, `sf`, `cr`, `invers`, `preamb`,
  `duration`, `level`, `afc`, `nfloor`, `pknfloor`, `snr`, `fec`, plus a
  wall-clock `timestamp_ms`, a `monotonic_ms` used for dedup and node TTL, and
  the dial `frequency_hz`. NaN or INT32_MIN means unknown, and the field is
  then omitted.
- Settings JSON (v1):
  `{"v":1,"preset":"LongFast","channels":[{"name":"Ops","psk":"..."}],"defaultKeyAllPresets":true,"dropDuplicates":true}`
  The settings allow at most 8 channels (the firmware `MAX_NUM_CHANNELS`) and names of 11 characters or fewer. An empty name means the
  preset display name.
- Each helper is exposed separately and tested on its own:
  `parse_header`, `resolve_key`, `channel_hash`, `packet_nonce`,
  `aes_ctr`, `preset_channel_names`.

## Behaviour

Behaviour follows OpenWebRX+ `owrx/meshtastic.py` (commit f1e0d1a), and the key/hash rules follow the
Meshtastic firmware (`Channels.cpp`, `CryptoEngine.cpp`,
`Router.cpp::perhapsDecode`).

- Drops, as in OpenWebRX+: CRC not ok (`crc < 1`); fewer than 16 bytes; the same
  (src, packet id) seen within the last 60 s (only the first 4096 entries are swept). Native
  addition: frames longer than 255 bytes are dropped (`bad_length`).
- Header: dst, src, packet_id, hop_limit, hop_start, want_ack, via_mqtt,
  channel_hash, next_hop, relay_node. The `comment` is `"<len> bytes, hop
  <start-limit>/<start>"`, as in OpenWebRX+.
- Keys (`resolve_key`): `default`/`AQ==` → default PSK. Hex input may have a `0x` prefix and
  `:`/`-` separators; otherwise it is read as strict base64. Expansion follows the firmware rules: a 1-byte index `n`
  gives the default key with its last byte increased by n-1, and index 0 means no
  encryption. Keys of 2..15 bytes are zero-padded to 16; keys of 17..31 bytes are padded to 32. Error strings never contain key
  text, and events never contain keys.
- Decryption follows the firmware rather than OpenWebRX+. The parser tries only candidates whose
  channel hash matches the header byte, in this order: configured channels, then the
  default key under the configured preset name, then (if
  `defaultKeyAllPresets` is set) the default key under every preset display name. A
  candidate is accepted when the plaintext decodes as `Data` with portnum ≠ 0. If no candidate is accepted, the event
  reports `encrypted:true` and includes the ciphertext hex. `decrypt` is
  `unknown_key` when no hash matched and `failed` when a hash matched but no key decoded. `pki_possible` is set for
  hash-0 unicast packets, which are PKI DMs and cannot be decrypted by a listener.
- Payloads (the same port set as OpenWebRX+ `APP_PROTO_DECODERS`, limited to
  vendored messages): TEXT (UTF-8 decode with `errors="replace"`
  semantics), POSITION (lat/lon/altitude), NODEINFO (User), ROUTING
  (`error_reason: NONE` dropped), TELEMETRY (battery/uptime/channelUse/
  airtimeUse/weather), TRACEROUTE, NEIGHBORINFO, WAYPOINT, PAXCOUNTER,
  STORE_FORWARD, REMOTE_HARDWARE. The protobuf→JSON conversion reproduces
  `MessageToDict(preserving_proto_field_name=True)`: presence rules, int64 as
  strings, enum names, bytes as base64, and float32 printed as the shortest
  round-trip representation. Any other portnum produces `raw` hex. A payload that fails
  protobuf decoding produces `raw` plus `payload_error`.
- The node cache works like OpenWebRX+ `MeshtasticCache`. NODEINFO/POSITION entries annotate later
  events with `nickName`/`longName`/`role`/`device`/`lat`/`lon`/`altitude`,
  and with `dstNickName`/`dstLongName` for unicast. Entries expire after 7 days and the cache is capped at 2048 nodes. It
  is in memory only: unlike OpenWebRX+ there is no file persistence and no map/reporting
  side effects.
- Fields added on top of the OpenWebRX+ output: `timestamp`, the header fields listed above,
  `length`, `phy`, `encrypted`, `decrypt`, `channel`, `channel_index` (-1
  means the built-in default key), `request_id`/`reply_id`/`emoji`, `raw`,
  `ciphertext`.

### Deliberate differences from OpenWebRX+

| Topic | OpenWebRX+ | Native |
|---|---|---|
| Key choice | one key, tried regardless of channel hash | firmware hash-matched multi-channel loop |
| Wrong key | emits garbage / drops silently | `encrypted:true`, ciphertext, no content |
| ADMIN_APP, ATAK_PLUGIN, POWERSTRESS | decoded | `raw` hex (protos not vendored) |
| `AA==` | derived key | firmware rule: no encryption |
| Unknown portnum name | Python raises | numeric string in `type` |
| Cache | file-backed, map updates | in memory, bounded |

## Vendored code

See `native/third_party/NOTICE.md` (Meshtastic packet layer section). The
vendored pieces are nanopb 0.4.9.2 (decode runtime only, zlib), Meshtastic protobufs
95c5f8c (GPL-3.0, with committed nanopb output that `regen.sh` regenerates) and B-Con
`aes.c` (public domain, two-line UB patch). Reflection tables for JSON are built
at compile time from the nanopb `FIELDLIST` X-macros
(`native/src/meshtastic/pb_reflect.cpp`), so no descriptor runtime is needed.

## Tests

`sdrcore_meshtastic_packet` (ctest; `native/tests/meshtastic_packet_test.cpp`):

- Header fields and flag bits, using a real packet and a synthetic all-flags header.
- Key forms: default aliases, short indexes 0/1/2/10, AES-128 hex with
  separators, AES-256 base64, padding, and rejections that must not leak key text.
- Channel hash: LongFast with the default key gives 0x08, which matches the real on-air packet.
- AES-CTR: the vectors from the firmware's own CTR test, RFC 3686 #2/#8 multi-block, a 32-bit counter
  wrap, in-place inversion, and the Meshtastic nonce layout.
- Oracle comparison of 22 packets in 4 key configurations. The expected events in
  `native/tests/data/meshtastic_vectors.json` come from the **unmodified**
  OpenWebRX+ `MeshtasticParser.parsePacket`, run by
  `native/tests/meshtastic_oracle.py`, which replaces only OpenWebRX+'s
  infrastructure imports with stubs. The packets are built with the official `meshtastic` Python
  protobufs and encrypted with pycryptodome. One packet is a **real
  over-the-air LongFast capture** published by meshtastic_sdr (gitlab
  crankylinuxuser/meshtastic_sdr, "TestingCLU1234"). The comparison covers text (UTF-8, invalid
  UTF-8), nodeinfo, position, device and environment telemetry, routing
  ack/error, traceroute, neighborinfo, waypoint, paxcounter, admin (raw), a
  raw portnum, a duplicate, header-only and short packets, an unknown key, AES-256, AES-128 hex,
  a wrong key under a matching hash, and short-PSK index 2 with the MediumFast preset.
  `--check` regenerates the fixture and diffs it against the committed file.
- Native semantics: plaintext channel, PHY metadata, CRC drops,
  dedup TTL and `reset()`, unknown hash, the PKI hint, config errors, no key
  material in events, and the >255-byte drop.
- 20 000 deterministic random packets through the AES, plaintext and unknown paths.

Commands and results (host, 2026-10-09):

```
cmake -S native -B $B -DCMAKE_BUILD_TYPE=Release && cmake --build $B -j6
(cd $B && ctest)                             # 23/23 passed
# ASan+UBSan build of sdrcore_meshtastic_packet_test: passed, clean
uv run --no-project --python 3.12 --with meshtastic==2.7.11 \
  --with pycryptodomex==3.24.0 native/tests/meshtastic_oracle.py --check   # OK
```

A mutation check showed the oracle comparison has teeth: changing three expected values in a copy of the
fixture (text, telemetry voltage, routing error) produced exactly 3 failures.

## Not verified / gaps

- There is no LoRa PHY yet, so nothing has been received off-air by this app. The only real-world
  input is the single published packet.
- The ADMIN, ATAK and POWERSTRESS protos are not decoded. TEXT_MESSAGE_COMPRESSED
  (unishox2) is shown as raw bytes plus a best-effort UTF-8 string, as in OpenWebRX+.
- PKI (AES-CCM to a node key) cannot be decrypted by design. Packets are only flagged.
- The node cache is not persisted across app restarts.
