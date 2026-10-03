## SPDX-License-Identifier: GPL-3.0-or-later
# Real backends for the audio sink contract (see audio_sink.h): null (always),
# WAV file (always), ALSA (Linux host only, when found). This file is
# include()d from native/CMakeLists.txt, so CMAKE_CURRENT_LIST_DIR is
# native/src/audio and CMAKE_CURRENT_SOURCE_DIR is native/.

add_library(sdrcore_audio STATIC
    ${CMAKE_CURRENT_LIST_DIR}/audio_sink.cpp
    ${CMAKE_CURRENT_LIST_DIR}/null_sink.cpp
    ${CMAKE_CURRENT_LIST_DIR}/wav_sink.cpp
)
set_target_properties(sdrcore_audio PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_compile_features(sdrcore_audio PUBLIC cxx_std_17)
target_compile_options(sdrcore_audio PRIVATE -fvisibility=hidden)
target_include_directories(sdrcore_audio PUBLIC ${CMAKE_CURRENT_LIST_DIR})
find_package(Threads REQUIRED)
target_link_libraries(sdrcore_audio PRIVATE Threads::Threads)

# ALSA playback backend: Linux host only, and only when the dev package is
# present. Android never gets this (AAudio lands separately in N2); on a
# host without ALSA, make_audio_sink() returns nullptr for kAlsa (see
# audio_sink.cpp).
if(NOT ANDROID)
    find_package(ALSA)
    if(ALSA_FOUND)
        target_sources(sdrcore_audio PRIVATE ${CMAKE_CURRENT_LIST_DIR}/alsa_sink.cpp)
        target_link_libraries(sdrcore_audio PRIVATE ALSA::ALSA)
        target_compile_definitions(sdrcore_audio PRIVATE SDRCORE_HAVE_ALSA)
    endif()
endif()

# Host CTest for this target only, for a standalone host configure (native/
# as the top-level project). Mirrors the guard used by native/CMakeLists.txt
# for its own test suite.
if(NOT ANDROID AND PROJECT_IS_TOP_LEVEL)
    add_executable(sdrcore_audio_sink_test ${CMAKE_CURRENT_SOURCE_DIR}/tests/audio_sink_test.cpp)
    target_link_libraries(sdrcore_audio_sink_test PRIVATE sdrcore_audio)
    if(ALSA_FOUND)
        # SDRCORE_HAVE_ALSA on sdrcore_audio is PRIVATE (it must not leak into
        # the public sdrcore.so build); the test needs to know independently
        # whether to exercise the ALSA-specific assertions.
        target_compile_definitions(sdrcore_audio_sink_test PRIVATE SDRCORE_HAVE_ALSA)
    endif()
    add_test(NAME sdrcore_audio_sink COMMAND sdrcore_audio_sink_test)
endif()
