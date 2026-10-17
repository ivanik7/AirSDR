# SPDX-License-Identifier: GPL-3.0-or-later
# DMR voice output tests (t_5b101746), included from the host-only test block
# in native/CMakeLists.txt after enable_testing().
add_executable(sdrcore_dmr_vocoder_test tests/dmr_vocoder_test.cpp)
target_include_directories(sdrcore_dmr_vocoder_test PRIVATE tests
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/openwebrx-dmr)
target_link_libraries(sdrcore_dmr_vocoder_test PRIVATE sdrcore_dmr_voice Threads::Threads m)
add_test(NAME sdrcore_dmr_vocoder COMMAND sdrcore_dmr_vocoder_test)

# Framing (digiham DmrDecoder port) -> VoiceOutput (softmbe/mbelib chain).
add_executable(sdrcore_dmr_framing_voice_test tests/dmr_framing_voice_test.cpp)
target_include_directories(sdrcore_dmr_framing_voice_test PRIVATE tests
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/openwebrx-dmr
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/digiham_dmr/upstream)
target_link_libraries(sdrcore_dmr_framing_voice_test PRIVATE
    sdrcore_dmr_framing sdrcore_dmr_voice Threads::Threads m)
add_test(NAME sdrcore_dmr_framing_voice COMMAND sdrcore_dmr_framing_voice_test)

# Host-only replay/corpus tool for tool/dmr_voice_oracle (not a CTest).
add_executable(dmr_voice_replay tests/dmr_voice_replay.cpp)
target_include_directories(dmr_voice_replay PRIVATE tests
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/openwebrx-dmr)
target_link_libraries(dmr_voice_replay PRIVATE sdrcore_dmr_voice Threads::Threads m)

add_executable(sdrcore_decoder_voice_replace_test
    tests/decoder_voice_replace_test.cpp src/dsp/receiver.cpp)
target_include_directories(sdrcore_decoder_voice_replace_test PRIVATE include)
target_compile_features(sdrcore_decoder_voice_replace_test PRIVATE cxx_std_17)
target_link_libraries(sdrcore_decoder_voice_replace_test PRIVATE sdrcore_rds)
add_test(NAME sdrcore_decoder_voice_replace COMMAND sdrcore_decoder_voice_replace_test)

# White-box: voice decoder PCM through sdrcore.cpp's DSP worker into a WAV sink.
add_executable(sdrcore_decoder_voice_abi_test
    tests/decoder_voice_abi_test.cpp src/dsp/receiver.cpp
    src/usb_rtlsdr_adapter.cpp src/usb_hackrf_adapter.cpp)
target_include_directories(sdrcore_decoder_voice_abi_test PRIVATE include)
target_compile_features(sdrcore_decoder_voice_abi_test PRIVATE cxx_std_17)
target_link_libraries(sdrcore_decoder_voice_abi_test PRIVATE
    sdrcore_rtlsdr sdrcore_hackrf sdrcore_audio sdrcore_rds Threads::Threads)
add_test(NAME sdrcore_decoder_voice_abi COMMAND sdrcore_decoder_voice_abi_test)
