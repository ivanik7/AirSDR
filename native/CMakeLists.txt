cmake_minimum_required(VERSION 3.22)
project(sdrcore VERSION 1.0.0 LANGUAGES C CXX)

# Supported toolchains: GCC/Clang on Linux, the NDK on Android, Apple Clang on
# macOS, and llvm-mingw Clang on Windows (cmake/llvm-mingw-x86_64.cmake). The
# sources use GNU flags and liquid-dsp needs C99 _Complex, so MSVC/clang-cl
# cannot build the core (docs/desktop-build.md).
if(MSVC)
    message(FATAL_ERROR "sdrcore cannot be built with MSVC or clang-cl. Build "
        "sdrcore.dll with llvm-mingw: -DCMAKE_TOOLCHAIN_FILE="
        "native/cmake/llvm-mingw-x86_64.cmake (see docs/desktop-build.md).")
endif()

add_subdirectory(third_party)
include(third_party/dmr_framing.cmake)
include(third_party/rds.cmake)
include(third_party/fftw.cmake)
# csdr-plus SSTV decoder sources (BSD-3) + SSTV-only Module shim; defines the
# static target sdrcore_csdr_sstv (links sdrcore_fftw3f).
include(third_party/csdr_sstv.cmake)
include(third_party/dump1090.cmake)
# DMR AMBE+2 voice output (mbelib + csdr Agc + digiham DigitalVoiceFilter);
# defines sdrcore_dmr_voice and the SDRCORE_ENABLE_MBELIB option.
include(src/dmr/dmr_voice.cmake)
add_library(sdrcore_rds STATIC src/rds/rds.cpp)
set_target_properties(sdrcore_rds PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_compile_features(sdrcore_rds PRIVATE cxx_std_17)
target_link_libraries(sdrcore_rds PUBLIC sdrcore_redsea)

# Meshtastic packet layer (header/keys/AES-CTR/nanopb payloads). Pure library;
# the LoRa PHY and decoder backend wiring are separate cards.
include(third_party/meshtastic.cmake)
add_library(sdrcore_meshtastic STATIC
    src/meshtastic/meshtastic.cpp
    src/meshtastic/pb_reflect.cpp)
set_target_properties(sdrcore_meshtastic PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_compile_features(sdrcore_meshtastic PUBLIC cxx_std_17)
target_include_directories(sdrcore_meshtastic PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src ${CMAKE_CURRENT_SOURCE_DIR}/third_party)
target_link_libraries(sdrcore_meshtastic PUBLIC sdrcore_meshtastic_pb)

# DMR channel front end (OpenWebRX+/digiham FmDemod -> DcBlock ->
# WideRrcFilter -> GfskDemodulator). Framing/voice and decoder registration
# are separate cards; only linked sources enter Android/Linux binaries.
set(DMR_VENDOR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/openwebrx-dmr)
add_library(sdrcore_dmr_channel STATIC
    src/dmr/channel.cpp
    src/dmr/channel_filter.cpp
    ${DMR_VENDOR}/csdr/fmdemod.cpp
    ${DMR_VENDOR}/csdr/dcblock.cpp
    ${DMR_VENDOR}/digiham/rrc_filter.cpp
    ${DMR_VENDOR}/digiham/gfsk_demodulator.cpp)
set_target_properties(sdrcore_dmr_channel PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_compile_features(sdrcore_dmr_channel PUBLIC cxx_std_17)
target_include_directories(sdrcore_dmr_channel PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src ${DMR_VENDOR})
target_link_libraries(sdrcore_dmr_channel PUBLIC sdrcore_dmr_csdr_base)

# rtl_433 upstream sources are embedded, not run as a subprocess. Preserve
# upstream source verbatim; link only the engine/API and protocol decoders.
set(RTL433_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/third_party/rtl_433)
file(GLOB RTL433_DEVICE_SOURCES CONFIGURE_DEPENDS ${RTL433_ROOT}/src/devices/*.c)
set(RTL433_ENGINE_SOURCES
    abuf am_analyze baseband bit_util bitbuffer compat_time data data_tag
    decoder_util fileformat jsmn list logger optparse pulse_analyzer pulse_data
    pulse_detect pulse_detect_fsk pulse_slicer r_api r_flow r_util raw_output
    samp_grab sigmf microtar string_expand)
set(RTL433_SOURCES ${RTL433_DEVICE_SOURCES})
foreach(name IN LISTS RTL433_ENGINE_SOURCES)
    list(APPEND RTL433_SOURCES ${RTL433_ROOT}/src/${name}.c)
endforeach()
add_library(sdrcore_rtl433 STATIC ${RTL433_SOURCES})
set_target_properties(sdrcore_rtl433 PROPERTIES POSITION_INDEPENDENT_CODE ON
    C_STANDARD 99 C_EXTENSIONS ON)
target_compile_definitions(sdrcore_rtl433 PRIVATE _GNU_SOURCE)
target_compile_options(sdrcore_rtl433 PRIVATE -O2 -ffunction-sections -fdata-sections -w)
target_include_directories(sdrcore_rtl433 PUBLIC ${RTL433_ROOT}/include)
if(APPLE OR WIN32)
    # ld64 and lld-COFF resolve symbols before dead stripping; define the
    # CLI-only rtl_433 symbols that r_api.c references (see the file header).
    target_sources(sdrcore_rtl433 PRIVATE src/decoder/rtl433_cli_stubs.c
        ${RTL433_ROOT}/src/rfraw.c)
endif()
if(WIN32)
    # rtl_433's compat/socket code needs Winsock even when unused paths are
    # dropped; matches upstream rtl_433's Windows build.
    target_link_libraries(sdrcore_rtl433 PUBLIC ws2_32)
endif()

add_library(sdrcore SHARED
    src/sdrcore.cpp
    src/dsp/receiver.cpp
    src/usb_rtlsdr_adapter.cpp
    src/usb_hackrf_adapter.cpp
    src/decoder/registry.cpp
    src/decoder/rtl433.cpp
    src/decoder/sstv.cpp
    src/decoder/adsb.cpp
    src/decoder/decoder_abi.cpp
)
if(ANDROID)
    target_sources(sdrcore PRIVATE src/sdr_jni.cpp)
else()
    # Desktop host platform layer (Linux, macOS, Windows): libusb enumeration
    # and open by usbfs path (Linux) or by bus/address (every host).
    target_sources(sdrcore PRIVATE src/sdrcore_host.cpp)
    target_link_libraries(sdrcore PRIVATE sdrcore_libusb)
endif()
target_compile_features(sdrcore PRIVATE cxx_std_17)
find_package(Threads REQUIRED)
target_link_libraries(sdrcore PRIVATE Threads::Threads sdrcore_rtlsdr sdrcore_hackrf sdrcore_rtl433 sdrcore_rds sdrcore_meshtastic sdrcore_csdr_sstv sdrcore_dump1090 sdrcore_dmr_framing)
target_link_libraries(sdrcore PRIVATE sdrcore_dmr_voice sdrcore_dmr_channel)
if(NOT WIN32)
    target_link_libraries(sdrcore PRIVATE m)
endif()
if(UNIX AND NOT APPLE)
    # Do not export upstream's API from libsdrcore: otherwise exported but
    # unused CLI/network sections keep unresolved CLI dependencies alive.
    target_link_options(sdrcore PRIVATE -Wl,--exclude-libs,ALL
        -Wl,--gc-sections)
elseif(APPLE)
    # libsdrcore.dylib, loaded from <App>.app/Contents/Frameworks through the
    # runner's @executable_path/../Frameworks rpath. Static dependencies are
    # compiled with hidden visibility; export only the sdr_* C API.
    set_target_properties(sdrcore PROPERTIES
        INSTALL_NAME_DIR "@rpath"
        BUILD_WITH_INSTALL_NAME_DIR ON)
    target_link_options(sdrcore PRIVATE -Wl,-dead_strip
        "-Wl,-exported_symbols_list,${CMAKE_CURRENT_SOURCE_DIR}/cmake/sdrcore-macos.exp")
elseif(WIN32)
    # sdrcore.dll (no "lib" prefix), loaded by the MSVC-built Flutter runner
    # through FFI only. Self-contained: libc++, libunwind and winpthreads are
    # linked statically, so the DLL imports only Windows system DLLs and the
    # UCRT. Only the __declspec(dllexport) sdr_* API is exported.
    set_target_properties(sdrcore PROPERTIES PREFIX "")
    target_link_options(sdrcore PRIVATE -static -Wl,--gc-sections
        -Wl,--exclude-all-symbols)
endif()
set_target_properties(sdrcore PROPERTIES
    CXX_EXTENSIONS OFF
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN YES)
target_include_directories(sdrcore PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)

# Symbol-level DMR framing is independent of the signal-chain integration.
if(NOT ANDROID AND PROJECT_IS_TOP_LEVEL)
    enable_testing()
    # Compile and exercise each vendored Source independently; the two copies
    # define the same symbols and must not mask one another at link time.
    foreach(variant IN ITEMS dmr sstv)
        add_executable(sdrcore_csdr_${variant}_source_test tests/csdr_source_test.cpp)
        if(variant STREQUAL "dmr")
            target_include_directories(sdrcore_csdr_${variant}_source_test PRIVATE ${DMR_VENDOR}/csdr)
            target_link_libraries(sdrcore_csdr_${variant}_source_test PRIVATE sdrcore_dmr_csdr_base)
        else()
            target_link_libraries(sdrcore_csdr_${variant}_source_test PRIVATE sdrcore_csdr_sstv)
        endif()
        target_compile_options(sdrcore_csdr_${variant}_source_test PRIVATE -UNDEBUG)
        add_test(NAME sdrcore_csdr_${variant}_source COMMAND sdrcore_csdr_${variant}_source_test)
    endforeach()
    add_executable(sdrcore_dmr_framing_test tests/dmr_framing_test.cpp)
    target_link_libraries(sdrcore_dmr_framing_test PRIVATE sdrcore_dmr_framing)
    target_include_directories(sdrcore_dmr_framing_test PRIVATE
        third_party/digiham_dmr/upstream third_party/digiham_dmr/compat)
    add_test(NAME sdrcore_dmr_framing COMMAND sdrcore_dmr_framing_test)
endif()

# The per-sample DSP path cannot sustain 2.4 MS/s at -O0: Flutter debug
# bundles (Linux runner and AGP debug APK) configure CMAKE_BUILD_TYPE=Debug and
# then overflow the IQ ring (tens of millions of drops in minutes). Optimise
# only the sample path in every configuration; the rest stays debuggable.
set_source_files_properties(src/dsp/receiver.cpp PROPERTIES
    COMPILE_OPTIONS "$<$<CONFIG:Debug>:-O2>")
# 2.4 MS/s IQ conversion and 1 Hz aircraft serialization run on the DSP
# worker, not the UI thread; do not ship an -O0 decoder in Flutter debug.
set_source_files_properties(src/decoder/adsb.cpp PROPERTIES
    COMPILE_OPTIONS "$<$<CONFIG:Debug>:-O2>")

# Audio sink backends (null/WAV/ALSA); defines target sdrcore_audio and, for
# standalone host builds, its CTest. See src/audio/audio_sink.h.
include(src/audio/audio.cmake)
target_link_libraries(sdrcore PRIVATE sdrcore_audio)

# Linux regression/oracle tests include usbfs fds, POSIX clocks and GNU linker
# wrapping. Keep these off Apple/Windows, where the portable subset below runs.
if(CMAKE_SYSTEM_NAME STREQUAL "Linux" AND PROJECT_IS_TOP_LEVEL)
    enable_testing()
    add_executable(sdrcore_dmr_channel_test tests/dmr_channel_test.cpp)
    target_link_libraries(sdrcore_dmr_channel_test PRIVATE sdrcore_dmr_channel Threads::Threads m)
    target_compile_options(sdrcore_dmr_channel_test PRIVATE -UNDEBUG)
    add_test(NAME sdrcore_dmr_channel COMMAND sdrcore_dmr_channel_test)
    add_executable(sdrcore_dmr_channel_filter_test tests/dmr_channel_filter_test.cpp)
    target_link_libraries(sdrcore_dmr_channel_filter_test PRIVATE sdrcore_dmr_channel Threads::Threads m)
    target_compile_options(sdrcore_dmr_channel_filter_test PRIVATE -UNDEBUG)
    add_test(NAME sdrcore_dmr_channel_filter COMMAND sdrcore_dmr_channel_filter_test)
    # Existing native tests use assert() for API calls with side effects;
    # retain those calls even when the production library is built Release.
    add_compile_options(-UNDEBUG)
    add_executable(sdrcore_rds_core_test tests/rds_core_test.cpp)
    target_link_libraries(sdrcore_rds_core_test PRIVATE sdrcore_rds)
    target_compile_features(sdrcore_rds_core_test PRIVATE cxx_std_17)
    target_compile_options(sdrcore_rds_core_test PRIVATE -UNDEBUG)
    add_test(NAME sdrcore_rds_core COMMAND sdrcore_rds_core_test)
    add_executable(sdrcore_rds_abi_test tests/rds_abi_test.cpp)
    target_link_libraries(sdrcore_rds_abi_test PRIVATE sdrcore)
    target_compile_options(sdrcore_rds_abi_test PRIVATE -UNDEBUG)
    add_test(NAME sdrcore_rds_abi COMMAND sdrcore_rds_abi_test)
    # Host-only oracle runner; feed the same external upstream MPX recording
    # to redsea's original Channel/Subcarrier and our WFM RDS adapter.
    add_executable(sdrcore_rds_mpx_oracle tests/rds_mpx_oracle.cpp)
    target_link_libraries(sdrcore_rds_mpx_oracle PRIVATE sdrcore_rds)
    target_compile_features(sdrcore_rds_mpx_oracle PRIVATE cxx_std_17)
    add_executable(sdrcore_rds_wfm_bench tests/rds_wfm_bench.cpp src/dsp/receiver.cpp)
    target_include_directories(sdrcore_rds_wfm_bench PRIVATE include)
    target_link_libraries(sdrcore_rds_wfm_bench PRIVATE sdrcore_rds)
    target_compile_options(sdrcore_rds_wfm_bench PRIVATE -O2)
    add_executable(sdrcore_rds_mpx_receiver tests/rds_mpx_receiver.cpp src/dsp/receiver.cpp)
    target_include_directories(sdrcore_rds_mpx_receiver PRIVATE include)
    target_link_libraries(sdrcore_rds_mpx_receiver PRIVATE sdrcore_rds)
    target_compile_options(sdrcore_rds_mpx_receiver PRIVATE -O2)
    add_executable(sdrcore_meshtastic_packet_test tests/meshtastic_packet_test.cpp)
    target_link_libraries(sdrcore_meshtastic_packet_test PRIVATE sdrcore_meshtastic)
    target_compile_definitions(sdrcore_meshtastic_packet_test PRIVATE
        MESHTASTIC_VECTORS="${CMAKE_CURRENT_SOURCE_DIR}/tests/data/meshtastic_vectors.json")
    add_test(NAME sdrcore_meshtastic_packet COMMAND sdrcore_meshtastic_packet_test)
    # Check the N2 header layouts independently of the DSP implementation.
    # The integrator advances sdr_version only after all N2 layers are ready.
    add_library(sdrcore_v3_contract_compile OBJECT tests/v3_contract_compile.c)
    target_include_directories(sdrcore_v3_contract_compile PRIVATE include)
    add_library(sdrcore_decoder_contract_compile OBJECT tests/decoder_contract_compile.c)
    target_include_directories(sdrcore_decoder_contract_compile PRIVATE include)
    add_executable(sdrcore_rtl433_engine_test tests/rtl433_engine_test.cpp)
    target_link_libraries(sdrcore_rtl433_engine_test PRIVATE sdrcore_rtl433)
    target_sources(sdrcore_rtl433_engine_test PRIVATE
        src/decoder/rtl433.cpp src/decoder/sstv.cpp src/decoder/adsb.cpp src/decoder/registry.cpp)
    target_link_libraries(sdrcore_rtl433_engine_test PRIVATE sdrcore_csdr_sstv sdrcore_dump1090)
    # third_party: the SSTV adapter linked in via registry.cpp uses the
    # vendored nlohmann/json.hpp (normally reached through sdrcore_redsea).
    target_include_directories(sdrcore_rtl433_engine_test PRIVATE include third_party)
    target_compile_features(sdrcore_rtl433_engine_test PRIVATE cxx_std_17)
    target_compile_options(sdrcore_rtl433_engine_test PRIVATE -UNDEBUG)
    target_link_options(sdrcore_rtl433_engine_test PRIVATE -Wl,--gc-sections)
    target_link_libraries(sdrcore_rtl433_engine_test PRIVATE m)
    add_test(NAME sdrcore_rtl433_engine COMMAND sdrcore_rtl433_engine_test)
    add_executable(sdrcore_rtl433_tap_oracle
        tests/rtl433_tap_oracle.cpp src/dsp/receiver.cpp
        src/decoder/rtl433.cpp src/decoder/sstv.cpp src/decoder/adsb.cpp src/decoder/registry.cpp)
    target_include_directories(sdrcore_rtl433_tap_oracle PRIVATE include)
    target_compile_features(sdrcore_rtl433_tap_oracle PRIVATE cxx_std_17)
    target_compile_options(sdrcore_rtl433_tap_oracle PRIVATE -O2)
    target_link_libraries(sdrcore_rtl433_tap_oracle PRIVATE sdrcore_rtl433 sdrcore_csdr_sstv sdrcore_dump1090 m)
    target_link_libraries(sdrcore_rtl433_tap_oracle PRIVATE sdrcore_rds)
    target_link_options(sdrcore_rtl433_tap_oracle PRIVATE -Wl,--gc-sections)
    add_executable(sdrcore_abi_test tests/abi_test.c)
    target_link_libraries(sdrcore_abi_test PRIVATE sdrcore)
    add_test(NAME sdrcore_abi COMMAND sdrcore_abi_test)
    add_executable(sdrcore_decoder_abi_test tests/decoder_abi_test.cpp)
    target_link_libraries(sdrcore_decoder_abi_test PRIVATE sdrcore)
    add_test(NAME sdrcore_decoder_abi COMMAND sdrcore_decoder_abi_test)
    add_executable(sdrcore_adsb_backend_test tests/adsb_backend_test.cpp src/decoder/adsb.cpp)
    target_include_directories(sdrcore_adsb_backend_test PRIVATE include third_party)
    target_compile_features(sdrcore_adsb_backend_test PRIVATE cxx_std_17)
    target_link_libraries(sdrcore_adsb_backend_test PRIVATE sdrcore_dump1090)
    add_test(NAME sdrcore_adsb_backend COMMAND sdrcore_adsb_backend_test)
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
        tests/decoder_registry_stub.cpp
        src/dsp/receiver.cpp
        src/usb_rtlsdr_adapter.cpp
        src/usb_hackrf_adapter.cpp)
    target_include_directories(sdrcore_ring_boundary_test PRIVATE include)
    target_compile_features(sdrcore_ring_boundary_test PRIVATE cxx_std_17)
    target_link_libraries(sdrcore_ring_boundary_test PRIVATE sdrcore_rtlsdr sdrcore_hackrf sdrcore_audio Threads::Threads)
    target_link_libraries(sdrcore_ring_boundary_test PRIVATE sdrcore_rds)
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
    add_executable(sdrcore_host_usb_direct_test tests/host_usb_direct_test.c)
    target_link_libraries(sdrcore_host_usb_direct_test PRIVATE sdrcore)
    add_test(NAME sdrcore_host_usb_direct COMMAND sdrcore_host_usb_direct_test)
    add_executable(sdrcore_rtl_gain_list_test
        tests/rtl_gain_list_test.cpp
        tests/decoder_registry_stub.cpp
        src/dsp/receiver.cpp
        src/usb_rtlsdr_adapter.cpp
        src/usb_hackrf_adapter.cpp)
    target_include_directories(sdrcore_rtl_gain_list_test PRIVATE include)
    target_compile_features(sdrcore_rtl_gain_list_test PRIVATE cxx_std_17)
    target_link_libraries(sdrcore_rtl_gain_list_test PRIVATE sdrcore_rtlsdr sdrcore_hackrf sdrcore_audio Threads::Threads)
    target_link_libraries(sdrcore_rtl_gain_list_test PRIVATE sdrcore_rds)
    add_test(NAME sdrcore_rtl_gain_list COMMAND sdrcore_rtl_gain_list_test)
    add_executable(sdrcore_live_retune_test
        tests/live_retune_test.cpp
        tests/decoder_registry_stub.cpp
        src/dsp/receiver.cpp
        src/usb_rtlsdr_adapter.cpp
        src/usb_hackrf_adapter.cpp)
    target_include_directories(sdrcore_live_retune_test PRIVATE include)
    target_compile_features(sdrcore_live_retune_test PRIVATE cxx_std_17)
    target_link_libraries(sdrcore_live_retune_test PRIVATE sdrcore_rtlsdr sdrcore_hackrf sdrcore_audio Threads::Threads)
    target_link_libraries(sdrcore_live_retune_test PRIVATE sdrcore_rds)
    add_test(NAME sdrcore_live_retune COMMAND sdrcore_live_retune_test)
    # White-box: discrete LO switches on a real-time paced fake RTL against an
    # AAudio callback model of the playback ring (t_8063d101).
    add_executable(sdrcore_retune_switch_gap_test
        tests/retune_switch_gap_test.cpp
        tests/decoder_registry_stub.cpp
        src/dsp/receiver.cpp
        src/usb_rtlsdr_adapter.cpp
        src/usb_hackrf_adapter.cpp)
    target_include_directories(sdrcore_retune_switch_gap_test PRIVATE include)
    target_compile_features(sdrcore_retune_switch_gap_test PRIVATE cxx_std_17)
    target_link_libraries(sdrcore_retune_switch_gap_test PRIVATE sdrcore_rtlsdr sdrcore_hackrf
        sdrcore_audio sdrcore_rds Threads::Threads)
    add_test(NAME sdrcore_retune_switch_gap COMMAND sdrcore_retune_switch_gap_test)
    add_executable(sdrcore_host_rtl_gain_test tests/host_rtl_gain_test.c)
    target_link_libraries(sdrcore_host_rtl_gain_test PRIVATE sdrcore)
    add_test(NAME sdrcore_host_rtl_gain COMMAND sdrcore_host_rtl_gain_test)
    # Tests that may open the attached SDR hardware must not run concurrently.
    set_tests_properties(sdrcore_host_usb sdrcore_host_usb_direct
        sdrcore_host_rtl_gain PROPERTIES RESOURCE_LOCK sdr_usb_device)
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
    target_link_libraries(sdrcore_wfm_stereo_dsp_test PRIVATE sdrcore_rds)
    # DSP-only: audio stays continuous across VFO drags and LO retunes.
    add_executable(sdrcore_retune_audio_continuity_test
        tests/retune_audio_continuity_test.cpp
        src/dsp/receiver.cpp)
    target_include_directories(sdrcore_retune_audio_continuity_test PRIVATE include)
    target_compile_features(sdrcore_retune_audio_continuity_test PRIVATE cxx_std_17)
    target_compile_options(sdrcore_retune_audio_continuity_test PRIVATE -O2)
    add_test(NAME sdrcore_retune_audio_continuity COMMAND sdrcore_retune_audio_continuity_test)
    target_link_libraries(sdrcore_retune_audio_continuity_test PRIVATE sdrcore_rds)
    add_executable(sdrcore_baseband_tap_test tests/baseband_tap_test.cpp src/dsp/receiver.cpp)
    target_include_directories(sdrcore_baseband_tap_test PRIVATE include)
    target_compile_features(sdrcore_baseband_tap_test PRIVATE cxx_std_17)
    add_test(NAME sdrcore_baseband_tap COMMAND sdrcore_baseband_tap_test)
    target_link_libraries(sdrcore_baseband_tap_test PRIVATE sdrcore_rds)
    add_executable(sdrcore_adsb_tap_test tests/adsb_tap_test.cpp src/dsp/receiver.cpp src/decoder/adsb.cpp)
    target_include_directories(sdrcore_adsb_tap_test PRIVATE include)
    target_compile_features(sdrcore_adsb_tap_test PRIVATE cxx_std_17)
    target_link_libraries(sdrcore_adsb_tap_test PRIVATE sdrcore_rds sdrcore_dump1090)
    add_test(NAME sdrcore_adsb_tap COMMAND sdrcore_adsb_tap_test)
    add_executable(sdrcore_baseband_tap_abi_test
        tests/baseband_tap_abi_test.cpp src/dsp/receiver.cpp
        src/usb_rtlsdr_adapter.cpp src/usb_hackrf_adapter.cpp)
    target_include_directories(sdrcore_baseband_tap_abi_test PRIVATE include)
    target_compile_features(sdrcore_baseband_tap_abi_test PRIVATE cxx_std_17)
    target_link_libraries(sdrcore_baseband_tap_abi_test PRIVATE
        sdrcore_rtlsdr sdrcore_hackrf sdrcore_audio Threads::Threads)
    target_link_libraries(sdrcore_baseband_tap_abi_test PRIVATE sdrcore_rds)
    add_test(NAME sdrcore_baseband_tap_abi COMMAND sdrcore_baseband_tap_abi_test)
    # SSTV backend (adapter + upstream decoder) and receiver audio-tap tests.
    include(tests/sstv_tests.cmake)
    include(tests/audio_tap_tests.cmake)
    include(tests/dmr_voice_tests.cmake)
endif()

# Standalone macOS/Windows CTest: link the actual shared library and run the
# ABI and direct-USB argument/no-device regressions. Audio CTests live in
# src/audio/audio.cmake and run on all desktops.
if((APPLE OR WIN32) AND PROJECT_IS_TOP_LEVEL)
    enable_testing()
    add_executable(sdrcore_abi_test tests/abi_test.c)
    target_link_libraries(sdrcore_abi_test PRIVATE sdrcore)
    add_test(NAME sdrcore_abi COMMAND sdrcore_abi_test)
    add_executable(sdrcore_host_usb_direct_test tests/host_usb_direct_test.c)
    target_link_libraries(sdrcore_host_usb_direct_test PRIVATE sdrcore)
    add_test(NAME sdrcore_host_usb_direct COMMAND sdrcore_host_usb_direct_test)
    add_executable(sdrcore_decoder_abi_test tests/decoder_abi_test.cpp)
    target_link_libraries(sdrcore_decoder_abi_test PRIVATE sdrcore)
    target_compile_options(sdrcore_decoder_abi_test PRIVATE -UNDEBUG)
    add_test(NAME sdrcore_decoder_abi COMMAND sdrcore_decoder_abi_test)
endif()
