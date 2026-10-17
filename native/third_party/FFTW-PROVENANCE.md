# FFTW 3.3.10 (fftw3f) provenance

## Upstream

- Project: FFTW (Fastest Fourier Transform in the West)
- Version: 3.3.10
- Upstream URL: https://www.fftw.org/fftw-3.3.10.tar.gz
- SHA-256: `56c932549852cddcfafdab3820b0200c7742675be92179e59e6215b340e26467`
- License: GPL-2.0-or-later. This application is GPL-3.0-or-later; FFTW is
  used under the GPLv3 terms permitted by "or-later" GPLv2 code (GPLv3 is
  compatible with and a legitimate successor license for GPLv2-or-later
  code).

The tarball is not vendored in this repository; only a plain-text source
subset extracted from it lives under `native/third_party/fftw-3.3.10/`.
**No prebuilt FFTW binaries, headers-only stubs, or pkg-config shims are
used anywhere in this project — the library is always compiled from this
vendored source by the project's own CMake (`fftw.cmake`).**

## Why FFTW is needed

The csdr-plus SSTV decoder (ported from OpenWebRX+) performs real-input FFTs
via `fftwf_plan_dft_r2c_1d` with `FFTW_ESTIMATE`. The build must therefore
provide a from-source, single-precision (`fftw3f`) FFTW library with no
host-installed `libfftw3f` dependency.

## What was vendored

A scalar (non-SIMD), non-threaded, non-Fortran, non-MPI, single-precision
subset of the upstream tree, copied byte-identical:

- `api/` — public API and planner glue (all `.c`/`.h`), **excluding**
  `f77api.c`, `f77funcs.h`, `x77.h` and the Fortran `.f`/`.f03`/`.f03.in`
  interface files (no Fortran wrappers are built; `DISABLE_FORTRAN=1`).
- `kernel/` — core planner, memory, trig, tensor and problem machinery
  (all `.c`/`.h`).
- `dft/` — top-level complex-DFT planning/solver sources (`.c`/`.h`) plus
  `dft/scalar/` (scalar direct/indirect kernels) and
  `dft/scalar/codelets/` (the generated scalar FFT codelets).
  `dft/simd/` and `simd-support/` were **not** vendored: no scalar source
  file includes anything under those directories (verified by grepping for
  `#include ".../simd` and `simd-support` across `api/`, `kernel/`, `dft/`,
  `rdft/`, `reodft/`), and the SIMD codelets are gated at compile time by
  `HAVE_SSE2`/`HAVE_AVX`/`HAVE_NEON`/etc., all left undefined in this build.
- `rdft/` — top-level real-DFT planning/solver sources (`.c`/`.h`) plus
  `rdft/scalar/` and its `r2cb/`, `r2cf/`, `r2r/` scalar codelet
  subdirectories (real-to-complex forward/backward and real-to-real
  codelets). `rdft/simd/` was omitted for the same reason as `dft/simd/`.
- `reodft/` — real-even/-odd DFT solvers (`.c`/`.h`), used by some
  higher-level real-transform planners.
- `COPYING`, `COPYRIGHT`, `README`, `AUTHORS`, `NEWS` — upstream license and
  attribution files, copied verbatim.
- `cmake.config.h.in` — upstream's `config.h` template, copied verbatim and
  rendered by `fftw.cmake` via `configure_file()`.

## What was omitted, and why

- `dft/simd/`, `rdft/simd/`, `simd-support/` — SSE2/AVX/AVX2/AVX-512/NEON/
  AltiVec/VSX/KCVI/generic-SIMD codelets and CPU-feature detection. This
  build targets a portable scalar FFT (`ENABLE_SSE=OFF`,
  `ENABLE_SSE2=OFF`, `ENABLE_AVX=OFF`, `ENABLE_AVX2=OFF` in upstream CMake
  terms); none of the vendored scalar/rdft/dft/api/kernel sources reference
  these directories.
- `threads/`, `mpi/` — multithreading (pthreads/OpenMP) and MPI support.
  Not needed; the decoder plans and executes on a single thread.
- `api/f77api.c`, `api/f77funcs.h`, `api/x77.h`, `api/*.f`, `api/*.f03`,
  `api/*.f03.in` — Fortran interface wrappers. `DISABLE_FORTRAN=1` is set.
- `genfft/`, `support/`, `tools/`, `libbench2/`, `tests/`, `doc/`,
  `m4/`, `mpi/` autotools and benchmark/test infrastructure, the codelet
  generator, and documentation. None of these are required to build or use
  the library; they are not part of the compiled artifact.
- `Makefile.am`, `Makefile.in`, `configure`, `configure.ac`, `aclocal.m4`,
  `config.h.in` (the autotools-generated variant, as opposed to
  `cmake.config.h.in`), `ltmain.sh`, `install-sh`, `depcomp`, `missing`,
  `compile`, `config.guess`, `config.sub`, `bootstrap.sh`, `ChangeLog`,
  `CONVENTIONS`, `TODO`, `INSTALL`, `README-perfcnt.md`,
  `FFTW3Config.cmake.in`, `FFTW3ConfigVersion.cmake.in`, `fftw.pc.in` —
  autotools/libtool build plumbing and packaging files superseded by this
  project's own `fftw.cmake`.

## Build configuration

- `FFTW_SINGLE` defined (single-precision `fftw3f` build only; no double,
  long-double, or quad precision).
- No SIMD instruction sets enabled (scalar C codelets only) — portable
  across host x86-64 and Android arm64-v8a without per-arch code paths.
- No threads, no OpenMP (`ENABLE_THREADS=OFF`, `ENABLE_OPENMP=OFF` in
  upstream CMake terms); the decoder uses the library from a single thread.
- `DISABLE_FORTRAN=1` (no Fortran wrappers).
- The only planner flag the SSTV decoder uses is `FFTW_ESTIMATE` — plans are
  built without runtime measurement/timing, matching the "no exhaustive
  planning side effects" requirement for an embedded/mobile DSP pipeline.
- Target `sdrcore_fftw3f` is a static library
  (`add_library(sdrcore_fftw3f STATIC ...)`), built with
  `POSITION_INDEPENDENT_CODE ON`, `C_STANDARD 99`, and
  `-O2 -fvisibility=hidden -ffunction-sections -fdata-sections -w`.
  It exposes only `api/fftw3.h` as its public include directory and links
  `m` (libm) publicly.
- Config checks (`HAVE_*`, `SIZEOF_*`) are computed locally by
  `fftw.cmake` for whichever toolchain is configuring (host or Android NDK)
  and rendered into `${CMAKE_CURRENT_BINARY_DIR}/fftw3f-config/config.h`,
  mirroring upstream `fftw-3.3.10/CMakeLists.txt`'s own `check_include_file`
  / `check_symbol_exists` / `check_type_size` calls. These checks run inside
  a CMake `function()` so none of FFTW's (deliberately unqualified)
  `HAVE_*`/`SIZEOF_*` cache variable names leak into the including
  `native/CMakeLists.txt` scope and collide with other vendored libraries
  built in the same tree (e.g. liquid-dsp's own, explicitly namespaced,
  `LIQUID_SIZEOF_INT`).

## No prebuilt binaries

This library is never fetched or linked as a prebuilt `.a`/`.so`, and the
build never calls `find_package(FFTW3f)`/`pkg-config` against a
host-installed FFTW. `native/third_party/fftw.cmake` compiles
`sdrcore_fftw3f` from the vendored sources above for every target
(host Linux and Android arm64-v8a) using the project's own CMake and the
Android NDK toolchain file, respectively.
