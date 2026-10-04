#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# N2 ABI-v3 host oracles (phone-free). See docs/native-n2-oracles.md.
#
# Usage:
#   native/tests/n2/run_n2_oracles.sh [--lib PATH] [--allow-version-2]
#                                     [--hw] [--hw-seconds N] [--rtl-baseline-seconds N]
#                                     [--perf-seconds N] [--out DIR]
#
#   --lib PATH        Test an existing libsdrcore.so instead of building this tree.
#   --allow-version-2 Probe a worker branch that exports sdr_v3_* but still
#                     reports sdr_version()==2 (abi_version stays MISSING).
#   --hw              Also run the Linux-host RTL-SDR Blog V4 acceptance soak.
#   --hw-seconds N    Soak duration (default 600 = ADR's 10 minutes).
#   --rtl-baseline-seconds N  Run `rtl_test -s 2400000` for N s first (default
#                     130) and compare native drops with its lost-bytes count.
#
# Outputs (default build/n2-oracle/): n2_oracle, libsdrcore.so (copy or
# symlink used by test/n2_oracle/native_parity_test.dart), suite.json,
# hw.json, rtl_test.log, n2_hw_wfm.wav.
#
# Exit: 0 all PASS; 1 any FAIL; 2 only MISSING hooks; 3 setup error.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
out="$root/build/n2-oracle"
lib=""
allow=()
hw=0
hw_seconds=600
rtl_seconds=130
perf_seconds=10
while [ $# -gt 0 ]; do
  case "$1" in
    --lib) lib="$2"; shift 2 ;;
    --allow-version-2) allow=(--allow-version-2); shift ;;
    --hw) hw=1; shift ;;
    --hw-seconds) hw_seconds="$2"; shift 2 ;;
    --rtl-baseline-seconds) rtl_seconds="$2"; shift 2 ;;
    --perf-seconds) perf_seconds="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 3 ;;
  esac
done
mkdir -p "$out"

if [ -z "$lib" ]; then
  cmake_bin="cmake"
  if ! command -v cmake >/dev/null 2>&1; then
    for candidate in "$HOME/sdk/android/cmake"/*/bin/cmake; do
      [ -x "$candidate" ] && cmake_bin="$candidate" && break
    done
  fi
  echo "== Building host libsdrcore.so (Release) from $root/native =="
  "$cmake_bin" -S "$root/native" -B "$out/lib-build" -DCMAKE_BUILD_TYPE=Release >/dev/null
  "$cmake_bin" --build "$out/lib-build" -j"$(nproc)" --target sdrcore
  lib="$out/lib-build/libsdrcore.so"
fi
lib="$(cd "$(dirname "$lib")" && pwd)/$(basename "$lib")"
[ -f "$lib" ] || { echo "library not found: $lib" >&2; exit 3; }
ln -sf "$lib" "$out/libsdrcore.so"

echo "== Building n2_oracle (dlopen harness; never links the library) =="
g++ -std=c++17 -O2 -Wall -Wextra -Werror -I"$root/native/include" \
    "$here/n2_oracle.cpp" -o "$out/n2_oracle" -ldl -lpthread

echo "== Exported v3 symbols in $lib =="
nm -D --defined-only "$lib" | grep -E ' sdr_(version|v3_)' || true

status=0
echo "== Synthetic/file/socket suite =="
TMPDIR="${TMPDIR:-/tmp}" "$out/n2_oracle" suite --lib "$lib" "${allow[@]}" \
    --perf-seconds "$perf_seconds" --json "$out/suite.json" || status=$?

if [ "$hw" = 1 ]; then
  lost=-1
  if command -v rtl_test >/dev/null 2>&1 && [ "$rtl_seconds" -gt 0 ]; then
    echo "== rtl_test baseline (${rtl_seconds}s, 2.4 MS/s) =="
    timeout "$rtl_seconds" rtl_test -s 2400000 >"$out/rtl_test.log" 2>&1 || true
    lost="$(grep -o 'lost at least [0-9]* bytes' "$out/rtl_test.log" \
            | awk '{s += $4} END {print s + 0}')"
    echo "rtl_test lost bytes: $lost in ${rtl_seconds}s"
  fi
  echo "== Blog V4 acceptance soak (${hw_seconds}s) =="
  hw_args=(hw --lib "$lib" "${allow[@]}" --seconds "$hw_seconds"
           --wav-dir "$out" --json "$out/hw.json")
  if [ "$lost" != "-1" ]; then
    hw_args+=(--rtl-lost-bytes "$lost" --rtl-seconds "$rtl_seconds")
  fi
  hw_status=0
  "$out/n2_oracle" "${hw_args[@]}" || hw_status=$?
  # Worst status wins: FAIL(1) over MISSING(2) over PASS(0).
  if [ "$hw_status" = 1 ] || [ "$status" = 0 ]; then status=$hw_status; fi
fi

echo
echo "Reports: $out/suite.json $([ "$hw" = 1 ] && echo "$out/hw.json")"
echo "Dart parity: N2_ORACLE_ARGS='${allow[*]}' flutter test test/n2_oracle"
exit "$status"
