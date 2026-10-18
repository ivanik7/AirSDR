#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# OpenWebRX+ MeshcoreDemodulator argv on exactly the same 1 MS/s IQ.
set -euo pipefail
loratx=$1
lorarx=$2
native=$3
compare=$4
work=$5
mkdir -p "$work"
printf '%s\n' '0D0001020304' > "$work/ack.hex"
"$loratx" -i "$work/ack.hex" -H -f f32 -r 1000000 -b 6 -s 8 -c 8 -N 12 -C -z 10 -o "$work/ack.f32" > /dev/null 2>&1
"$lorarx" -i "$work/ack.f32" -r 1000000 -f f32 -v -N -Q -H 5 -W 50 -b 6 -s 7 -s 8 -j "$work/upstream.jsonl" > /dev/null
"$native" "$work/ack.f32" '{"version":1,"settings":{"bandwidth":"6","channels":[]}}' 869618000 meshcore > "$work/native.jsonl"
"$compare" "$work/upstream.jsonl" "$work/native.jsonl" "$work/ack.hex"
