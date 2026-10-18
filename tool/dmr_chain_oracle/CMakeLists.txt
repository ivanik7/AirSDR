cmake_minimum_required(VERSION 3.20)
# Native half of tool/dmr_chain_oracle: the app's DMR Channel + Framing.
# The pristine OpenWebRX+ half is built by build_oracle.sh.
project(dmr_chain_oracle LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
get_filename_component(ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
add_subdirectory("${ROOT}/native" native EXCLUDE_FROM_ALL)
add_executable(native_chain chain.cpp)
target_link_libraries(native_chain PRIVATE sdrcore_dmr_framing sdrcore_dmr_channel)
# Native voice chain (VoiceOutput 8 kHz capture) for the PCM comparison.
add_executable(dmr_voice_replay "${ROOT}/native/tests/dmr_voice_replay.cpp")
target_include_directories(dmr_voice_replay PRIVATE "${ROOT}/native/tests"
    "${ROOT}/native/third_party/openwebrx-dmr")
find_package(Threads REQUIRED)
target_link_libraries(dmr_voice_replay PRIVATE sdrcore_dmr_voice Threads::Threads m)
