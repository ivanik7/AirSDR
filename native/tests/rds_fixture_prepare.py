#!/usr/bin/env python3
"""Convert upstream FLAC RDS MPX to identical S16LE samples for both backends.

Usage: uv run --with soundfile python native/tests/rds_fixture_prepare.py IN.flac OUT.s16
The input is external to this repository (redsea test/resources via Git LFS).
"""
import argparse
import pathlib
import soundfile as sf

parser = argparse.ArgumentParser()
parser.add_argument("input", type=pathlib.Path)
parser.add_argument("output", type=pathlib.Path)
args = parser.parse_args()
samples, rate = sf.read(args.input, dtype="int16")
if rate < 128000 or len(samples.shape) != 1:
    raise ValueError(f"Expected mono MPX >=128 kHz, got {samples.shape} at {rate} Hz")
args.output.write_bytes(samples.astype("<i2", copy=False).tobytes())
print(f"{args.input.name}: {rate} Hz, {len(samples)} samples -> {args.output}")
