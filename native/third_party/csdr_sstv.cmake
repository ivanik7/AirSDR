# csdr-plus SSTV decoder (BSD-3, Marat Fayzullin) + csdr Module/Source/Sink
# glue (GPL-3.0-or-later, Jakob Ketterl), vendored verbatim with five
# documented patches (sdr_flutter.patch) to the sstv.hpp/sstv.cpp pair only.
# See native/third_party/csdr_sstv/PROVENANCE.md for the full file-by-file
# provenance and patch rationale.
#
# This file is include()d from native/CMakeLists.txt, so CMAKE_CURRENT_LIST_DIR
# here is native/third_party (see fftw.cmake, which is included just before
# this file and defines sdrcore_fftw3f).
set(CSDR_SSTV_ROOT ${CMAKE_CURRENT_LIST_DIR}/csdr_sstv)

add_library(sdrcore_csdr_sstv STATIC
    ${CSDR_SSTV_ROOT}/src/sstv.cpp
    ${CSDR_SSTV_ROOT}/src/module.cpp
    ${CSDR_SSTV_ROOT}/src/source.cpp
    ${CSDR_SSTV_ROOT}/src/sink.cpp
    ${CSDR_SSTV_ROOT}/src/ringbuffer.cpp
)
target_include_directories(sdrcore_csdr_sstv PUBLIC ${CSDR_SSTV_ROOT}/include)
target_link_libraries(sdrcore_csdr_sstv PUBLIC sdrcore_fftw3f)
set_target_properties(sdrcore_csdr_sstv PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_compile_features(sdrcore_csdr_sstv PUBLIC cxx_std_17)
# Vendored code uses its own upstream conventions (e.g. implicit int<->double
# narrowing in SSTV timing math, printf-style format diagnostics already
# bounded by patch 4); do not apply this app's warning policy to it.
target_compile_options(sdrcore_csdr_sstv PRIVATE -w)
find_package(Threads REQUIRED)
target_link_libraries(sdrcore_csdr_sstv PUBLIC Threads::Threads)
