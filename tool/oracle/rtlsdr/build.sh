#!/usr/bin/env bash
# Build the librtlsdr host oracle (real osmocom librtlsdr + fake libusb) and
# regenerate the golden traces used by test/drivers/rtlsdr/oracle_trace_test.dart.
#
# usage: tool/oracle/rtlsdr/build.sh [path-to-rtl-sdr-source]   (default ~/prj/ref/rtl-sdr)
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HOME/prj/ref/rtl-sdr}"
OUT="${ORACLE_BUILD_DIR:-${TMPDIR:-/tmp}/rtlsdr_oracle_build}"
mkdir -p "$OUT"

echo "librtlsdr source: $SRC ($(git -C "$SRC" describe --always --tags 2>/dev/null || echo unknown))"

gcc -std=gnu99 -O0 -g -w \
  -I"$HERE/include" -I"$HERE" -I"$SRC/include" \
  "$SRC/src/librtlsdr.c" \
  "$SRC/src/tuner_e4k.c" "$SRC/src/tuner_fc0012.c" "$SRC/src/tuner_fc0013.c" \
  "$SRC/src/tuner_fc2580.c" "$SRC/src/tuner_r82xx.c" \
  "$HERE/fake_libusb.c" "$HERE/oracle_main.c" \
  -lm -o "$OUT/rtlsdr_oracle"

mkdir -p "$HERE/golden"
for s in "$HERE"/scenarios/*.txt; do
  name="$(basename "$s" .txt)"
  "$OUT/rtlsdr_oracle" "$s" "$HERE/golden/$name.trace" 2>/dev/null
  echo "golden/$name.trace: $(wc -l < "$HERE/golden/$name.trace") lines"
done
