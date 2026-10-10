# FFTW 3.3.10 (fftw3f, single precision, scalar codelets only) is compiled from
# vendored GPL-2.0-or-later source. No SIMD, no threads/OpenMP, no Fortran, no MPI.
# See native/third_party/FFTW-PROVENANCE.md for the exact file list and rationale.
#
# This file is include()d from native/CMakeLists.txt, so CMAKE_CURRENT_LIST_DIR
# here is native/third_party.
set(FFTW_ROOT ${CMAKE_CURRENT_LIST_DIR}/fftw-3.3.10)

# --- Scalar single-precision config checks (mirrors upstream fftw-3.3.10/CMakeLists.txt) ---
# Wrapped in block() so these FFTW-specific check_* result variables (and the
# unqualified SIZEOF_* / HAVE_* cache names cmake.config.h.in expects) do not
# leak into the including directory scope and collide with other vendored
# libraries built in the same CMake tree (e.g. liquid-dsp's LIQUID_SIZEOF_INT,
# which is deliberately namespaced; FFTW's own cmake.config.h.in is not, so we
# contain the leak here instead by using block(SCOPE_FOR VARIABLES) semantics
# via a function that configures the header once).
function(_sdrcore_fftw3f_configure)
  include(CheckIncludeFile)
  check_include_file(alloca.h         HAVE_ALLOCA_H)
  check_include_file(altivec.h        HAVE_ALTIVEC_H)
  check_include_file(dlfcn.h          HAVE_DLFCN_H)
  check_include_file(inttypes.h       HAVE_INTTYPES_H)
  check_include_file(limits.h         HAVE_LIMITS_H)
  check_include_file(mach/mach_time.h HAVE_MACH_MACH_TIME_H)
  check_include_file(malloc.h         HAVE_MALLOC_H)
  check_include_file(memory.h         HAVE_MEMORY_H)
  check_include_file(stddef.h         HAVE_STDDEF_H)
  check_include_file(stdint.h         HAVE_STDINT_H)
  check_include_file(stdlib.h         HAVE_STDLIB_H)
  check_include_file(string.h         HAVE_STRING_H)
  check_include_file(strings.h        HAVE_STRINGS_H)
  check_include_file(sys/types.h      HAVE_SYS_TYPES_H)
  check_include_file(sys/time.h       HAVE_SYS_TIME_H)
  check_include_file(sys/stat.h       HAVE_SYS_STAT_H)
  check_include_file(sys/sysctl.h     HAVE_SYS_SYSCTL_H)
  check_include_file(time.h           HAVE_TIME_H)
  check_include_file(unistd.h         HAVE_UNISTD_H)
  if(HAVE_TIME_H AND HAVE_SYS_TIME_H)
    set(TIME_WITH_SYS_TIME TRUE)
  endif()

  include(CheckPrototypeDefinition)
  check_prototype_definition(drand48 "double drand48 (void)" "0" stdlib.h HAVE_DECL_DRAND48)
  check_prototype_definition(srand48 "void srand48(long int seedval)" "0" stdlib.h HAVE_DECL_SRAND48)
  check_prototype_definition(cosl "long double cosl( long double arg )" "0" math.h HAVE_DECL_COSL)
  check_prototype_definition(sinl "long double sinl( long double arg )" "0" math.h HAVE_DECL_SINL)
  check_prototype_definition(memalign "void *memalign(size_t alignment, size_t size)" "0" malloc.h HAVE_DECL_MEMALIGN)
  check_prototype_definition(posix_memalign "int posix_memalign(void **memptr, size_t alignment, size_t size)" "0" stdlib.h HAVE_DECL_POSIX_MEMALIGN)

  include(CheckSymbolExists)
  check_symbol_exists(clock_gettime time.h HAVE_CLOCK_GETTIME)
  check_symbol_exists(gettimeofday sys/time.h HAVE_GETTIMEOFDAY)
  check_symbol_exists(getpagesize unistd.h HAVE_GETPAGESIZE)
  check_symbol_exists(drand48 stdlib.h HAVE_DRAND48)
  check_symbol_exists(srand48 stdlib.h HAVE_SRAND48)
  check_symbol_exists(memalign malloc.h HAVE_MEMALIGN)
  check_symbol_exists(posix_memalign stdlib.h HAVE_POSIX_MEMALIGN)
  check_symbol_exists(mach_absolute_time mach/mach_time.h HAVE_MACH_ABSOLUTE_TIME)
  check_symbol_exists(alloca alloca.h HAVE_ALLOCA)
  if(NOT HAVE_ALLOCA)
    unset(HAVE_ALLOCA CACHE)
    check_symbol_exists(alloca malloc.h HAVE_ALLOCA)
  endif()
  check_symbol_exists(isnan math.h HAVE_ISNAN)
  check_symbol_exists(snprintf stdio.h HAVE_SNPRINTF)
  check_symbol_exists(strchr string.h HAVE_STRCHR)
  check_symbol_exists(sysctl unistd.h HAVE_SYSCTL)

  if(UNIX)
    set(CMAKE_REQUIRED_LIBRARIES m)
  endif()
  check_symbol_exists(cosl math.h HAVE_COSL)
  check_symbol_exists(sinl math.h HAVE_SINL)

  include(CheckTypeSize)
  check_type_size("float" SIZEOF_FLOAT)
  check_type_size("double" SIZEOF_DOUBLE)
  check_type_size("int" SIZEOF_INT)
  check_type_size("long" SIZEOF_LONG)
  check_type_size("long long" SIZEOF_LONG_LONG)
  check_type_size("unsigned int" SIZEOF_UNSIGNED_INT)
  check_type_size("unsigned long" SIZEOF_UNSIGNED_LONG)
  check_type_size("unsigned long long" SIZEOF_UNSIGNED_LONG_LONG)
  check_type_size("size_t" SIZEOF_SIZE_T)
  check_type_size("ptrdiff_t" SIZEOF_PTRDIFF_T)

  find_library(LIBM_LIBRARY NAMES m)
  if(LIBM_LIBRARY)
    set(HAVE_LIBM TRUE)
  endif()

  # Scalar build: no SIMD extensions, no threads/OpenMP, single precision,
  # Fortran wrappers disabled.
  set(FFTW_SINGLE TRUE)
  set(BENCHFFT_SINGLE TRUE)
  set(DISABLE_FORTRAN TRUE)
  set(FFTW_VERSION "3.3.10")

  configure_file(${FFTW_ROOT}/cmake.config.h.in
      ${CMAKE_CURRENT_BINARY_DIR}/fftw3f-config/config.h @ONLY)
