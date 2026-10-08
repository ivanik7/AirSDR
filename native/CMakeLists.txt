cmake_minimum_required(VERSION 3.22)
project(sdrcore VERSION 1.0.0 LANGUAGES C CXX)

add_subdirectory(third_party)

add_library(sdrcore SHARED
    src/sdrcore.cpp
    src/dsp/receiver.cpp
    src/usb_rtlsdr_adapter.cpp
    src/usb_hackrf_adapter.cpp
    src/decoder/registry.cpp
    src/decoder/decoder_abi.cpp
)
if(ANDROID)
    target_sources(sdrcore PRIVATE src/sdr_jni.cpp)
else()
    # Desktop Linux platform layer (L1): libusb enumeration + open by path.
    target_sources(sdrcore PRIVATE src/sdrcore_host.cpp)
    target_link_libraries(sdrcore PRIVATE sdrcore_libusb)
endif()
target_compile_features(sdrcore PRIVATE cxx_std_17)
find_package(Threads REQUIRED)
target_link_libraries(sdrcore PRIVATE Threads::Threads sdrcore_rtlsdr sdrcore_hackrf)
set_target_properties(sdrcore PROPERTIES
    CXX_EXTENSIONS OFF
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN YES)
target_include_directories(sdrcore PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)

# The per-sample DSP path cannot sustain 2.4 MS/s at -O0: Flutter debug
# bundles (Linux runner and AGP debug APK) configure CMAKE_BUILD_TYPE=Debug and
# then overflow the IQ ring (tens of millions of drops in minutes). Optimise
# only the sample path in every configuration; the rest stays debuggable.
set_source_files_properties(src/dsp/receiver.cpp PROPERTIES
    COMPILE_OPTIONS "$<$<CONFIG:Debug>:-O2>")

# Audio sink backends (null/WAV/ALSA); defines target sdrcore_audio and, for
# standalone host builds, its CTest. See src/audio/audio_sink.h.
include(src/audio/audio.cmake)
target_link_libraries(sdrcore PRIVATE sdrcore_audio)

