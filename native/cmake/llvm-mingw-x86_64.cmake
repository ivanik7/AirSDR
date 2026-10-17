# SPDX-License-Identifier: GPL-3.0-or-later
#
# CMake toolchain for the Windows x64 native core (sdrcore.dll) with
# llvm-mingw (https://github.com/mstorsjo/llvm-mingw, UCRT flavour):
# clang + lld + libc++ targeting x86_64-w64-mingw32.
#
# MSVC cannot build the core: liquid-dsp (RDS) needs C99 _Complex arithmetic
# and <complex.h>, which MSVC and the UCRT headers used by clang-cl do not
# provide. The Flutter Windows runner itself stays MSVC; it only loads the
# self-contained sdrcore.dll through the plain C ABI.
#
# Usage (cross from Linux, or natively on Windows with the llvm-mingw zip):
#   cmake -S native -B build-win -G Ninja \
#     -DCMAKE_TOOLCHAIN_FILE=native/cmake/llvm-mingw-x86_64.cmake \
#     -DLLVM_MINGW_ROOT=/path/to/llvm-mingw-<ver>-ucrt-<host>
# LLVM_MINGW_ROOT may also come from the environment. Without it the
# compilers must be on PATH.

set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

if(NOT LLVM_MINGW_ROOT AND DEFINED ENV{LLVM_MINGW_ROOT})
    set(LLVM_MINGW_ROOT "$ENV{LLVM_MINGW_ROOT}")
endif()
# Try-compile projects re-read this file; forward the root to them.
set(LLVM_MINGW_ROOT "${LLVM_MINGW_ROOT}" CACHE PATH "llvm-mingw installation root")
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES LLVM_MINGW_ROOT)

set(_sdr_triple x86_64-w64-mingw32)
if(CMAKE_HOST_WIN32)
    set(_sdr_exe ".exe")
else()
    set(_sdr_exe "")
endif()
if(LLVM_MINGW_ROOT)
    set(_sdr_bin "${LLVM_MINGW_ROOT}/bin/")
else()
    set(_sdr_bin "")
endif()

set(CMAKE_C_COMPILER "${_sdr_bin}${_sdr_triple}-clang${_sdr_exe}")
set(CMAKE_CXX_COMPILER "${_sdr_bin}${_sdr_triple}-clang++${_sdr_exe}")
set(CMAKE_RC_COMPILER "${_sdr_bin}${_sdr_triple}-windres${_sdr_exe}")
set(CMAKE_AR "${_sdr_bin}llvm-ar${_sdr_exe}" CACHE FILEPATH "")
set(CMAKE_RANLIB "${_sdr_bin}llvm-ranlib${_sdr_exe}" CACHE FILEPATH "")

if(LLVM_MINGW_ROOT)
    set(CMAKE_FIND_ROOT_PATH "${LLVM_MINGW_ROOT}/${_sdr_triple}")
endif()
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
