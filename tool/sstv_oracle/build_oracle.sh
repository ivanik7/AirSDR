#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds the offline OpenWebRX+ SSTV oracle from PRISTINE upstream sources:
#   - FFTW 3.3.10 (fftw3f, SHA-256 56c93254...6467) from www.fftw.org,
#   - libsamplerate 0.2.2 (needed only to configure libcsdr++),
#   - csdr-plus at the pinned commit f26b520 (local ref checkout),
#   - csdr's own `csdr sstvdecode` CLI and owrx_sstv_harness (this dir),
#     which runs SstvDecoder(24000, 300000) as OpenWebRX+ does.
# Nothing built here is linked into the app or launched by it.
#
# Optional control (when NATIVE_BUILD points at a native/ CMake build dir
# that has built libsdrcore_fftw3f.a): owrx_sstv_harness_vfftw = the same
# PRISTINE upstream sstv.cpp, -O2 without fast-math, linked against the
# app's vendored FFTW. It separates FFTW rounding from sdr_flutter patches.
#
# Usage: [NATIVE_BUILD=build/native-host] tool/sstv_oracle/build_oracle.sh WORKDIR
set -euo pipefail
work=$(realpath -m "${1:?usage: build_oracle.sh WORKDIR}")
here=$(cd "$(dirname "$0")" && pwd)
csdr=${CSDR_PLUS_SRC:-$HOME/prj/ref/openwebrx/csdr-plus}
pin=f26b52071c4a127fc8193d058c249cac57585de4
mkdir -p "$work"
cd "$work"
prefix=$work/prefix

[ "$(git -C "$csdr" rev-parse HEAD)" = "$pin" ] || { echo "csdr-plus is not at $pin" >&2; exit 1; }
[ -z "$(git -C "$csdr" status --porcelain)" ] || { echo "csdr-plus checkout is modified" >&2; exit 1; }

if [ ! -f "$prefix/lib/libfftw3f.so" ]; then
  [ -f fftw-3.3.10.tar.gz ] || curl -sSLo fftw-3.3.10.tar.gz https://www.fftw.org/fftw-3.3.10.tar.gz
  echo "56c932549852cddcfafdab3820b0200c7742675be92179e59e6215b340e26467  fftw-3.3.10.tar.gz" | sha256sum -c -
  tar xzf fftw-3.3.10.tar.gz
  (cd fftw-3.3.10 && ./configure --prefix="$prefix" --enable-float --enable-sse2 --enable-avx \
     --enable-avx2 --enable-shared --disable-static --disable-fortran >/dev/null && make -j4 >/dev/null &&
   make install >/dev/null)
fi
if [ ! -f "$prefix/lib/libsamplerate.so" ]; then
  [ -f libsamplerate-0.2.2.tar.xz ] || curl -sSLo libsamplerate-0.2.2.tar.xz \
    https://github.com/libsndfile/libsamplerate/releases/download/0.2.2/libsamplerate-0.2.2.tar.xz
  echo "3258da280511d24b49d6b08615bbe824d0cacc9842b0e4caf11c52cf2b043893  libsamplerate-0.2.2.tar.xz" | sha256sum -c -
  tar xJf libsamplerate-0.2.2.tar.xz
  cmake -S libsamplerate-0.2.2 -B libsamplerate-0.2.2/build -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF -DLIBSAMPLERATE_EXAMPLES=OFF >/dev/null
  cmake --build libsamplerate-0.2.2/build -j4 >/dev/null
  cmake --install libsamplerate-0.2.2/build >/dev/null
fi

# Upstream's own CMake (Release, its -O3 -ffast-math flags), out of tree.
export CPATH=$prefix/include LIBRARY_PATH=$prefix/lib PKG_CONFIG_PATH=$prefix/lib/pkgconfig
cmake -S "$csdr" -B csdr-build -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$prefix" \
  -DCMAKE_BUILD_RPATH="$prefix/lib" >/dev/null
cmake --build csdr-build -j4 >/dev/null

# The harness links upstream's own libcsdr++ (pristine sstv.cpp inside).
g++ -std=c++17 -O3 -ffast-math -mfpmath=sse -I"$csdr/include" -I"$prefix/include" \
  "$here/owrx_sstv_harness.cpp" -o owrx_sstv_harness \
  -L"$work/csdr-build/src/lib" -lcsdr++ -L"$prefix/lib" -lfftw3f -lpthread \
  -Wl,-rpath,"$work/csdr-build/src/lib:$prefix/lib"
echo "oracle: $work/owrx_sstv_harness, csdr CLI: $work/csdr-build/src/apps/csdr/csdr"

if [ -n "${NATIVE_BUILD:-}" ]; then
  nb=$(realpath "$NATIVE_BUILD")
  g++ -std=c++17 -O2 -I"$csdr/include" -I"$prefix/include" "$here/owrx_sstv_harness.cpp" \
    "$csdr"/src/lib/{sstv,module,source,sink,ringbuffer,writer,reader}.cpp \
    -o owrx_sstv_harness_vfftw "$nb/libsdrcore_fftw3f.a" -lpthread -lm
  echo "control: $work/owrx_sstv_harness_vfftw"
fi
