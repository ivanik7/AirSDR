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

if(ANDROID)
    target_sources(sdrcore_audio PRIVATE ${CMAKE_CURRENT_LIST_DIR}/aaudio_sink.cpp)
    target_link_libraries(sdrcore_audio PUBLIC dl log)
endif()

# ALSA playback backend: Linux host only, and only when the dev package is
# present. Android never gets this; on a
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

# miniaudio playback backend (vendored third_party/miniaudio, playback only):
# every desktop host. It is the production sink on macOS (CoreAudio) and
# Windows (WASAPI); on Linux it is available as "miniaudio" next to the ALSA
# sink, which stays the Linux default. Never built for Android (AAudio).
if(NOT ANDROID)
    target_sources(sdrcore_audio PRIVATE
        ${CMAKE_CURRENT_LIST_DIR}/miniaudio_sink.cpp
        ${CMAKE_CURRENT_LIST_DIR}/miniaudio_impl.c)
    target_include_directories(sdrcore_audio PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/third_party/miniaudio)
    target_compile_definitions(sdrcore_audio PRIVATE SDRCORE_HAVE_MINIAUDIO)
    # Vendored code: keep upstream warnings out of the build log.
    set_source_files_properties(${CMAKE_CURRENT_LIST_DIR}/miniaudio_impl.c
        PROPERTIES COMPILE_OPTIONS "-w")
    if(APPLE)
        # MA_NO_RUNTIME_LINKING on Apple (miniaudio_config.h).
        target_link_libraries(sdrcore_audio PRIVATE
            "-framework CoreFoundation" "-framework CoreAudio"
            "-framework AudioToolbox")
    elseif(WIN32)
        # WASAPI is loaded at run time by miniaudio; ole32 provides COM init.
        target_link_libraries(sdrcore_audio PRIVATE ole32)
    else()
        # PulseAudio/ALSA/JACK are dlopen()ed at run time: no new DT_NEEDED
        # beyond libdl (part of libc on glibc >= 2.34) and libm.
        target_link_libraries(sdrcore_audio PRIVATE ${CMAKE_DL_LIBS} m)
    endif()
endif()

# Host CTest for this target only, for a standalone host configure (native/
# as the top-level project). Mirrors the guard used by native/CMakeLists.txt
# for its own test suite.
if(NOT ANDROID AND PROJECT_IS_TOP_LEVEL)
    add_executable(sdrcore_pcm_ring_test ${CMAKE_CURRENT_SOURCE_DIR}/tests/pcm_ring_test.cpp)
    target_include_directories(sdrcore_pcm_ring_test PRIVATE ${CMAKE_CURRENT_LIST_DIR})
    target_link_libraries(sdrcore_pcm_ring_test PRIVATE Threads::Threads)
    add_test(NAME sdrcore_pcm_ring COMMAND sdrcore_pcm_ring_test)
    add_executable(sdrcore_pcm_ring_jitter_test ${CMAKE_CURRENT_SOURCE_DIR}/tests/pcm_ring_jitter_test.cpp)
    target_include_directories(sdrcore_pcm_ring_jitter_test PRIVATE ${CMAKE_CURRENT_LIST_DIR})
    target_compile_features(sdrcore_pcm_ring_jitter_test PRIVATE cxx_std_17)
    add_test(NAME sdrcore_pcm_ring_jitter COMMAND sdrcore_pcm_ring_jitter_test)
    add_executable(sdrcore_audio_sink_test ${CMAKE_CURRENT_SOURCE_DIR}/tests/audio_sink_test.cpp)
    target_link_libraries(sdrcore_audio_sink_test PRIVATE sdrcore_audio)
    if(ALSA_FOUND)
        # SDRCORE_HAVE_ALSA on sdrcore_audio is PRIVATE (it must not leak into
        # the public sdrcore.so build); the test needs to know independently
        # whether to exercise the ALSA-specific assertions.
        target_compile_definitions(sdrcore_audio_sink_test PRIVATE SDRCORE_HAVE_ALSA)
    endif()
    target_compile_definitions(sdrcore_audio_sink_test PRIVATE SDRCORE_HAVE_MINIAUDIO)
    add_test(NAME sdrcore_audio_sink COMMAND sdrcore_audio_sink_test)
    add_executable(sdrcore_miniaudio_sink_test ${CMAKE_CURRENT_SOURCE_DIR}/tests/miniaudio_sink_test.cpp)
    target_include_directories(sdrcore_miniaudio_sink_test PRIVATE ${CMAKE_CURRENT_LIST_DIR})
    target_link_libraries(sdrcore_miniaudio_sink_test PRIVATE sdrcore_audio Threads::Threads)
    add_test(NAME sdrcore_miniaudio_sink COMMAND sdrcore_miniaudio_sink_test)
endif()
