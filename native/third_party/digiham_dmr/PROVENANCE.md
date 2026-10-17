# DMR framing upstream provenance

Source: luarvique/digiham, `beec78229edb8e049f8b82729498def952b79cc1`
(`~/prj/ref/openwebrx/digiham-plus`). License: GPL-3.0, see `LICENSE`.
Copied `src/dmr_decoder` framing, metadata, LC, GPS, talker alias, CACH,
slot type, embedded signalling, BPTC/Hamming/Golay/QR FEC sources and
`src/lib/{hamming_distance,coordinate}`. The CLI, codecserver, csdr pipelines,
ICU and syndrome-generating executables are not part of this library.

Local delta: `dmr_phase` exposes active slot and optional color-code filtering,
reports decoded color codes and observed voice duration; `dmr_meta` adds CC,
privacy indication and duration fields, initializes source/target to zero;
`lc` reads the privacy bit of the service-options octet; `embedded` requires
all four fragments and initializes the decode matrix (upstream reads an
uninitialized fourth fragment when only three are received). `compat` replaces only
csdr stream/metawriter plumbing and ICU ISO-8859-1 conversion. `framing.cpp`
feeds the same digiham phase state machine in process memory. For a source diff,
compare this `upstream/` directory against the named paths at the pinned commit.

Voice LC RS(12,9) is not checked upstream. Data headers/rate-3/4 payloads and
cryptographic decryption are not implemented. GPS and talker alias use the
upstream collectors. Duration is observed 30-ms voice frames per slot, not an
independently verified wall-clock call duration. A color filter suppresses
metadata and AMBE until a validated EMB/slot-type supplies a matching CC;
first voice-sync frame may therefore be muted with the filter on.
