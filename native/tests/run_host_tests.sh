#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Reproducible host-side test runner for the ABI 2 native core
# (native/include/sdrcore.h). Builds libsdrcore.so for the host with CMake,
# runs the CMake-wired ctest suite (sdrcore_abi/sdrcore_stream — owned by
# native/CMakeLists.txt, not modified here), then builds and runs the extra
# standalone fd/lifecycle and checksum-oracle test programs in this
# directory that are intentionally NOT added to native/CMakeLists.txt
# (that file's test target list is owned by the native implementation
# lead; see docs/native-n1-tests.md).
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

echo "== Configuring host build in $build_dir =="
"$cmake_bin" -S "$root/native" -B "$build_dir" -DCMAKE_BUILD_TYPE=Debug
echo "== Building sdrcore + CMake-wired tests =="
"$cmake_bin" --build "$build_dir" -j"$(nproc)"

echo "== Running CMake-wired ctest suite =="
(cd "$build_dir" && ctest --output-on-failure)

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

echo "== Running standalone fd/lifecycle test =="
"$build_dir/fd_lifecycle_test"

echo "== Running standalone checksum oracle test =="
"$build_dir/checksum_oracle_test"

echo "== Dart FFI tests against the same host libsdrcore.so =="
echo "   (run manually: SDRCORE_HOST_LIBRARY=$lib flutter test test/native)"
echo
echo "All host native tests passed. Library: $lib"
