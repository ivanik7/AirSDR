#!/usr/bin/env python3
"""Event-locked audio envelope around control changes.

Usage: event_envelope.py <file.wav> <events.jsonl> <event> [period_ms]

Averages the 2 ms-window RMS from -20 ms to +300 ms around every <event>
("lo", "vfo", or "fake" = synthetic events every period_ms after "begin",
for a no-retune baseline), normalised by the RMS of the 50 ms before the
event. A dip that only exists right after control changes is a retune
artifact; programme-material level changes average out.

Also prints the hole rate: the share of events with any 2 ms window in the
first 20 ms below 25% of the pre-event RMS. Compare it with the "fake"
baseline of a no-retune recording (programme material has natural pauses).
"""
import json
import struct
import sys
import wave


def main():
    w = wave.open(sys.argv[1], "rb")
    rate, ch = w.getframerate(), w.getnchannels()
    raw = w.readframes(w.getnframes())
    vals = struct.unpack("<%dh" % (len(raw) // 2), raw)
    mono = [(vals[i] + vals[i + 1]) / 65536.0 for i in range(0, len(vals) - 1, ch)]
    events = [json.loads(l) for l in open(sys.argv[2]) if l.startswith("{")]
    kind = sys.argv[3]
    begin = next(e["frame"] for e in events if e["event"] == "begin")
    end = next(e["frame"] for e in events if e["event"] == "end")
    if kind == "fake":
        period = int(float(sys.argv[4]) * rate / 1000)
        frames = list(range(begin + period, end - rate // 2, period))
    else:
        frames = [e["frame"] for e in events if e["event"] == kind]
    win = int(rate * 0.002)
    bins = list(range(-10, 150))
    acc = [0.0] * len(bins)
    worst = [9.0] * len(bins)
    used = 0
    holes = 0
    for f in frames:
        if f - rate // 10 < 0 or f + 151 * win >= len(mono):
            continue
        pre = mono[f - int(rate * 0.05):f]
        ref = (sum(x * x for x in pre) / len(pre)) ** 0.5
        if ref < 0.01:
            continue
        used += 1
        hole = False
        for k, b in enumerate(bins):
            s = f + b * win
            seg = mono[s:s + win]
            r = (sum(x * x for x in seg) / win) ** 0.5 / ref
            acc[k] += r
            worst[k] = min(worst[k], r)
            if 0 <= b < 10 and r < 0.25:
                hole = True
        holes += hole
    print("events used:", used)
    print("hole rate (2 ms window < 25%% of pre-RMS within 20 ms): %d/%d = %.1f%%" %
          (holes, used, 100.0 * holes / max(used, 1)))
    for k, b in enumerate(bins):
        if b % 5 == 0 or acc[k] / max(used, 1) < 0.6:
            print("%+5d ms  mean %.2f  min %.2f" % (b * 2, acc[k] / max(used, 1), worst[k]))


if __name__ == "__main__":
    main()
