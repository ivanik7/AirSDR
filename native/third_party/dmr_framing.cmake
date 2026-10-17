# Digiham's DMR framing/FEC, built from GPL-3.0 source; no CLI or csdr I/O.
set(DMR_UPSTREAM ${CMAKE_CURRENT_LIST_DIR}/digiham_dmr/upstream)
add_library(sdrcore_dmr_framing STATIC
    src/dmr/framing.cpp
    ${DMR_UPSTREAM}/dmr_phase.cpp ${DMR_UPSTREAM}/dmr_meta.cpp
    ${DMR_UPSTREAM}/emb.cpp ${DMR_UPSTREAM}/quadratic_residue.c
    ${DMR_UPSTREAM}/cach.cpp ${DMR_UPSTREAM}/tact.cpp
    ${DMR_UPSTREAM}/hamming_7_4.c ${DMR_UPSTREAM}/embedded.cpp
    ${DMR_UPSTREAM}/lc.cpp ${DMR_UPSTREAM}/hamming_16_11.c
    ${DMR_UPSTREAM}/talkeralias.cpp ${DMR_UPSTREAM}/slottype.cpp
    ${DMR_UPSTREAM}/golay_20_8.c ${DMR_UPSTREAM}/bptc_196_96.c
    ${DMR_UPSTREAM}/hamming_13_9.c ${DMR_UPSTREAM}/hamming_15_11.c
    ${DMR_UPSTREAM}/gps.cpp ${DMR_UPSTREAM}/coordinate.cpp
    ${DMR_UPSTREAM}/hamming_distance.c)
target_compile_features(sdrcore_dmr_framing PUBLIC cxx_std_17)
set_target_properties(sdrcore_dmr_framing PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_include_directories(sdrcore_dmr_framing PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/src)
target_include_directories(sdrcore_dmr_framing PRIVATE
    ${DMR_UPSTREAM} ${CMAKE_CURRENT_LIST_DIR}/digiham_dmr/compat)