endfunction()

_sdrcore_fftw3f_configure()

# --- Source list: scalar single-precision subset only (mirrors upstream globs) ---
file(GLOB FFTW_API_SOURCES              ${FFTW_ROOT}/api/*.c)
file(GLOB FFTW_KERNEL_SOURCES           ${FFTW_ROOT}/kernel/*.c)
file(GLOB FFTW_DFT_SOURCES              ${FFTW_ROOT}/dft/*.c)
file(GLOB FFTW_DFT_SCALAR_SOURCES       ${FFTW_ROOT}/dft/scalar/*.c)
file(GLOB FFTW_DFT_SCALAR_CODELETS      ${FFTW_ROOT}/dft/scalar/codelets/*.c)
file(GLOB FFTW_RDFT_SOURCES             ${FFTW_ROOT}/rdft/*.c)
file(GLOB FFTW_RDFT_SCALAR_SOURCES      ${FFTW_ROOT}/rdft/scalar/*.c)
file(GLOB FFTW_RDFT_SCALAR_R2CB         ${FFTW_ROOT}/rdft/scalar/r2cb/*.c)
file(GLOB FFTW_RDFT_SCALAR_R2CF         ${FFTW_ROOT}/rdft/scalar/r2cf/*.c)
file(GLOB FFTW_RDFT_SCALAR_R2R          ${FFTW_ROOT}/rdft/scalar/r2r/*.c)
file(GLOB FFTW_REODFT_SOURCES           ${FFTW_ROOT}/reodft/*.c)

set(FFTW_SOURCES
    ${FFTW_API_SOURCES}
    ${FFTW_KERNEL_SOURCES}
    ${FFTW_DFT_SOURCES}
    ${FFTW_DFT_SCALAR_SOURCES}
    ${FFTW_DFT_SCALAR_CODELETS}
    ${FFTW_RDFT_SOURCES}
    ${FFTW_RDFT_SCALAR_SOURCES}
    ${FFTW_RDFT_SCALAR_R2CB}
    ${FFTW_RDFT_SCALAR_R2CF}
    ${FFTW_RDFT_SCALAR_R2R}
    ${FFTW_REODFT_SOURCES}
)

add_library(sdrcore_fftw3f STATIC ${FFTW_SOURCES})
set_target_properties(sdrcore_fftw3f PROPERTIES
    POSITION_INDEPENDENT_CODE ON
    C_STANDARD 99)
target_compile_definitions(sdrcore_fftw3f PRIVATE FFTW_SINGLE)
target_compile_options(sdrcore_fftw3f PRIVATE -O2 -fvisibility=hidden -ffunction-sections -fdata-sections -w)
target_include_directories(sdrcore_fftw3f PUBLIC ${FFTW_ROOT}/api)
target_include_directories(sdrcore_fftw3f PRIVATE
    ${FFTW_ROOT}
    ${CMAKE_CURRENT_BINARY_DIR}/fftw3f-config)
target_link_libraries(sdrcore_fftw3f PUBLIC m)
