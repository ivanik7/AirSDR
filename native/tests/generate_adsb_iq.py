#!/usr/bin/env python3
"""Generate GPL-3.0-or-later synthetic 2.4 MS/s Mode S SC16 IQ.

The two DF17 airborne CPR messages are published at
https://github.com/junzis/pyModeS/issues/68 (ICAO 40621D).
No recording or third-party waveform is copied: this script constructs the
standard 8 us preamble and 112-bit pulse-position-modulated symbols.
"""
import argparse
import struct

RATE = 2_400_000
EVEN = bytes.fromhex("8d40621d58c382d690c8ac2863a7")
ODD = bytes.fromhex("8d40621d58c386435cc412692ad6")


def generate(path, pairs):
    # Place messages around the adapter's 16384-sample processing boundary.
    starts = [16320, 23000, 33000, 48000][:pairs * 2]
    messages = [EVEN, ODD, EVEN, ODD][:pairs * 2]
    sample_count = 69000 if pairs == 2 else 40000
    iq = bytearray(sample_count * 4)
    pulses = []
    for start, message in zip(starts, messages):
        base = start / RATE
        pulses.extend((base + offset * 1e-6, base + (offset + 0.5) * 1e-6)
                      for offset in (0, 1, 3.5, 4.5))
        for bit in range(112):
            value = (message[bit // 8] >> (7 - bit % 8)) & 1
            offset = 8 + bit + (0 if value else 0.5)
            pulses.append((base + offset * 1e-6, base + (offset + 0.5) * 1e-6))
    for lo, hi in pulses:
        # Sample at the center of each sample interval; 0.6 I, zero Q.
        first = max(0, int(lo * RATE) - 1)
        last = min(sample_count, int(hi * RATE) + 2)
        for i in range(first, last):
            if lo <= (i + 0.5) / RATE < hi:
                struct.pack_into("<hh", iq, 4 * i, 19660, 0)
    with open(path, "wb") as output:
        output.write(iq)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", help="output interleaved little-endian SC16 IQ")
    parser.add_argument("--pairs", type=int, choices=(1, 2), default=1)
    options = parser.parse_args()
    generate(options.output, options.pairs)
