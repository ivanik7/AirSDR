#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds the offline OpenWebRX+ DMR VOICE oracle from PRISTINE upstream
# sources (host only; nothing here is linked into or launched by the app):
#   - mbelib 9a04ed5 (1.3.x, ISC)              -> libmbe (static, -O3 as softmbe)
#   - codecserver-softmbe 66397fcf             -> softmbesession.cpp + blockingqueue.cpp
#       compiled against ./shim (session.hpp/proto stand-ins: no protobuf);
#       owrx_softmbe_harness = what codecserver hands to MbeSynthesizer
#   - digiham-plus beec7822 DigitalVoiceFilter -> owrx_dvfilter_harness
#   - csdr-plus f26b520 `csdr agc`             -> reused from the SSTV oracle
#       build (tool/sstv_oracle/build_oracle.sh), CSDR_BUILD points at it
# OpenWebRX+ chain (csdr/chain/digiham.py DigihamChain):
#   MbeSynthesizer -> DigitalVoiceFilter -> Agc(SHORT, maxGain 30, initialGain 3)
#
# Usage: CSDR_BUILD=<sstv oracle csdr-build> tool/dmr_voice_oracle/build_oracle.sh WORKDIR
set -euo pipefail
work=$(realpath -m "${1:?usage: build_oracle.sh WORKDIR}")
here=$(cd "$(dirname "$0")" && pwd)
ext=${OWRX_EXT:-$HOME/prj/ref/openwebrx/ext}
digiham=${DIGIHAM_PLUS_SRC:-$HOME/prj/ref/openwebrx/digiham-plus}
mkdir -p "$work"

check_pin() {  # dir pin
  [ "$(git -C "$1" rev-parse HEAD)" = "$2" ] || { echo "$1 is not at $2" >&2; exit 1; }
  [ -z "$(git -C "$1" status --porcelain)" ] || { echo "$1 checkout is modified" >&2; exit 1; }
}
check_pin "$ext/mbelib" 9a04ed5c78176a9965f3d43f7aa1b1f5330e771f
check_pin "$ext/codecserver-softmbe" 66397fcff051a91371673dcdc82b50bd05ac9c53
check_pin "$digiham" beec78229edb8e049f8b82729498def952b79cc1

mkdir -p "$work/mbe"
for f in mbelib ecc ambe3600x2450 ambe3600x2400 imbe7100x4400 imbe7200x4400; do
  gcc -O3 -c "$ext/mbelib/$f.c" -I"$ext/mbelib" -o "$work/mbe/$f.o"
done
ar rcs "$work/libmbe.a" "$work"/mbe/*.o

# softmbesession.cpp includes "softmbesession.hpp", which includes
# "session.hpp", "softmbedevice.hpp", "proto/*.pb.h". Quoted includes resolve
# next to the including file first, so the pristine session files are copied
# (byte-identical, verified) into a directory WITHOUT softmbedevice.hpp and
# the shim supplies the codecserver/protobuf stand-ins.
mkdir -p "$work/softmbe"
for f in softmbesession.cpp softmbesession.hpp blockingqueue.cpp blockingqueue.hpp \
         interleaver_permutations_const.hpp; do
  cp "$ext/codecserver-softmbe/src/$f" "$work/softmbe/$f"
  cmp "$ext/codecserver-softmbe/src/$f" "$work/softmbe/$f"
done
g++ -std=c++17 -O3 -I"$here/shim" -I"$work/softmbe" -I"$ext/mbelib" \
  "$here/owrx_softmbe_harness.cpp" "$work/softmbe/softmbesession.cpp" \
  "$work/softmbe/blockingqueue.cpp" "$work/libmbe.a" -lm -lpthread \
  -o "$work/owrx_softmbe_harness"

# DigitalVoiceFilter needs csdr's Module base (pristine csdr-plus headers).
csdr_src=${CSDR_PLUS_SRC:-$HOME/prj/ref/openwebrx/csdr-plus}
# digiham includes <csdr/module.hpp> (installed layout); map it to the source tree.
mkdir -p "$work/inc"
ln -sfn "$csdr_src/include" "$work/inc/csdr"
g++ -std=c++17 -O3 -I"$digiham/include" -I"$work/inc" -I"$csdr_src/include" \
  "$here/owrx_dvfilter_harness.cpp" "$digiham/src/digitalvoice_filter/digitalvoice_filter.cpp" \
  "${CSDR_BUILD:?set CSDR_BUILD}/src/lib/libcsdr++.so" -Wl,-rpath,"$CSDR_BUILD/src/lib" \
  -o "$work/owrx_dvfilter_harness"
ln -sf "$CSDR_BUILD/src/apps/csdr/csdr" "$work/csdr"
echo "oracle: $work/{owrx_softmbe_harness,owrx_dvfilter_harness,csdr}"
