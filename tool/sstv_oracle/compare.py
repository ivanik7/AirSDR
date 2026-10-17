#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare the native SSTV backend with the OpenWebRX+ oracle on a corpus.

For every case in <corpus>/manifest.json (from gen_corpus.py):

  oracle   owrx_sstv_harness (pristine csdr-plus f26b520 SstvDecoder(24000,
           300000), fed like csdr's runModule) -> byte stream, framed the way
           OpenWebRX+ owrx/sstv.py::SstvParser frames it (observable framing
           re-implemented here, the AGPL parser is not copied).
  adapter  sdrcore_sstv_replay adapter: same WAV -> production adapter
           (native/src/decoder/sstv.cpp + vendored, patched SstvDecoder).
  receiver sdrcore_sstv_replay receiver: same WAV -> CU8 IQ -> production
           Receiver + 24 kHz audio tap -> adapter (selected cases/demods).

Checks per case: frame count, VIS/mode/dimensions, row count, padded rows,
completion (status/reason vs. the oracle's natural end), per-row progress
timing, pixel equality with the oracle and PSNR against the source image.
Writes <out>/report.json and <out>/report.md and decoded PNGs.

Usage:
  python3 compare.py --corpus DIR --oracle owrx_sstv_harness \
      --replay build/native-host/sdrcore_sstv_replay --out DIR [--receiver]
Needs Pillow (to read the source PNGs and write decoded images).
"""
import argparse
import json
import math
import os
import subprocess
import sys

from PIL import Image

# OpenWebRX+ owrx/sstv.py display names (the parser's modeNames table,
# facts only); the native backend reports the csdr-plus C++ NAME instead.
OWRX_NAMES = {0: "Robot 12", 4: "Robot 24", 8: "Robot 36", 12: "Robot 72", 32: "Martin 4",
              36: "Martin 3", 40: "Martin 2", 44: "Martin 1", 48: "Scottie 4", 51: "SC2 30",
              52: "Scottie 3", 55: "SC2 180", 56: "Scottie 2", 59: "SC2 60", 60: "Scottie 1",
              63: "SC2 120", 68: "AVT 90", 76: "Scottie DX", 93: "PD 50", 94: "PD 290",
              95: "PD 120", 96: "PD 180", 97: "PD 240", 98: "PD 160", 99: "PD 90"}

# csdr-plus WINDOW_FACTOR per VIS (sstv.hpp): each pixel's tone is estimated
# from an FFT window this many pixel times wide, so edges smear by about
# this much horizontally. Flat-patch PSNR excludes that margin.
WINDOW_FACTOR = {8: 7.70, 44: 2.34, 40: 4.68, 60: 2.48, 56: 3.82, 76: 0.98, 99: 2.01, 95: 5.63,
                 98: 2.79, 96: 3.74, 97: 2.80, 94: 3.74, 55: 1.46, 63: 2.93}

# Acceptance thresholds (justification in docs/status/sstv-oracle.md).
# Adapter vs oracle: same decoder source and input; the only allowed
# difference is float rounding from a different FFTW build (vendored
# portable FFTW vs upstream's SIMD FFTW + -ffast-math), which can move a
# pixel by one 8-bit level where the upstream code truncates near an
# integer boundary.
ADAPTER_MAX_ABS_DIFF = 1
ADAPTER_MAX_DIFF_FRACTION = 1e-3
ADAPTER_MAX_PSNR_LOSS = 0.05       # dB vs the oracle's own PSNR
# Absolute floors vs the source image on flat patches (edge-smear margin
# excluded): RMS error 14.3 levels (25 dB) clean, 25 levels (20 dB) at
# 10 dB SNR, 51 levels (14 dB) at 5 dB SNR, 0 dB SNR measured only.
CLEAN_MIN_PATCH_PSNR = 25.0
NOISY_MIN_PATCH_PSNR = {10: 20.0, 5: 14.0, 0: None}
RECEIVER_MIN_PSNR_VS_ORACLE = 30.0  # dB, flat patches, receiver vs oracle image
RECEIVER_MAX_PSNR_LOSS = 1.0       # dB, receiver path vs oracle, vs source


def parse_oracle(stream):
    """Frames the upstream byte stream like SstvParser: ' [..]' debug text
    outside images, 'BM' + 54-byte header (VIS at byte 6, LE32 width at 18,
    LE32 -height at 22), then width*3 bytes per row until `height` rows."""
    frames, messages = [], []
    i, n = 0, len(stream)
    while i < n:
        bm = stream.find(b"BM", i)
        dbg = stream.find(b" [", i)
        if bm < 0 and dbg < 0:
            break
        if bm < 0 or (0 <= dbg < bm):
            end = stream.find(b"]", dbg)
            if end < 0:
                break
            messages.append(stream[dbg + 2:end].decode(errors="replace"))
            i = end + 1
            continue
        if bm + 54 > n:
            break
        h = stream[bm:bm + 54]
        width = int.from_bytes(h[18:22], "little")
        height = 0x100000000 - int.from_bytes(h[22:26], "little")
        frame = dict(vis=h[6], tag=h[7], width=width, height=height, header_offset=bm,
                     rows=[], messages_before=len(messages))
        i = bm + 54
        w = width * 3
        while len(frame["rows"]) < height and i + w <= n:
            frame["rows"].append(stream[i:i + w])
            i += w
        frames.append(frame)
    return frames, messages


def oracle_progress(path, frames):
    """Input sample index at which each oracle row became available."""
    points = []
    with open(path) as f:
        for line in f:
            s, b = line.split()
            points.append((int(s), int(b)))
    out = []
    for fr in frames:
        base = fr["header_offset"] + 54
        rows = []
        k = 0
        for r in range(len(fr["rows"])):
            need = base + (r + 1) * fr["width"] * 3
            while k < len(points) and points[k][1] < need:
                k += 1
            rows.append(points[k][0] if k < len(points) else None)
        out.append(rows)
    return out


def load_native(outdir):
    frames = []
    with open(os.path.join(outdir, "events.jsonl")) as f:
        for line in f:
            e = json.loads(line)
            if e["kind"] == "image_progress" and e["phase"] == "start":
                frames.append(dict(start=e, lines=[], complete=None))
            elif frames and e["frame_id"] == frames[-1]["start"]["frame_id"]:
                if e["kind"] == "image_complete":
                    frames[-1]["complete"] = e
                else:
                    frames[-1]["lines"].append(e)
    for fr in frames:
        w = fr["start"]["width"] * 3
        path = os.path.join(outdir, f"frame_{fr['start']['frame_id']}.bgr")
        data = open(path, "rb").read() if os.path.exists(path) else b""
        fr["rows"] = [data[k * w:(k + 1) * w] for k in range(len(data) // w)]
    return frames


def bgr_rows_to_rgb(rows, width):
    out = bytearray()
    for r in rows:
        for x in range(width):
            out += bytes((r[3 * x + 2], r[3 * x + 1], r[3 * x]))
    return bytes(out)


def save_png(rows, width, path):
    if rows:
        Image.frombytes("RGB", (width, len(rows)), bgr_rows_to_rgb(rows, width)).save(path)


def psnr_rows(rows, src, width, region=None, margin_x=0, margin_y=0):
    """PSNR (dB) of decoded BGR rows against an RGB PIL image. region: list
    of inclusive rectangles; each is shrunk by the margins. Missing rows
    count as all-zero (black), exactly as a viewer would show them."""
    spx = src.load()
    se, n = 0.0, 0
    height = src.size[1]
    rects = region or [[0, 0, width - 1, height - 1]]
    for x0, y0, x1, y1 in rects:
        for y in range(y0 + margin_y, y1 - margin_y + 1):
            row = rows[y] if y < len(rows) else None
            for x in range(x0 + margin_x, x1 - margin_x + 1):
                s = spx[x, y]
                for c in range(3):
                    d = row[3 * x + 2 - c] if row is not None else 0
                    se += (s[c] - d) ** 2
                    n += 1
    if n == 0:
        return None
    mse = se / n
    return 99.0 if mse == 0 else 10 * math.log10(255 * 255 / mse)


def psnr_between(rows_a, rows_b, width, region, margin_x, margin_y):
    se, n = 0.0, 0
    for x0, y0, x1, y1 in region:
        for y in range(y0 + margin_y, y1 - margin_y + 1):
            if y >= len(rows_a) or y >= len(rows_b):
                continue
            a, b = rows_a[y], rows_b[y]
            for i in range(3 * (x0 + margin_x), 3 * (x1 - margin_x + 1)):
                se += (a[i] - b[i]) ** 2
                n += 1
    if n == 0:
        return None
    return 99.0 if se == 0 else 10 * math.log10(255 * 255 / (se / n))


def byte_diff(rows_a, rows_b):
    count, worst = 0, 0
    for a, b in zip(rows_a, rows_b):
        if a == b:
            continue
        for x, y in zip(a, b):
            if x != y:
                count += 1
                worst = max(worst, abs(x - y))
    return count, worst


def run(cmd, **kw):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, **kw)
    if p.returncode:
        raise RuntimeError(f"{cmd[0]} exited {p.returncode}: {p.stderr.decode()[-400:]}")
    return p.stdout


def psnr_threshold(case):
    snr = case.get("snr_db")
    return CLEAN_MIN_PATCH_PSNR if snr is None else NOISY_MIN_PATCH_PSNR[snr]


def analyse(case, corpus, out, oracle_bin, replay_bin, receiver_modes, control_bin=None,
            nfm_args=()):
    name = case["name"]
    wav = os.path.join(corpus, case["wav"])
    cdir = os.path.join(out, name)
    os.makedirs(cdir, exist_ok=True)
    stream = run([oracle_bin, "--progress", os.path.join(cdir, "oracle_progress.txt"), wav])
    with open(os.path.join(cdir, "oracle.bin"), "wb") as f:
        f.write(stream)
    o_frames, o_msgs = parse_oracle(stream)
    o_prog = oracle_progress(os.path.join(cdir, "oracle_progress.txt"), o_frames)
    adir = os.path.join(cdir, "adapter")
    os.makedirs(adir, exist_ok=True)
    a_dropped = json.loads(run([replay_bin, "adapter", wav, adir]))["dropped"]
    a_frames = load_native(adir)
    src = Image.open(os.path.join(corpus, case["source"])).convert("RGB")
    exp = case["expect"]
    res = dict(name=name, mode=case["mode"], seconds=round(case["seconds"], 1),
               oracle_frames=len(o_frames), adapter_frames=len(a_frames),
               adapter_dropped=a_dropped, oracle_messages=o_msgs, checks=[])

    def check(ok, what):
        res["checks"].append(dict(ok=bool(ok), what=what))

    if exp is None:
        check(not o_frames and not a_frames,
              f"unsupported VIS: oracle {len(o_frames)} frames, native {len(a_frames)} frames")
        return res
    if not o_frames:
        # Upstream itself decodes nothing (e.g. offset beyond its VIS
        # tolerance): parity means native must decode nothing either.
        res["upstream_no_decode"] = True
        check(not a_frames, f"oracle decoded no frame; native decoded {len(a_frames)}")
        return res
    check(len(o_frames) == 1, f"oracle decoded exactly one frame ({len(o_frames)})")
    check(len(a_frames) == len(o_frames),
          f"native frame count equals oracle ({len(a_frames)} vs {len(o_frames)})")
    if not o_frames or not a_frames:
        return res
    of, af = o_frames[0], a_frames[0]
    st = af["start"]
    res.update(vis=of["vis"], oracle_name=OWRX_NAMES.get(of["vis"]), native_name=st["sstv_mode"],
               width=of["width"], height=of["height"], oracle_rows=len(of["rows"]),
               native_rows=len(af["rows"]))
    check(of["vis"] == exp["vis"] == st["vis"] and of["tag"] == 0x73,
          f"VIS {exp['vis']} detected by oracle ({of['vis']}) and native ({st['vis']})")
    check(st["sstv_mode"] == exp["name"],
          f"native mode name '{st['sstv_mode']}' = csdr-plus NAME '{exp['name']}' "
          f"(OpenWebRX+ UI name '{OWRX_NAMES.get(of['vis'])}')")
    check((of["width"], of["height"]) == (st["width"], st["height"]) == (exp["width"], exp["height"]),
          f"dimensions {exp['width']}x{exp['height']} (oracle {of['width']}x{of['height']}, "
          f"native {st['width']}x{st['height']})")
    # Completion: OpenWebRX+ has no completion message; the oracle frame is
    # complete when all `height` rows arrived. Native must say complete/end
    # with the same row count, and report padded rows honestly.
    comp = af["complete"] or {}
    padded = sum(1 for e in af["lines"] if e["padded"])
    res.update(native_status=comp.get("status"), native_reason=comp.get("reason"),
               native_padded=padded)
    o_complete = len(of["rows"]) == of["height"]
    check(o_complete == (comp.get("status") == "complete") and
          comp.get("received_lines") == len(af["rows"]) == len(of["rows"]) and
          comp.get("padded_lines") == padded,
          f"completion: oracle {len(of['rows'])}/{of['height']} rows, native "
          f"{comp.get('status')}/{comp.get('reason')} received={comp.get('received_lines')} "
          f"padded={padded}")
    # Padded rows are all-zero rows upstream; the native flag must match them.
    zero = [k for k, r in enumerate(of["rows"]) if not any(r)]
    flagged = [k for k, e in enumerate(af["lines"]) if e["padded"]]
    check(set(flagged) <= set(zero),
          f"every native padded row is an all-zero oracle row ({len(flagged)} padded, "
          f"{len(zero)} zero rows)")
    nd, worst = byte_diff(of["rows"], af["rows"])
    res.update(adapter_bytes_differing=nd, adapter_max_abs_diff=worst)
    total = max(1, sum(len(r) for r in of["rows"]))
    # The byte tolerance is the fraction only: a rounding flip in a sync or
    # threshold decision can move a few pixels by more than one level; the
    # vendored-FFTW control below proves such differences are FFTW rounding.
    check(nd <= ADAPTER_MAX_DIFF_FRACTION * total and len(of["rows"]) == len(af["rows"]),
          f"adapter pixels match oracle on >= {1 - ADAPTER_MAX_DIFF_FRACTION:.1%} of bytes "
          f"({nd}/{total} differ, max |d|={worst})")
    if control_bin:
        # Pristine upstream sstv.cpp linked with the VENDORED FFTW (see
        # build_oracle.sh): isolates our patches from FFTW rounding.
        c_frames, _ = parse_oracle(run([control_bin, wav]))
        cd = byte_diff(c_frames[0]["rows"], af["rows"])[0] if c_frames else None
        res["adapter_bytes_differing_vs_vendored_fftw_control"] = cd
        check(cd == 0 and len(c_frames[0]["rows"]) == len(af["rows"]),
              f"adapter byte-identical to pristine upstream sstv.cpp built with the vendored "
              f"FFTW ({cd} bytes differ)")
    # Progress: per-row availability (input sample index) native vs oracle.
    lags = [e["input_samples"] - o for e, o in zip(af["lines"], o_prog[0]) if o is not None]
    if lags:
        res.update(progress_lag_samples=dict(min=min(lags), max=max(lags)))
        check(max(abs(v) for v in lags) <= 1024,
              f"row progress within one 1024-sample block of the oracle "
              f"(lag {min(lags)}..{max(lags)} samples)")
    starts = [e["input_samples"] for e in af["lines"]]
    check(all(b >= a for a, b in zip(starts, starts[1:])), "native rows arrive in order, incrementally")
    # PSNR vs source. pySSTV sends Martin 2 / Scottie 2 with 160 pixels per
    # scan line while csdr-plus samples every mode at its LINE_WIDTH (320):
    # the source is then scaled to the decoded grid by pixel replication
    # (each transmitted pixel occupies two decoded columns) and so are the
    # patch rectangles.
    wf = WINDOW_FACTOR.get(of["vis"], 3.0)
    mx, my = int(math.ceil(wf)) + 1, 2
    region = case["patches"]
    if src.size != (of["width"], of["height"]):
        sx = of["width"] / src.size[0]
        sy = of["height"] / src.size[1]
        res["source_scaled"] = [src.size[0], src.size[1], of["width"], of["height"]]
        src = src.resize((of["width"], of["height"]), Image.NEAREST)
        region = [[int(x0 * sx), int(y0 * sy), int((x1 + 1) * sx) - 1, int((y1 + 1) * sy) - 1]
                  for x0, y0, x1, y1 in region]
        mx = int(math.ceil(wf * sx)) + 1
    p_full_o = psnr_rows(of["rows"], src, of["width"])
    p_full_a = psnr_rows(af["rows"], src, of["width"])
    p_patch_o = psnr_rows(of["rows"], src, of["width"], region, mx, my)
    p_patch_a = psnr_rows(af["rows"], src, of["width"], region, mx, my)
    res.update(psnr_full_oracle=p_full_o, psnr_full_adapter=p_full_a,
               psnr_patch_oracle=p_patch_o, psnr_patch_adapter=p_patch_a)
    thr = psnr_threshold(case)
    check(p_patch_a is not None and p_patch_a >= p_patch_o - ADAPTER_MAX_PSNR_LOSS,
          f"native flat-patch PSNR {p_patch_a:.2f} dB within {ADAPTER_MAX_PSNR_LOSS} dB of "
          f"oracle {p_patch_o:.2f} (whole image native {p_full_a:.2f} / oracle {p_full_o:.2f})")
    # Absolute floors are reported, not gated: the oracle itself is the
    # reference, and where it misses a floor so does native (identical
    # PSNR is checked above). See docs/status/sstv-oracle.md.
    res["meets_absolute_floor"] = None if thr is None else bool(p_patch_a >= thr)
    res["oracle_meets_absolute_floor"] = None if thr is None else bool(p_patch_o >= thr)
    save_png(of["rows"], of["width"], os.path.join(cdir, "oracle.png"))
    save_png(af["rows"], of["width"], os.path.join(cdir, "adapter.png"))
    # Receiver path (IQ -> demod -> 24 kHz tap -> adapter).
    res["receiver"] = {}
    for demod in receiver_modes:
        rdir = os.path.join(cdir, f"receiver_{demod}")
        os.makedirs(rdir, exist_ok=True)
        extra = list(nfm_args) if demod == "nfm" else []
        r_dropped = json.loads(run([replay_bin, "receiver", wav, rdir, "--mode", demod,
                                    "--rate", "240000", "--vfo", "0"] + extra))["dropped"]
        r_frames = load_native(rdir)
        entry = dict(frames=len(r_frames), dropped=r_dropped)
        res["receiver"][demod] = entry
        ok = len(r_frames) == 1 and r_frames[0]["start"]["vis"] == of["vis"]
        check(ok, f"receiver {demod}: one frame, VIS {of['vis']} ({len(r_frames)} frames)")
        if not ok:
            continue
        rf = r_frames[0]
        rc = rf["complete"] or {}
        p_r = psnr_rows(rf["rows"], src, of["width"], region, mx, my)
        p_ro = psnr_between(rf["rows"], of["rows"], of["width"], region, mx, my)
        entry.update(rows=len(rf["rows"]), status=rc.get("status"), reason=rc.get("reason"),
                     padded=rc.get("padded_lines"), psnr_patch_vs_source=p_r,
                     psnr_patch_vs_oracle=p_ro,
                     frequency_hz=rf["start"]["frequency_hz"],
                     underlying=rf["start"]["underlying"])
        check(rc.get("status") == ("complete" if o_complete else rc.get("status")) and
              len(rf["rows"]) == len(of["rows"]) and rf["start"]["underlying"] == demod,
              f"receiver {demod}: {len(rf['rows'])} rows {rc.get('status')}/{rc.get('reason')}, "
              f"underlying={rf['start']['underlying']}")
        # Under noise (audio SNR in the corpus, or RF CNR added by the NFM
        # modulator) the receiver's channel filter and FM threshold change
        # the noise, so receiver-vs-oracle similarity is only meaningful on
        # noise-free input.
        rf_noise = demod == "nfm" and "--cnr" in extra
        if case.get("snr_db") is None and not rf_noise:
            check(p_ro is not None and p_ro >= RECEIVER_MIN_PSNR_VS_ORACLE,
                  f"receiver {demod}: flat-patch PSNR vs oracle image {p_ro:.2f} dB >= "
                  f"{RECEIVER_MIN_PSNR_VS_ORACLE}")
        if not rf_noise:
            check(p_r is not None and p_r >= p_patch_o - RECEIVER_MAX_PSNR_LOSS,
                  f"receiver {demod}: flat-patch PSNR vs source {p_r:.2f} dB within "
                  f"{RECEIVER_MAX_PSNR_LOSS} dB of the oracle's {p_patch_o:.2f}")
        save_png(rf["rows"], of["width"], os.path.join(cdir, f"receiver_{demod}.png"))
    return res


def fmt(v):
    return "-" if v is None else f"{v:.2f}" if isinstance(v, float) else str(v)


def write_md(results, path):
    lines = ["| case | s | VIS | oracle/native name | rows o/n | status | padded | bytes != | "
             "lag (samples) | PSNR patch o/n | PSNR full o/n | receiver usb/lsb/nfm patch vs src (vs oracle) | ok |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in results:
        rx = []
        for m, e in r.get("receiver", {}).items():
            rx.append(f"{m} {fmt(e.get('psnr_patch_vs_source'))} ({fmt(e.get('psnr_patch_vs_oracle'))})")
        lag = r.get("progress_lag_samples")
        ok = all(c["ok"] for c in r["checks"])
        lines.append("| " + " | ".join([
            r["name"], fmt(r["seconds"]), fmt(r.get("vis")),
            f"{fmt(r.get('oracle_name'))} / {fmt(r.get('native_name'))}",
            f"{fmt(r.get('oracle_rows'))}/{fmt(r.get('native_rows'))}",
            f"{fmt(r.get('native_status'))}/{fmt(r.get('native_reason'))}",
            fmt(r.get("native_padded")), fmt(r.get("adapter_bytes_differing")),
            "-" if not lag else f"{lag['min']}..{lag['max']}",
            f"{fmt(r.get('psnr_patch_oracle'))}/{fmt(r.get('psnr_patch_adapter'))}",
            f"{fmt(r.get('psnr_full_oracle'))}/{fmt(r.get('psnr_full_adapter'))}",
            "; ".join(rx) or "-", "yes" if ok else "**NO**"]) + " |")
    failed = [(r["name"], c["what"]) for r in results for c in r["checks"] if not c["ok"]]
    lines.append("")
    lines.append(f"{sum(len(r['checks']) for r in results)} checks, {len(failed)} failed.")
    for n, w in failed:
        lines.append(f"- FAIL {n}: {w}")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", required=True)
    ap.add_argument("--oracle", required=True)
    ap.add_argument("--replay", required=True)
    ap.add_argument("--fftw-control", help="owrx_sstv_harness_vfftw from build_oracle.sh")
    ap.add_argument("--out", required=True)
    ap.add_argument("--receiver", action="store_true",
                    help="also run the IQ receiver path (Robot36/MartinM1/PD90 clean in "
                         "USB/LSB/NFM, other cases in USB)")
    ap.add_argument("--receiver-modes",
                    help="comma-separated demods to run for EVERY case instead of the "
                         "--receiver default selection (e.g. nfm)")
    ap.add_argument("--nfm-preemph", choices=["none", "tia"], default="none",
                    help="NFM modulator: 'tia' applies 750 us land-mobile pre-emphasis "
                         "before FM, as a real FM transmitter's mic path does")
    ap.add_argument("--nfm-cnr", type=float,
                    help="NFM modulator: add white noise for this carrier-to-noise ratio "
                         "(dB in 12.5 kHz); disables the noise-free receiver checks")
    ap.add_argument("--only")
    args = ap.parse_args()
    nfm_args = ["--preemph", args.nfm_preemph]
    if args.nfm_cnr is not None:
        nfm_args += ["--cnr", str(args.nfm_cnr)]
    manifest = json.load(open(os.path.join(args.corpus, "manifest.json")))
    only = set(args.only.split(",")) if args.only else None
    results = []
    for case in manifest["cases"]:
        if only and case["name"] not in only:
            continue
        modes = []
        if args.receiver_modes and case["expect"] is not None:
            modes = args.receiver_modes.split(",")
        elif args.receiver and case["expect"] is not None:
            three = case["name"] in ("Robot36_clean", "MartinM1_clean", "PD90_clean")
            modes = ["usb", "lsb", "nfm"] if three else ["usb"]
        r = analyse(case, args.corpus, args.out, args.oracle, args.replay, modes,
                    args.fftw_control, nfm_args)
        ok = all(c["ok"] for c in r["checks"])
        print(f"{'ok  ' if ok else 'FAIL'} {r['name']}", flush=True)
        for c in r["checks"]:
            if not c["ok"]:
                print(f"     - {c['what']}", flush=True)
        results.append(r)
    json.dump(results, open(os.path.join(args.out, "report.json"), "w"), indent=1)
    write_md(results, os.path.join(args.out, "report.md"))
    failed = sum(1 for r in results for c in r["checks"] if not c["ok"])
    print(f"{len(results)} cases, {failed} failed checks; report: {args.out}/report.md")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
