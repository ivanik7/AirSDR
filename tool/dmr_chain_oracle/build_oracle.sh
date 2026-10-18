#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds the offline DMR receive-chain oracle (host only; nothing here is
# linked into or launched by the app):
#   owrx_chain     OpenWebRX+ f1e0d1ac DMR chain from PRISTINE upstream:
#                  csdr-plus f26b520 libcsdr++ (selector + FmDemod/DcBlock),
#                  digiham-plus beec7822 WideRrc/Gfsk/DmrDecoder + ICU charset
#   native_chain   this app's sdrcore::dmr::Channel + Framing (native/ CMake)
#   dmr_tx_encode  synthetic BS-sourced DMR transmission, encoded with the
#                  pristine MMDVMHost a819ae64 DMR classes (GPL-2.0-or-later)
#   dmr_modulate   test 4FSK modulator (native/tests/dmr_fsk_modulator.hpp)
#
# Usage: CSDR_BUILD=<sstv oracle work>/csdr-build \
#        tool/dmr_chain_oracle/build_oracle.sh WORKDIR
# CSDR_BUILD comes from tool/sstv_oracle/build_oracle.sh (same csdr pin).
set -euo pipefail
work=$(realpath -m "${1:?usage: build_oracle.sh WORKDIR}")
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
ref=${OWRX_REF:-$HOME/prj/ref/openwebrx}
csdr_src=${CSDR_PLUS_SRC:-$ref/csdr-plus}
digiham=${DIGIHAM_PLUS_SRC:-$ref/digiham-plus}
mmdvm=${MMDVMHOST_SRC:-$ref/ext/MMDVMHost}
csdr_build=${CSDR_BUILD:?set CSDR_BUILD to the SSTV oracle csdr-build}
mkdir -p "$work"

check_pin() {  # dir pin
  [ "$(git -C "$1" rev-parse HEAD)" = "$2" ] || { echo "$1 is not at $2" >&2; exit 1; }
  [ -z "$(git -C "$1" status --porcelain)" ] || { echo "$1 checkout is modified" >&2; exit 1; }
}
check_pin "$csdr_src" f26b52071c4a127fc8193d058c249cac57585de4
check_pin "$digiham" beec78229edb8e049f8b82729498def952b79cc1
check_pin "$mmdvm" a819ae64edd5de5a7468b24e47d673a53f94fc9f

# digiham includes <csdr/...> (installed layout); map it to the source tree.
mkdir -p "$work/inc"
ln -sfn "$csdr_src/include" "$work/inc/csdr"

# Pristine OpenWebRX+ chain: every digiham DMR/FEC source + its own lib/
# (meta, decoder, phase, charset with ICU, coordinate, hamming_distance).
dmr=$digiham/src/dmr_decoder
srcs=()
for f in dmr_decoder dmr_phase dmr_meta emb cach tact embedded lc talkeralias slottype gps; do
  srcs+=("$dmr/$f.cpp")
done
for f in quadratic_residue hamming_7_4 hamming_16_11 golay_20_8 bptc_196_96 hamming_13_9 hamming_15_11; do
  srcs+=("$dmr/$f.c")
done
for f in decoder.cpp meta.cpp phase.cpp charset.cpp coordinate.cpp hamming_distance.c; do
  srcs+=("$digiham/src/lib/$f")
done
srcs+=("$digiham/src/rrc_filter/rrc_filter.cpp" "$digiham/src/gfsk_demodulator/gfsk_demodulator.cpp")
mkdir -p "$work/obj"
objs=()
for s in "${srcs[@]}"; do
  o="$work/obj/$(basename "$s").o"
  case "$s" in
    *.c) gcc -O2 -c "$s" -I"$digiham/src/lib" -o "$o" ;;
    *) g++ -std=c++17 -O2 -c "$s" -I"$digiham/include" -I"$digiham/src/lib" -I"$dmr" \
         -I"$work/inc" -o "$o" ;;
  esac
  objs+=("$o")
done
fftw=${FFTW_PREFIX:-$csdr_build/../prefix}
g++ -std=c++17 -O2 -DDMR_PRISTINE "$here/chain.cpp" "${objs[@]}" \
  -I"$digiham/include" -I"$digiham/src/lib" -I"$dmr" -I"$work/inc" -I"$fftw/include" \
  "$csdr_build/src/lib/libcsdr++.so" -Wl,-rpath,"$csdr_build/src/lib" \
  -L"$fftw/lib" -lfftw3f -Wl,-rpath,"$fftw/lib" -licuuc \
  -o "$work/owrx_chain"

# Pristine MMDVMHost DMR encoder classes. Log.h needs nlohmann/json only for
# WriteJSON(), which none of these classes call: stub it and Log().
mkdir -p "$work/mmdvm_shim/nlohmann"
printf '%s\n' '#pragma once' '#include <ctime>' 'namespace nlohmann { struct json {}; }' > "$work/mmdvm_shim/nlohmann/json.hpp"
printf '%s\n' '#include <cstdio>' 'void Log(unsigned int, const char*, ...) {}' > "$work/mmdvm_shim/log_stub.cpp"
msrc=()
for f in BPTC19696 CRC DMREMB DMREmbeddedData DMRFullLC DMRLC DMRSlotType Golay2087 Hamming QR1676 RS129 Sync Utils; do
  msrc+=("$mmdvm/$f.cpp")
done
g++ -std=c++17 -O2 -I"$work/mmdvm_shim" -I"$mmdvm" -I"$root/native/tests" \
  -I"$root/native/third_party/openwebrx-dmr" \
  "$here/encode.cpp" "${msrc[@]}" "$work/mmdvm_shim/log_stub.cpp" -o "$work/dmr_tx_encode"

g++ -std=c++17 -O2 -I"$root/native/tests" "$here/modulate.cpp" -o "$work/dmr_modulate"

# Native side: the app's static DMR libraries from native/.
cmake -S "$here" -B "$work/native" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$work/native" -j3 --target native_chain dmr_voice_replay >/dev/null
ln -sf "$work/native/native_chain" "$work/native_chain"
ln -sf "$work/native/dmr_voice_replay" "$work/dmr_voice_replay"
echo "oracle: $work/{owrx_chain,native_chain,dmr_tx_encode,dmr_modulate,dmr_voice_replay}"
