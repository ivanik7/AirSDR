#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate the reproducible SSTV oracle corpus with pySSTV.

Every case is a mono 24000 S/s s16 WAV of *demodulated audio*, the exact
input OpenWebRX+ feeds to csdr-plus SstvDecoder(24000, 300000). The source
image of every mode is saved next to it as PNG. A manifest.json lists every
case with its encoder parameters, its expected csdr-plus mode and the
SHA-256 of each file.

pySSTV (MIT, https://github.com/dnet/pySSTV) is the encoder; it is an
independent implementation, not ours and not csdr-plus. Pillow is its only
dependency. Run with PYTHONPATH pointing at a pySSTV checkout (or an
installed pysstv) and Pillow, e.g.:

    uv venv venv && VIRTUAL_ENV=venv uv pip install pysstv==0.5.9 pillow==12.3.0
    venv/bin/python tool/sstv_oracle/gen_corpus.py OUTDIR [--full]

The default set covers 10 modes plus noise/offset/clock/VOX/negative cases
(~25 min of audio). --full adds the long modes (PD-180/240/290, Scottie DX,
SC2-120).

Nothing here is used by the app at runtime.
"""
import argparse
import hashlib
import json
import math
import os
import random
import struct
import sys
import wave

from PIL import Image, ImageDraw

from pysstv import color, grayscale

RATE = 24000

# pySSTV class -> csdr-plus (VIS, C++ NAME, width, height) it must decode as.
EXPECT = {
    "Robot36": (8, "Robot 36", 320, 240),
    "MartinM1": (44, "Martin 1", 320, 256),
    "MartinM2": (40, "Martin 2", 320, 256),
    "ScottieS1": (60, "Scottie 1", 320, 256),
    "ScottieS2": (56, "Scottie 2", 320, 256),
    "ScottieDX": (76, "Scottie DX", 320, 256),
    "PD90": (99, "PD-90", 320, 256),
    "PD120": (95, "PD-120", 640, 496),
    "PD160": (98, "PD-160", 512, 400),
    "PD180": (96, "PD-180", 640, 496),
    "PD240": (97, "PD-240", 640, 496),
    "PD290": (94, "PD-290", 800, 616),
    "WraaseSC2180": (55, "Wraase SC2-180", 320, 256),
    "WraaseSC2120": (63, "Wraase SC2-120", 320, 256),
    # Not decodable by csdr-plus: VIS 10 (Robot BW24) is unmapped upstream.
    "Robot24BW": None,
}

DEFAULT_MODES = ["Robot36", "MartinM1", "MartinM2", "ScottieS1", "ScottieS2",
                 "PD90", "PD120", "PD160", "WraaseSC2180"]
LONG_MODES = ["ScottieDX", "PD180", "PD240", "PD290", "WraaseSC2120"]


def mode_class(name):
    return getattr(color, name, None) or getattr(grayscale, name)


def make_image(width, height, seed):
    """Deterministic test picture: smooth gradients (natural-image-like
    content), flat colour patches (where levels and colour conversion are
    fully observable) and thin details (resolution/edge smear). Returns the
    image and the patch rectangles [x0, y0, x1, y1] (inclusive)."""
    rnd = random.Random(seed)
    img = Image.new("RGB", (width, height))
    px = img.load()
    for y in range(height):
        v = y / max(1, height - 1)
        for x in range(width):
            u = x / max(1, width - 1)
            r = int(255 * (0.5 + 0.5 * math.sin(2 * math.pi * (u + 0.1 * v))))
            g = int(255 * (0.15 + 0.7 * v))
            b = int(255 * (0.5 + 0.5 * math.cos(2 * math.pi * (u * 0.7 - v * 0.4))))
            px[x, y] = (r, g, b)
    d = ImageDraw.Draw(img)
    # Two rows of four flat patches in the upper half.
    colours = [(255, 255, 255), (0, 0, 0), (255, 0, 0), (0, 255, 0),
               (0, 0, 255), (255, 255, 0), (0, 255, 255), (128, 128, 128)]
    pw, ph = width // 5, height // 6
    gx, gy = (width - 4 * pw) // 5, height // 24
    patches = []
    for i, c in enumerate(colours):
        cx = gx + (i % 4) * (pw + gx)
        cy = gy + (i // 4) * (ph + gy)
        d.rectangle([cx, cy, cx + pw - 1, cy + ph - 1], fill=c)
        patches.append([cx, cy, cx + pw - 1, cy + ph - 1])
    # Thin detail: a circle, diagonal lines and a few random dots.
    r = min(width, height) // 6
    cx, cy = width * 3 // 4, height * 3 // 4
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(255, 255, 255), width=3)
    d.line([0, height - 1, width // 2, height // 2], fill=(0, 0, 0), width=2)
    for _ in range(12):
        x, y = rnd.randrange(width), rnd.randrange(height // 2, height)
        d.rectangle([x, y, x + 3, y + 3], fill=(255, 0, 255))
    return img, patches


def build_encoder(cls, image, offset_hz=0.0, clock_ratio=1.0, vox=False):
    """pySSTV encoder for `cls`. offset_hz shifts every tone (a mistuned SSB
    receiver shifts the whole audio spectrum). clock_ratio renders the
    transmission at RATE*clock_ratio samples/s while the WAV is labelled
    RATE, i.e. a transmitter/receiver sample-clock mismatch."""
    rate = RATE * clock_ratio

    class Enc(cls):
        def gen_freq_bits(self):
            for freq, msec in super().gen_freq_bits():
                yield freq + offset_hz, msec

    enc = Enc(image, rate, 16)
    enc.vox_enabled = vox
    return enc


def write_case(path, enc, amplitude, snr_db, seed, lead_s, trail_s):
    """Renders enc to `path` as 24 kHz s16 mono. The signal is scaled to
    `amplitude` of full scale; white Gaussian noise of the given SNR (signal
    power / noise power over the whole 0-12 kHz audio band) is added to the
    lead, the transmission and the trailer."""
    rnd = random.Random(seed)
    sig = [v * amplitude for v in enc.gen_values()]
    lead = [0.0] * int(lead_s * RATE)
    trail = [0.0] * int(trail_s * RATE)
    sig_power = amplitude * amplitude / 2.0
    noise_sigma = math.sqrt(sig_power / (10 ** (snr_db / 10.0))) if snr_db is not None else 0.0
    out = bytearray()
    clipped = 0
    for v in lead + sig + trail:
        if noise_sigma:
            v += rnd.gauss(0.0, noise_sigma)
        s = int(round(v * 32767))
        if s > 32767 or s < -32768:
            clipped += 1
            s = max(-32768, min(32767, s))
        out += struct.pack("<h", s)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)  # also for clock-error cases: the receiver's clock
        w.writeframes(bytes(out))
    return len(out) // 2, clipped


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def cases(full):
    modes = DEFAULT_MODES + (LONG_MODES if full else [])
    out = [dict(name=f"{m}_clean", mode=m) for m in modes]
    out += [
        dict(name="Robot36_snr10", mode="Robot36", snr_db=10),
        dict(name="Robot36_snr5", mode="Robot36", snr_db=5),
        dict(name="Robot36_snr0", mode="Robot36", snr_db=0),
        dict(name="MartinM1_snr10", mode="MartinM1", snr_db=10),
        dict(name="PD90_snr10", mode="PD90", snr_db=10),
        dict(name="Robot36_off+30", mode="Robot36", offset_hz=30),
        dict(name="Robot36_off-45", mode="Robot36", offset_hz=-45),
        dict(name="Robot36_off+60", mode="Robot36", offset_hz=60),
        dict(name="MartinM1_off+40", mode="MartinM1", offset_hz=40),
        dict(name="ScottieS1_off-30_snr10", mode="ScottieS1", offset_hz=-30, snr_db=10),
        dict(name="MartinM1_clock+500ppm", mode="MartinM1", clock_ratio=1.0005),
        dict(name="ScottieS1_clock-500ppm", mode="ScottieS1", clock_ratio=0.9995),
        dict(name="Robot36_vox", mode="Robot36", vox=True),
        dict(name="Robot24BW_unsupported", mode="Robot24BW"),
    ]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("outdir")
    ap.add_argument("--full", action="store_true")
    ap.add_argument("--only", help="comma-separated case names")
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)
    manifest = {"rate": RATE, "encoder": "pySSTV", "cases": []}
    only = set(args.only.split(",")) if args.only else None
    images = {}
    for i, c in enumerate(cases(args.full)):
        if only and c["name"] not in only:
            continue
        cls = mode_class(c["mode"])
        key = c["mode"]
        if key not in images:
            img, patches = make_image(cls.WIDTH, cls.HEIGHT, seed=1000 + len(images))
            src = os.path.join(args.outdir, f"src_{key}.png")
            img.save(src)
            images[key] = (img, src, patches)
        img, src, patches = images[key]
        enc = build_encoder(cls, img, c.get("offset_hz", 0.0), c.get("clock_ratio", 1.0),
                            c.get("vox", False))
        wav = os.path.join(args.outdir, c["name"] + ".wav")
        # 0.25 FS peak leaves >5 sigma headroom for the 0 dB SNR noise.
        n, clipped = write_case(wav, enc, 0.25, c.get("snr_db"), 7000 + i, 1.0, 3.0)
        exp = EXPECT[c["mode"]]
        entry = dict(c, wav=os.path.basename(wav), source=os.path.basename(src),
                     source_size=[cls.WIDTH, cls.HEIGHT], patches=patches,
                     lead_samples=RATE, samples=n, seconds=n / RATE,
                     clipped_samples=clipped, wav_sha256=sha256(wav),
                     source_sha256=sha256(src),
                     expect=None if exp is None else dict(vis=exp[0], name=exp[1],
                                                          width=exp[2], height=exp[3]))
        manifest["cases"].append(entry)
        print(f"{c['name']}: {n / RATE:.1f} s, clipped={clipped}", flush=True)
    with open(os.path.join(args.outdir, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)


if __name__ == "__main__":
    sys.exit(main())
