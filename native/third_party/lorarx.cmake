# SPDX-License-Identifier: GPL-3.0-or-later
# OE5DXL lorarx LoRa PHY (dxlAPRS, GPL-2.0-or-later), vendored verbatim in
# third_party/lorarx (PROVENANCE.md). Two builds of the same sources:
#
#  sdrcore_lorarx  - linked into sdrcore. -DSDRCORE_LORARX_EMBED compiles out
#                    upstream main()/file/pipe IO and exposes lorarx_embed.h;
#                    embed/ replaces the upstream OS layer, so no file, pipe,
#                    socket, tty or console is touched (portable to Android,
#                    macOS and llvm-mingw Windows).
#  host oracle     - (Linux top-level only, see lorarx_tests.cmake) the
#                    unmodified upstream lorarx and loratx executables built
#                    with the verbatim upstream-os layer.
#
# -ffp-contract=off keeps FMA contraction from changing float rounding on
# arm64 relative to the x86-64 reference (OpenWebRX+ packages x86 builds).
set(LORARX_ROOT ${CMAKE_CURRENT_LIST_DIR}/lorarx)
add_library(sdrcore_lorarx STATIC
    ${LORARX_ROOT}/lorarx.c
    ${LORARX_ROOT}/loraprotocols.c
    ${LORARX_ROOT}/aprsstr.c
    ${LORARX_ROOT}/embed/lorarx_os.c)
set_target_properties(sdrcore_lorarx PROPERTIES POSITION_INDEPENDENT_CODE ON
    C_STANDARD 99 C_EXTENSIONS ON)
target_compile_definitions(sdrcore_lorarx PRIVATE SDRCORE_LORARX_EMBED)
# Machine-translated Modula-2: upstream code is kept warning-for-warning.
target_compile_options(sdrcore_lorarx PRIVATE -O2 -w -ffp-contract=off)
target_include_directories(sdrcore_lorarx PRIVATE ${LORARX_ROOT}/embed)
target_include_directories(sdrcore_lorarx PUBLIC ${LORARX_ROOT})
if(NOT WIN32)
    target_link_libraries(sdrcore_lorarx PRIVATE m)
endif()
