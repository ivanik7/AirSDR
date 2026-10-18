#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Cross-compile check for the embedded lorarx (sdrcore_lorarx sources) with
# the Android NDK clang: compiles every embed source for the given targets and
# lists the remaining undefined symbols (must be libc/libm only).
# Usage: tool/lorarx_cross_check.sh <ndk-root> <outdir> [clang-target...]
set -euo pipefail
NDK=$1
OUT=$2
shift 2
TARGETS=("$@")
[ ${#TARGETS[@]} -gt 0 ] || TARGETS=(aarch64-linux-android24 armv7a-linux-androideabi24 x86_64-linux-android24)
BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
SRC=$(cd "$(dirname "$0")/../native/third_party/lorarx" && pwd)
mkdir -p "$OUT"
for target in "${TARGETS[@]}"; do
  objs=()
  for f in lorarx.c loraprotocols.c aprsstr.c embed/lorarx_os.c; do
    obj="$OUT/$target-$(basename "$f" .c).o"
    "$BIN/clang" --target="$target" -std=gnu99 -DSDRCORE_LORARX_EMBED \
      -I"$SRC/embed" -I"$SRC" -O2 -w -ffp-contract=off -fPIC -c "$SRC/$f" -o "$obj"
    objs+=("$obj")
  done
  "$BIN/llvm-nm" -u "${objs[@]}" | awk 'NF && $NF !~ /:$/ {print $NF}' | sort -u > "$OUT/$target.undef"
  "$BIN/llvm-nm" --defined-only "${objs[@]}" | awk 'NF == 3 {print $3}' | sort -u > "$OUT/$target.def"
  undefined=$(comm -23 "$OUT/$target.undef" "$OUT/$target.def" | tr '\n' ' ')
  echo "$target: ok; external symbols: $undefined"
done
