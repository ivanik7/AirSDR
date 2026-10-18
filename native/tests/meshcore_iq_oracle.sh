#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Same 1 MS/s IQ through the unmodified upstream lorarx CLI with the
# OpenWebRX+ MeshcoreDemodulator argv and through the app registry backend.
# Packets: signed ADVERT, Public GRP_TXT, ACK (native/tests/meshcore_vectors.cpp).
# Cases: EU/UK narrow SF8/CR8 centred; SF7/CR5 shifted -5.5 kHz (the offset
# left by the 12.5 kHz quick-tune grid at 869.618 MHz) with white noise.
set -euo pipefail
loratx=$1
lorarx=$2
native=$3
compare=$4
vectors=$5
work=$6
mkdir -p "$work"
"$vectors" > "$work/packets.hex"
run_case() {
  local name=$1 sf=$2 cr=$3
  shift 3
  "$loratx" -i "$work/packets.hex" -H -f f32 -r 1000000 -b 6 -s "$sf" -c "$cr" -N 12 -C -z 10 \
    "$@" -o "$work/$name.f32" > /dev/null 2>&1
  "$lorarx" -i "$work/$name.f32" -r 1000000 -f f32 -v -N -Q -H 5 -W 50 -b 6 -s 7 -s 8 \
    -j "$work/$name.upstream.jsonl" > /dev/null
  "$native" "$work/$name.f32" '{"version":1,"settings":{"bandwidth":"6","channels":[]}}' \
    869612500 meshcore > "$work/$name.native.jsonl"
  "$compare" "$work/$name.upstream.jsonl" "$work/$name.native.jsonl" "$work/packets.hex" "$sf" "$cr"
}
run_case eu_narrow 8 8
run_case sf7_offset_noise 7 5 -S -5500 -w 0.3
