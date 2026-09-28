#!/usr/bin/env bash
# Build the libhackrf host oracle (real hackrf.c + fake libusb) and regenerate
# the golden traces used by test/drivers/hackrf/hackrf_oracle_test.dart.
#
#   tool/oracle/hackrf/build.sh            # build + regenerate golden/*.trace
#   HACKRF_SRC=/path/to/libhackrf/src tool/oracle/hackrf/build.sh
#
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HACKRF_SRC="${HACKRF_SRC:-$HOME/prj/ref/hackrf/host/libhackrf/src}"
OUT="${OUT:-${TMPDIR:-/tmp}/hackrf_oracle}"
mkdir -p "$OUT" "$HERE/golden"

if [ ! -f "$HACKRF_SRC/hackrf.c" ]; then
	echo "hackrf.c not found in $HACKRF_SRC" >&2
	exit 1
fi

REV="$(git -C "$HACKRF_SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)"

gcc -std=gnu11 -O2 -Wall -Wno-unused-function -Wno-unused-variable \
	-DLIBRARY_VERSION='"oracle"' -DLIBRARY_RELEASE='"oracle"' \
	-I"$HERE/fake_libusb" -I"$HACKRF_SRC" \
	"$HACKRF_SRC/hackrf.c" "$HERE/fake_libusb/fake_libusb.c" "$HERE/hackrf_oracle.c" \
	-lpthread -o "$OUT/hackrf_oracle"

for s in main oldfw errors openfail rates; do
	"$OUT/hackrf_oracle" "$s" "$HERE/golden/$s.trace"
	echo "golden/$s.trace: $(wc -l < "$HERE/golden/$s.trace") lines"
done
echo "$REV" > "$HERE/golden/HACKRF_REV"
echo "libhackrf revision: $REV"
