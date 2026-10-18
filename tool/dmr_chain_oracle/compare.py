#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare the app's native DMR receive chain with pristine OpenWebRX+.

Usage:
  compare.py CHAIN_WORK VOICE_WORK OUT_DIR [--golden DIR]

CHAIN_WORK  output of tool/dmr_chain_oracle/build_oracle.sh
            (owrx_chain, native_chain, dmr_tx_encode, dmr_modulate,
            dmr_voice_replay)
VOICE_WORK  output of tool/dmr_voice_oracle/build_oracle.sh
            (owrx_softmbe_harness, owrx_dvfilter_harness, csdr)
--golden    also write the CTest fixture (oracle outputs) to DIR; see
            native/tests/dmr_chain_fixture_test.cpp

Every case starts from the same MMDVMHost-encoded transmission (tx.dibits).
Dibit cases feed the same symbol file to both decoders; IQ cases modulate it
once (dmr_modulate) and feed the same cf32 file to both receive chains.

Measured per case (see docs/status/dmr-chain-oracle.md for the method):
  symbols   decided-symbol stream of each chain aligned to tx.dibits by the
            lag that maximises the symbol match rate (search 0..2000 dibits);
            SER = mismatches / overlap at that lag
  frames    AMBE frames: count, index-aligned identical frames, frames that
            are bit-equal to a transmitted frame
  metadata  per-slot transition lists (consecutive duplicate events of a slot
            removed; native also reports CC/duration changes), compared slot
            by slot (the interleaving of the two slots' first events depends
            on which slot acquires sync first); equality, and whether every
            truth.txt line appears in each chain
  voice     each chain's frames through its own voice chain: OpenWebRX+
            softmbe -> DigitalVoiceFilter -> csdr agc vs native VoiceOutput
            (8 kHz capture), rand() seed 1 on both. Alignment: lag in whole
            20 ms vocoder frames (k*160 samples, |k| <= 3) maximising the
            normalised correlation; reports corr, exact samples, max|d| and
            the fraction of 20 ms blocks that are bit-exact.
  fidelity  each chain's PCM against the reference PCM (the oracle voice
            chain on the error-free dibit-case frames, i.e. the transmitted
            frames in decode order): waveform correlation, and the mean
            log-spectral distance (LSD) of 16 band energies (Hann-windowed
            160-sample DFT per 20 ms block, 5 bins = 250 Hz per band, dB).
            mbelib draws unvoiced phases from rand(), so one differing frame
            desynchronises all later noise between the chains and waveform
            correlation collapses even when every later frame is identical;
            the band-energy LSD is insensitive to that phase noise and is the
            voice threshold for cases whose AMBE frames are not identical.
