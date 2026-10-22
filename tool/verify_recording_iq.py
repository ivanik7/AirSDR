#!/usr/bin/env python3
"""Check generated-IQ SigMF pairs from desktop or pulled Android recordings.

Usage: python3 tool/verify_recording_iq.py DIR PREFIX [PREFIX ...]
Each prefix is a full session timestamp (AirSDR_YYYY-MM-DD_HH-MM-SS).
"""
import json
import pathlib
import sys


def verify(folder: pathlib.Path, prefix: str) -> None:
    files = sorted(folder.glob(prefix + "*"))
    assert len(files) == 2, (prefix, files)
    data = next(path for path in files if path.name.endswith(".sigmf-data"))
    meta = next(path for path in files if path.name.endswith(".sigmf-meta"))
    assert data.name.removesuffix(".sigmf-data") == meta.name.removesuffix(".sigmf-meta")
    info = json.loads(meta.read_text())
    assert info["global"]["core:datatype"] == "cu8"
    assert info["global"]["core:sample_rate"] == 300000
    assert info["captures"][0]["core:frequency"] == 100000000
    raw = data.read_bytes()
    assert len(raw) > 1000 and len(raw) % 2 == 0
    assert all(raw[i + 1] == (raw[i] + 1) % 256 for i in range(min(4095, len(raw) - 1)))
    print(f"{prefix}: CU8 oracle and SigMF metadata passed; {len(raw)} IQ bytes")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit("usage: verify_recording_iq.py DIR PREFIX [PREFIX ...]")
    directory = pathlib.Path(sys.argv[1])
    for prefix in sys.argv[2:]:
        verify(directory, prefix)
