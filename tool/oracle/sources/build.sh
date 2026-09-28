#!/usr/bin/env bash
# Golden traces for the SDR++ source module ports (rtl_sdr_source, hackrf_source).
#
#  * RTL-SDR: the librtlsdr scenario interpreter of tool/oracle/rtlsdr
#    (real osmocom librtlsdr + fake libusb) runs rtl_scenarios/*.txt, which
#    spell out the librtlsdr calls made by rtl_sdr_source/src/main.cpp.
#  * HackRF: hackrf_source_oracle.c replays hackrf_source/src/main.cpp
#    against the real hackrf.c + tool/oracle/hackrf/fake_libusb.
#
# usage: tool/oracle/sources/build.sh
#   RTLSDR_SRC (default ~/prj/ref/rtl-sdr), HACKRF_SRC (default
#   ~/prj/ref/hackrf/host/libhackrf/src)
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ORACLE="$HERE/.."
RTLSDR_SRC="${RTLSDR_SRC:-$HOME/prj/ref/rtl-sdr}"
HACKRF_SRC="${HACKRF_SRC:-$HOME/prj/ref/hackrf/host/libhackrf/src}"
OUT="${ORACLE_BUILD_DIR:-${TMPDIR:-/tmp}/sources_oracle_build}"
mkdir -p "$OUT" "$HERE/golden"

R="$ORACLE/rtlsdr"
gcc -std=gnu99 -O0 -g -w \
  -I"$R/include" -I"$R" -I"$RTLSDR_SRC/include" \
  "$RTLSDR_SRC/src/librtlsdr.c" \
  "$RTLSDR_SRC/src/tuner_e4k.c" "$RTLSDR_SRC/src/tuner_fc0012.c" "$RTLSDR_SRC/src/tuner_fc0013.c" \
  "$RTLSDR_SRC/src/tuner_fc2580.c" "$RTLSDR_SRC/src/tuner_r82xx.c" \
  "$R/fake_libusb.c" "$R/oracle_main.c" \
  -lm -o "$OUT/rtlsdr_oracle"

for s in "$HERE"/rtl_scenarios/*.txt; do
  name="$(basename "$s" .txt)"
  "$OUT/rtlsdr_oracle" "$s" "$HERE/golden/$name.trace" 2>/dev/null
  echo "golden/$name.trace: $(wc -l < "$HERE/golden/$name.trace") lines"
done

H="$ORACLE/hackrf/fake_libusb"
gcc -std=gnu11 -O2 -Wall -Wno-unused-function -Wno-unused-variable \
  -DLIBRARY_VERSION='"oracle"' -DLIBRARY_RELEASE='"oracle"' \
  -I"$H" -I"$HACKRF_SRC" \
  "$HACKRF_SRC/hackrf.c" "$H/fake_libusb.c" "$HERE/hackrf_source_oracle.c" \
  -lpthread -o "$OUT/hackrf_source_oracle"

for s in default configured; do
  "$OUT/hackrf_source_oracle" "$s" "$HERE/golden/hackrf_source_$s.trace"
  echo "golden/hackrf_source_$s.trace: $(wc -l < "$HERE/golden/hackrf_source_$s.trace") lines"
done