# Tests only for a standalone host configure (native/ as the top-level project);
# the Flutter Linux runner adds native/ as a subdirectory and needs the library only.
if(NOT ANDROID AND PROJECT_IS_TOP_LEVEL)
    enable_testing()
    # Check the N2 header layouts independently of the DSP implementation.
    # The integrator advances sdr_version only after all N2 layers are ready.
    add_library(sdrcore_v3_contract_compile OBJECT tests/v3_contract_compile.c)
    target_include_directories(sdrcore_v3_contract_compile PRIVATE include)
    add_library(sdrcore_decoder_contract_compile OBJECT tests/decoder_contract_compile.c)
    target_include_directories(sdrcore_decoder_contract_compile PRIVATE include)
    add_executable(sdrcore_abi_test tests/abi_test.c)
    target_link_libraries(sdrcore_abi_test PRIVATE sdrcore)
    add_test(NAME sdrcore_abi COMMAND sdrcore_abi_test)
    add_executable(sdrcore_decoder_abi_test tests/decoder_abi_test.cpp)
    target_link_libraries(sdrcore_decoder_abi_test PRIVATE sdrcore)
    add_test(NAME sdrcore_decoder_abi COMMAND sdrcore_decoder_abi_test)
    add_executable(sdrcore_wfm_stereo_abi_test tests/wfm_stereo_abi_test.cpp)
    target_link_libraries(sdrcore_wfm_stereo_abi_test PRIVATE sdrcore Threads::Threads)
    add_test(NAME sdrcore_wfm_stereo_abi COMMAND sdrcore_wfm_stereo_abi_test)
    add_executable(sdrcore_stream_test tests/stream_test.cpp)
    target_link_libraries(sdrcore_stream_test PRIVATE sdrcore)
    add_test(NAME sdrcore_stream COMMAND sdrcore_stream_test)
    add_executable(sdrcore_fd_lifecycle_test tests/fd_lifecycle_test.cpp)
    target_link_libraries(sdrcore_fd_lifecycle_test PRIVATE sdrcore Threads::Threads)
    add_test(NAME sdrcore_fd_lifecycle COMMAND sdrcore_fd_lifecycle_test)
    add_executable(sdrcore_checksum_oracle_test tests/checksum_oracle_test.c)
    target_link_libraries(sdrcore_checksum_oracle_test PRIVATE sdrcore)
    add_test(NAME sdrcore_checksum_oracle COMMAND sdrcore_checksum_oracle_test)
    add_executable(sdrcore_ring_boundary_test
        tests/ring_boundary_test.cpp
        src/dsp/receiver.cpp
        src/usb_rtlsdr_adapter.cpp
        src/usb_hackrf_adapter.cpp)
    target_include_directories(sdrcore_ring_boundary_test PRIVATE include)
    target_compile_features(sdrcore_ring_boundary_test PRIVATE cxx_std_17)
    target_link_libraries(sdrcore_ring_boundary_test PRIVATE sdrcore_rtlsdr sdrcore_hackrf sdrcore_audio Threads::Threads)
    add_test(NAME sdrcore_ring_boundary COMMAND sdrcore_ring_boundary_test)
    add_executable(sdrcore_rtl_libusb_init_failure_test tests/rtl_libusb_init_failure_test.c)
    target_include_directories(sdrcore_rtl_libusb_init_failure_test PRIVATE
        third_party/rtl-sdr/include
        third_party/libusb/libusb)
    target_link_libraries(sdrcore_rtl_libusb_init_failure_test PRIVATE sdrcore_rtlsdr sdrcore_libusb m)
    target_link_options(sdrcore_rtl_libusb_init_failure_test PRIVATE -Wl,--wrap=libusb_init)
    add_test(NAME sdrcore_rtl_libusb_init_failure COMMAND sdrcore_rtl_libusb_init_failure_test)
    add_executable(sdrcore_host_usb_test tests/host_usb_test.c)
    target_link_libraries(sdrcore_host_usb_test PRIVATE sdrcore)
    add_test(NAME sdrcore_host_usb COMMAND sdrcore_host_usb_test)
    add_executable(sdrcore_rtl_gain_list_test
        tests/rtl_gain_list_test.cpp
        src/dsp/receiver.cpp
        src/usb_rtlsdr_adapter.cpp
        src/usb_hackrf_adapter.cpp)
    target_include_directories(sdrcore_rtl_gain_list_test PRIVATE include)
    target_compile_features(sdrcore_rtl_gain_list_test PRIVATE cxx_std_17)
    target_link_libraries(sdrcore_rtl_gain_list_test PRIVATE sdrcore_rtlsdr sdrcore_hackrf sdrcore_audio Threads::Threads)
    add_test(NAME sdrcore_rtl_gain_list COMMAND sdrcore_rtl_gain_list_test)
    add_executable(sdrcore_live_retune_test
        tests/live_retune_test.cpp
        src/dsp/receiver.cpp
        src/usb_rtlsdr_adapter.cpp
        src/usb_hackrf_adapter.cpp)
    target_include_directories(sdrcore_live_retune_test PRIVATE include)
    target_compile_features(sdrcore_live_retune_test PRIVATE cxx_std_17)
    target_link_libraries(sdrcore_live_retune_test PRIVATE sdrcore_rtlsdr sdrcore_hackrf sdrcore_audio Threads::Threads)
    add_test(NAME sdrcore_live_retune COMMAND sdrcore_live_retune_test)
    add_executable(sdrcore_host_rtl_gain_test tests/host_rtl_gain_test.c)
    target_link_libraries(sdrcore_host_rtl_gain_test PRIVATE sdrcore)
    add_test(NAME sdrcore_host_rtl_gain COMMAND sdrcore_host_rtl_gain_test)
    add_executable(sdrcore_host_rx_diag tests/host_rx_diag.c)
    target_link_libraries(sdrcore_host_rx_diag PRIVATE sdrcore)
    # Manual real-hardware diagnostic (needs an attached RTL-SDR); not a ctest.
    add_executable(sdrcore_host_retune_latency tests/host_retune_latency.c)
    target_link_libraries(sdrcore_host_retune_latency PRIVATE sdrcore)
    # Manual probe of stale IQ after a live tuner retune (vendored librtlsdr).
    add_executable(sdrcore_host_retune_settle tests/host_retune_settle.c)
    target_include_directories(sdrcore_host_retune_settle PRIVATE third_party/rtl-sdr/include)
    target_link_libraries(sdrcore_host_retune_settle PRIVATE sdrcore_rtlsdr Threads::Threads m)
    # Manual probe: bulk IQ arrival gaps while the tuner is retuned live.
    add_executable(sdrcore_host_retune_iq_gaps tests/host_retune_iq_gaps.c)
    target_include_directories(sdrcore_host_retune_iq_gaps PRIVATE third_party/rtl-sdr/include)
    target_link_libraries(sdrcore_host_retune_iq_gaps PRIVATE sdrcore_rtlsdr Threads::Threads m)
    # Manual real-hardware audio continuity check under UI-like retunes.
    add_executable(sdrcore_host_retune_audio tests/host_retune_audio.c)
    target_link_libraries(sdrcore_host_retune_audio PRIVATE sdrcore Threads::Threads)
    # DSP-only, white-box: links receiver.cpp directly against the public
    # sdrcore::dsp::Receiver interface (no ABI/sdrcore.cpp, no USB adapters,
    # no Dart/FFI) so the WFM stereo decoder is checkable in isolation with
    # deterministic synthetic MPX IQ. See wfm_stereo_dsp_test.cpp.
    add_executable(sdrcore_wfm_stereo_dsp_test
        tests/wfm_stereo_dsp_test.cpp
        src/dsp/receiver.cpp)
    target_include_directories(sdrcore_wfm_stereo_dsp_test PRIVATE include)
    target_compile_features(sdrcore_wfm_stereo_dsp_test PRIVATE cxx_std_17)
    add_test(NAME sdrcore_wfm_stereo_dsp COMMAND sdrcore_wfm_stereo_dsp_test)
    # DSP-only: audio stays continuous across VFO drags and LO retunes.
    add_executable(sdrcore_retune_audio_continuity_test
        tests/retune_audio_continuity_test.cpp
        src/dsp/receiver.cpp)
    target_include_directories(sdrcore_retune_audio_continuity_test PRIVATE include)
    target_compile_features(sdrcore_retune_audio_continuity_test PRIVATE cxx_std_17)
    target_compile_options(sdrcore_retune_audio_continuity_test PRIVATE -O2)
    add_test(NAME sdrcore_retune_audio_continuity COMMAND sdrcore_retune_audio_continuity_test)
endif()
