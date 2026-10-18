# SPDX-License-Identifier: GPL-3.0-or-later
# LoRa PHY (embedded lorarx) tests, included from the Linux host-only test
# block in native/CMakeLists.txt after enable_testing().

# Reference oracle: the unmodified upstream lorarx and loratx executables with
# the verbatim upstream-os layer (PROVENANCE.md), no SDRCORE_LORARX_EMBED.
set(LORARX_ORACLE_OS
    ${LORARX_ROOT}/upstream-os/osi.c
    ${LORARX_ROOT}/upstream-os/osic.c
    ${LORARX_ROOT}/upstream-os/udp.c)
add_executable(lorarx_oracle
    ${LORARX_ROOT}/lorarx.c ${LORARX_ROOT}/loraprotocols.c
    ${LORARX_ROOT}/aprsstr.c ${LORARX_ORACLE_OS})
add_executable(loratx_oracle
    ${LORARX_ROOT}/loratx.c ${LORARX_ROOT}/aprsstr.c ${LORARX_ORACLE_OS})
foreach(oracle lorarx_oracle loratx_oracle)
    target_include_directories(${oracle} PRIVATE ${LORARX_ROOT} ${LORARX_ROOT}/upstream-os)
    target_compile_options(${oracle} PRIVATE -O2 -w -ffp-contract=off)
    target_link_libraries(${oracle} PRIVATE m)
endforeach()

# Embedded build replayed from a file with the same argv.
add_executable(sdrcore_lorarx_replay tests/lorarx_replay.cpp)
target_compile_features(sdrcore_lorarx_replay PRIVATE cxx_std_17)
target_link_libraries(sdrcore_lorarx_replay PRIVATE sdrcore_lorarx)

# 20 loratx fixtures (all Meshtastic preset bandwidths, SF7..11, CR 4/5..4/8,
# explicit header with/without CRC, sync words 0x2B/0x12, damaged frame,
# noise, carrier offset): embedded JSON == upstream oracle JSON byte for byte.
add_test(NAME sdrcore_lorarx_parity
    COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/tests/lorarx_parity.sh
        $<TARGET_FILE:lorarx_oracle> $<TARGET_FILE:loratx_oracle>
        $<TARGET_FILE:sdrcore_lorarx_replay>
        ${CMAKE_CURRENT_SOURCE_DIR}/tests/data/meshtastic_vectors.json
        ${CMAKE_CURRENT_BINARY_DIR}/lorarx_parity)

# Full receive chain: u8 2.4 MS/s capture (loratx, LongFast, real Meshtastic
# text frame, +200 kHz off the LO) -> Receiver 1 MS/s tap -> registry
# "meshtastic" backend -> message event.
set(MESHTASTIC_PHY_CAPTURE ${CMAKE_CURRENT_BINARY_DIR}/meshtastic_phy_longfast.u8)
set(MESHTASTIC_PHY_HEX ${CMAKE_CURRENT_BINARY_DIR}/meshtastic_phy_longfast.hex)
file(WRITE ${MESHTASTIC_PHY_HEX}
    "ffffffffb45463dab971aa8c6308000078aacf76587a5a4cf4a20e2c1d0349ab3f72\n")
add_custom_command(OUTPUT ${MESHTASTIC_PHY_CAPTURE}
    COMMAND loratx_oracle -i ${MESHTASTIC_PHY_HEX} -H -f u8 -r 2400000
        -b 8 -s 11 -c 5 -N 2B -C -S 200000 -g 0.5 -z 10
        -o ${MESHTASTIC_PHY_CAPTURE} > /dev/null
    DEPENDS loratx_oracle
    VERBATIM)
add_custom_target(meshtastic_phy_capture ALL DEPENDS ${MESHTASTIC_PHY_CAPTURE})
add_executable(sdrcore_meshtastic_phy_test
    tests/meshtastic_phy_test.cpp src/dsp/receiver.cpp
    src/decoder/rtl433.cpp src/decoder/sstv.cpp src/decoder/adsb.cpp
    src/decoder/meshtastic.cpp src/decoder/dmr.cpp src/decoder/registry.cpp)
target_include_directories(sdrcore_meshtastic_phy_test PRIVATE include third_party)
target_compile_features(sdrcore_meshtastic_phy_test PRIVATE cxx_std_17)
target_link_libraries(sdrcore_meshtastic_phy_test PRIVATE
    sdrcore_rtl433 sdrcore_csdr_sstv sdrcore_dump1090 sdrcore_meshtastic
    sdrcore_lorarx sdrcore_rds sdrcore_dmr_channel sdrcore_dmr_framing sdrcore_dmr_voice m)
target_link_options(sdrcore_meshtastic_phy_test PRIVATE -Wl,--gc-sections)
add_dependencies(sdrcore_meshtastic_phy_test meshtastic_phy_capture)
add_test(NAME sdrcore_meshtastic_phy
    COMMAND sdrcore_meshtastic_phy_test ${MESHTASTIC_PHY_CAPTURE})

# Host-only exact-IQ replay for the external OpenWebRX+ parser comparison.
add_executable(sdrcore_meshtastic_replay
    tests/meshtastic_replay.cpp src/decoder/rtl433.cpp src/decoder/sstv.cpp
    src/decoder/adsb.cpp src/decoder/meshtastic.cpp src/decoder/dmr.cpp src/decoder/registry.cpp)
target_include_directories(sdrcore_meshtastic_replay PRIVATE include third_party)
target_compile_features(sdrcore_meshtastic_replay PRIVATE cxx_std_17)
target_link_libraries(sdrcore_meshtastic_replay PRIVATE
    sdrcore_rtl433 sdrcore_csdr_sstv sdrcore_dump1090 sdrcore_meshtastic
    sdrcore_lorarx sdrcore_rds sdrcore_dmr_channel sdrcore_dmr_framing sdrcore_dmr_voice m)
target_link_options(sdrcore_meshtastic_replay PRIVATE -Wl,--gc-sections)
