# SPDX-License-Identifier: GPL-3.0-or-later
# DMR AMBE+2 voice synthesis (t_5b101746). include()d from native/CMakeLists.txt
# before the sdrcore target links it; CMAKE_CURRENT_SOURCE_DIR is native/.
#
# Vendored, unmodified upstream sources (provenance: native/third_party/mbelib/
# PROVENANCE.md and native/third_party/openwebrx-dmr/PROVENANCE-voice.md):
#   mbelib 1.3.0 (ISC)                  -> sdrcore_mbelib       (only if enabled)
#   csdr-plus Module/Source/Sink/Agc    -> sdrcore_dmr_csdr_base / sdrcore_dmr_voice
#   digiham-plus DigitalVoiceFilter     -> sdrcore_dmr_voice
#   codecserver-softmbe DMR permutation -> header only
#
# SDRCORE_ENABLE_MBELIB=OFF builds a vocoder-less library: AMBE frames are
# counted and dropped, read_audio() returns 0 and the receiver plays silence.
# Nothing else changes (DMR sync/metadata stay usable). See STATUS-dmr.md §5.
option(SDRCORE_ENABLE_MBELIB
    "Build the mbelib AMBE+2 vocoder into DMR (see STATUS-dmr.md patent note)" ON)

set(DMR_VENDOR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/openwebrx-dmr)

# csdr-plus Module/Source/Sink base classes shared by every vendored csdr or
# digiham Module. The DMR channel card (t_8e3dfcc0) compiles the same three
# files; at integration both DMR libraries should link this one target.
if(NOT TARGET sdrcore_dmr_csdr_base)
    add_library(sdrcore_dmr_csdr_base STATIC
        ${DMR_VENDOR}/csdr/module.cpp
        ${DMR_VENDOR}/csdr/source.cpp
        ${DMR_VENDOR}/csdr/sink.cpp)
    set_target_properties(sdrcore_dmr_csdr_base PROPERTIES POSITION_INDEPENDENT_CODE ON)
    target_compile_features(sdrcore_dmr_csdr_base PUBLIC cxx_std_17)
    target_include_directories(sdrcore_dmr_csdr_base PUBLIC ${DMR_VENDOR})
endif()

if(SDRCORE_ENABLE_MBELIB)
    set(MBELIB_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/third_party/mbelib)
    # Same source set as upstream's FILE(GLOB SRCS *.c). Unused codecs are
    # dropped by --gc-sections in libsdrcore.
    add_library(sdrcore_mbelib STATIC
        ${MBELIB_ROOT}/mbelib.c
        ${MBELIB_ROOT}/ecc.c
        ${MBELIB_ROOT}/ambe3600x2450.c
        ${MBELIB_ROOT}/ambe3600x2400.c
        ${MBELIB_ROOT}/imbe7100x4400.c
        ${MBELIB_ROOT}/imbe7200x4400.c)
    set_target_properties(sdrcore_mbelib PROPERTIES POSITION_INDEPENDENT_CODE ON
        C_STANDARD 99 C_EXTENSIONS ON)
    target_compile_options(sdrcore_mbelib PRIVATE -O2 -ffunction-sections -fdata-sections -w)
    target_include_directories(sdrcore_mbelib PUBLIC ${MBELIB_ROOT})
    target_link_libraries(sdrcore_mbelib PUBLIC m)
endif()

add_library(sdrcore_dmr_voice STATIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src/dmr/vocoder.cpp
    ${DMR_VENDOR}/csdr/agc.cpp
    ${DMR_VENDOR}/digiham/digitalvoice_filter.cpp)
set_target_properties(sdrcore_dmr_voice PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_compile_features(sdrcore_dmr_voice PUBLIC cxx_std_17)
target_include_directories(sdrcore_dmr_voice PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src ${DMR_VENDOR})
target_link_libraries(sdrcore_dmr_voice PUBLIC sdrcore_dmr_csdr_base)
# Like receiver.cpp: the 50 frames/s synthesis must not run at -O0 in the
# Flutter debug bundles.
set_source_files_properties(${CMAKE_CURRENT_SOURCE_DIR}/src/dmr/vocoder.cpp
    PROPERTIES COMPILE_OPTIONS "$<$<CONFIG:Debug>:-O2>")
if(SDRCORE_ENABLE_MBELIB)
    target_compile_definitions(sdrcore_dmr_voice PUBLIC SDRCORE_ENABLE_MBELIB=1)
    target_link_libraries(sdrcore_dmr_voice PUBLIC sdrcore_mbelib)
else()
    target_compile_definitions(sdrcore_dmr_voice PUBLIC SDRCORE_ENABLE_MBELIB=0)
endif()
