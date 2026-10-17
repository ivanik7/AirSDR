# STATUS — Meshtastic packet, message and node UI

Card t_dc3a6f15, branch `feat/meshtastic-packet-ui`. This is the Flutter side
of the Meshtastic decoder. It shows only real native `message` events from the
`meshtastic` decoder (`"mode":"Meshtastic"`, documented in
`docs/status/meshtastic.md`). There is no demo data.

The layout follows the OpenWebRX+ `MeshtasticMessagePanel`
(`htdocs/lib/MessagePanel.js` at f1e0d1a: Time · From · To · Data rows, with
text and attribute rows below), rearranged as cards for a 344 dp screen.

## Files

| File | Purpose |
|---|---|
| `lib/ui/decoders/meshtastic_keys.dart` | Channel PSK parsing that mirrors native `resolve_key` (default/`AQ==`, 1-byte default variants, hex with `0x` and `:`/`-` separators, strict base64, 1..32 bytes, zero-padding to 16/32). Also normalizes the `channels` setting (max 8 entries, names ≤11 ASCII chars) and redacts configured keys. Errors never contain key text. |
| `lib/ui/decoders/meshtastic_packets.dart` | `MeshtasticPacket.fromEvent` (header, PHY, encrypted/decrypt states, OWRX+ attribute conversions), `MeshtasticNode`, and `MeshtasticLog` (250 packets and 250 texts as in OWRX+ `clearMessages(250)`, 500 nodes, newest first). |
| `lib/ui/decoders/meshtastic_mode_panel.dart` | Status, preset/region, quick tune, key list and editor, and the Packets / Text / Nodes views. |
| `lib/ui/decoders/decoder_contract.dart` | `DecoderSetting.normalize` and `accept()` for structured values; the `channels` setting. |
| `lib/ui/decoders/decoder_session.dart` | Routes events to `meshtastic` and clears packets on reset (see Behaviour). |
| `lib/ui/favorites/favorites.dart` | Presets keep `preset`, `region` and valid `channels` through the same `accept()` path. |
| `native/tests/meshtastic_ui_fixture.cpp` | ctest `sdrcore_meshtastic_ui_fixture`: runs the real `PacketParser` over `native/tests/data/meshtastic_vectors.json` and checks that `test/ui/fixtures/meshtastic_native_events.json` matches byte for byte. |

## Config sent to native

`{"version":1,"settings":{"preset":"LongFast","region":"EU_868","channels":[{"name":"","psk":"…"}]}}`

The contract is posted on t_fc46969e. `region` is only used for Dart
quick-tune. The PHY/backend card maps `preset` and `channels` to
`ParserConfig` and must not log them.

## Behaviour

Packet rows:

- Each row shows UTC HH:MM:SS from the native `timestamp`, `!xxxxxxxx` → `ALL`
  or the destination, and the port type.
- Decoded text is shown beneath.
- The row also shows frequency, SF/BW/CR, level and SNR, plus the header
  (packet id, hop, channel hash, flags). lorarx sends BW in Hz; it is shown
  in kHz.
- Tapping a row expands the attribute rows and the full JSON.
- Encrypted packets have explicit states: `Encrypted · unknown key`,
  `key did not decode`, and PKI-possible. They never become text or nodes.

Attribute conversions follow OWRX+: `latitude_i`/`longitude_i` ×1e-7,
battery %, voltage V, utilisation %, temperature °C, `time` as ISO UTC, and
`macaddr` as hex.

Nodes:

- Nodes are built from decoded NODEINFO, POSITION and TELEMETRY packets.
- A decoded packet from a node that is already known updates its SNR, last
  heard time and packet count.
- A text from an unknown node does not create a node.

Clearing:

- A retune, VFO offset or sample-rate change, receiver stop, a new native
  stream generation, or selecting another decoder clears the packet and
  text logs.
- The node list survives a retune, like the OWRX+ node cache.
- The Clear button clears packets/texts; "Clear nodes" clears the node list.

Keys:

- The PSK field is obscured, has suggestions, IME learning and autocorrect
  off, and is never pre-filled on edit.
- The list shows only the name and the key kind: default, no encryption,
  `default #n`, AES-128 or AES-256.
- Any configured non-public key text (raw, base64 or hex form) is redacted
  as `[redacted]` in packet strings before they are stored or shown.
- Keys are saved with presets in SharedPreferences, like other decoder
  settings. They are not encrypted at rest.

Without the native PHY (`create=nullptr` until t_fc46969e lands), the panel
says `Decoder unavailable: native LoRa PHY not installed`, and the key editor
notes that keys take effect once the decoder is available.

## Tests

| Command | Result |
|---|---|
| `flutter analyze` | No issues found |
| `flutter test --concurrency=2` (full suite) | +540 ~17, all passed |
| `flutter build apk --debug` | built `app-debug.apk` |
| `flutter test test/ui/meshtastic_packets_test.dart test/ui/meshtastic_panel_test.dart` | 24 passed |
| `cmake --build build/mesh-ui && ctest` | 41/41 passed, including `sdrcore_meshtastic_ui_fixture` |

New tests:

- `meshtastic_packets_test.dart` (20 tests):
  - fixture integrity
  - packet parsing of the real on-air text vector, BW Hz→kHz, and the
    unknown/wrong-key states
  - OWRX+ attribute conversions, and rejection of non-Meshtastic events
  - log bounds, node merging and bounds
  - `resolve_key` parity cases taken from `meshtastic_packet_test.cpp`, key
    kinds, `channels` normalization, and redaction
  - session config, routing, clearing on retune/generation/mode, the
    not-ready state below 1 MS/s, and the preset round-trip
- `meshtastic_panel_test.dart` (4 tests):
  - packets/text/nodes views at 344 and 720 dp
  - the key dialog: obscured, never pre-filled, validation error, AES-256
    label, no key text in the tree, delete
  - region/preset quick tune through `CenteredReceiver`
    (centre == tuned, offset 0)

The tests were written alongside the code, not strictly RED first. To show
they bite, three mutations were applied and each failed the tests before
being reverted:

- disabled redaction → the redaction test failed
- packet bound off by one → the log bound test failed
- removed clear-on-reset → the retune/generation test failed

## Not verified / gaps

- Live-air Meshtastic packets in the UI: not possible yet. The native
  LoRa PHY (t_fc46969e) is still in progress, and the registry entry has
  `create=nullptr`. All UI tests use real native packet-parser output for
  vector packets, not PHY-decoded air traffic.
- Linux host: `flutter build linux --debug` built, and a 20 s `xvfb-run`
  launch ran until `timeout` (exit 124) with no Dart exception. The
  RTL-SDR Blog V4 was not attached to the host during this run (`lsusb`
  showed only hubs), so no hardware session or screenshot was taken.
  It could only show the unavailable state until the PHY lands anyway.
- Android emulator behaviour of the panel: not checked; nothing in this
  change is Android-specific.
- Keys are stored unencrypted in SharedPreferences, alongside other preset
  settings. Platform keystore storage would be a separate task.
- No map view for node positions; OWRX+ links to its map, but this app
  has none.
