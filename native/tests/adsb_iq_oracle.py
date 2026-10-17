#!/usr/bin/env python3
"""Compare synthetic SC16 IQ via original dump1090 CLI and native backend.

Build the upstream executable from the pinned source (see docs/status/adsb-oracle.md),
then pass its path and the CMake sdrcore_adsb_backend_test binary as arguments.
No third-party IQ recording or prebuilt binary is needed.
"""
import json
import pathlib
import re
import subprocess
import sys
import tempfile

from generate_adsb_iq import generate, EVEN, ODD


def main(upstream, backend, receiver):
    with tempfile.TemporaryDirectory(prefix="adsb-oracle-") as temporary:
        root = pathlib.Path(temporary)
        for pairs in (1, 2):
            iq = root / f"{pairs}.sc16"
            out = root / f"json-{pairs}"
            out.mkdir()
            generate(iq, pairs)
            reference = subprocess.run(
                [upstream, "--ifile", str(iq), "--iformat", "SC16",
                 "--modeac", "--raw", "--write-json", str(out)],
                capture_output=True, text=True, check=False, timeout=30)
            # Upstream exits 1 at ordinary file EOF ("Abnormal exit.").
            assert reference.returncode in (0, 1), reference.stderr
            raw = re.findall(r"\*([0-9a-fA-F]+);", reference.stdout)
            expected = [frame.hex() for frame in (EVEN, ODD) * pairs]
            assert raw == expected, (raw, expected, reference.stderr)
            original = json.loads((out / "aircraft.json").read_text())
            refs = {item["hex"].upper(): item for item in original["aircraft"]}
            for label, binary in (("float adapter", backend), ("CU8 receiver", receiver)):
                result = subprocess.run([binary, str(iq), str(2 * pairs)],
                                        capture_output=True, text=True, check=True,
                                        timeout=30)
                actual = json.loads(result.stdout)
                tracks = {item["icao"]: item for item in actual["aircraft"]}
                assert refs.keys() == tracks.keys() == {"40621D"}, (refs, tracks)
                for icao in refs:
                    ref, track = refs[icao], tracks[icao]
                    assert ref["messages"] == track["messages"] == 2 * pairs
                    assert ref["alt_baro"] == track["altitude_ft"] == 38000
                    assert ("lat" in ref) == ("latitude" in track)
                    assert ("lon" in ref) == ("longitude" in track)
                    if "lat" in ref:
                        assert abs(ref["lat"] - track["latitude"]) < 0.00001
                        assert abs(ref["lon"] - track["longitude"]) < 0.00001
                    assert abs(ref["rssi"] - track["rssi"]) < 0.1
                assert actual["crc_fixed"] == 0
                print(f"{pairs} pair(s), {label}: {len(raw)} raw reference frames, "
                      f"ICAO {list(tracks)}, position={('lat' in refs['40621D'])}, "
                      "altitude=38000 ft, RSSI within 0.1 dB: match")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("usage: adsb_iq_oracle.py /path/to/upstream/dump1090 "
                 "/path/to/sdrcore_adsb_backend_test /path/to/sdrcore_adsb_tap_test")
    main(sys.argv[1], sys.argv[2], sys.argv[3])
