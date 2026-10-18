// SPDX-License-Identifier: GPL-3.0-or-later
// Same-IQ comparison: unmodified upstream lorarx CLI (OpenWebRX+
// MeshcoreDemodulator argv) vs the app registry `meshcore` backend on the same
// loratx IQ. Every generated packet must be CRC-valid in upstream, byte-equal
// in native `raw`, and carry the same SF/CR. Native must also verify the ADVERT
// signature and authenticate/decrypt the Public GRP_TXT. Neither side may
// produce a packet outside the generated set. Duplicate detections of the same
// packet are tolerated (lorarx can re-emit one at EOF).
#include <nlohmann/json.hpp>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <string>
#include <vector>

namespace {
std::string b64(const std::string& hex) {
  static const char* a = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::vector<uint8_t> v;
  for (size_t i = 0; i < hex.size(); i += 2)
    v.push_back(static_cast<uint8_t>(std::strtoul(hex.substr(i, 2).c_str(), nullptr, 16)));
  std::string out;
  for (size_t i = 0; i < v.size(); i += 3) {
    uint32_t x = uint32_t(v[i]) << 16;
    if (i + 1 < v.size()) x |= uint32_t(v[i + 1]) << 8;
    if (i + 2 < v.size()) x |= v[i + 2];
    out += a[(x >> 18) & 63];
    out += a[(x >> 12) & 63];
    out += i + 1 < v.size() ? a[(x >> 6) & 63] : '=';
    out += i + 2 < v.size() ? a[x & 63] : '=';
  }
  return out;
}
int fail(const char* why, const std::string& what = "") {
  std::fprintf(stderr, "FAIL: %s %s\n", why, what.c_str());
  return 1;
}
}  // namespace

int main(int argc, char** argv) {
  if (argc != 6) {
    std::fprintf(stderr, "usage: %s <upstream.jsonl> <native.jsonl> <packets.hex> <sf> <cr>\n",
                 argv[0]);
    return 2;
  }
  const int sf = std::atoi(argv[4]), cr = std::atoi(argv[5]);
  std::ifstream up(argv[1]), nat(argv[2]), hexes(argv[3]);
  if (!up || !nat || !hexes) return 2;
  std::vector<std::string> sent;
  for (std::string l; std::getline(hexes, l);)
    if (!l.empty()) sent.push_back(l);
  if (sent.empty()) return fail("no generated packets");
  std::map<std::string, std::string> by_b64;
  for (const auto& h : sent) by_b64[b64(h)] = h;

  std::map<std::string, nlohmann::json> upstream;  // hex -> first crc:1 row
  for (std::string l; std::getline(up, l);) {
    if (l.empty()) continue;
    auto row = nlohmann::json::parse(l);
    if (row.value("crc", 0) != 1) continue;
    auto it = by_b64.find(row.value("payload", ""));
    if (it == by_b64.end()) return fail("upstream produced an unexpected packet", row.dump());
    upstream.emplace(it->second, row);
  }
  std::map<std::string, nlohmann::json> native;
  for (std::string l; std::getline(nat, l);) {
    if (l.empty()) continue;
    auto row = nlohmann::json::parse(l);
    const std::string raw = row.value("raw", "");
    bool known = false;
    for (const auto& h : sent) known |= h == raw;
    if (!known || row.value("mode", "") != "MeshCore")
      return fail("native produced an unexpected event", row.dump());
    native.emplace(raw, row);
  }
  for (const auto& h : sent) {
    if (!upstream.count(h)) return fail("upstream lorarx missed packet", h);
    if (!native.count(h)) return fail("native backend missed packet", h);
    const auto& u = upstream[h];
    const auto& n = native[h];
    if (u.value("net", -1) != 18 || u.value("sf", 0) != sf || u.value("cr", 0) != cr ||
        u.value("bw", 0.0) != 62500.0)
      return fail("upstream PHY mismatch", u.dump());
    if (n.at("phy").at("sf") != u.at("sf") || n.at("phy").at("cr") != u.at("cr") ||
        n.at("phy").at("bw") != 62.5 || n.at("phy").at("crc") != 1)
      return fail("native PHY differs from upstream", n.dump());
    const std::string type = n.at("header").at("type_name");
    const auto& p = n.at("payload");
    if (type == "ADVERT") {
      if (p.at("signature_valid") != true || p.at("advert").at("name") != "Astana" ||
          p.at("advert").at("latitude") != 51.169392 ||
          p.at("advert").at("longitude") != 71.449074)
        return fail("ADVERT not verified/decoded", n.dump());
    } else if (type == "GRP_TXT") {
      if (p.at("encrypted") != false || p.at("channel") != "Public" ||
          p.at("text") != "Ivan: hello MeshCore" || p.at("sender_timestamp") != 1792300001u)
        return fail("GRP_TXT not authenticated/decrypted", n.dump());
    } else if (type == "ACK") {
      if (p.at("checksum") != 0x04030201u) return fail("ACK checksum", n.dump());
    } else {
      return fail("unexpected type", type);
    }
  }
  std::printf("MeshCore same-IQ parity OK: %zu packets, SF%d CR%d\n", sent.size(), sf, cr);
  return 0;
}