Thresholds per case are in CASES; exit 1 if any is violated.
"""
import json
import math
import os
import shutil
import struct
import subprocess
import sys

# name, input kind, rate, C/N dB, carrier offset Hz, noise seed, thresholds.
#   exact:      AMBE frames identical and voice PCM bit-exact
#   min_frame:  minimum fraction of index-aligned identical AMBE frames
#   lsd_margin: native mean LSD to the reference PCM may exceed the oracle's
#               by at most this many dB
#   ser_margin: native SER may exceed oracle SER by at most this
#   truth=False: skip the truth.txt metadata check (heavy error injection
#               corrupts embedded LC on both chains)
# Per-slot metadata transitions must be equal in every case.
CASES = [
    ("dibits", "dibits", 0, 0, 0, 0, dict(exact=True)),
    ("dibits_err", "dibits_err", 0, 0, 0, 0, dict(exact=True, truth=False)),
    ("iq240_clean", "iq", 240000, 200, 0, 1, dict(exact=True, ser_margin=0.005)),
    ("iq240_cn20", "iq", 240000, 20, 0, 1, dict(exact=True, ser_margin=0.005)),
    ("iq240_cn15", "iq", 240000, 15, 0, 1, dict(min_frame=0.95, lsd_margin=1.5, ser_margin=0.005)),
    ("iq240_cn12", "iq", 240000, 12, 0, 1, dict(min_frame=0.90, lsd_margin=1.5, ser_margin=0.01)),
    ("iq240_off300_cn20", "iq", 240000, 20, 300, 2, dict(min_frame=0.95, lsd_margin=1.5, ser_margin=0.005)),
    ("iq250_clean", "iq", 250000, 200, 0, 1, dict(min_frame=0.95, lsd_margin=1.5, ser_margin=0.005)),
    ("iq250_cn15", "iq", 250000, 15, 0, 1, dict(min_frame=0.90, lsd_margin=1.5, ser_margin=0.01)),
    ("iq288_cn20", "iq", 288000, 20, 0, 3, dict(min_frame=0.95, lsd_margin=1.5, ser_margin=0.005)),
]
# Cases copied into the CTest fixture (small enough to keep in git).
GOLDEN = ("dibits", "dibits_err", "iq240_cn15", "iq250_cn15")


def run(cmd, data=None, env=None):
    return subprocess.run(cmd, input=data, stdout=subprocess.PIPE, check=True, env=env).stdout


def inject_errors(dibits):
    """Deterministic channel errors; mirrored in dmr_chain_fixture_test.cpp."""
    out = bytearray(dibits)
    for i in range(len(out)):
        if i % 61 == 17:
            out[i] ^= 1
        if i % 211 == 5:
            out[i] ^= 2
    return bytes(out)


def frames(path):
    with open(path, "rb") as f:
        data = f.read()
    return [data[i:i + 9] for i in range(0, len(data) - 8, 9)]


def transitions(path):
    """Per-slot metadata transitions: {slot: [line, ...]}."""
    out = {}
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            seq = out.setdefault(line.split(" ", 2)[1], [])
            if not seq or seq[-1] != line:
                seq.append(line)
    return out


def align(sym, ref, max_lag=2000):
    """Best lag (sym[i + lag] ~ ref[i]) and SER; coarse stride then exact."""
    if not sym:
        return None, 1.0, 0

    def score(lag, step):
        hit = n = 0
        for i in range(0, len(ref), step):
            j = i + lag
            if 0 <= j < len(sym):
                n += 1
                hit += sym[j] == ref[i]
        return (hit / n if n else 0.0), n

    lag = max(range(0, max_lag), key=lambda k: score(k, 13)[0])
    rate, n = score(lag, 1)
    return lag, 1.0 - rate, n


def s16(buf):
    return struct.unpack(f"<{len(buf) // 2}h", buf)


_N, _BANDS = 160, 16
_WIN = [0.5 - 0.5 * math.cos(2 * math.pi * i / _N) for i in range(_N)]
_COS = [[math.cos(2 * math.pi * k * i / _N) for i in range(_N)] for k in range(_N // 2)]
_SIN = [[math.sin(2 * math.pi * k * i / _N) for i in range(_N)] for k in range(_N // 2)]


def band_energies(pcm):
    """Per 20 ms block: 16 band energies in dB (5 DFT bins = 250 Hz each)."""
    out = []
    for at in range(0, len(pcm) - _N + 1, _N):
        w = [pcm[at + i] * _WIN[i] for i in range(_N)]
        p = [sum(a * c for a, c in zip(w, _COS[k])) ** 2 + sum(a * s for a, s in zip(w, _SIN[k])) ** 2
             for k in range(_N // 2)]
        out.append([10 * math.log10(sum(p[5 * j:5 * j + 5]) + 1.0) for j in range(_BANDS)])
    return out


def mean_lsd(a, b):
    d = [math.sqrt(sum((x - y) ** 2 for x, y in zip(u, v)) / _BANDS) for u, v in zip(a, b)]
    return round(sum(d) / len(d), 3) if d else None


def pcm_compare(native, oracle):
    best = None
    for k in range(-3, 4):
        lag = 160 * k
        pairs = [(native[i + lag], oracle[i]) for i in range(len(oracle))
                 if 0 <= i + lag < len(native)]
        if not pairs:
            continue
        sab = sum(a * b for a, b in pairs)
        saa = sum(a * a for a, _ in pairs)
        sbb = sum(b * b for _, b in pairs)
        corr = sab / math.sqrt(saa * sbb) if saa and sbb else (1.0 if saa == sbb else 0.0)
        if best is None or corr > best["corr"]:
            blocks = [pairs[i:i + 160] for i in range(0, len(pairs) - 159, 160)]
            best = {"lag_samples": lag, "corr": round(corr, 6),
                    "exact": sum(a == b for a, b in pairs),
                    "overlap": len(pairs),
                    "exact_blocks": sum(all(a == b for a, b in blk) for blk in blocks),
                    "blocks": len(blocks),
                    "max_abs_diff": max(abs(a - b) for a, b in pairs)}
    if best is None:
        return {"lag_samples": None, "corr": 0.0, "exact": 0, "overlap": 0,
                "exact_blocks": 0, "blocks": 0, "max_abs_diff": None,
                "len_native": len(native), "len_oracle": len(oracle)}
    best["len_native"], best["len_oracle"] = len(native), len(oracle)
    return best


def voice(chain, voice_work, ambe, native):
    if native:
        return run([os.path.join(chain, "dmr_voice_replay"), "chain", "1"], ambe)
    synth = run([os.path.join(voice_work, "owrx_softmbe_harness"), "1"], ambe)
    filt = run([os.path.join(voice_work, "owrx_dvfilter_harness")], synth)
    return run([os.path.join(voice_work, "csdr"), "agc", "-f", "s16", "-m", "30", "-i", "3"], filt)


def main():
    args = sys.argv[1:]
    golden = None
    if "--golden" in args:
        i = args.index("--golden")
        golden = args[i + 1]
        del args[i:i + 2]
    chain, voice_work, out = args
    os.makedirs(out, exist_ok=True)
    # Pin FFTW_MEASURE plans (see chain.cpp): one wisdom file per chain, kept
    # in OUT_DIR so reruns into the same directory reuse it.
    env = {c: dict(os.environ, DMR_FFTW_WISDOM=os.path.join(out, f"fftw_wisdom_{c}"))
           for c in ("o", "n")}
    run([os.path.join(chain, "dmr_tx_encode"), out])
    with open(os.path.join(out, "tx.dibits"), "rb") as f:
        tx = f.read()
    tx_frames = set(frames(os.path.join(out, "tx_ts1.ambe")) + frames(os.path.join(out, "tx_ts2.ambe")))
    with open(os.path.join(out, "truth.txt")) as f:
        truth = [line.rstrip("\n") for line in f if line.strip()]

    report, ok = {}, True
    reference = None  # oracle PCM of the error-free dibit case (first case)
    reference_bands = None
    for name, kind, rate, cnr, offset, seed, limits in CASES:
        prefix = {c: os.path.join(out, f"{c}_{name}") for c in ("o", "n")}
        if kind == "iq":
            data = run([os.path.join(chain, "dmr_modulate"), str(rate), str(offset), str(cnr), str(seed)], tx)
            argv = ["iq", str(rate)]
        else:
            data = tx if kind == "dibits" else inject_errors(tx)
            argv = ["dibits"]
        run([os.path.join(chain, "owrx_chain"), *argv, prefix["o"]], data, env["o"])
        run([os.path.join(chain, "native_chain"), *argv, prefix["n"]], data, env["n"])

        r = {"input": kind, "rate": rate, "cnr_db": cnr, "offset_hz": offset, "seed": seed}
        fo, fn = frames(prefix["o"] + ".ambe"), frames(prefix["n"] + ".ambe")
        same = sum(a == b for a, b in zip(fo, fn))
        r["frames"] = {"oracle": len(fo), "native": len(fn), "identical": same,
                       "oracle_in_tx": sum(x in tx_frames for x in fo),
                       "native_in_tx": sum(x in tx_frames for x in fn)}
        to, tn = transitions(prefix["o"] + ".meta"), transitions(prefix["n"] + ".meta")
        flat_o = [x for seq in to.values() for x in seq]
        flat_n = [x for seq in tn.values() for x in seq]
        r["metadata"] = {"transitions_equal": to == tn, "oracle": len(flat_o), "native": len(flat_n),
                         "truth_in_oracle": all(t in flat_o for t in truth),
                         "truth_in_native": all(t in flat_n for t in truth)}
        if kind == "iq":
            sym = {}
            for c in ("o", "n"):
                with open(prefix[c] + ".sym", "rb") as f:
                    s = f.read()
                lag, ser, n = align(s, tx)
                sym[c] = {"length": len(s), "lag": lag, "ser": round(ser, 5), "overlap": n}
            r["symbols"] = {"oracle": sym["o"], "native": sym["n"]}
        with open(prefix["o"] + ".ambe", "rb") as f:
            ambe_o = f.read()
        with open(prefix["n"] + ".ambe", "rb") as f:
            ambe_n = f.read()
        pcm_n = s16(voice(chain, voice_work, ambe_n, True))
        pcm_o = s16(voice(chain, voice_work, ambe_o, False))
        if reference is None:
            reference = pcm_o
            reference_bands = band_energies(reference)
        r["voice"] = pcm_compare(pcm_n, pcm_o)
        r["fidelity"] = {"corr_native": pcm_compare(pcm_n, reference)["corr"],
                         "corr_oracle": pcm_compare(pcm_o, reference)["corr"],
                         "lsd_db_native": mean_lsd(band_energies(pcm_n), reference_bands),
                         "lsd_db_oracle": mean_lsd(band_energies(pcm_o), reference_bands)}

        fails = []
        if limits.get("truth", True) and not (r["metadata"]["truth_in_oracle"]
                                              and r["metadata"]["truth_in_native"]):
            fails.append("truth metadata missing")
        if not r["metadata"]["transitions_equal"]:
            fails.append("metadata transitions differ")
        if limits.get("exact"):
            if not (len(fo) == len(fn) == same and fo):
                fails.append("AMBE frames not identical")
            v = r["voice"]
            if not (v["len_native"] == v["len_oracle"] == v["exact"] and v["lag_samples"] == 0):
                fails.append("voice PCM not bit-exact")
        if "min_frame" in limits and (not fo or same / len(fo) < limits["min_frame"]
                                      or len(fn) != len(fo)):
            fails.append(f"identical frames {same}/{len(fo)} < {limits['min_frame']}")
        fid = r["fidelity"]
        if "lsd_margin" in limits and \
                fid["lsd_db_native"] > fid["lsd_db_oracle"] + limits["lsd_margin"]:
            fails.append(f"voice LSD {fid['lsd_db_native']} dB > oracle "
                         f"{fid['lsd_db_oracle']} + {limits['lsd_margin']}")
        if "ser_margin" in limits:
            so, sn = r["symbols"]["oracle"]["ser"], r["symbols"]["native"]["ser"]
            if sn > so + limits["ser_margin"]:
                fails.append(f"native SER {sn} > oracle {so} + {limits['ser_margin']}")
        r["limits"], r["failures"] = limits, fails
        ok &= not fails
        report[name] = r
        sym = r.get("symbols")
        print(f"{name:18s} frames o/n {len(fo):3d}/{len(fn):3d} same {same:3d} "
              f"in_tx {r['frames']['oracle_in_tx']:3d}/{r['frames']['native_in_tx']:3d} "
              f"meta {'eq' if r['metadata']['transitions_equal'] else 'DIFF'} "
              + (f"SER o/n {sym['oracle']['ser']:.4f}/{sym['native']['ser']:.4f} "
                 f"lag {sym['oracle']['lag']}/{sym['native']['lag']} " if sym else "")
              + f"pcm corr {r['voice']['corr']:.4f} exact-blk {r['voice']['exact_blocks']}/{r['voice']['blocks']} "
              + f"LSD o/n {fid['lsd_db_oracle']:.2f}/{fid['lsd_db_native']:.2f} dB "
              + ("OK" if not fails else "FAIL: " + "; ".join(fails)))

    with open(os.path.join(out, "report.json"), "w") as f:
        json.dump(report, f, indent=1)

    # The comparator itself must reject corruption (no vacuous pass).
    fo = frames(os.path.join(out, "o_dibits.ambe"))
    assert fo and [b"\xff" * 9] + fo[1:] != fo, "comparator mutation not detected"

    if golden:
        os.makedirs(golden, exist_ok=True)
        shutil.copy(os.path.join(out, "tx.dibits"), golden)
        shutil.copy(os.path.join(out, "truth.txt"), golden)
        for name in GOLDEN:
            shutil.copy(os.path.join(out, f"o_{name}.ambe"), os.path.join(golden, f"{name}.ambe"))
            with open(os.path.join(golden, f"{name}.meta"), "w") as f:
                per_slot = transitions(os.path.join(out, f"o_{name}.meta"))
                f.write("".join(line + "\n" for slot in sorted(per_slot) for line in per_slot[slot]))
        pcm = voice(chain, voice_work, open(os.path.join(out, "o_dibits.ambe"), "rb").read(), False)
        with open(os.path.join(golden, "dibits.pcm8k"), "wb") as f:
            f.write(pcm)
        print(f"golden fixture written to {golden}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
