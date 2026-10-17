# FlightAware dump1090-fa Mode S/ADS-B decoder core (GPL-2.0-or-later),
# vendored verbatim except for one narrow conditional seam in mode_s.c (see
# native/third_party/dump1090/PROVENANCE.md). Builds the decode-only subset
# of upstream's translation units plus the generic (non-SIMD) starch DSP
# magnitude-conversion dispatcher as the static target `sdrcore_dump1090`.
#
# Excluded by design (not vendored at all): dump1090.c (CLI/main/argv/SDR
# open-run loop), sdr*.c (SDR acquisition), fifo.c (SDR->demod FIFO),
# net_io.c/anet.c (network and file JSON output), interactive.c (ncurses),
# view1090.c/faup1090.c (separate executables), public_html/ and oneoff/.
# No executable target is defined here and no network or SDR-acquisition
# code is compiled into this target.
#
# This file is included from native/CMakeLists.txt (not modified by this
# task's owner), the same way third_party/csdr_sstv.cmake and
# third_party/rds.cmake are; CMAKE_CURRENT_LIST_DIR below is
# native/third_party.
set(DUMP1090_ROOT ${CMAKE_CURRENT_LIST_DIR}/dump1090)

add_library(sdrcore_dump1090 STATIC
    # Bridge: defines the global `Modes` state and no-op
    # adaptive_init()/adaptive_update() stand-ins for the SDR-gain-driving
    # adaptive.c this embedding deliberately does not vendor. New file,
    # not upstream dump1090-fa source — see PROVENANCE.md.
    ${DUMP1090_ROOT}/bridge.c

    # Upstream decode-only core (verbatim, except mode_s.c's one
    # SDRCORE_DUMP1090_NO_NET_IO #ifdef seam — see PROVENANCE.md).
    ${DUMP1090_ROOT}/demod_2400.c
    ${DUMP1090_ROOT}/mode_s.c
    ${DUMP1090_ROOT}/mode_ac.c
    ${DUMP1090_ROOT}/crc.c
    ${DUMP1090_ROOT}/cpr.c
    ${DUMP1090_ROOT}/track.c
    ${DUMP1090_ROOT}/comm_b.c
    ${DUMP1090_ROOT}/ais_charset.c
    ${DUMP1090_ROOT}/icao_filter.c
    ${DUMP1090_ROOT}/util.c
    ${DUMP1090_ROOT}/stats.c
    ${DUMP1090_ROOT}/convert.c
    ${DUMP1090_ROOT}/cpu.c

    # Generic (portable, non-SIMD) starch DSP magnitude-conversion
    # dispatcher: the exact IQ -> magnitude conversion convert.c calls.
    # flavor.generic.c #includes the dsp/impl/*.generic.c implementation
    # files itself (starch code-generation convention, see
    # dsp/generated/starch_generic.cmake upstream); do not add those impl
    # files as separate sources, or they will be compiled twice.
    ${DUMP1090_ROOT}/dsp/generated/flavor.generic.c
    ${DUMP1090_ROOT}/dsp/generated/dispatcher.c
    ${DUMP1090_ROOT}/dsp/helpers/tables.c
)

set_target_properties(sdrcore_dump1090 PROPERTIES
    POSITION_INDEPENDENT_CODE ON
    C_STANDARD 11
    C_STANDARD_REQUIRED ON
    C_EXTENSIONS ON)

# Vendored root is the PUBLIC include dir: upstream's own headers
# #include each other unqualified (e.g. dump1090.h does
# `#include "util.h"`), and the parent C++ adapter needs the same upstream
# headers (dump1090.h, mode_s.h, track.h, demod_2400.h, crc.h, cpr.h,
# icao_filter.h, stats.h, ...) on its own include path to declare/call
# modesChecksumInit(), icaoFilterInit(), modeACInit(), demodulate2400(),
# etc. and to read/write `struct _Modes Modes` fields.
target_include_directories(sdrcore_dump1090 PUBLIC ${DUMP1090_ROOT})

# STARCH_MIX_GENERIC selects the portable magnitude-conversion flavor in
# dsp/generated/starch.h / flavor.generic.c (see upstream's own
# starch_generic.cmake, which this mirrors for a single vendored flavor).
# _POSIX_C_SOURCE/_DEFAULT_SOURCE mirror upstream's own Makefile
# (DUMP1090_CPPFLAGS) so clock_gettime/localtime_r/pthread_setname_np and
# friends are visible on glibc and Android bionic without upstream's
# configure step.
target_compile_definitions(sdrcore_dump1090 PRIVATE
    STARCH_MIX_GENERIC
    _POSIX_C_SOURCE=200112L
    _DEFAULT_SOURCE)

# Upstream builds with -Wall -Wmissing-declarations -Werror of its own; we
# do not re-apply this app's own warning policy to vendored code (same
# policy as sdrcore_rtl433 / sdrcore_liquid in this directory). -O2 keeps
# the demodulator fast enough for live 2.4 MS/s processing even in a Debug
# CMAKE_BUILD_TYPE (matching the rationale already documented for sdrcore's
# own per-sample DSP path in native/CMakeLists.txt). -ffunction-sections
# -fdata-sections let the final executable/shared-library link
# (owned by the parent task, not this file) --gc-sections away any
# translation-unit-level code this embedding never calls (e.g.
# display_stats()'s SDR-gain-dB formatting, never invoked because this
# embedding exposes no gain control) without needing stub definitions for
# every such upstream display/debug helper.
target_compile_options(sdrcore_dump1090 PRIVATE
    -O2 -ffunction-sections -fdata-sections -w)

find_package(Threads REQUIRED)
target_link_libraries(sdrcore_dump1090 PUBLIC Threads::Threads)
target_link_libraries(sdrcore_dump1090 PUBLIC m)
