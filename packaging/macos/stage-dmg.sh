#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Stage the signed app, Applications shortcut and first-launch instructions.
set -euo pipefail
app="${1:?usage: $0 <AirSDR.app> <staging-directory>}"
stage="${2:?usage: $0 <AirSDR.app> <staging-directory>}"
here="$(cd "$(dirname "$0")" && pwd)"
test -d "$app/Contents"
mkdir -p "$stage"
ditto "$app" "$stage/AirSDR.app"
ln -s /Applications "$stage/Applications"
cp "$here/README.txt" "$stage/README.txt"
