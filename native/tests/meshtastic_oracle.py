#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate/check native Meshtastic packet-layer vectors against OpenWebRX+.

The expected output of every vector is produced by the *unmodified*
OpenWebRX+ owrx/meshtastic.py (MeshtasticParser.parsePacket) imported from
~/prj/ref/openwebrx/openwebrx-plus, with only its OpenWebRX infrastructure
imports (map, reporting, storage, config, colours, bandplan) replaced by
inert stubs. Packets are serialized with the official Meshtastic Python
protobufs and encrypted with PyCryptodome AES-CTR, exactly what
OpenWebRX+ uses to decrypt. The committed fixture is consumed by
native/tests/meshtastic_packet_test.cpp; the app never runs Python.

Usage (host only):
  uv run --no-project --python 3.12 --with meshtastic==2.7.11 \
      --with pycryptodomex==3.24.0 native/tests/meshtastic_oracle.py [--check]
Without --check the fixture is (re)written; with --check it is compared.
"""
import argparse
import base64
import importlib
import json
import struct
import sys
import tempfile
import types
from pathlib import Path

from Cryptodome.Cipher import AES
from Cryptodome.Util import Counter
from meshtastic.protobuf import (admin_pb2, mesh_pb2, paxcount_pb2,
                                 portnums_pb2, telemetry_pb2)

ROOT = Path(__file__).resolve().parents[2]
OWRX = Path.home() / "prj/ref/openwebrx/openwebrx-plus"
# Reference commit used to produce the committed fixture.
OWRX_COMMIT = "f1e0d1ac7dfac3732f2981078e8bf7fff63d9764"
FIXTURE = ROOT / "native/tests/data/meshtastic_vectors.json"
DEFAULT_KEY = bytes.fromhex("d4f1bb3a20290759f0bcffabcf4e6901")
FREQ = 869525000
# Keys OpenWebRX+ adds that depend on wall clock or presentation only.
VOLATILE = ["timestamp", "color", "symbol"]


def load_owrx():
    """Import the real owrx/meshtastic.py with stub infrastructure modules."""
    pkg = types.ModuleType("owrx")
    pkg.__path__ = [str(OWRX / "owrx")]
    sys.modules["owrx"] = pkg

    def stub(name, **attrs):
        mod = types.ModuleType("owrx." + name)
        for key, value in attrs.items():
            setattr(mod, key, value)
        sys.modules["owrx." + name] = mod
        setattr(pkg, name, mod)

    class TextParser:
        def __init__(self, filePrefix=None, service=False):
            self.frequency = 0

        def setDialFrequency(self, frequency):
            self.frequency = frequency

    class ColorCache:
        def getColor(self, key):
            return "#000000"

    class _Shared:
        _inst = None

        @classmethod
        def getSharedInstance(cls):
            if cls._inst is None:
                cls._inst = cls()
            return cls._inst

    class ReportingEngine(_Shared):
        def spot(self, out):
            pass

    class Map(_Shared):
        def updateLocation(self, *args, **kwargs):
            pass

    class LatLngLocation:
        def __init__(self, lat, lon):
            self.lat, self.lon = lat, lon

        def __dict__(self):
            return {"lat": self.lat, "lon": self.lon}

    class Bandplan(_Shared):
        def findBand(self, frequency):
            return None

    tmp = tempfile.mkdtemp(prefix="owrx-mesh-")

    class Storage:
        @staticmethod
        def getFilePath(name):
            return str(Path(tmp) / name)

    class Config:
        @staticmethod
        def get():
            return {"map_position_retention_time": 7200}

    stub("toolbox", TextParser=TextParser)
    stub("color", ColorCache=ColorCache)
    stub("reporting", ReportingEngine=ReportingEngine)
    stub("map", Map=Map, LatLngLocation=LatLngLocation)
    stub("bands", Bandplan=Bandplan, Band=object)
    stub("storage", Storage=Storage)
    stub("config", Config=Config)
    import logging
    logging.disable(logging.CRITICAL)  # owrx logs a cache-file miss
    return importlib.import_module("owrx.meshtastic")


def header(dst, src, pid, hop_limit, hop_start, chash, want_ack=False,
           via_mqtt=False, next_hop=0, relay=0):
    flags = (hop_limit & 7) | (8 if want_ack else 0) | (16 if via_mqtt else 0) \
        | ((hop_start & 7) << 5)
    return struct.pack("<IIIBBBB", dst, src, pid, flags, chash, next_hop, relay)


def chash(name, key):
    h = 0
    for b in name.encode() + key:
        h ^= b
    return h


def encrypt(key, pid, src, plain):
    ctr = Counter.new(32, prefix=pid.to_bytes(8, "little") + src.to_bytes(4, "little"),
                      initial_value=0)
    return AES.new(key, AES.MODE_CTR, counter=ctr).encrypt(plain)


def data_msg(port, payload, **extra):
    d = mesh_pb2.Data(portnum=port, payload=payload, **extra)
    return d.SerializeToString()


def build_vectors():
    """Return (name, config, packets[]) groups; each packet has bytes + notes."""
    groups = []
    k = DEFAULT_KEY
    lf = chash("LongFast", k)
    n1, n2, n3 = 0xDA6354B4, 0x433C1A2B, 0x9E7F0001

    def pkt(src, pid, port, payload, dst=0xFFFFFFFF, key=k, h=lf, hl=3, hs=3,
            **kw):
        body = encrypt(key, pid, src, data_msg(port, payload, **kw))
        return header(dst, src, pid, hl, hs, h) + body

    default = []
    # Real over-the-air LongFast packet published by meshtastic_sdr
    # (gitlab.com/crankylinuxuser/meshtastic_sdr, GPL-3.0, commit 2ff1a68,
    # python scripts/meshtastic_gnuradio_RX.py "SDR output example data").
    default.append({"name": "real_meshtastic_sdr_text",
                    "hex": "ffffffffb45463dab971aa8c6308000078aacf76587a5a4cf4a20e2c1d0349ab3f72",
                    "notes": "real capture, default key, TEXT_MESSAGE_APP"})
    user = mesh_pb2.User(id="!433c1a2b", long_name="Test Heltec V3",
                         short_name="TST", macaddr=bytes.fromhex("48ca433c1a2b"),
                         hw_model=mesh_pb2.HELTEC_V3, role=0,
                         public_key=bytes(range(32)))
    default.append({"name": "nodeinfo", "bytes": pkt(n2, 0x11111111, 4, user.SerializeToString())})
    pos = mesh_pb2.Position(latitude_i=516789012, longitude_i=-1234567,
                            altitude=153, time=1791500000,
                            location_source=mesh_pb2.Position.LOC_INTERNAL,
                            precision_bits=32, ground_speed=3, sats_in_view=9)
    default.append({"name": "position", "bytes": pkt(n2, 0x11111112, 3, pos.SerializeToString())})
    default.append({"name": "text_utf8_after_nodeinfo",
                    "bytes": pkt(n2, 0x11111113, 1, "Привет, mesh! 📡".encode())})
    default.append({"name": "text_invalid_utf8",
                    "bytes": pkt(n1, 0x11111114, 1, b"ok\xff\xfe\xe2\x82 end")})
    tel = telemetry_pb2.Telemetry(time=1791500100, device_metrics=telemetry_pb2.DeviceMetrics(
        battery_level=87, voltage=4.105, channel_utilization=12.34,
        air_util_tx=1.5, uptime_seconds=86400))
    default.append({"name": "telemetry_device", "bytes": pkt(n2, 0x11111115, 67, tel.SerializeToString())})
    env = telemetry_pb2.Telemetry(time=1791500200, environment_metrics=telemetry_pb2.EnvironmentMetrics(
        temperature=21.7, relative_humidity=48.25, barometric_pressure=1013.1, iaq=55))
    default.append({"name": "telemetry_environment", "bytes": pkt(n3, 0x11111116, 67, env.SerializeToString())})
    default.append({"name": "routing_ack_none",
                    "bytes": pkt(n1, 0x11111117, 5, mesh_pb2.Routing(error_reason=0).SerializeToString(),
                                 dst=n2, request_id=0x11111113)})
    default.append({"name": "routing_error",
                    "bytes": pkt(n1, 0x11111118, 5,
                                 mesh_pb2.Routing(error_reason=mesh_pb2.Routing.NO_RESPONSE).SerializeToString(),
                                 dst=n2, hl=1, hs=3)})
    route = mesh_pb2.RouteDiscovery(route=[n3], snr_towards=[24, -8], route_back=[n3], snr_back=[12])
    default.append({"name": "traceroute", "bytes": pkt(n2, 0x11111119, 70, route.SerializeToString(), dst=n1)})
    neigh = mesh_pb2.NeighborInfo(node_id=n2, last_sent_by_id=n2, node_broadcast_interval_secs=900,
                                  neighbors=[mesh_pb2.Neighbor(node_id=n1, snr=6.75),
                                             mesh_pb2.Neighbor(node_id=n3, snr=-3.5)])
    default.append({"name": "neighborinfo", "bytes": pkt(n2, 0x1111111A, 71, neigh.SerializeToString())})
    wp = mesh_pb2.Waypoint(id=7, latitude_i=516780000, longitude_i=-1230000, name="Camp",
                           description="base", icon=0x1F3D5, expire=1791600000)
    default.append({"name": "waypoint", "bytes": pkt(n2, 0x1111111B, 8, wp.SerializeToString())})
    pax = paxcount_pb2.Paxcount(wifi=12, ble=30, uptime=3600)
    default.append({"name": "paxcounter", "bytes": pkt(n3, 0x1111111C, 34, pax.SerializeToString())})
    admin = admin_pb2.AdminMessage(get_owner_request=True)
    default.append({"name": "admin_raw", "bytes": pkt(n1, 0x1111111D, 6, admin.SerializeToString(), dst=n2),
                    "ignore": ["data"],
                    "notes": "ADMIN_APP: OpenWebRX+ decodes AdminMessage; native keeps raw payload"})
    default.append({"name": "detection_sensor_raw",
                    "bytes": pkt(n3, 0x1111111E, 10, b"Motion detected")})
    default.append({"name": "duplicate_dropped", "bytes": pkt(n2, 0x11111113, 1, b"dup"),
                    "expect_drop": "duplicate"})
    default.append({"name": "header_only", "bytes": header(0xFFFFFFFF, n1, 0x1111111F, 3, 3, lf)})
    default.append({"name": "short_dropped", "bytes": bytes(15), "expect_drop": "bad_length"})
    other = bytes.fromhex("000102030405060708090a0b0c0d0e0f")
    default.append({"name": "unknown_key_hash_mismatch",
                    "bytes": pkt(n1, 0x11111120, 1, b"secret", key=other, h=chash("Secret", other)),
                    "encrypted": "unknown_key",
                    "notes": "OpenWebRX+ tries the default key regardless of channel hash"})
    groups.append({"name": "default", "psk": "AQ==", "config": {"v": 1}, "packets": default})

    key256 = bytes(range(0x20, 0x40))
    psk256 = base64.b64encode(key256).decode()
    hk = chash("Ops", key256)
    custom = [{"name": "aes256_text",
               "bytes": pkt(n1, 0x22220001, 1, b"AES-256 channel", key=key256, h=hk)},
              {"name": "aes256_position",
               "bytes": pkt(n1, 0x22220002, 3,
                            mesh_pb2.Position(latitude_i=-337000000, longitude_i=1512000000).SerializeToString(),
                            key=key256, h=hk)}]
    groups.append({"name": "aes256", "psk": psk256,
                   "config": {"v": 1, "channels": [{"name": "Ops", "psk": psk256}],
                              "defaultKeyAllPresets": False},
                   "packets": custom})
    # 16-byte key given as colon-separated hex (OpenWebRX+ accepts this form).
    key128 = bytes.fromhex("8a1f0c55e2d4b6970311aabbccddeeff")
    psk_hex = ":".join(f"{b:02X}" for b in key128)
    h128 = chash("Family", key128)
    groups.append({"name": "aes128_hex", "psk": psk_hex,
                   "config": {"v": 1, "channels": [{"name": "Family", "psk": psk_hex}]},
                   "packets": [{"name": "aes128_text",
                                "bytes": pkt(n3, 0x33330001, 1, b"hex key", key=key128, h=h128)},
                               {"name": "aes128_wrong_key_reported_encrypted",
                                "bytes": pkt(n3, 0x33330002, 1, b"hidden", key=other, h=h128),
                                "encrypted": "failed"}]})
    # Short PSK index 2 ("Ag==") = default key with last byte + 1.
    k2 = DEFAULT_KEY[:-1] + bytes([DEFAULT_KEY[-1] + 1])
    groups.append({"name": "short_psk_index2", "psk": "Ag==",
                   "config": {"v": 1, "preset": "MediumFast",
                              "channels": [{"psk": "Ag=="}]},
                   "packets": [{"name": "short_psk_text",
                                "bytes": pkt(n2, 0x44440001, 1, b"index two", key=k2,
                                             h=chash("MediumFast", k2))}]})
    return groups


def owrx_expected(mesh, group):
    """Run the real OpenWebRX+ parser over a group's packets in order."""
    mesh.MeshtasticCache.sharedInstance = None
    parser = mesh.MeshtasticParser()
    parser.key = mesh._resolve_key(group["psk"])
    parser.setDialFrequency(FREQ)
    results = []
    for p in group["packets"]:
        raw = bytes.fromhex(p["hex"]) if "hex" in p else p["bytes"]
        out = parser.parsePacket(raw)
        if out is not None:
            out = {k: v for k, v in out.items() if k not in VOLATILE}
        results.append((raw, out))
    return results


