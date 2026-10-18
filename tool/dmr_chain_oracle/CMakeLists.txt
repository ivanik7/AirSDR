cmake_minimum_required(VERSION 3.20)
# Native half of tool/dmr_chain_oracle: the app's DMR Channel + Framing.
# The pristine OpenWebRX+ half is built by build_oracle.sh.
project(dmr_chain_oracle LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
get_filename_component(ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
add_subdirectory("${ROOT}/native" native EXCLUDE_FROM_ALL)
add_executable(native_chain chain.cpp)
target_link_libraries(native_chain PRIVATE sdrcore_dmr_framing sdrcore_dmr_channel)
