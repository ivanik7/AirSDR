# MeshCore native packet interpreter

The wire layout and crypto operation order are adapted from MeshCore firmware
[`81dbae592ffad40b4212bc0b37e82b38da08f4bc`](https://github.com/meshcore-dev/MeshCore),
MIT (`license.txt` in upstream repository): `src/Packet.cpp`, `src/Mesh.cpp`,
`src/Utils.cpp`, `src/helpers/BaseChatMesh.cpp`, `docs/packet_format.md`, and
`docs/payloads.md`. No firmware source was copied. The static public channel
key comes from upstream `docs/qr_codes.md` and is intentionally never in JSON.

Portable crypto:

- `native/third_party/meshcore/monocypher/{monocypher.c,monocypher.h,monocypher-ed25519.c,monocypher-ed25519.h,LICENCE.md}`:
  Monocypher 4.0.2 by Loup Vaillant et al.; BSD-2-Clause or CC0 (use BSD-2-Clause).
  Upstream: <https://github.com/LoupVaillant/Monocypher/tree/4.0.2/src>.
  Used for Ed25519 detached signature verification only.
- `native/third_party/meshcore/sha256.{c,h}`: Brad Conte crypto-algorithms,
  commit `cfbde48414baacf51fc7c74f275190881f037d32`, public domain
  (`native/third_party/crypto-algorithms/README.md`). Patched `sha256.c` to
  cast input bytes to unsigned WORD before left shifts (UBSan fix).
- Reuse existing `native/third_party/crypto-algorithms/aes.{c,h}` at the same
  upstream revision and the repository's signed-shift UB patch. Encryption
  uses its AES-128 ECB block decrypt operation.

Build `meshcore.cpp` with these four C objects: `sha256.c`, `monocypher.c`,
`monocypher-ed25519.c`, and existing `crypto-algorithms/aes.c`. The runtime
has no OpenSSL dependency; the standalone oracle test links `libcrypto` only
for independent AES/HMAC/SHA/Ed25519 test-vector generation. Existing
`nlohmann/json.hpp` is used for strict settings parsing and output encoding.

The parser checks packet version, transport-code and encoded-path bounds before
reading fields; CRC failure returns no event. HMAC is checked before decrypting;
MAC verifies only the ciphertext (matching firmware). A verified ADVERT signs
`pubkey || timestamp LE || appdata`; unverified ADVERTs do not expose trusted
`advert` fields. Text in GRP_TXT is unverified sender-supplied content, not an
authenticated identity. Private packets remain encrypted without node keys.
No calibrated RSSI is inferred from relative PHY level.

Remaining parity limitation: generated test vectors independently reproduce the
firmware wire layout and crypto operations via OpenSSL, but the embedded
firmware's `Packet` and `Utils` implementations have not been compiled as a
second executable to compare the exact same byte fixtures.
