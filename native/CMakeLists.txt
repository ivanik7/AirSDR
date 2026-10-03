cmake_minimum_required(VERSION 3.22)
project(sdrcore VERSION 1.0.0 LANGUAGES C CXX)

add_library(sdrcore SHARED src/sdrcore.cpp)
target_compile_features(sdrcore PRIVATE cxx_std_17)
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
endif()
