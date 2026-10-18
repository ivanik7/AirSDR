// SPDX-License-Identifier: GPL-3.0-or-later
// Same-IQ lorarx OpenWebRX+ MeshcoreDemodulator + native registry oracle.
// The oracle binaries are host-only; production embeds the same PHY.
#include <nlohmann/json.hpp>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>

int main(int argc, char** argv) {
  if (argc != 4) {
    std::fprintf(stderr, "usage: %s <upstream.jsonl> <native.jsonl> <packet.hex>\n", argv[0]);
    return 2;
  }
  std::ifstream upstream_file(argv[1]), native_file(argv[2]), hex_file(argv[3]);
  if (!upstream_file || !native_file || !hex_file) return 2;
  std::string upstream_line, native_line, sent_hex;
  std::getline(upstream_file, upstream_line);
  std::getline(native_file, native_line);
  std::getline(hex_file, sent_hex);
  if (upstream_line.empty() || native_line.empty() || sent_hex.empty()) return 1;
  auto upstream = nlohmann::json::parse(upstream_line);
  auto native = nlohmann::json::parse(native_line);
  if (upstream.value("crc", 0) != 1 || upstream.value("net", -1) != 18 ||
      upstream.value("sf", 0) != 8 || upstream.value("cr", 0) != 8 ||
      upstream.value("bw", 0.0) != 62500.0 ||
      native.value("mode", "") != "MeshCore" ||
      native.at("raw") != sent_hex ||
      native.at("phy").at("sf") != upstream.at("sf") ||
      native.at("phy").at("cr") != upstream.at("cr") ||
      native.at("phy").at("bw") != 62.5 ||
      native.at("header").at("type_name") != "ACK" ||
      native.at("payload").at("checksum") != 0x04030201) return 1;
  // Generic OpenWebRX+ LoraParser preserves these fields; unlike native it
  // does not parse a MeshCore packet and leaves the base64 payload intact.
  const std::string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string encoded;
  for (size_t i = 0; i < sent_hex.size(); i += 6) {
    uint32_t val = 0;
    const size_t count = std::min(size_t{3}, (sent_hex.size() - i) / 2);
    for (size_t j = 0; j < count; ++j)
      val |= static_cast<uint32_t>(std::strtoul(sent_hex.substr(i + 2 * j, 2).c_str(), nullptr, 16)) << (16 - j * 8);
    encoded += alphabet[(val >> 18) & 63];
    encoded += alphabet[(val >> 12) & 63];
    encoded += count > 1 ? alphabet[(val >> 6) & 63] : '=';
    encoded += count > 2 ? alphabet[val & 63] : '=';
  }
  if (upstream.at("payload") != encoded) return 1;
  // lorarx occasionally emits the same CRC-valid packet twice at EOF. Accept
  // duplicate detections, but never accept a different packet on either side.
  std::string more;
  while (std::getline(upstream_file, more)) {
    if (!more.empty() && nlohmann::json::parse(more) != upstream) return 1;
  }
  while (std::getline(native_file, more)) {
    if (!more.empty()) {
      auto duplicate = nlohmann::json::parse(more);
      duplicate["timestamp"] = native.at("timestamp");
      if (duplicate != native) return 1;
    }
  }
  std::puts("MeshCore same-IQ lorarx packet/PHY parity OK");
  return 0;
}
