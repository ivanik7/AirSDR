# Provenance: vendored FlightAware dump1090-fa decoder core

## Upstream pin

Source: FlightAware `dump1090` (dump1090-fa), commit
`0339a57b89cd6e61856cbb13ae342c31ae7be5ac` (2026-07-01 15:08:02 -0500), local
reference checkout `~/prj/ref/openwebrx/ext/dump1090` (vendored as part of
OpenWebRX+'s `ext/` tree; upstream project is
https://github.com/flightaware/dump1090). See
`STATUS-adsb-audit.md` for the source/feasibility audit this embedding
implements §"Concrete integration blockers and ordered plan" item 2.

License: **GPL-2.0-or-later** — see the vendored `LICENSE` and `COPYING`
files (full upstream GNU GPL v2 text) and each vendored file's own header.
Several files (`dump1090.h`, `mode_s.h`/`.c`, `track.h`/`.c`, `stats.h`/`.c`,
`util.h`/`.c`) additionally incorporate 2012 BSD-style-licensed work by
Salvatore Sanfilippo (reproduced in `LICENSE`); that attribution is retained
in the per-file headers. Decode algorithms and tables are unchanged; the
vendored `mode_s.c` network seam, `crc.c` reinitialization cleanup, and `dump1090.h` C++ parsing shim are
documented below.

## Files in this directory

### Headers (declarations only; included transitively via `dump1090.h`)

`dump1090.h dsp-types.h util.h anet.h net_io.h crc.h demod_2400.h stats.h
cpr.h icao_filter.h convert.h sdr.h fifo.h adaptive.h track.h mode_s.h
comm_b.h ais_charset.h cpu.h compat/compat.h` — copied verbatim from the
upstream root (`compat/compat.h` from `compat/`). These are headers only;
vendoring them does not pull in network/SDR-acquisition code, they merely
let `dump1090.h`'s own `#include` chain resolve and expose the small set of
upstream types/prototypes (`struct mag_buf`, `struct modesMessage`, `struct
aircraft`, `demodulate2400()`, `modesChecksumInit()`, `icaoFilterInit()`,
`modeACInit()`, ...) that the parent C++ adapter needs. `net_io.h`, `sdr.h`,
`fifo.h`, and `adaptive.h` declare functions whose *implementations*
(`net_io.c`, `sdr*.c`, `fifo.c`, `adaptive.c`) are intentionally **not**
vendored (see "Excluded upstream files" below); the handful of those
declared functions that are actually referenced by compiled code
(`adaptive_init`/`adaptive_update`, `modesQueueOutput`) are resolved by
`bridge.c` (new file) or compiled out (see "Conditional seam" below), not
by vendoring their real implementations.

### Decode-only core sources (verbatim except the one documented seam)

| File | Role |
|---|---|
| `demod_2400.c`/`.h` | 2.4 MS/s Mode S pulse-position demodulator (`demodulate2400`) and Mode A/C demodulator (`demodulate2400AC`). |
| `mode_s.c`/`.h` | Mode S/ADS-B message decode (`decodeModesMessage`), scoring (`scoreModesMessage`), dispatch (`useModesMessage`). **One seam, see below.** |
| `mode_ac.c` | Mode A/C <-> Mode C altitude conversion tables (`modeACInit`, `modeAToModeC`, `modeCToModeA`) and `decodeModeAMessage`. (`mode_ac.h` does not exist upstream; prototypes live in `dump1090.h`.) |
| `crc.c`/`.h` | Mode S CRC/syndrome tables and optional 1/2-bit error correction (`modesChecksumInit`, `modesChecksum`, `modesChecksumDiagnose`, `modesChecksumFix`). `modesChecksumInit` frees previous tables on repeated calls; upstream initializes only once. |
| `cpr.c`/`.h` | Compact Position Reporting global/local/relative/surface decode. |
| `track.c`/`.h` | Aircraft state tracking, per-field validity/reliability/TTL, CPR position resolution dispatch, `trackPeriodicUpdate`. |
| `comm_b.c`/`.h` | Comm-B (BDS) message decode, used by `mode_s.c`. |
| `ais_charset.c`/`.h` | 6-bit AIS character table used by callsign decode in `mode_s.c`/`comm_b.c`. |
| `icao_filter.c`/`.h` | ICAO address trust hashtable (`icaoFilterInit/Add/Test/TestFuzzy/Expire`). |
| `util.c`/`.h` | Clock helpers (`mstime`, `messageNow`/`_messageNow`, `receiveclock_*_elapsed`), CPU timing, thread naming/join. |
| `stats.c`/`.h` | Decoder/CPR/tracking counters (`struct stats`, `add_stats`, `reset_stats`, `display_stats`, `add_timespecs`). |
| `convert.c`/`.h` | IQ -> magnitude converter selection (`init_converter`/`cleanup_converter`), calls the starch dispatcher below. |
| `cpu.c`/`.h` | Runtime CPU/SIMD-flavor detection helpers used by the starch dispatcher registries (only the always-present `generic`/`#else` paths are reachable here; see "Generic starch mix" below). |

### Generic starch DSP magnitude dispatcher (`dsp/`)

| File | Role |
|---|---|
| `dsp/generated/starch.h` | Generated registry/typedef declarations for all starch functions and flavors (verbatim; "do not edit" header is upstream's own, not ours). |
| `dsp/generated/dispatcher.c` | Generated flavor-selection/ranking/wisdom-file logic (verbatim). |
| `dsp/generated/flavor.generic.c` | Generated: defines `STARCH_SYMBOL`/`STARCH_IMPL` for the `generic` flavor and `#include`s the four `dsp/impl/*.generic.c` files below (upstream's own code-generation convention — see `dsp/generated/starch_generic.cmake`, which this CMake file mirrors for a single flavor). |
| `dsp/impl/magnitude_sc16.generic.c` | Exact SC16 (`int16` interleaved I/Q) -> `uint16` magnitude, `exact_u32`/`exact_float` variants. **This is the exact conversion `docs/adsb-snapshot-v1.md`'s SC16 ingress contract and `STATUS-adsb-audit.md`'s audit both reference** (`min(65535, 2*sqrt(I^2+Q^2))`, float variant shown; `exact_u32` is the integer-math equivalent). |
| `dsp/impl/magnitude_uc8.generic.c`, `magnitude_power_uc8.generic.c`, `magnitude_sc16q11.generic.c`, `mean_power_u16.generic.c`, `count_above_u16.generic.c` | Other starch primitives `convert.c`/`stats.c`'s dispatch paths can reach (UC8/SC16Q11 input formats, mean-power, threshold-counting); vendored for a complete, buildable starch registry set — only the SC16 path above is expected to be exercised by this project's decoder adapter (2.4 MS/s SC16 ingress per `docs/adsb-snapshot-v1.md`). |
| `dsp/helpers/tables.c`/`.h` | Lookup-table builders (`get_uc8_mag_table`, `get_sc16q11_mag_{11,12}bit_table`) used by the `lookup`/`*_table` starch impls above. |

**Not vendored** from `dsp/`: `dsp/generated/flavor.x86_avx2.c`,
`flavor.armv7a_neon_vfpv4.c`, `flavor.armv8_neon_simd.c` (SIMD flavors —
only the portable `generic` flavor is built, selected via
`STARCH_MIX_GENERIC` in `dump1090.cmake`, matching this project's other
vendored libraries' "no per-arch SIMD source variant" convention — see
e.g. `liquid-dsp`'s SIMD exclusion filter in `third_party/rds.cmake`).
`dsp/impl/*.neon.c`, `*.benchmark.c`; `dsp/generated/benchmark.c`,
`makefile.*`, `starch_{x86,arm,aarch64}.cmake`, `starchgen.py`; `starch/`
(the code generator itself, not needed to build already-generated output);
`wisdom*` (runtime SIMD-flavor-preference files, meaningless with only one
flavor compiled in).

### `bridge.c` and `dump1090.cmake` — new files, not upstream

`bridge.c` (in this directory) and `../dump1090.cmake` are **new files
written for this project**, not derived from any upstream dump1090-fa
source. `bridge.c` defines the single required global `struct _Modes
Modes` instance and provides no-op `adaptive_init()`/`adaptive_update()`
implementations (see "Excluded upstream files" and "Conditional seams"
below for why). The bridge also clears all four Mode A/C repetition arrays
on retune/stream reset, including upstream's `modeAC_lastcount`, so the
next track-periodic subtraction cannot underflow. `dump1090.cmake` is this
library's CMake build file.

## Excluded upstream files (not vendored at all)

`dump1090.c` (CLI argument parsing, `main()`, the SDR read/demod main loop,
periodic background-task scheduling, `--help`); `sdr.c`/`sdr_stub.c`/
`sdr_ifile.c`/`sdr_rtlsdr.*`/`sdr_bladerf.*`/`sdr_hackrf.*`/`sdr_limesdr.*`/
`sdr_soapy.*` (SDR device acquisition — this embedding performs **no** SDR
acquisition or tuner control of any kind, matching the task contract);
`fifo.c` (cross-thread SDR-to-demodulator FIFO, meaningless without a
separate SDR-reader thread); `net_io.c`/`anet.c` (TCP network services,
Beast/SBS/Stratux/raw protocols, `generateAircraftJson`/file JSON output —
**no network references** are compiled into this target at all, matching
the task contract; see "Conditional seam" below for how `mode_s.c`'s single
call site into this excluded file is handled); `interactive.c` (ncurses
terminal UI); `view1090.c`/`faup1090.c` (separate upstream executables that
are not needed and are not linkable library code as-is per
`STATUS-adsb-audit.md`); `adaptive.c` (SDR-gain-driven adaptive burst/range
control — see "Conditional seams" below); `cprtests.c` (upstream's own CPR
unit-test executable; this task's only verification step is the isolated
CMake compile described below, not re-running upstream's test suite);
`public_html/` (web UI assets); `oneoff/` (benchmark/measurement programs);
`bladerf/` (BladeRF-specific FPGA bitstream, irrelevant hardware); `Makefile`
(upstream's own GNU Make build, superseded by `dump1090.cmake`);
`compat/clock_nanosleep/`, `compat/clock_gettime/` (polyfills for platforms
lacking POSIX clock functions — not needed on this project's Linux/Android
targets, which both provide `clock_gettime`/`clock_nanosleep` natively via
glibc/bionic).

## Conditional seams

Per the task: "Provide a minimal conditional seam in vendored mode_s.c to
avoid output/network references (quiet/no network), and no-op
adaptive_update when disabled (no tuner control) in a new vendored bridge
C file."

1. **Quiet / no display output**: `bridge.c` sets `Modes.quiet = 1` in the
   `struct _Modes Modes` initializer. This alone makes
   `mode_s.c:useModesMessage()`'s existing
   `if (!Modes.interactive && !Modes.quiet && ...) displayModesMessage(mm);`
   guard permanently false — **no patch to `mode_s.c` was needed for this
   half of the seam**, because `Modes.quiet` is an upstream field upstream
   itself already checks at that exact call site; setting it is sufficient
   and matches OpenWebRX+'s own `--quiet` invocation flag
   (`STATUS-adsb-audit.md` §"Actual OpenWebRX+ behavior").
2. **No network references**: `mode_s.c:useModesMessage()`'s
   `if (Modes.net) { modesQueueOutput(mm, a); }` call is different: `Modes.net`
   being permanently `0` (zero-initialized, no setter exposed) makes the
   call unreachable at *runtime*, but the call expression itself still
   requires `modesQueueOutput` (declared in the excluded `net_io.h`,
   defined in the excluded `net_io.c`) to exist as a link-time symbol —
   the `if` is a runtime branch on a non-const global, which the compiler
   cannot fold away and omit at compile time. The **minimal** change
   actually needed is therefore not a stub implementation of
   `modesQueueOutput` (which would require either vendoring parts of
   `net_io.c`'s types or hand-maintaining a signature-matching stub with
   no real body — functionally fine, but still a form of "network
   reference" surviving in the binary's symbol table) but compiling the
   call out entirely: `mode_s.c`'s single call site is now wrapped in
   `#ifdef SDRCORE_DUMP1090_WITH_NET_IO ... #endif`, which `dump1090.cmake`
   never defines. The result: zero bytes of this build's `mode_s.o`
   reference `modesQueueOutput`, and no network code of any kind is
   compiled into `sdrcore_dump1090`. This is the one documented
   source-level change to a vendored `.c` file; it is a 10-line comment
   plus a pair of `#ifdef`/`#endif` lines around the pre-existing
   3-line `if` block, changing no decode-path behavior (the branch was
   already permanently false at runtime; it is now also absent at compile
   time).
3. **No tuner control (adaptive gain)**: `demod_2400.c` calls
   `adaptive_update()` unconditionally from both `demodulate2400()` and
   `demodulate2400AC()`, for every processed and skipped sample range —
   this call is **not** gated by any `Modes.*` flag at the call site
   (upstream's own `adaptive_update()` implementation in the excluded
   `adaptive.c` does the gating internally: `if
   (!Modes.adaptive_burst_control && !Modes.adaptive_range_control)
   return;`). Since this embedding never sets either
   `Modes.adaptive_burst_control` or `Modes.adaptive_range_control` (they
   stay at their zero-initialized default, `false`, and no setter is
   exposed by this library), the real upstream function would always
   return immediately without touching its arguments or any SDR gain
   state — this embedding's `bridge.c` reproduces exactly that
   always-returns-immediately behavior as an explicit no-op, without
   vendoring `adaptive.c`'s `sdrGetMaxGain()`/`sdrSetGain()`-driving burst
   /range control logic at all. `adaptive_init()` is likewise a no-op
   (upstream only calls it once from the excluded `dump1090.c:main()`
   anyway).
4. **The global `Modes` struct**: every vendored decode/track/stats
   translation unit references `extern struct _Modes Modes;` (declared in
   `dump1090.h`). Upstream defines the one real instance in the excluded
   `dump1090.c`. `bridge.c` provides the sole definition instead, so this
   project links without needing any part of `dump1090.c`.

`dump1090.h` has an additional C++-only `atomic_int` typedef for the
unused `Modes.exit` field: the upstream C11 `<stdatomic.h>` typedef cannot
be parsed inside the adapter's `extern "C"` include. The C ABI and all C
translation units retain upstream's original atomic type. `crc.c` additionally
releases its correction tables before reinitialization (on decoder reset);
this changes memory ownership only, not the CRC algorithm. No other vendored
`.c` file was patched. `mode_ac.c`, `cpr.c`,
`comm_b.c`, `ais_charset.c`, `icao_filter.c`, `util.c`, `stats.c`,
`convert.c`, `cpu.c`, every `dsp/` file, and every other header are
byte-for-byte copies of the pinned commit.

## Startup sequence required of callers

This library does not call any of its own startup functions automatically
(upstream's `dump1090.c:main()`/`initializeState()` normally does, as part
of code this embedding excludes). Before feeding any samples to
`demodulate2400()`/`demodulate2400AC()`, a caller (the in-process C++
adapter, owned by the parent task per `STATUS-adsb-audit.md`) must call, in
this order, once per decoder session:

1. `modesChecksumInit(fixBits)` — `fixBits=0` matches OpenWebRX+'s own
   default (`Modes.nfix_crc` starts at 0 upstream; `STATUS-adsb-audit.md`
   §"Actual OpenWebRX+ behavior": "The chain does not add `--fix` or
   `--fix-2bit`"). `Modes.nfix_crc` should be set to the same value the
   caller passes to `modesChecksumInit` so `demod_2400.c`'s
   `init_bitsets()`/`generate_damage_set()` paths stay consistent with the
   CRC correction tables actually built.
2. `icaoFilterInit()`
3. `modeACInit()` — required because Mode A/C decoding is in scope
   (`STATUS-adsb-audit.md`: "`--modeac` enables Mode A/C demodulation").

Per-session `Modes.*` fields a caller will typically also set directly
(there is no setter API; `dump1090.h`'s `struct _Modes` fields are public):
`Modes.mode_ac` (1 to call `demodulate2400AC()` at all — mirrors
`--modeac`), `Modes.enable_df24` (DF24..31 Comm-D ELM decode), `Modes.fUserLat`
/`fUserLon`/`bUserFlags |= MODES_USER_LATLON_VALID` (receiver position for
surface/local-CPR and range-check math in `track.c`, only if the caller has
an explicitly configured receiver location per `docs/adsb-snapshot-v1.md`),
`Modes.maxRange` (receiver-centered CPR range sanity check — see
`STATUS-adsb-audit.md` §"Source boundary and dependencies"). The caller is
also responsible for the live-clock background work upstream's main loop
does and `SDR_IFILE` input skips (`STATUS-adsb-audit.md` §"Actual OpenWebRX+
behavior": "The embedded live receiver must explicitly call
`icaoFilterExpire()` and `trackPeriodicUpdate()` on its wall clock"), and
for setting `_messageNow`/calling `mstime()`-consistent timestamps per
message the way `track.c`/`util.h`'s `messageNow()` expect.

## License compatibility

GPL-2.0-or-later (dump1090-fa) with each file's own "or (at your option)
any later version" grant, combined into this project's GPL-3.0-or-later
codebase (see repository `AGENTS.md`: "License: GPL-3.0"): the "or later"
grant on the GPL-2.0 side permits redistributing the combined work under
GPL-3.0-or-later, the stricter of the two applicable terms — the same
license-compatibility pattern already documented for `rtl-sdr`
(GPL-2.0-or-later) in `native/third_party/NOTICE.md`. The complete upstream
GPL-2.0 text is retained verbatim in the vendored `LICENSE`/`COPYING`
files; no copyright or license header was stripped from any vendored file.
`bridge.c` and `dump1090.cmake` (new files written for this project) are
licensed GPL-3.0-or-later, consistent with the rest of this project's
native sources and compatible with being linked into the same static
target as the GPL-2.0-or-later vendored sources.

## Build target

`sdrcore_dump1090` (static library), defined in `../dump1090.cmake`. Public
include directory: this vendored root (`native/third_party/dump1090`), so
both this target's own sources and any external C++ adapter can
`#include "dump1090.h"` unqualified, matching upstream's own `-I.` include
convention (`Makefile:7`, `DUMP1090_CPPFLAGS := -I. ...`). Links
`Threads::Threads` (for `pthread_setname_np`/`pthread_timedjoin_np` in
`util.c`) and `m` (for `sqrtf`/`log10`/etc. used throughout the
demodulator/CRC/CPR/stats code). No network, SDR-acquisition, or
executable target is produced by this file.

## Isolated compilation check performed by this task

See `STATUS-adsb-audit.md`'s own precedent ("14 relevant upstream C
translation units passed host `cc -std=c11 ... -fsyntax-only`") for the
baseline this task re-verifies against the final vendored+bridged tree,
now as a real static-library CMake build (not just `-fsyntax-only`) that
also exercises the link step (`bridge.c`'s `Modes` definition and
no-op `adaptive_update` resolving every reference the decode/track/stats
sources make into previously-excluded files). Exact command and result are
recorded in this task's final report (not duplicated here to avoid
drifting out of sync with re-runs); re-run with:

```
cmake -S native -B "$HOME/.hermes/profiles/sdr-dev/cache/scratch/adsb-build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$HOME/.hermes/profiles/sdr-dev/cache/scratch/adsb-build" -j3 --target sdrcore_adsb_backend_test
```

(or see the parent `native/CMakeLists.txt`'s own `add_subdirectory(third_party)`
/ `include(third_party/dump1090.cmake)` wiring once the parent task
integrates this target — this task does not modify `native/CMakeLists.txt`
itself, per its file-ownership boundary).
