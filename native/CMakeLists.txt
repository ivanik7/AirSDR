cmake_minimum_required(VERSION 3.22)
project(sdrcore VERSION 1.0.0 LANGUAGES C CXX)

add_subdirectory(third_party)

add_library(sdrcore SHARED
    src/sdrcore.cpp
    src/usb_rtlsdr_adapter.cpp
    src/usb_hackrf_adapter.cpp
)
if(ANDROID)
    target_sources(sdrcore PRIVATE src/sdr_jni.cpp)
endif()
target_compile_features(sdrcore PRIVATE cxx_std_17)
find_package(Threads REQUIRED)
target_link_libraries(sdrcore PRIVATE Threads::Threads sdrcore_rtlsdr sdrcore_hackrf)
set_target_properties(sdrcore PROPERTIES
    CXX_EXTENSIONS OFF
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN YES)
target_include_directories(sdrcore PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)

if(NOT ANDROID)
    enable_testing()
    add_executable(sdrcore_abi_test tests/abi_test.c)
    target_link_libraries(sdrcore_abi_test PRIVATE sdrcore)
    add_test(NAME sdrcore_abi COMMAND sdrcore_abi_test)
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
        src/usb_rtlsdr_adapter.cpp
        src/usb_hackrf_adapter.cpp)
    target_include_directories(sdrcore_ring_boundary_test PRIVATE include)
    target_compile_features(sdrcore_ring_boundary_test PRIVATE cxx_std_17)
    target_link_libraries(sdrcore_ring_boundary_test PRIVATE sdrcore_rtlsdr sdrcore_hackrf Threads::Threads)
    add_test(NAME sdrcore_ring_boundary COMMAND sdrcore_ring_boundary_test)
endif()
