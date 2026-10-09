#!/usr/bin/env python3
"""Compare redsea's upstream MPX chain, embedded adapter and full WFM DSP.

Uses external raw S16 mono MPX extracted from redsea's Git-LFS fixtures;
no recordings or expected JSON are fabricated by this test.
"""
import argparse
import json
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("binary", type=Path, help="sdrcore_rds_mpx_oracle")
parser.add_argument("receiver", type=Path, help="sdrcore_rds_mpx_receiver")
parser.add_argument("mpx", type=Path, help="rds2-minirds-192k.s16")
args = parser.parse_args()


def run(command):
    proc = subprocess.run(command, text=True, capture_output=True, check=True)
    return [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]


for rbds in ("0", "1"):
    raw = str(args.mpx)
    reference = run([str(args.binary), "redsea", raw, "192000", rbds])
    adapter = run([str(args.binary), "embedded", raw, "192000", rbds])
    wfm = run([str(args.receiver), raw, rbds])
    # Upstream Channel::flush emits a PI-only terminal line when its finite
    # input ends; our live streaming Sink has no EOF and must not invent one.
    assert reference and reference[-1].keys() <= {"pi", "callsign_uncertain"}
    reference = reference[:-1]
    assert len(reference) >= 16, "Insufficient groups to exercise PS assembly"
    assert reference == adapter == wfm, (
        f"RBDS={rbds}: decoded group JSON differs: "
        f"upstream={len(reference)}, adapter={len(adapter)}, WFM={len(wfm)}"
    )
    fields = {k for group in reference for k in group}
    assert {"pi", "ps", "prog_type", "di", "open_data_app"} <= fields
    assert any(group.get("ps") == "MiniRDS " for group in reference)
    if rbds == "1":
        assert all(group["callsign_uncertain"] == "KAAA" for group in reference)
    else:
        assert all("callsign" not in group for group in reference)
    print(f"RBDS={rbds}: {len(reference)} identical redsea/adapter/WFM groups; "
          f"fields={','.join(sorted(fields))}; PS=MiniRDS")
