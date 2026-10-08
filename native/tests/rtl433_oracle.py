#!/usr/bin/env python3
"""Compare the embedded engine with pinned upstream CLI on recorded CU8 IQ.

Usage: RTL433_ENGINE_BINARY=/path/to/sdrcore_rtl433_engine_test \
    python3 native/tests/rtl433_oracle.py [--limit 400] [--all]
Defaults to native/build/sdrcore_rtl433_engine_test.
The script is host-only; the app never launches or depends on the CLI.
"""
import argparse
import array
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REF = Path.home() / "prj/ref/openwebrx/ext"
# Reference corpus: rtl_433_tests commit 1aa8c29d6b9383739d1aeed495dbc5069b704392.
# Decoder/oracle: rtl_433 commit 02cd4b69270cb27d4cb1a318d5a549fa8e848dc8.
CORPUS = REF / "rtl_433_tests/tests"
ORACLE = REF / "rtl_433/build/rtl_433"
ENGINE = Path(os.environ.get("RTL433_ENGINE_BINARY", str(ROOT / "native/build/sdrcore_rtl433_engine_test")))
TAP = Path(os.environ.get("RTL433_TAP_BINARY", str(ROOT / "build/native-host-tests/sdrcore_rtl433_tap_oracle")))
META = {"time", "mod", "freq", "freq1", "freq2", "rssi", "snr", "noise"}
# OpenWebRX+ IsmDemodulator: `rtl_433 -r cf32:- -s 250000 -Y autolevel`
# (csdr-plus/module/toolbox.py Rtl433Module). -A only prints pulse analysis.
OWRX_ARGS = ["-Y", "autolevel", "-F", "json", "-M", "level"]


def oracle_cf32(path, rate):
    return read_events([str(ORACLE), "-r", f"cf32:{rate // 1000}k:{path}", *OWRX_ARGS])


def read_events(args):
    proc = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          timeout=35, check=False)
    if proc.returncode:
        raise RuntimeError(f"{args[0]} exited {proc.returncode}: {proc.stderr.decode(errors='replace')[-300:]}")
    return [json.loads(line) for line in proc.stdout.decode().splitlines()
            if line.lstrip().startswith("{")]


def normalize(events):
    return [{key: value for key, value in event.items() if key not in META}
            for event in events]


def equal_payload(expected, actual):
    if len(expected) != len(actual):
        return False
    for a, b in zip(normalize(expected), normalize(actual)):
        if a.keys() != b.keys():
            return False
        for key in a:
            if isinstance(a[key], (int, float)) and not isinstance(a[key], bool) \
                    and isinstance(b[key], (int, float)) and not isinstance(b[key], bool):
                # CLI JSON output formats sensor doubles to three decimals;
                # data_print_jsons_dup retains the underlying full precision.
                if abs(a[key] - b[key]) > 0.001:
                    return False
            elif a[key] != b[key]:
                return False
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=400)
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--tap", action="store_true", help="compare 250 kS/s captures after the tuned-VFO 2.5 MS/s DSP branch")
    args = parser.parse_args()
    if not CORPUS.exists() or not (TAP if args.tap else ENGINE).exists() or not ORACLE.exists():
        parser.error("missing corpus, built embedded engine or pinned oracle executable")
    # The engine accepts complex 200-300k and has no center-frequency input.
    # Prefer compact 433.92 MHz sensor captures; include other 250k captures
    # as separate protocol coverage, comparing device fields (not RF metadata).
    files = [path for path in CORPUS.rglob("*.cu8")
             if re.search(r"(?:_|-)(?:200|250|300)k(?:\.|_)", path.name, re.I)
             and (not args.tap or "250k" in path.name)
             and 0 < path.stat().st_size <= 3 * 1024 * 1024]
    files.sort(key=lambda path: ("433.92M" not in path.name,
                                 "250k" not in path.name, str(path)))
    if not args.all:
        files = files[:args.limit]
    passed = 0
    decoded = 0
    event_count = 0
    raw_matched = 0
    mismatches = []
    for path in files:
        match = re.search(r"(?:_|-)(200|250|300)k(?:\.|_)", path.name, re.I)
        assert match is not None
        rate = int(match.group(1)) * 1000
        try:
            # Upstream fileformat.c scans the WHOLE pathname for format hints,
            # so always force the format with a prefix (tempfile names can
            # contain stray tokens). Input is the same float IQ in both runs.
            with tempfile.TemporaryDirectory(prefix="rtl433-") as directory:
                cf32 = Path(directory) / "input.cf32"
                if args.tap:
                    # The SAME post-VFO/FIR samples the engine received.
                    actual = read_events([str(TAP), str(path), "--dump", str(cf32)])
                    rate = 250000
                else:
                    raw = path.read_bytes()
                    with cf32.open("wb") as handle:
                        array.array("f", ((b - 127.5) / 128.0 for b in raw)).tofile(handle)
                    actual = read_events([str(ENGINE), str(path), str(rate)])
                expected = oracle_cf32(cf32, rate)
            if args.tap:
                original = read_events([str(ORACLE), "-r", f"cu8:250k:{path}", *OWRX_ARGS])
                raw_matched += equal_payload(original, actual)
            if not equal_payload(expected, actual):
                mismatches.append((str(path.relative_to(CORPUS)),
                                   normalize(expected)[:2], normalize(actual)[:2],
                                   len(expected), len(actual)))
            else:
                passed += 1
                decoded += bool(expected)
                event_count += len(expected)
        except (RuntimeError, subprocess.TimeoutExpired, ValueError) as exc:
            mismatches.append((str(path.relative_to(CORPUS)), str(exc)))
    print(f"Compared {len(files)} captures; matched {passed}; decoded {decoded} captures / {event_count} events; mismatched {len(mismatches)}")
    if args.tap:
        print(f"Of those, {raw_matched}/{len(files)} also match original IQ before the tuned-VFO FIR")
    for mismatch in mismatches[:20]:
        print(mismatch)
    if mismatches:
        raise SystemExit(1)
    if len(files) < 200 or decoded == 0:
        raise SystemExit("Insufficient corpus coverage")


if __name__ == "__main__":
    main()
