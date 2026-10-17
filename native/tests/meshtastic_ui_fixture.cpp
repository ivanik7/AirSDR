// SPDX-License-Identifier: GPL-3.0-or-later
//
// Generates (or checks) the Dart UI fixture test/ui/fixtures/
// meshtastic_native_events.json: the real native PacketParser output for the
// packets of data/meshtastic_vectors.json, with deterministic PHY metadata in
// the lorarx field set. The Flutter packet/node UI tests consume this file,
// so the UI is tested against events the native layer actually emits.
//
//   sdrcore_meshtastic_ui_fixture <vectors.json> <fixture.json> [--write]
//
// Without --write it exits non-zero if the committed fixture is stale.
#include <cmath>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "meshtastic/meshtastic.h"

namespace mt = sdrcore::meshtastic;
using Json = nlohmann::json;

namespace {

std::vector<uint8_t> hex(const std::string& s) {
  std::vector<uint8_t> out;
  for (size_t i = 0; i + 1 < s.size(); i += 2)
    out.push_back(static_cast<uint8_t>(std::stoi(s.substr(i, 2), nullptr, 16)));
  return out;
}

Json generate(const Json& vectors) {
  Json groups = Json::array();
  for (const auto& g : vectors["groups"]) {
    mt::ParserConfig cfg;
    std::string err;
    if (!mt::parse_config_json(g["config"].dump(), cfg, &err)) {
      std::fprintf(stderr, "config %s: %s\n", g["name"].get<std::string>().c_str(),
                   err.c_str());
      std::exit(2);
    }
    mt::PacketParser parser;
    if (!parser.configure(cfg, &err)) std::exit(2);
    Json events = Json::array();
    int64_t t = 0;
    int i = 0;
    for (const auto& p : g["packets"]) {
      auto bytes = hex(p["hex"].get<std::string>());
      t += 1000;
      mt::PhyMeta m;
      m.timestamp_ms = 1791500000000 + t;
      m.monotonic_ms = t;
      m.frequency_hz = 869525000;
      m.crc = 1;
      m.bw_khz = 250.0;
      m.sf = 11;
      m.cr = 5;
      m.inverted = 0;
      m.preamble = 16;
      m.duration_ms = 400 + 10 * i;
      m.level_db = 10.5 + i;
      m.snr_db = 11.0 - 0.5 * i;
      m.noise_floor_db = -34.0;
      m.afc_hz = 0;
      m.fec = 0;
      ++i;
      mt::DropReason why;
      auto ev = parser.parse(bytes.data(), bytes.size(), m, &why);
      if (!ev) continue;  // drops never reach the UI
      Json e = Json::parse(*ev);
      e["fixture"] = p["name"];
      events.push_back(std::move(e));
    }
    Json cfg_out = g["config"];
    groups.push_back({{"name", g["name"]}, {"config", cfg_out}, {"events", events}});
  }
  return {{"generator", "native/tests/meshtastic_ui_fixture.cpp"},
          {"source", "native/tests/data/meshtastic_vectors.json"},
          {"groups", groups}};
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: %s vectors.json fixture.json [--write]\n", argv[0]);
    return 2;
  }
  std::ifstream in(argv[1]);
  if (!in.good()) return 2;
  const std::string out = generate(Json::parse(in)).dump(1) + "\n";
  if (argc > 3 && std::string(argv[3]) == "--write") {
    std::ofstream(argv[2]) << out;
    std::printf("wrote %s\n", argv[2]);
    return 0;
  }
  std::ifstream cur(argv[2]);
  std::stringstream ss;
  ss << cur.rdbuf();
  if (ss.str() != out) {
    std::fprintf(stderr, "%s is stale; rerun with --write\n", argv[2]);
    return 1;
  }
  std::printf("meshtastic UI fixture matches native parser output\n");
  return 0;
}
