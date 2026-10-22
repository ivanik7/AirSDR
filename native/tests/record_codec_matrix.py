#!/usr/bin/env python3
"""Inspect actual worker outputs with independent ffprobe/ffmpeg decoders."""
import array
import json
import math
import pathlib
import subprocess
import sys
import tempfile


def run(*args):
    return subprocess.check_output(args, stderr=subprocess.PIPE)


def verify(path, fmt, channels, duration, start_frame):
    info = json.loads(run("ffprobe", "-v", "error", "-show_entries",
                          "stream=codec_name,sample_rate,channels,start_time:format=duration",
                          "-of", "json", str(path)))
    stream = info["streams"][0]
    codec = {1: "pcm_s16le", 2: "flac", 3: "mp3", 4: "opus"}[fmt]
    assert stream["codec_name"] == codec, (path, stream)
    assert int(stream["channels"]) == channels, (path, stream)
    assert int(stream["sample_rate"]) == 48000, (path, stream)
    assert "duration" in info["format"], (path, info)
    length = float(info["format"]["duration"])
    # FFprobe's Ogg duration includes the preskip (also for ffmpeg's own Opus
    # output). Read OpusHead's actual preskip and compare audible duration.
    preskip = 0
    if fmt == 4:
        prefix = path.read_bytes()[:100]
        pos = prefix.index(b"OpusHead")
        preskip = int.from_bytes(prefix[pos + 10:pos + 12], "little")
    presented = length - preskip / 48000
    assert abs(presented - duration) < (0.055 if fmt == 3 else 0.005), (path, presented, duration)
    samples = array.array("f")
    samples.frombytes(run("ffmpeg", "-v", "error", "-i", str(path),
                          "-f", "f32le", "-acodec", "pcm_f32le", "-"))
    assert abs(len(samples) / channels / 48000 - duration) < (0.055 if fmt == 3 else 0.005), path
    # Lossless sample oracle: nearest PCM16 LSB across continuous and sliced files.
    if fmt in (1, 2):
        assert len(samples) == round(duration * 48000) * channels, path
        for frame in range(round(duration * 48000)):
            t = (start_frame + frame) / 48000
            for channel in range(channels):
                freq, amplitude = (440, .55) if channel == 0 else (770, .35)
                ref = amplitude * math.sin(2 * math.pi * freq * t)
                quantized = max(-32768, min(32767, round(ref * 32768))) / 32768
                assert abs(samples[frame * channels + channel] - quantized) < 1.1 / 32768, (path, frame)
    else:
        # Lossy codecs may have delay/padding: compare spectral tone and
        # channel isolation to independently generated reference PCM.
        n = len(samples) // channels
        for channel in range(channels):
            data = samples[n // 4 * channels + channel: 3 * n // 4 * channels: channels]
            rms = math.sqrt(sum(x * x for x in data) / len(data))
            assert .09 < rms < .55, (path, channel, rms)
            def magnitude(freq):
                real = sum(x * math.cos(2 * math.pi * freq * i / 48000) for i, x in enumerate(data))
                imag = sum(x * math.sin(2 * math.pi * freq * i / 48000) for i, x in enumerate(data))
                return math.hypot(real, imag)
            own, other = (440, 770) if channel == 0 else (770, 440)
            if channels == 2:
                assert magnitude(own) > 5 * magnitude(other), (path, channel)
            assert magnitude(own) > len(data) * .04, (path, channel)


def main():
    with tempfile.TemporaryDirectory(prefix="airsdr-codec-") as temp:
        run(sys.argv[1], temp)
        cases = 0
        for fmt in range(1, 5):
            for channels in (1, 2):
                for streams in (2, 4, 6):
                    folder = pathlib.Path(temp) / f"{fmt}-{channels}-{streams}"
                    extension = {1: ".wav", 2: ".flac", 3: ".mp3", 4: ".opus"}[fmt]
                    files = list(folder.iterdir())
                    assert len(files) == int(bool(streams & 2)) + 2 * int(bool(streams & 4)), files
                    assert all(p.suffix == extension for p in files), files
                    for path in files:
                        name = path.name
                        if "_sq1" in name:
                            verify(path, fmt, channels, .2, 0)
                        elif "_sq2" in name:
                            verify(path, fmt, channels, .2, 24000)
                        else:
                            verify(path, fmt, channels, 1.0, 0)
                        cases += 1
        for fmt in range(1, 5):
            for frames in (123, 1000):
                folder = pathlib.Path(temp) / f"short-{fmt}-{frames}"
                files = list(folder.iterdir())
                assert len(files) == 1, files
                info = json.loads(run("ffprobe", "-v", "error", "-show_entries",
                                      "stream=codec_name,sample_rate,channels", "-of", "json", str(files[0])))
                stream = info["streams"][0]
                assert stream["codec_name"] == {1: "pcm_s16le", 2: "flac", 3: "mp3", 4: "opus"}[fmt]
                assert int(stream["sample_rate"]) == 48000 and stream["channels"] == 1
                decoded = run("ffmpeg", "-v", "error", "-i", str(files[0]),
                              "-f", "f32le", "-acodec", "pcm_f32le", "-")
                decoded_frames = len(decoded) // 4
                assert abs(decoded_frames - frames) <= (2304 if fmt == 3 else 1), (files[0], decoded_frames)
                if fmt in (1, 2):
                    samples = array.array("f")
                    samples.frombytes(decoded)
                    assert all(abs(sample - .25) < 1 / 32768 for sample in samples)
                cases += 1
        print(f"Verified {cases} files across 24 format/channel/segmentation cases and 8 short clips")


if __name__ == "__main__":
    main()
