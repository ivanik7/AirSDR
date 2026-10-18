#!/usr/bin/env python3
"""Generate synthetic DMR dibits, not licensed on-air audio or AMBE speech."""
from pathlib import Path
import sys

VOICE = (1, 3, 1, 1, 1, 1, 3, 3, 3, 1, 1, 3, 3, 1, 3, 3, 1, 3, 1, 1, 3, 3, 1, 3)
DATA = (3, 1, 3, 3, 3, 3, 1, 1, 1, 3, 3, 1, 1, 3, 1, 1, 3, 1, 3, 3, 1, 1, 3, 1)
TACT = (0, 4, 8, 12, 14, 18, 22)


def parity(word):
    # digiham hamming_7_4.c parity-check matrix, pin beec7822.
    return all((word & mask).bit_count() % 2 == 0
               for mask in (0b01110100, 0b00111010, 0b01101001))


def burst(slot, sync, index, corrupt=0):
    result = bytearray(144)
    tact = next(word for word in range(128) if parity(word) and ((word >> 5) & 1) == slot)
    for i, pos in enumerate(TACT):
        result[pos // 2] |= ((tact >> (6 - i)) & 1) << (1 - pos % 2)
    for i in range(54):
        result[12 + i] = (i + index) % 4
        result[90 + i] = (i * 3 + index) % 4
    result[66:90] = bytes(sync)
    for i in range(corrupt):
        result[66 + i] ^= 1
    return result


def main():
    output = Path(sys.argv[1])
    # Non-repetitive payloads, acquisition offset, alternating slots,
    # voice -> data transition and a three-symbol sync error.
    frames = [burst(i % 2, VOICE, i, 3 if i == 4 else 0) for i in range(8)]
    frames += [burst(i % 2, DATA, i + 8) for i in range(4)]
    output.write_bytes(bytes([0, 2, 1, 0, 3]) + b''.join(frames))
    print(f"fixture: {len(frames)} bursts, {output.stat().st_size} dibits")


if __name__ == '__main__':
    main()
