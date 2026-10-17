#!/bin/sh
# Build the unmodified vendored lorarx (upstream OS layer) as a reference
# oracle and run the exact OpenWebRX+ Meshtastic command on an IQ file.
# Usage: tool/lorarx_oracle.sh <outdir> <iq.f32> [bw_index]
set -eu
SRC=$(cd "$(dirname "$0")/../native/third_party/lorarx" && pwd)
OUT=$1
IQ=$2
BW=${3:-8}
mkdir -p "$OUT"
for f in lorarx loraprotocols aprsstr; do
  gcc -I"$SRC" -I"$SRC/upstream-os" -O3 -w -c "$SRC/$f.c" -o "$OUT/$f.o"
done
for f in osi osic udp; do
  gcc -I"$SRC" -I"$SRC/upstream-os" -O3 -w -c "$SRC/upstream-os/$f.c" -o "$OUT/$f.o"
done
gcc -o "$OUT/lorarx" "$OUT/lorarx.o" "$OUT/loraprotocols.o" "$OUT/aprsstr.o" \
  "$OUT/osi.o" "$OUT/osic.o" "$OUT/udp.o" -lm
rm -f "$OUT/out.jsonl"
"$OUT/lorarx" -i "$IQ" -r 1000000 -f f32 -v -N -Q -H 5 -W 50 -b "$BW" \
  -s 7 -s 8 -s 9 -s 10 -s 11 -j "$OUT/out.jsonl" > "$OUT/stdout.txt"
cat "$OUT/out.jsonl"
