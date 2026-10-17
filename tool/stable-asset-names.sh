#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copies CI build outputs to version-free file names, so README download
# links (releases/latest/download/<name>, releases/download/nightly/<name>)
# never change. See docs/releasing.md.
#
# Usage: tool/stable-asset-names.sh <in_dir> <out_dir>
#
# Every stable name must match exactly one input file; a platform whose
# build job failed is skipped with a warning. Exits non-zero if nothing
# matched at all.
set -euo pipefail

in="${1:?usage: $0 <in_dir> <out_dir>}"
out="${2:?usage: $0 <in_dir> <out_dir>}"
mkdir -p "$out"

# stable name | glob of the versioned file
map='
AirSDR-android-arm64-v8a.apk|AirSDR-*-android-arm64-v8a.apk
AirSDR-android-armeabi-v7a.apk|AirSDR-*-android-armeabi-v7a.apk
AirSDR-android-x86_64.apk|AirSDR-*-android-x86_64.apk
AirSDR-linux-amd64.deb|airsdr_*_amd64.deb
AirSDR-linux-x86_64.rpm|airsdr-*.x86_64.rpm
AirSDR-linux-x86_64.pkg.tar.zst|airsdr-*-x86_64.pkg.tar.zst
AirSDR-linux-x86_64.tar.gz|airsdr-*-linux-x86_64.tar.gz
AirSDR-macos.dmg|AirSDR-*-macos.dmg
AirSDR-windows-x86_64.zip|AirSDR-*-windows-x86_64.zip
'

copied=0
while IFS='|' read -r name glob; do
  [ -n "$name" ] || continue
  shopt -s nullglob
  # shellcheck disable=SC2206 # the glob is meant to expand
  files=("$in"/$glob)
  shopt -u nullglob
  case "${#files[@]}" in
    0) echo "::warning::no file for $name ($glob)" ;;
    1) cp "${files[0]}" "$out/$name"; echo "$name <- $(basename "${files[0]}")"
       copied=$((copied + 1)) ;;
    *) echo "more than one file matches $glob: ${files[*]}" >&2; exit 1 ;;
  esac
done <<< "$map"

[ "$copied" -gt 0 ] || { echo "no release files found in $in" >&2; exit 1; }
