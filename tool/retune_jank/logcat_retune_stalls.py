#!/usr/bin/env python3
"""Extract per-retune UI-thread stall metrics from an app logcat dump.

Old native path: a retune is visible as touch-up (ViewPostIme pointer 1) ->
AAudioStream_requestStop -> ... -> AAudioStream_requestStart returned, all on
the main thread, followed by a Choreographer "Skipped N frames" line.

New path: NativeRadioController logs "sdr: hardware controls <us> us" for
every LO/gain/rate change; Choreographer skips within 300 ms are attributed to
that retune.

Usage: logcat_retune_stalls.py <logcat.txt>
"""
import re
import statistics
import sys
from datetime import datetime


def ts(line):
    return datetime.strptime(line[6:18], "%H:%M:%S.%f")


def pct(values, q):
    return values[min(len(values) - 1, int(round(q * (len(values) - 1))))]


def summary(label, rows):
    if not rows:
        print(f"{label}: no samples")
        return
    b = sorted(r[1] for r in rows)
    s = sorted(r[2] for r in rows)
    print(f"{label}: n={len(rows)} block ms p50={statistics.median(b):.1f} "
          f"p95={pct(b, .95):.1f} max={b[-1]:.1f}; skipped frames "
          f"p50={statistics.median(s):.0f} max={s[-1]}")


def main(path):
    lines = open(path, errors="replace").read().splitlines()
    events = []
    for line in lines:
        if len(line) < 20 or not line[:2].isdigit():
            continue
        if "ViewPostIme pointer 1" in line:
            events.append(("up", ts(line), 0))
        elif "AAudioStream_requestStop(" in line:
            events.append(("stop", ts(line), 0))
        elif re.search(r"AAudioStream_requestStart\(s#\d+\) returned", line):
            events.append(("started", ts(line), 0))
        elif "Choreographer: Skipped" in line:
            n = int(re.search(r"Skipped (\d+) frames", line).group(1))
            events.append(("skipped", ts(line), n))
        else:
            m = re.search(r"sdr: hardware controls (\d+) us", line)
            if m:
                events.append(("controls", ts(line), int(m.group(1))))

    restart_rows, live_rows = [], []
    for i, (kind, t, value) in enumerate(events):
        later = events[i + 1:]
        if kind == "controls":
            skipped = next((e for e in later if e[0] == "skipped" and
                            (e[1] - t).total_seconds() < 0.3), None)
            live_rows.append((t.strftime("%H:%M:%S.%f")[:-3], value / 1000,
                              skipped[2] if skipped else 0))
            continue
        if kind != "up":
            continue
        stop = next((e for e in later if e[0] == "stop"), None)
        if not stop or (stop[1] - t).total_seconds() > 0.2:
            continue
        started = next((e for e in later if e[0] == "started"), None)
        if not started or (started[1] - t).total_seconds() > 2:
            continue
        skipped = next((e for e in later if e[0] == "skipped" and
                        (e[1] - started[1]).total_seconds() < 0.2 and
                        e[1] >= started[1]), None)
        restart_rows.append((t.strftime("%H:%M:%S.%f")[:-3],
                             (started[1] - t).total_seconds() * 1000,
                             skipped[2] if skipped else 0))
    for r in restart_rows:
        print(f"{r[0]}  up->audio restarted {r[1]:6.0f} ms  skipped frames {r[2]}")
    for r in live_rows:
        print(f"{r[0]}  hardware controls FFI {r[1]:8.2f} ms  skipped frames {r[2]}")
    summary("full-restart retunes", restart_rows)
    summary("controls-FFI retunes", live_rows)


if __name__ == "__main__":
    main(sys.argv[1])
