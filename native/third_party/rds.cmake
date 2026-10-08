# redsea 1.3.1 (7555c9f) and liquid-dsp 1.6.0 are compiled from vendored
# permissively licensed source. CLI, libsndfile input and subprocesses are not linked.
set(LIQUID_ROOT ${CMAKE_CURRENT_LIST_DIR}/liquid-dsp-1.6.0)
include(CheckTypeSize)
check_type_size("int" LIQUID_SIZEOF_INT)
configure_file(${CMAKE_CURRENT_LIST_DIR}/liquid-config.h.in
    ${CMAKE_CURRENT_BINARY_DIR}/liquid-config/config.h @ONLY)
file(GLOB LIQUID_SOURCES CONFIGURE_DEPENDS ${LIQUID_ROOT}/src/*/src/*.c)
list(FILTER LIQUID_SOURCES EXCLUDE REGEX "\\.proto\\.c$")
list(FILTER LIQUID_SOURCES EXCLUDE REGEX "[._](avx|av|sse|mmx|neon)[^/]*\\.c$")
list(APPEND LIQUID_SOURCES ${LIQUID_ROOT}/src/libliquid.c)
add_library(sdrcore_liquid STATIC ${LIQUID_SOURCES})
set_target_properties(sdrcore_liquid PROPERTIES POSITION_INDEPENDENT_CODE ON C_STANDARD 99)
target_compile_options(sdrcore_liquid PRIVATE -O2 -ffunction-sections -fdata-sections -w)
target_include_directories(sdrcore_liquid PUBLIC ${LIQUID_ROOT}/include)
target_include_directories(sdrcore_liquid PRIVATE
    ${CMAKE_CURRENT_BINARY_DIR}/liquid-config ${LIQUID_ROOT})
target_link_libraries(sdrcore_liquid PUBLIC m)

set(REDSEA_ROOT ${CMAKE_CURRENT_LIST_DIR}/redsea)
set(REDSEA_SOURCES
    block_sync channel dsp/liquid_wrappers dsp/subcarrier group io/output
    rft station tables text/rdsstring tmc/events_data tmc/eventdb
    tmc/message tmc/tmc tmc/locationdb util/csv util/util)
set(REDSEA_SOURCE_FILES)
foreach(name IN LISTS REDSEA_SOURCES)
    list(APPEND REDSEA_SOURCE_FILES ${REDSEA_ROOT}/src/${name}.cc)
endforeach()
add_library(sdrcore_redsea STATIC ${REDSEA_SOURCE_FILES})
set_target_properties(sdrcore_redsea PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_compile_features(sdrcore_redsea PRIVATE cxx_std_17)
target_compile_options(sdrcore_redsea PRIVATE -O2 -Wno-unknown-pragmas)
target_compile_definitions(sdrcore_redsea PRIVATE MODEM_IS_MODEMCF)
target_include_directories(sdrcore_redsea PUBLIC ${REDSEA_ROOT} ${CMAKE_CURRENT_LIST_DIR})
target_link_libraries(sdrcore_redsea PUBLIC sdrcore_liquid)
