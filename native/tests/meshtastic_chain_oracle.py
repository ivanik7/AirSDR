#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare OpenWebRX+ lorarx + actual parser and the native backend on one IQ file.

Run with uv as documented in docs/status/meshtastic-parity.md. The external
OpenWebRX+ checkout is an oracle only; no Python is loaded by the application.
"""
import argparse
import base64
import json
import subprocess
import sys
import tempfile
from pathlib import Path

from meshtastic_oracle import DEFAULT_KEY, chash, load_owrx

BW = {"LongFast": 8, "MediumSlow": 8, "MediumFast": 8,
      "ShortSlow": 8, "ShortFast": 8, "NarrowFast": 6,
      "NarrowSlow": 6, "LongMod": 7, "LiteFast": 7,
      "LiteSlow": 7, "ShortTurbo": 9, "MediumTurbo": 9,
      "LongTurbo": 9}
SF = {"LongFast": 11, "MediumSlow": 10, "MediumFast": 9,
      "ShortSlow": 8, "ShortFast": 7, "NarrowFast": 7,
      "NarrowSlow": 8, "LongMod": 11, "LiteFast": 9,
      "LiteSlow": 10, "ShortTurbo": 7, "MediumTurbo": 9,
      "LongTurbo": 11}
CR = {"LongMod": 8, "LongTurbo": 8, "NarrowFast": 6, "NarrowSlow": 6}
BW_KHZ = {6: 62.5, 7: 125.0, 8: 250.0, 9: 500.0}
FREQUENCY = 869525000


def run(args):
    return subprocess.run(args, capture_output=True, check=True).stdout


def compare(case, raw, oracle, native):
    """Compare lorarx bytes/PHY, then OWRX+ parsed fields against native event."""
    name, preset, config, crc = case
    expected = 1 if crc else 0
    if len(oracle) != 1:
        raise AssertionError(f"{name}: expected one lorarx frame, got {len(oracle)}")
    phy = oracle[0]
    decoded = base64.b64decode(phy["payload"], validate=True)
    if crc:
        assert decoded == raw, f"{name}: PHY bytes differ from transmitted Meshtastic frame"
    assert phy["sf"] == SF[preset] and phy["cr"] == CR.get(preset, 5)
    assert phy["bw"] == BW_KHZ[BW[preset]] * 1000
    assert phy["net"] == 43 and phy["crc"] == expected
    if len(native) != expected:
        raise AssertionError(f"{name}: native events {len(native)}, expected {expected}")
    if not crc:
        mesh = load_owrx()
        parser = mesh.MeshtasticParser()
        assert parser.parse(json.dumps(phy).encode()) is None
        print(f"{name}: corrupted decoded bytes, SF/BW/CR/net; crc=0 dropped by both parsers")
        return
    event = native[0]
    meta = event["phy"]
    for key in ("crc", "sf", "cr", "invers", "preamb", "duration", "afc", "fec"):
        assert meta[key] == phy[key], (name, key, meta[key], phy[key])
    assert meta["bw"] == phy["bw"] / 1000
    # The backend copies lorarx's parsed doubles unchanged.
    for key in ("snr", "level", "nfloor", "pknfloor"):
        assert meta[key] == phy[key], (name, key, meta[key], phy[key])
    from datetime import datetime, timezone
    now_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
    assert abs(event["timestamp"] - now_ms) < 30000, (name, event["timestamp"])
    # Header bytes are the ground truth: OpenWebRX+ doesn't include the packet
    # id/channel hash/hop flags in its output.
    assert event["packet_id"] == int.from_bytes(raw[8:12], "little")
    assert event["channel_hash"] == raw[13] and event["freq"] == FREQUENCY
    mesh = load_owrx()
    mesh.MeshtasticCache.sharedInstance = None
    parser = mesh.MeshtasticParser()
    parser.key = mesh._resolve_key(config["psk"])
    parser.setDialFrequency(FREQUENCY)
    parsed = parser.parse(json.dumps(phy).encode())
    assert parsed is not None, f"{name}: OWRX+ parser rejected lorarx JSON"
    assert event["encrypted"] is False, f"{name}: native could not decrypt the packet"
    assert "type" in parsed and parsed["type"] == event["type"], (name, parsed, event)
    for field in ("mode", "src", "dst", "comment", "freq", "type", "message",
                  "lat", "lon", "altitude", "battery", "uptime", "channelUse",
                  "airtimeUse", "weather", "data"):
        if field in parsed:
            assert field in event, (name, field, parsed[field], event)
            a, b = parsed[field], event[field]
            if isinstance(a, (int, float)) and not isinstance(a, bool):
                assert abs(a - b) < 0.001, (name, field, a, b)
            else:
                assert a == b, (name, field, a, b)
    # The parsers are independent calls, so their wall-clock timestamps need
    # only be close; OWRX+ lacks PHY fields and has its own presentation keys.
    assert abs(event["timestamp"] - parsed["timestamp"]) < 30000
    print(f"{name}: identical bytes, PHY values, CRC, decryption and OWRX+ fields")


def main():
    ap = argparse.ArgumentParser()
    for arg in ("loratx", "lorarx", "native_replay", "vectors"):
        ap.add_argument(arg, type=Path)
    args = ap.parse_args()
    groups = {g["name"]: g for g in json.loads(args.vectors.read_text())["groups"]}
    # Real on-air *packet bytes* come from meshtastic_sdr; the IQ here is a
    # synthetic retransmission, not an over-the-air IQ capture.
    specs = [
        ("on_air_bytes_longfast", "default", "real_meshtastic_sdr_text", "LongFast", True),
        ("on_air_bytes_mediumfast", "default", "real_meshtastic_sdr_text", "MediumFast", True),
        ("on_air_bytes_mediumslow", "default", "real_meshtastic_sdr_text", "MediumSlow", True),
        ("on_air_bytes_shortslow", "default", "real_meshtastic_sdr_text", "ShortSlow", True),
        ("on_air_bytes_narrowfast", "default", "real_meshtastic_sdr_text", "NarrowFast", True),
        ("on_air_bytes_narrowslow", "default", "real_meshtastic_sdr_text", "NarrowSlow", True),
        ("on_air_bytes_longmod", "default", "real_meshtastic_sdr_text", "LongMod", True),
        ("on_air_bytes_litefast", "default", "real_meshtastic_sdr_text", "LiteFast", True),
        ("on_air_bytes_liteslow", "default", "real_meshtastic_sdr_text", "LiteSlow", True),
        ("on_air_bytes_shortturbo", "default", "real_meshtastic_sdr_text", "ShortTurbo", True),
        ("on_air_bytes_mediumturbo", "default", "real_meshtastic_sdr_text", "MediumTurbo", True),
        ("on_air_bytes_longturbo", "default", "real_meshtastic_sdr_text", "LongTurbo", True),
        ("nodeinfo", "default", "nodeinfo", "LongFast", True),
        ("position", "default", "position", "LongFast", True),
        ("telemetry", "default", "telemetry_device", "LongFast", True),
        ("aes256_text", "aes256", "aes256_text", "ShortFast", True),
        ("aes128_text", "aes128_hex", "aes128_text", "MediumFast", True),
        ("bad_crc", "default", "real_meshtastic_sdr_text", "ShortFast", False),
    ]
    with tempfile.TemporaryDirectory(prefix="meshtastic-chain-") as tmp:
        work = Path(tmp)
        for name, group, vector, preset, crc in specs:
            packet = next(v for v in groups[group]["packets"] if v["name"] == vector)
            raw = bytes.fromhex(packet["hex"])
            if group == "default" and preset != "LongFast":
                # Reuse genuine on-air ciphertext with the firmware's channel
                # hash for the selected PHY preset; the nonce is unchanged.
                raw = raw[:13] + bytes([chash(preset, DEFAULT_KEY)]) + raw[14:]
            config = groups[group]["config"]
            channel = config.get("channels", [])
            psk = channel[0]["psk"] if channel else "AQ=="
            rx_config = {"version": 1, "settings": {"preset": preset, "region": "EU_868",
                                                    "channels": channel}}
            hexfile, iq, output = (work / f"{name}.{ext}" for ext in ("hex", "f32", "jsonl"))
            hexfile.write_text(raw.hex() + "\n")
            tx = [str(args.loratx), "-i", str(hexfile), "-H", "-f", "f32", "-r", "1000000",
                  "-b", str(BW[preset]), "-s", str(SF[preset]), "-c", str(CR.get(preset, 5)), "-N", "2B",
                  "-C", "-z", "10", "-o", str(iq)]
            if not crc:
                tx += ["-T", "20", "0", "-T", "21", "0", "-T", "22", "0"]
            run(tx)
            run([str(args.lorarx), "-i", str(iq), "-r", "1000000", "-f", "f32",
                 "-v", "-N", "-Q", "-H", "5", "-W", "50", "-b", str(BW[preset]),
                 "-s", "7", "-s", "8", "-s", "9", "-s", "10", "-s", "11",
                 "-j", str(output)])
            oracle = [json.loads(line) for line in output.read_text().splitlines()]
            native = [json.loads(line) for line in run([
                str(args.native_replay), str(iq), json.dumps(rx_config),
                str(FREQUENCY)]).splitlines()]
            compare((name, preset, {"psk": psk}, crc), raw, oracle, native)
    print(f"PASS: {len(specs)} identical-IQ chain comparisons")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, subprocess.CalledProcessError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
