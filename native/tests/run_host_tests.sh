#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Reproducible host-side test runner for the ABI 2 native core
# (native/include/sdrcore.h). Builds libsdrcore.so for the host with CMake,
# runs the CMake-wired ctest suite, then runs standalone diagnostics.
#
# Usage: native/tests/run_host_tests.sh [build_dir]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
build_dir="${1:-$root/build/native-host-tests}"

# Prefer a plain `cmake` on PATH; fall back to the Android SDK's bundled
# cmake (used to build the host libsdrcore.so, not an Android build).
cmake_bin="cmake"
if ! command -v cmake >/dev/null 2>&1; then
  for candidate in "$HOME/sdk/android/cmake"/*/bin/cmake; do
    if [ -x "$candidate" ]; then
      cmake_bin="$candidate"
      break
    fi
  done
fi
if ! command -v "$cmake_bin" >/dev/null 2>&1; then
  echo "cmake not found (checked PATH and ~/sdk/android/cmake/*/bin)" >&2
  exit 1
fi
ctest_bin="$(dirname "$(command -v "$cmake_bin")")/ctest"
if [ ! -x "$ctest_bin" ]; then
  echo "ctest not found alongside $cmake_bin" >&2
  exit 1
fi

echo "== Configuring host build in $build_dir =="
"$cmake_bin" -S "$root/native" -B "$build_dir" -DCMAKE_BUILD_TYPE=Debug
echo "== Building sdrcore + CMake-wired tests =="
"$cmake_bin" --build "$build_dir" -j"$(nproc)"

echo "== Running CMake-wired ctest suite =="
"$ctest_bin" --test-dir "$build_dir" --output-on-failure

lib="$build_dir/libsdrcore.so"
if [ ! -f "$lib" ]; then
  echo "libsdrcore.so not found at $lib after build" >&2
  exit 1
fi

echo "== Building standalone fd/lifecycle and checksum-oracle tests =="
g++ -O2 -std=c++17 -I"$root/native/include" \
    -o "$build_dir/fd_lifecycle_test" "$here/fd_lifecycle_test.cpp" \
    -L"$build_dir" -lsdrcore -lpthread -Wl,-rpath,"$build_dir"
gcc -O2 -std=c11 -I"$root/native/include" \
    -o "$build_dir/checksum_oracle_test" "$here/checksum_oracle_test.c" \
    -L"$build_dir" -lsdrcore -Wl,-rpath,"$build_dir"
# Exercise the pinned rtl-sdr source archive, replacing only libusb_init.
gcc -O1 -g -std=c11 \
    -I"$root/native/third_party/rtl-sdr/include" \
    -I"$root/native/third_party/libusb/libusb" \
    "$here/rtl_libusb_init_failure_test.c" \
    "$build_dir/third_party/libsdrcore_rtlsdr.a" \
    "$build_dir/third_party/libsdrcore_libusb.a" \
    -Wl,--wrap=libusb_init -lm -lpthread \
    -o "$build_dir/rtl_libusb_init_failure_test"

echo "== Running standalone fd/lifecycle test =="
"$build_dir/fd_lifecycle_test"

echo "== Running standalone checksum oracle test =="
"$build_dir/checksum_oracle_test"

echo "== Running pinned RTL-SDR libusb initialization failure regression =="
"$build_dir/rtl_libusb_init_failure_test"

echo "== Comparing vendored Blog V4 C control trace with the original C oracle =="
rtl="$root/native/third_party/rtl-sdr"
oracle="$root/tool/oracle/rtlsdr"
gcc -std=gnu99 -O0 -g -w \
    -I"$oracle/include" -I"$oracle" -I"$rtl/include" \
    "$rtl/src/librtlsdr.c" "$rtl/src/tuner_e4k.c" \
    "$rtl/src/tuner_fc0012.c" "$rtl/src/tuner_fc0013.c" \
    "$rtl/src/tuner_fc2580.c" "$rtl/src/tuner_r82xx.c" \
    "$oracle/fake_libusb.c" "$oracle/oracle_main.c" -lm \
    -o "$build_dir/vendor_rtlsdr_oracle"
"$build_dir/vendor_rtlsdr_oracle" "$oracle/scenarios/blog_v4.txt" \
    "$build_dir/blog_v4-vendor.trace"
cmp "$oracle/golden/blog_v4.trace" "$build_dir/blog_v4-vendor.trace"
echo "[ok] pinned Blog V4 trace matches original C golden"

echo "== Dart FFI tests against the same host libsdrcore.so =="
echo "   (run manually: SDRCORE_HOST_LIBRARY=$lib flutter test test/native)"
echo
echo "All host native tests passed. Library: $lib"
