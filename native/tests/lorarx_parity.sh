#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# LoRa PHY fixture + parity test for the embedded lorarx (sdrcore_lorarx).
#
# For every case, the upstream generator loratx (vendored, unmodified) writes
# a deterministic 1 MS/s complex-f32 IQ file; then
#   1. the unmodified upstream lorarx (oracle, verbatim upstream-os layer) and
#   2. sdrcore_lorarx_replay (the embedded build, same argv, --restart)
# decode it with the exact OpenWebRX+ Meshtastic command. Their JSON output
# must be byte-identical, and the decoded frames must match what was sent
# (payload, sf, cr, bw, sync word, CRC state).
#
# Usage: lorarx_parity.sh <oracle-lorarx> <loratx> <replay> <vectors.json> <workdir>
set -euo pipefail

ORACLE=$1
LORATX=$2
REPLAY=$3
VECTORS=$4
WORK=$5
mkdir -p "$WORK"
cd "$WORK"

# Real Meshtastic frames from the packet-layer vectors: 34, 96 and 48 bytes.
grep -o '"hex": "[0-9a-f]*"' "$VECTORS" | head -3 | sed 's/"hex": "//; s/"$//' > three.hex
head -1 three.hex > one.hex
[ "$(wc -l < three.hex)" -eq 3 ] || { echo "FAIL: vectors missing"; exit 1; }

b64() { printf '%b' "$(printf '%s' "$1" | sed 's/../\\x&/g')" | base64 | tr -d '\n'; }

OWRX=(-i /dev/stdin -r 1000000 -f f32 -v -N -Q -H 5 -W 50)
SFS=(-s 7 -s 8 -s 9 -s 10 -s 11)
BWHZ=([6]=62500.0 [7]=125000.0 [8]=250000.0 [9]=500000.0)
fail=0
cases=0

# check <name> <bw> <hexfile> <oracle-jsonl> <expected-crc> <sf> <cr> <net>
# Every sent frame must be decoded with the given CRC state and PHY values.
check_frames() {
  local name=$1 bw=$2 hexfile=$3 out=$4 crc=$5 sf=$6 cr=$7 net=$8
  local h p
  while read -r h; do
    p=$(b64 "$h")
    if ! grep -F "\"payload\":\"$p\"" "$out" | grep -q \
        "\"net\":$net,\"crc\":$crc,\"invers\":0,\"bw\":${BWHZ[$bw]},\"sf\":$sf,\"cr\":$cr,"; then
      echo "FAIL[$name]: frame ${h:0:16}... not decoded as net=$net crc=$crc sf=$sf cr=$cr"
      fail=1
    fi
  done < "$hexfile"
}

# run_case <name> <bw> <hexfile> <loratx args...>
run_case() {
  local name=$1 bw=$2 hexfile=$3
  shift 3
  cases=$((cases + 1))
  # Upstream -j appends to an existing file: always start from scratch.
  rm -f "$name.f32" "$name.oracle.jsonl" "$name.embed.jsonl"
  "$LORATX" -i "$hexfile" -H -f f32 -r 1000000 -b "$bw" -o "$name.f32" -z 10 "$@" \
      > /dev/null 2>&1
  "$ORACLE" "${OWRX[@]}" -i "$name.f32" -b "$bw" "${SFS[@]}" -j "$name.oracle.jsonl" \
      > /dev/null
  touch "$name.oracle.jsonl"
  "$REPLAY" --restart "$name.f32" "${OWRX[@]}" -b "$bw" "${SFS[@]}" -j /dev/stdout \
      > "$name.embed.jsonl"
  rm -f "$name.f32"
  if ! cmp -s "$name.oracle.jsonl" "$name.embed.jsonl"; then
    echo "FAIL[$name]: embedded output differs from upstream oracle"
    diff "$name.oracle.jsonl" "$name.embed.jsonl" | head -6
    fail=1
  fi
  if [ ! -s "$name.oracle.jsonl" ]; then
    echo "FAIL[$name]: no frame decoded"
    fail=1
  fi
  echo "case $name: $(wc -l < "$name.oracle.jsonl") JSON line(s), parity checked"
}

# Every Meshtastic preset bandwidth (62.5/125/250/500 kHz) at the SF/CR of
# its presets (lib/ui/decoders/meshtastic_tuning.dart), explicit header + CRC,
# sync word 0x2B. Long SF11 frames use one short packet to bound file size.
while read -r bw sf cr hexfile; do
  name="bw${bw}_sf${sf}_cr${cr}"
  run_case "$name" "$bw" "$hexfile" -s "$sf" -c "$cr" -N 2B -C
  check_frames "$name" "$bw" "$hexfile" "$name.oracle.jsonl" 1 "$sf" "$cr" 43
done <<'EOF'
6 7 6 three.hex
6 8 6 three.hex
7 9 5 three.hex
7 10 5 three.hex
7 11 8 one.hex
8 7 5 three.hex
8 8 5 three.hex
8 9 5 three.hex
8 10 5 three.hex
8 11 5 one.hex
9 7 5 three.hex
9 9 5 three.hex
9 11 8 one.hex
EOF

# Coding rates 4/5..4/8 are taken from the explicit header (no -c given to rx).
for cr in 6 7; do
  run_case "cr$cr" 8 three.hex -s 9 -c "$cr" -N 2B -C
  check_frames "cr$cr" 8 three.hex "cr$cr.oracle.jsonl" 1 9 "$cr" 43
done

# Explicit header without payload CRC: lorarx reports crc -1.
run_case nocrc 8 one.hex -s 9 -c 5 -N 2B
check_frames nocrc 8 one.hex nocrc.oracle.jsonl -1 9 5 43

# Other sync word (0x12, LoRa-APRS/private): reported as net 18, not 43.
run_case sync12 8 one.hex -s 9 -c 5 -N 12 -C
check_frames sync12 8 one.hex sync12.oracle.jsonl 1 9 5 18

# Damaged frame: three zeroed data chirps defeat FEC; a crc 0 line must appear.
run_case badcrc 8 one.hex -s 9 -c 5 -N 2B -C -T 20 0 -T 21 0 -T 22 0
grep -q '"crc":0,' badcrc.oracle.jsonl || { echo "FAIL[badcrc]: no crc 0 line"; fail=1; }

# Additive white noise and a +20 kHz carrier offset (AFC) still decode.
run_case noise 8 three.hex -s 9 -c 5 -N 2B -C -w 2 -R 1
check_frames noise 8 three.hex noise.oracle.jsonl 1 9 5 43
run_case offset 8 one.hex -s 10 -c 5 -N 2B -C -S 20000
check_frames offset 8 one.hex offset.oracle.jsonl 1 10 5 43

if [ "$fail" -ne 0 ]; then
  echo "lorarx parity: FAILED"
  exit 1
fi
echo "lorarx parity: $cases cases, embedded == upstream oracle byte for byte"
