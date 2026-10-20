#!/usr/bin/env python3
"""Validate pulled Android SAF output from a generated-IQ recording session.

Usage: python3 tool/verify_recording_emulator.py DIR AirSDR_YYYY-MM-DD_HH-MM-
The prefix must select only one four-format run; older files are ignored.
"""
import json
import pathlib
import subprocess
import sys


def main(folder: pathlib.Path, prefix: str) -> None:
    files = sorted(path for path in folder.glob(prefix + "*") if path.is_file())
    assert files, f"No SAF files match {prefix!r} in {folder}"
    formats = {".wav": "pcm_s16le", ".flac": "flac", ".mp3": "mp3", ".opus": "opus"}
    for extension, codec in formats.items():
        outputs = [path for path in files if path.suffix == extension]
        assert len(outputs) == 2, (extension, outputs)
        assert sum("_sq1" in path.stem for path in outputs) == 1, outputs
        for path in outputs:
            info = json.loads(subprocess.check_output([
                "ffprobe", "-v", "error", "-show_entries",
                "stream=codec_name,channels,sample_rate:format=duration", "-of", "json", str(path),
            ]))
            stream = info["streams"][0]
            assert (stream["codec_name"], stream["channels"], stream["sample_rate"]) == (codec, 2, "48000"), (path, info)
            assert float(info["format"]["duration"]) > 0.1, (path, info)
            decoded = subprocess.check_output([
                "ffmpeg", "-v", "error", "-i", str(path), "-f", "s16le", "-acodec", "pcm_s16le", "-",
            ])
            assert len(decoded) > 1000 and any(decoded), (path, len(decoded))
            print(f"{path.name}: {codec}, stereo 48000 Hz, {info['format']['duration']} s, decoded {len(decoded)} bytes")
    data = [path for path in files if path.name.endswith(".sigmf-data")]
    meta = [path for path in files if path.name.endswith(".sigmf-meta")]
    assert len(data) == len(meta) == 4, (data, meta)
    for path in data:
        sibling = path.with_name(path.name.removesuffix(".sigmf-data") + ".sigmf-meta")
        assert sibling in meta, path
        info = json.loads(sibling.read_text())
        assert info["global"]["core:datatype"] == "cu8", info
        assert info["global"]["core:sample_rate"] == 300000, info
        assert info["captures"][0]["core:frequency"] == 100000000, info
        raw = path.read_bytes()
        assert len(raw) > 1000 and len(raw) % 2 == 0, (path, len(raw))
        # Synthetic producer writes monotonically incrementing CU8 bytes. A
        # received block may be skipped at a generation boundary; sample inside
        # the first accepted block remains deterministic.
        assert all(raw[i + 1] == (raw[i] + 1) % 256 for i in range(min(4095, len(raw) - 1))), path
        print(f"{path.name}: cu8, 300000 samples/s, 100000000 Hz, {len(raw)} bytes, synthetic oracle passed")
    logs = [path for path in files if path.name.endswith(".jsonl")]
    assert len(logs) == 4, logs
    for path in logs:
        events = [json.loads(line) for line in path.read_text().splitlines()]
        assert events and all(event["decoder_id"] == "rds" for event in events), (path, events)
        assert any(event["payload"]["event"] == "reset" for event in events), (path, events)
        print(f"{path.name}: {len(events)} parsed RDS reset event(s)")
    assert len(files) == 20, len(files)
    print("Verified 20 SAF files, four combined-stream sessions")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: verify_recording_emulator.py DIR SESSION_PREFIX")
    main(pathlib.Path(sys.argv[1]), sys.argv[2])