def fixture():
    mesh = load_owrx()
    groups = []
    for g in build_vectors():
        packets = []
        for p, (raw, out) in zip(g["packets"], owrx_expected(mesh, g)):
            entry = {"name": p["name"], "hex": raw.hex()}
            for key in ("notes", "ignore", "expect_drop", "encrypted"):
                if key in p:
                    entry[key] = p[key]
            if "expect_drop" not in p and out is None:
                raise SystemExit(f"{p['name']}: OpenWebRX+ dropped an unexpected packet")
            if "expect_drop" in p and out is not None:
                raise SystemExit(f"{p['name']}: OpenWebRX+ did not drop the packet")
            # For packets the native layer reports as encrypted, OpenWebRX+
            # either decodes garbage or nothing; only the header is comparable.
            if "encrypted" in p and out is not None:
                out = {k: out[k] for k in ("mode", "comment", "dst", "src", "freq") if k in out}
            entry["owrx"] = out
            packets.append(entry)
        groups.append({"name": g["name"], "config": g["config"], "packets": packets})
    return {
        "generator": "native/tests/meshtastic_oracle.py",
        "reference": f"openwebrx-plus {OWRX_COMMIT} owrx/meshtastic.py MeshtasticParser.parsePacket",
        "python_packages": "meshtastic==2.7.11 protobuf pycryptodomex==3.24.0",
        "freq": FREQ,
        "volatile_keys": VOLATILE,
        "groups": groups,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    data = fixture()
    text = json.dumps(data, indent=1, ensure_ascii=False, sort_keys=False) + "\n"
    if args.check:
        current = FIXTURE.read_text(encoding="utf-8")
        if current != text:
            print("fixture differs from regenerated oracle output", file=sys.stderr)
            return 1
        print(f"OK: {FIXTURE.relative_to(ROOT)} matches OpenWebRX+ oracle")
        return 0
    FIXTURE.parent.mkdir(parents=True, exist_ok=True)
    FIXTURE.write_text(text, encoding="utf-8")
    n = sum(len(g["packets"]) for g in data["groups"])
    print(f"wrote {n} vectors to {FIXTURE.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
