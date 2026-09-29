#!/usr/bin/env python3
"""Generate original AirSDR legacy launcher PNGs from the adaptive icon geometry.

Pure stdlib; run from repository root: python3 tool/branding/generate_icons.py
The Android 26+ icon uses the equivalent vector drawables directly.
"""

import math
import pathlib
import struct
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[2] / "android/app/src/main/res"
BACKGROUND = (11, 13, 15)
GREEN = (168, 207, 106)
WHITE = (231, 228, 222)
DENSITIES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}


def png_chunk(kind, payload):
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(
        ">I", zlib.crc32(kind + payload) & 0xFFFFFFFF
    )


def draw_icon(size):
    # Render at 3x and average for smooth 48dp edges without third-party packages.
    side = size * 3
    scale = side / 108
    pixels = bytearray(BACKGROUND * (side * side))

    def disc(x, y, radius, color):
        cx, cy, r = x * scale, y * scale, radius * scale
        for py in range(max(0, int(cy - r)), min(side, int(cy + r) + 1)):
            for px in range(max(0, int(cx - r)), min(side, int(cx + r) + 1)):
                if (px + 0.5 - cx) ** 2 + (py + 0.5 - cy) ** 2 <= r * r:
                    start = (py * side + px) * 3
                    pixels[start:start + 3] = bytes(color)

    def quadratic(start, control, end, color):
        for step in range(161):
            t = step / 160
            x = (1 - t) ** 2 * start[0] + 2 * t * (1 - t) * control[0] + t * t * end[0]
            y = (1 - t) ** 2 * start[1] + 2 * t * (1 - t) * control[1] + t * t * end[1]
            disc(x, y, 2.25, color)

    # Keep the same 108x108 coordinates as ic_launcher_foreground.xml.
    for a, b, c in [
        ((41, 35), (29, 49), (41, 63)),
        ((67, 35), (79, 49), (67, 63)),
        ((32, 26), (12, 49), (32, 72)),
        ((76, 26), (96, 49), (76, 72)),
    ]:
        quadratic(a, b, c, GREEN)
    for y in range(49, 75):
        disc(54, y, 2.5, WHITE)
    for x in range(42, 67):
        disc(x, 75, 2.5, WHITE)
    disc(54, 42, 7, GREEN)

    raw = bytearray()
    for y in range(size):
        raw.append(0)  # PNG filter: None
        for x in range(size):
            rgb = [0, 0, 0]
            for dy in range(3):
                for dx in range(3):
                    offset = ((y * 3 + dy) * side + x * 3 + dx) * 3
                    for channel in range(3):
                        rgb[channel] += pixels[offset + channel]
            raw.extend(round(channel / 9) for channel in rgb)
    return (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(raw, 9))
        + png_chunk(b"IEND", b"")
    )


for density, size in DENSITIES.items():
    target = ROOT / f"mipmap-{density}/ic_launcher.png"
    target.write_bytes(draw_icon(size))
    print(f"{target}: {size}x{size}")
