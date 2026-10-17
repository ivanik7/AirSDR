#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare native DMR voice output with the pristine OpenWebRX+ oracle.

Usage: compare.py ORACLE_WORK REPLAY_BIN OUT_DIR [N_FRAMES]

For each corpus kind (clean/errors/special/random) and two rand() seeds:
  native  dmr_voice_replay corpus -> frames.bin
  oracle  owrx_softmbe_harness SEED | owrx_dvfilter_harness | csdr agc -f s16 -m 30 -i 3
  native  dmr_voice_replay synth SEED / chain SEED
and reports exact-match counts and max |diff| at two taps: the 8 kHz vocoder
output (codecserver's reply) and the post-AGC 8 kHz stream (OpenWebRX+'s
fixed-audio-rate output). Writes OUT_DIR/report.json. Exit 1 on mismatch.
"""
import json
import os
import struct
import subprocess
import sys


def run(cmd, data=None):
    return subprocess.run(cmd, input=data, stdout=subprocess.PIPE, check=True).stdout


def s16(buf):
    return struct.unpack(f"<{len(buf) // 2}h", buf)


def diff(a, b):
    n = min(len(a), len(b))
    exact = sum(1 for i in range(n) if a[i] == b[i])
    maxd = max((abs(a[i] - b[i]) for i in range(n)), default=0)
    return {"len_native": len(a), "len_oracle": len(b), "exact": exact, "max_abs_diff": maxd}


def main():
    work, replay, out = sys.argv[1], sys.argv[2], sys.argv[3]
    nframes = sys.argv[4] if len(sys.argv) > 4 else "1500"
    os.makedirs(out, exist_ok=True)
    softmbe = os.path.join(work, "owrx_softmbe_harness")
    dvfilter = os.path.join(work, "owrx_dvfilter_harness")
    csdr = os.path.join(work, "csdr")
    report, ok = {}, True
    for kind in ("clean", "errors", "special", "random"):
        frames = run([replay, "corpus", kind, nframes, "7"])
        for seed in ("1", "12345"):
            o_synth = run([softmbe, seed], frames)
            o_filt = run([dvfilter], o_synth)
            o_agc = run([csdr, "agc", "-f", "s16", "-m", "30", "-i", "3"], o_filt)
            n_synth = run([replay, "synth", seed], frames)
            n_chain = run([replay, "chain", seed], frames)
            r = {
                "frames": len(frames) // 9,
                "vocoder_8k": diff(s16(n_synth), s16(o_synth)),
                "post_agc_8k": diff(s16(n_chain), s16(o_agc)),
            }
            report[f"{kind}/seed{seed}"] = r
            for tap in ("vocoder_8k", "post_agc_8k"):
                d = r[tap]
                good = d["len_native"] == d["len_oracle"] and d["exact"] == d["len_native"]
                ok &= good
                print(f"{kind:8s} seed {seed:5s} {tap:12s} native {d['len_native']:7d} "
                      f"oracle {d['len_oracle']:7d} exact {d['exact']:7d} "
                      f"max|d| {d['max_abs_diff']:5d} {'OK' if good else 'MISMATCH'}")
    with open(os.path.join(out, "report.json"), "w") as f:
        json.dump(report, f, indent=1)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
