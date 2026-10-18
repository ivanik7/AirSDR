#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copies CI build outputs to version-free file names, so README download
# links (releases/latest/download/<name>, releases/download/nightly/<name>)
# never change. See docs/releasing.md.
#
# Usage: [BUILD_RESULTS='android=success linux=failure ...'] \
#          tool/stable-asset-names.sh <in_dir> <out_dir>
#
# Every stable name must match at most one input file. BUILD_RESULTS holds
# the result of each platform build job (android, linux, macos, windows):
# a platform whose job succeeded must provide all of its files, otherwise
# the script fails before copying anything, so a built package is never
# silently left out of a release. A platform whose build did not succeed is
# skipped with a warning. Exits non-zero if nothing matched at all.
set -euo pipefail

in="${1:?usage: $0 <in_dir> <out_dir>}"
out="${2:?usage: $0 <in_dir> <out_dir>}"

# platform | stable name | glob of the versioned file
map='
android|AirSDR-android-arm64-v8a.apk|AirSDR-*-android-arm64-v8a.apk
android|AirSDR-android-armeabi-v7a.apk|AirSDR-*-android-armeabi-v7a.apk
android|AirSDR-android-x86_64.apk|AirSDR-*-android-x86_64.apk
linux|AirSDR-linux-amd64.deb|airsdr_*_amd64.deb
linux|AirSDR-linux-x86_64.rpm|airsdr-*.x86_64.rpm
linux|AirSDR-linux-x86_64.pkg.tar.zst|airsdr-*-x86_64.pkg.tar.zst
linux|AirSDR-linux-x86_64.tar.gz|airsdr-*-linux-x86_64.tar.gz
macos|AirSDR-macos.dmg|AirSDR-*-macos.dmg
windows|AirSDR-windows-x86_64.zip|AirSDR-*-windows-x86_64.zip
'

results=" ${BUILD_RESULTS:-} "
pairs=()
missing=0
while IFS='|' read -r platform name glob; do
  [ -n "$name" ] || continue
  shopt -s nullglob
  # shellcheck disable=SC2206 # the glob is meant to expand
  files=("$in"/$glob)
  shopt -u nullglob
  case "${#files[@]}" in
    0) if [[ "$results" == *" $platform=success "* ]]; then
         echo "::error::$platform build succeeded but $in has no file for $name ($glob)" >&2
         missing=$((missing + 1))
       else
         echo "::warning::no file for $name ($glob)"
       fi ;;
    1) pairs+=("$name|${files[0]}") ;;
    *) echo "more than one file matches $glob: ${files[*]}" >&2; exit 1 ;;
  esac
done <<< "$map"

[ "$missing" -eq 0 ] || { echo "$missing file(s) of successful builds missing" >&2; exit 1; }
[ "${#pairs[@]}" -gt 0 ] || { echo "no release files found in $in" >&2; exit 1; }

mkdir -p "$out"
for pair in "${pairs[@]}"; do
  name="${pair%%|*}"
  src="${pair#*|}"
  cp "$src" "$out/$name"
  echo "$name <- $(basename "$src")"
done
