#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Regenerate the committed nanopb C sources in generated/ from the vendored
# Meshtastic .proto/.options files. Host-only; the app build never runs this.
#
# Requirements: git, uv (fetches protobuf<7 + grpcio-tools for protoc).
# Generator: nanopb 0.4.9.2 (commit 160d4f09e5fabb2b66aa2dea32d4f38ace2c4b3f),
# the same release as the vendored runtime in ../nanopb.
#
# Usage: native/third_party/meshtastic-protobufs/regen.sh [nanopb_checkout]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
nanopb="${1:-${TMPDIR:-/tmp}/nanopb-0.4.9.2}"
if [ ! -f "$nanopb/generator/nanopb_generator.py" ]; then
  git clone --depth=1 --branch nanopb-0.4.9.2 https://github.com/nanopb/nanopb.git "$nanopb"
fi
test "$(git -C "$nanopb" rev-parse HEAD)" = 160d4f09e5fabb2b66aa2dea32d4f38ace2c4b3f

out="$here/generated"
mkdir -p "$out"
cd "$here/proto"
# Only the files reachable from mesh.proto plus the app payload protos the
# packet layer decodes. admin/deviceonly/localonly/powermon are not needed.
uv run --no-project --python 3.12 --with 'protobuf<7' --with grpcio-tools \
  python "$nanopb/generator/nanopb_generator.py" -q -I . -D "$out" \
  -s enum_to_string:true \
  --protoc-opt=--experimental_allow_proto3_optional \
  meshtastic/mesh.proto meshtastic/channel.proto meshtastic/config.proto \
  meshtastic/device_ui.proto meshtastic/module_config.proto \
  meshtastic/atak.proto meshtastic/xmodem.proto meshtastic/telemetry.proto \
  meshtastic/portnums.proto meshtastic/paxcount.proto \
  meshtastic/storeforward.proto meshtastic/remote_hardware.proto \
  meshtastic/field_metadata.proto
echo "Regenerated nanopb sources in $out"
