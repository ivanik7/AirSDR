#!/usr/bin/env bash
# Builds the SDR++ DSP golden-reference generator against the real SDR++ headers and a scalar
# VOLK stub, then regenerates test/sdrpp/dsp/golden/.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
sdrpp="${SDRPP:-$HOME/prj/sdrpp}"
out="$root/test/sdrpp/dsp/golden"
mkdir -p "$out" "$root/build/oracle"
g++ -O2 -std=c++17 -I"$here/volk_stub" -I"$sdrpp/core/src" \
    -o "$root/build/oracle/dsp_oracle" "$here/dsp_oracle.cpp" -lpthread
"$root/build/oracle/dsp_oracle" "$out"
