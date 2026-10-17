// SPDX-License-Identifier: GPL-3.0-or-later
//
// bridge.c: in-process link seam for the vendored FlightAware dump1090-fa
// decoder core (see PROVENANCE.md). This file is NEW, written for the
// AirSDR project (sdr_flutter) — it is not derived from any upstream
// dump1090-fa source file. It exists only to satisfy two link-time
// dependencies that upstream's decoder/demodulator translation units have
// on code we deliberately do NOT vendor (dump1090.c's CLI/main, and
// adaptive.c's SDR-gain-driven adaptive control):
//
//   1. `extern struct _Modes Modes;` (declared in dump1090.h) is defined
//      exactly once, here. Upstream normally defines this global in
//      dump1090.c, which we exclude (CLI/argv parsing, main loop, SDR
//      open/run, --help, etc. are all out of scope for an in-process
//      decoder library — see PROVENANCE.md "Excluded upstream files").
//   2. `adaptive_init()` / `adaptive_update()` (declared in adaptive.h) are
//      called unconditionally from demod_2400.c (both Mode S demodulator
//      paths feed every processed/skipped sample run through
//      adaptive_update(), regardless of whether adaptive gain control is
//      enabled). Upstream's real adaptive.c implements SDR-gain-driven
//      burst/range control on top of sdrGetMaxGain()/sdrSetGain() (declared
//      in sdr.h, implemented by dump1090.c's chosen SDR backend) — gain
//      control this embedding must never expose, per the task contract
//      ("no SDR acquisition... no tuner control"). We therefore do not
//      vendor adaptive.c (or sdr.c/sdr_stub.c/net_io.c/fifo.c/anet.c, which
//      it and the CLI would otherwise require); this file supplies
//      no-op bridge implementations instead.
//
// Because this project's combined work is distributed under GPL-3.0-or-later
// (see repository LICENSE and docs/adsb-snapshot-v1.md), and the vendored
// dump1090-fa sources are "GPL-2.0-or-later" (i.e. the author's own "or
// later" grant permits relicensing the combination under GPL-3.0), this
// shim may be licensed under the same GPL-3.0-or-later as the rest of the
// AirSDR native core. See PROVENANCE.md for the full license analysis.

#include "dump1090.h"
#include "adaptive.h"

// The single definition of dump1090's global state struct. `dump1090.h`
// declares it `extern`; every vendored translation unit (mode_s.c,
// demod_2400.c, crc.c, cpr.c, track.c, comm_b.c, ais_charset.c, mode_ac.c,
// icao_filter.c, util.c, stats.c, convert.c) references fields of it.
//
// All fields default to zero (static storage duration, no initializer list
// needed beyond the one explicit field below), matching a fresh
// zero-initialized `struct _Modes` the way upstream's own
// `dump1090.c:initializeState()` starts before applying command-line
// defaults — except we do not run any CLI default-setting code at all.
// The in-process C++ adapter (owned by the parent task, not this file) is
// responsible for calling the startup functions upstream's
// `initializeState()`/`dump1090.c:main()` would otherwise call before
// feeding any samples: `modesChecksumInit(fixBits)`, `icaoFilterInit()`,
// `modeACInit()` (all declared in the vendored headers this library
// exposes), and for setting any additional `Modes.*` fields it needs
// (e.g. `Modes.fUserLat`/`fUserLon`/`bUserFlags`/`maxRange` for CPR
// receiver-relative decoding, `Modes.mode_ac`/`enable_df24`/`nfix_crc` for
// decode policy) before calling into `demodulate2400()`/`demodulate2400AC()`.
//
// `Modes.quiet = 1` is the one field this bridge sets explicitly. Several
// vendored functions retained for their *decoding* logic also contain
// legacy stdout/stderr paths that are display-only and have no decode-path
// side effects (`displayModesMessage()` in mode_s.c, gated by
// `!Modes.quiet`; various `fprintf(stderr, ...)` diagnostics in
// icao_filter.c/convert.c/dsp/helpers/tables.c for truly exceptional
// conditions like a full hash table or failed malloc). Setting
// `Modes.quiet = 1` matches OpenWebRX+'s own invocation (`--quiet`, see
// STATUS-adsb-audit.md) and silences the normal per-message
// `displayModesMessage()` output without touching mode_s.c itself: this is
// the "minimal conditional seam... to avoid output... references
// (quiet...)" required by the task, implemented entirely by setting this
// pre-existing upstream flag rather than patching mode_s.c's own quiet
// check. `Modes.net` stays at its zero-initialized default (0 / false), so
// the `if (Modes.net) { modesQueueOutput(mm, a); }` branch in
// `mode_s.c:useModesMessage()` is also never taken — this is the "no
// network references" seam, and likewise needs no mode_s.c patch because
// `modesQueueOutput()` is never actually called (only referenced, which is
// resolved by the minimal `#ifdef`-guarded declaration described in
// PROVENANCE.md).
struct _Modes Modes = {
    .quiet = 1,
};

// Upstream's real implementation (native/third_party/dump1090 does not
// vendor adaptive.c) drives SDR gain hardware through sdrGetMaxGain()/
// sdrSetGain() once `Modes.adaptive_burst_control` or
// `Modes.adaptive_range_control` is set. This embedding never sets either
// flag (they stay at their zero-initialized default, `false`, forever —
// nothing in this library or the adapter contract exposes a setter for
// them), so adaptive gain control is permanently disabled here: no decoder
// path may ever command the tuner. adaptive_init() is consequently a no-op;
// callers do not need to invoke it (upstream only calls it once from
// dump1090.c's main(), which this library does not include), but it is
// provided so a caller mirroring upstream's startup sequence can do so
// harmlessly.
void adaptive_init(void)
{
    /* Adaptive SDR gain control is not wired in this embedding: no-op. */
}

// Called unconditionally (regardless of whether adaptive control is
// enabled) from every sample range demodulate2400() processes or skips.
// Upstream's adaptive_update() itself starts with:
//   if (!Modes.adaptive_burst_control && !Modes.adaptive_range_control) return;
// Since both flags are permanently false in this embedding (see
// adaptive_init() above), every real call to upstream's function would
// return immediately without touching `buf`/`decoded`. This no-op
// reproduces exactly that always-disabled behavior without vendoring
// adaptive.c's SDR-gain-driving logic.
void adaptive_update(uint16_t *buf, unsigned length, struct modesMessage *decoded)
{
    (void) buf;
    (void) length;
    (void) decoded;
    /* Adaptive SDR gain control is not wired in this embedding: no-op. */
}

// Reset the Mode A/C repetition history with the single receiver. Clearing
// only its public arrays would underflow track.c's lastcount subtraction.
void sdrcore_dump1090_reset_modeac(void)
{
    extern uint32_t modeAC_lastcount[4096];
    memset(modeAC_count, 0, sizeof(modeAC_count));
    memset(modeAC_lastcount, 0, sizeof(modeAC_count));
    memset(modeAC_match, 0, sizeof(modeAC_match));
    memset(modeAC_age, 0, sizeof(modeAC_age));
}
