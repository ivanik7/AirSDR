# Meshtastic packet layer (header, channel keys, AES-CTR, protobuf payloads).
# Vendored, built from source, no protoc or Python at app build time:
#   nanopb 0.4.9.2 runtime (zlib)        -> nanopb/
#   Meshtastic protobufs 95c5f8c (GPL-3) -> meshtastic-protobufs/ (+ committed
#                                           nanopb output, see regen.sh)
#   Brad Conte crypto-algorithms aes.c (public domain) -> crypto-algorithms/
# See NOTICE.md and docs/status/meshtastic.md.
set(MESHTASTIC_TP ${CMAKE_CURRENT_LIST_DIR})
set(MESHTASTIC_GEN ${MESHTASTIC_TP}/meshtastic-protobufs/generated)
set(MESHTASTIC_PB_SOURCES
    ${MESHTASTIC_TP}/nanopb/pb_common.c
    ${MESHTASTIC_TP}/nanopb/pb_decode.c)
foreach(name mesh channel config device_ui module_config atak xmodem telemetry
        portnums paxcount storeforward remote_hardware field_metadata)
    list(APPEND MESHTASTIC_PB_SOURCES ${MESHTASTIC_GEN}/meshtastic/${name}.pb.c)
endforeach()
add_library(sdrcore_meshtastic_pb STATIC
    ${MESHTASTIC_PB_SOURCES}
    ${MESHTASTIC_TP}/crypto-algorithms/aes.c)
set_target_properties(sdrcore_meshtastic_pb PROPERTIES
    POSITION_INDEPENDENT_CODE ON C_STANDARD 99)
# PB_ENABLE_MALLOC stays off: all generated messages are static-size.
target_compile_options(sdrcore_meshtastic_pb PRIVATE
    -O2 -ffunction-sections -fdata-sections -w)
target_include_directories(sdrcore_meshtastic_pb PUBLIC
    ${MESHTASTIC_TP}/nanopb
    ${MESHTASTIC_GEN}
    ${MESHTASTIC_TP}/crypto-algorithms)
