#!/usr/bin/env python3
"""Find audio gaps/dips in a WAV recorded by sdrcore_host_retune_audio.

Usage: wav_gaps.py <file.wav> [events.jsonl]

Reports:
  * zero runs: >= 2 ms of exact digital silence (both channels 0);
  * dips: 10 ms windows whose RMS is below 25% of the median RMS of the
    surrounding 2 s (an audible level drop on a steady station);
  * clicks: sample-to-sample steps > 0.5 full scale.
With an events file (JSON lines with "event" and "frame"), each finding is
matched to the nearest preceding control change.
"""
import json
import statistics
import struct
import sys
import wave


def load(path):
    w = wave.open(path, "rb")
    rate, ch, n = w.getframerate(), w.getnchannels(), w.getnframes()
    raw = w.readframes(n)
    vals = struct.unpack("<%dh" % (len(raw) // 2), raw)
    left = [v / 32768.0 for v in vals[0::ch]]
    right = [v / 32768.0 for v in vals[1::ch]] if ch > 1 else left
    return rate, left, right


def main():
    rate, left, right = load(sys.argv[1])
    events = []
    if len(sys.argv) > 2:
        for line in open(sys.argv[2]):
            line = line.strip()
            if line.startswith("{"):
                events.append(json.loads(line))
    begin = next((e["frame"] for e in events if e["event"] == "begin"), 0)
    end = next((e["frame"] for e in events if e["event"] == "end"), len(left))
    controls = [e for e in events if e["event"] in ("lo", "vfo")]

    def nearest(frame):
        prev = [e for e in controls if e["frame"] <= frame]
        if not prev:
            return "-"
        e = prev[-1]
        return "%s+%.1fms" % (e["event"], (frame - e["frame"]) * 1000.0 / rate)

    zero_runs, run = [], 0
    for i in range(begin, min(end, len(left))):
        if left[i] == 0.0 and right[i] == 0.0:
            run += 1
        else:
            if run >= rate * 0.002:
                zero_runs.append((i - run, run))
            run = 0
    win = int(rate * 0.010)
    rms = []
    for s in range(begin, min(end, len(left)) - win, win):
        acc = sum(left[i] * left[i] + right[i] * right[i] for i in range(s, s + win))
        rms.append((s, (acc / (2 * win)) ** 0.5))
    dips = []
    ctx = int(2.0 / 0.010)
    for k, (s, v) in enumerate(rms):
        lo, hi = max(0, k - ctx // 2), min(len(rms), k + ctx // 2)
        med = statistics.median(r for _, r in rms[lo:hi])
        if med > 0.01 and v < 0.25 * med:
            dips.append((s, v, med))
    clicks = []
    for i in range(max(begin, 1), min(end, len(left))):
        if abs(left[i] - left[i - 1]) > 0.5 or abs(right[i] - right[i - 1]) > 0.5:
            clicks.append(i)
    seconds = (min(end, len(left)) - begin) / rate
    lo_n = sum(1 for e in controls if e["event"] == "lo")
    vfo_n = sum(1 for e in controls if e["event"] == "vfo")
    all_rms = [v for _, v in rms]
    print("analysed %.1f s, LO retunes %d, VFO moves %d, median RMS %.3f" %
          (seconds, lo_n, vfo_n, statistics.median(all_rms) if all_rms else 0))
    print("zero runs >=2ms: %d, total %.1f ms" %
          (len(zero_runs), sum(r for _, r in zero_runs) * 1000.0 / rate))
    for s, r in zero_runs[:20]:
        print("  zero  t=%.3fs len=%.1fms after %s" % ((s - begin) / rate, r * 1000.0 / rate, nearest(s)))
    print("dips (<25%% of local median, 10 ms windows): %d" % len(dips))
    for s, v, med in dips[:20]:
        print("  dip   t=%.3fs rms=%.3f local=%.3f after %s" % ((s - begin) / rate, v, med, nearest(s)))
    print("clicks (>0.5 FS step): %d" % len(clicks))
    for i in clicks[:10]:
        print("  click t=%.3fs after %s" % ((i - begin) / rate, nearest(i)))
    sys.exit(1 if zero_runs or dips else 0)


if __name__ == "__main__":
    main()
