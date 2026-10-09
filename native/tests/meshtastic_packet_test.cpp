// SPDX-License-Identifier: GPL-3.0-or-later
//
// Known-vector tests for the native Meshtastic packet layer:
//  * header field extraction and flag bits;
//  * OpenWebRX+ `_resolve_key` input forms + firmware Channels::getKey rules;
//  * firmware channel hash (LongFast/default key = 0x08);
//  * AES-CTR against RFC 3686 and the Meshtastic nonce layout;
//  * full packets against fixture output of the real OpenWebRX+ parser
//    (native/tests/meshtastic_oracle.py, data/meshtastic_vectors.json),
//    including a real over-the-air LongFast packet;
//  * encrypted/unknown-key reporting, plaintext channels, config errors,
//    duplicate suppression and key-material hygiene.
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "meshtastic/meshtastic.h"

#ifndef MESHTASTIC_VECTORS
#error "MESHTASTIC_VECTORS must point at native/tests/data/meshtastic_vectors.json"
#endif

using sdrcore::meshtastic::Key;
using sdrcore::meshtastic::PacketParser;
using sdrcore::meshtastic::ParserConfig;
using sdrcore::meshtastic::PhyMeta;
namespace mt = sdrcore::meshtastic;
using Json = nlohmann::json;

namespace {

int g_failures = 0;
#define CHECK(cond)                                                       \
  do {                                                                    \
    if (!(cond)) {                                                        \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__,         \
                   __LINE__, #cond);                                      \
      ++g_failures;                                                       \
    }                                                                     \
  } while (0)

std::vector<uint8_t> hex(const std::string& s) {
  std::vector<uint8_t> out;
  for (size_t i = 0; i + 1 < s.size(); i += 2)
    out.push_back(static_cast<uint8_t>(std::stoul(s.substr(i, 2), nullptr, 16)));
  return out;
}

std::string key_hex(const Key& k) { return mt::to_hex(k.bytes.data(), k.length); }

PhyMeta meta_at(int64_t ms) {
  PhyMeta m;
  m.timestamp_ms = 1791500000000 + ms;
  m.monotonic_ms = ms;
  m.frequency_hz = 869525000;
  return m;
}

void test_header() {
  // Real packet published by meshtastic_sdr (see oracle script).
  auto p = hex("ffffffffb45463dab971aa8c6308000078aacf76587a5a4cf4a20e2c1d0349ab3f72");
  mt::Header h;
  CHECK(mt::parse_header(p.data(), p.size(), h));
  CHECK(h.dst == 0xFFFFFFFFu);
  CHECK(h.src == 0xDA6354B4u);
  CHECK(h.packet_id == 0x8CAA71B9u);
  CHECK(h.flags == 0x63);
  CHECK(h.hop_limit() == 3 && h.hop_start() == 3);
  CHECK(!h.want_ack() && !h.via_mqtt());
  CHECK(h.channel_hash == 0x08 && h.next_hop == 0 && h.relay_node == 0);
  // flags 0b101_1_1_010: hop_start 5, via_mqtt, want_ack, hop_limit 2
  uint8_t f[16] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 0xBA, 0x77, 0x2A, 0x3C};
  CHECK(mt::parse_header(f, 16, h));
  CHECK(h.dst == 0x04030201u && h.src == 0x08070605u && h.packet_id == 0x0C0B0A09u);
  CHECK(h.hop_limit() == 2 && h.hop_start() == 5 && h.want_ack() && h.via_mqtt());
  CHECK(h.channel_hash == 0x77 && h.next_hop == 0x2A && h.relay_node == 0x3C);
  CHECK(!mt::parse_header(f, 15, h));
}

void test_keys() {
  Key k;
  std::string err;
  const std::string def = "d4f1bb3a20290759f0bcffabcf4e6901";
  for (const char* s : {"AQ==", "aq==", "default", " Default ", "01", "0x01"}) {
    CHECK(mt::resolve_key(s, k, &err));
    CHECK(k.length == 16 && key_hex(k) == def);
  }
  // Unpadded base64 is rejected, like base64.b64decode(validate=True).
  CHECK(!mt::resolve_key("AQ", k, &err));
  CHECK(mt::resolve_key("Ag==", k) && k.length == 16 &&
        key_hex(k) == "d4f1bb3a20290759f0bcffabcf4e6902");
  CHECK(mt::resolve_key("0A", k) && key_hex(k) == "d4f1bb3a20290759f0bcffabcf4e690a");
  // Firmware: short index 0 disables encryption.
  CHECK(mt::resolve_key("AA==", k) && k.length == 0);
  // Full AES-128 / AES-256 in hex (with separators / 0x) and base64.
  CHECK(mt::resolve_key("0x8A:1F:0C:55-E2:D4:B6:97:03:11:AA:BB:CC:DD:EE:FF", k) &&
        k.length == 16 && key_hex(k) == "8a1f0c55e2d4b6970311aabbccddeeff");
  CHECK(mt::resolve_key("ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=", k) &&
        k.length == 32 &&
        key_hex(k) == "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f");
  // Short keys are zero padded to the next AES size.
  CHECK(mt::resolve_key("aabbcc", k) && k.length == 16 &&
        key_hex(k) == "aabbcc00000000000000000000000000");
  CHECK(mt::resolve_key(std::string(34, 'a'), k) && k.length == 32 &&
        key_hex(k).substr(0, 34) == std::string(34, 'a') &&
        key_hex(k).substr(34) == std::string(30, '0'));
  // Rejected inputs; errors never echo the input.
  const std::string secret = "not*a*key";
  CHECK(!mt::resolve_key(secret, k, &err) && err.find(secret) == std::string::npos);
  CHECK(!mt::resolve_key("", k, &err));
  CHECK(!mt::resolve_key(std::string(66, 'b'), k, &err));
}

void test_channel_hash() {
  Key def;
  CHECK(mt::resolve_key("AQ==", def));
  CHECK(mt::channel_hash("LongFast", def) == 0x08);  // observed on air
  // xor of name bytes alone when encryption is disabled
  Key none;
  CHECK(mt::channel_hash("AB", none) == ('A' ^ 'B'));
}

void test_aes_ctr() {
  struct V { const char* key; const char* iv; const char* ct; size_t len; };
  const V vectors[] = {
      // RFC 3686 #1-style vectors used by firmware test_AES_CTR
      {"AE6852F8121067CC4BF7A5765577F39E", "00000030000000000000000000000001",
       "e4095d4fb7a7b3792d6175a3261311b8", 16},
      {"776BEFF2851DB06F4C8A0542C8696F6C6A81AF1EEC96B4D37FC1D689E6C1C104",
       "00000060DB5672C97AA8F0B200000001", "145ad01dbf824ec7560863dc71e3e0c0", 16},
  };
  for (const auto& v : vectors) {
    Key k;
    auto kb = hex(v.key);
    std::copy(kb.begin(), kb.end(), k.bytes.begin());
    k.length = kb.size();
    auto ivb = hex(v.iv);
    std::array<uint8_t, 16> iv;
    std::copy(ivb.begin(), ivb.end(), iv.begin());
    uint8_t out[16];
    mt::aes_ctr(k, iv, reinterpret_cast<const uint8_t*>("Single block msg"), 16, out);
    CHECK(mt::to_hex(out, v.len) == v.ct);
  }
  // RFC 3686 #2 (AES-128) and #8 (AES-256), 32-byte multi-block
  struct M { const char* key; const char* iv; const char* ct; };
  const M multi[] = {
      {"7E24067817FAE0D743D6CE1F32539163", "006CB6DBC0543B59DA48D90B00000001",
       "5104a106168a72d9790d41ee8edad388eb2e1efc46da57c8fce630df9141be28"},
      {"F6D66D6BD52D59BB0796365879EFF886C66DD51A5B6A99744B50590C87A23884",
       "00FAAC24C1585EF15A43D87500000001",
       "f05e231b3894612c49ee000b804eb2a9b8306b508f839d6a5530831d9344af1c"},
      // 32-bit counter wraps inside the last four bytes (pycryptodome)
      {"00000000000000000000000000000000", "0102030405060708090a0b0cffffffff",
       "74b950f9475bd7c9466fc17ac4daff1a5c8d9b4016440c85a1b9d814ef6aee98ab1556451ec1095d"},
  };
  for (const auto& v : multi) {
    Key k;
    auto kb = hex(v.key);
    std::copy(kb.begin(), kb.end(), k.bytes.begin());
    k.length = kb.size();
    auto ivb = hex(v.iv);
    std::array<uint8_t, 16> iv;
    std::copy(ivb.begin(), ivb.end(), iv.begin());
    const size_t n = std::strlen(v.ct) / 2;
    std::vector<uint8_t> pt(n), out(n);
    for (size_t i = 0; i < n; ++i) pt[i] = (n == 40) ? 0 : static_cast<uint8_t>(i);
    mt::aes_ctr(k, iv, pt.data(), n, out.data());
    CHECK(mt::to_hex(out.data(), n) == v.ct);
    mt::aes_ctr(k, iv, out.data(), n, out.data());  // in place, inverse
    CHECK(out == pt);
  }
  // Meshtastic nonce: id LE64 | src LE32 | counter 0
  auto n = mt::packet_nonce(0x8CAA71B9u, 0xDA6354B4u);
  CHECK(mt::to_hex(n.data(), 16) == "b971aa8c00000000b45463da00000000");
}

bool json_equal(const Json& a, const Json& b) {
  if (a.is_number() && b.is_number() && !a.is_boolean() && !b.is_boolean()) {
    if (a.is_number_float() || b.is_number_float()) {
      const double x = a.get<double>(), y = b.get<double>();
      return std::fabs(x - y) <= 1e-9 * std::max(1.0, std::fabs(x));
    }
    return a == b;
  }
  if (a.type() != b.type()) return false;
  if (a.is_object()) {
    if (a.size() != b.size()) return false;
    for (auto it = a.begin(); it != a.end(); ++it)
      if (!b.contains(it.key()) || !json_equal(it.value(), b[it.key()])) return false;
    return true;
  }
  if (a.is_array()) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); ++i)
      if (!json_equal(a[i], b[i])) return false;
    return true;
  }
  return a == b;
}

// Keys the native event adds beyond OpenWebRX+'s parsePacket output.
const std::set<std::string> kNativeExtras = {
    "timestamp", "packet_id", "hop_limit", "hop_start", "want_ack", "via_mqtt",
    "channel_hash", "next_hop", "relay_node", "length", "phy", "encrypted",
    "decrypt", "channel", "channel_index", "request_id", "reply_id", "emoji",
    "raw", "payload_error", "ciphertext", "pki_possible"};

void test_oracle_vectors() {
  std::ifstream in(MESHTASTIC_VECTORS);
  CHECK(in.good());
  if (!in.good()) return;
  Json fx = Json::parse(in);
  size_t compared = 0;
  for (const auto& g : fx["groups"]) {
    ParserConfig cfg;
    std::string err;
    CHECK(mt::parse_config_json(g["config"].dump(), cfg, &err));
    PacketParser parser;
    CHECK(parser.configure(cfg, &err));
    int64_t t = 0;
    for (const auto& p : g["packets"]) {
      const std::string name = g["name"].get<std::string>() + "/" + p["name"].get<std::string>();
      auto bytes = hex(p["hex"].get<std::string>());
      mt::DropReason why;
      auto ev = parser.parse(bytes.data(), bytes.size(), meta_at(t += 1000), &why);
      if (p.contains("expect_drop")) {
        const std::string want = p["expect_drop"];
        const bool ok = !ev && ((want == "duplicate" && why == mt::DropReason::duplicate) ||
                                (want == "bad_length" && why == mt::DropReason::bad_length));
        if (!ok) std::fprintf(stderr, "%s: expected drop %s\n", name.c_str(), want.c_str());
        CHECK(ok);
        continue;
      }
      CHECK(ev.has_value());
      if (!ev) continue;
      Json got = Json::parse(*ev);
      Json want = p["owrx"];
      std::set<std::string> ignore;
      if (p.contains("ignore"))
        for (const auto& k : p["ignore"]) ignore.insert(k.get<std::string>());
      bool ok = true;
      for (auto it = want.begin(); it != want.end(); ++it) {
        if (ignore.count(it.key())) continue;
        if (!got.contains(it.key()) || !json_equal(it.value(), got[it.key()])) {
          std::fprintf(stderr, "%s: key '%s' differs\n  owrx:   %s\n  native: %s\n",
                       name.c_str(), it.key().c_str(), it.value().dump().c_str(),
                       got.contains(it.key()) ? got[it.key()].dump().c_str() : "<missing>");
          ok = false;
        }
      }
      for (auto it = got.begin(); it != got.end(); ++it) {
        if (want.contains(it.key()) || kNativeExtras.count(it.key()) || ignore.count(it.key()))
          continue;
        std::fprintf(stderr, "%s: unexpected native key '%s'\n", name.c_str(), it.key().c_str());
        ok = false;
      }
      if (p.contains("encrypted")) {
        ok = ok && got.value("encrypted", false) &&
             got.value("decrypt", "") == p["encrypted"].get<std::string>() &&
             !got.contains("port") && !got.contains("message") && got.contains("ciphertext");
      } else if (got.contains("port")) {
        ok = ok && got["encrypted"] == false;
      }
      if (ignore.count("data")) ok = ok && got.contains("raw") && !got.contains("data");
      CHECK(ok);
      ++compared;
    }
  }
  CHECK(compared >= 20);
  std::printf("compared %zu packets with OpenWebRX+ oracle output\n", compared);
}

// Native-only semantics (no OpenWebRX+ equivalent): plaintext channels,
// firmware channel-hash selection, unknown keys, PHY metadata, hygiene.
void test_native_semantics() {
  // Plaintext channel "Open" (PSK index 0): Data is not encrypted.
  ParserConfig cfg;
  cfg.channels.push_back({"Open", "AA=="});
  PacketParser parser;
  std::string err;
  CHECK(parser.configure(cfg, &err));
  const uint8_t data[] = {0x08, 0x01, 0x12, 0x02, 'h', 'i'};
  uint8_t pkt[16 + sizeof data] = {0xff, 0xff, 0xff, 0xff, 1, 0, 0, 0, 2, 0, 0, 0, 0x03,
                                   static_cast<uint8_t>('O' ^ 'p' ^ 'e' ^ 'n'), 0, 0};
  std::memcpy(pkt + 16, data, sizeof data);
  PhyMeta m = meta_at(5);
  m.crc = 1;
  m.sf = 11;
  m.bw_khz = 250.0;
  m.cr = 5;
  m.snr_db = -7.25;
  m.level_db = -98.5;
  auto ev = parser.parse(pkt, sizeof pkt, m);
  CHECK(ev.has_value());
  Json j = Json::parse(*ev);
  CHECK(j["decrypt"] == "plaintext" && j["message"] == "hi" && j["channel"] == "Open");
  CHECK(j["channel_index"] == 0);
  CHECK(j["phy"]["sf"] == 11 && j["phy"]["bw"] == 250.0 && j["phy"]["snr"] == -7.25);
  CHECK(!j["phy"].contains("afc") && !j["phy"].contains("fec"));

  // CRC failure and missing CRC are dropped like OpenWebRX+ (crc < 1).
  PhyMeta bad = meta_at(10);
  bad.crc = 0;
  mt::DropReason why;
  CHECK(!parser.parse(pkt, sizeof pkt, bad, &why) && why == mt::DropReason::crc);
  bad.crc = -1;
  CHECK(!parser.parse(pkt, sizeof pkt, bad, &why) && why == mt::DropReason::crc);

  // Duplicate within 60 s dropped, accepted again after TTL and after reset().
  CHECK(!parser.parse(pkt, sizeof pkt, meta_at(30000), &why) &&
        why == mt::DropReason::duplicate);
  CHECK(parser.parse(pkt, sizeof pkt, meta_at(65006)).has_value());
  parser.reset();
  CHECK(parser.parse(pkt, sizeof pkt, meta_at(65007)).has_value());

  // Unknown channel hash: reported encrypted, no invented content.
  pkt[13] = 0x5A;
  pkt[8] = 9;
  ev = parser.parse(pkt, sizeof pkt, meta_at(70000));
  CHECK(ev.has_value());
  j = Json::parse(*ev);
  CHECK(j["encrypted"] == true && j["decrypt"] == "unknown_key");
  CHECK(!j.contains("port") && !j.contains("message") && !j.contains("data"));
  CHECK(j["ciphertext"] == mt::to_hex(data, sizeof data));

  // Direct message with hash 0 is flagged as a possible PKI packet.
  uint8_t dm[16 + 20] = {0x2b, 0x1a, 0x3c, 0x43, 1, 0, 0, 0, 3, 0, 0, 0, 0x03, 0x00, 0, 0};
  ev = parser.parse(dm, sizeof dm, meta_at(71000));
  CHECK(ev.has_value() && Json::parse(*ev).value("pki_possible", false));

  // Config errors keep the old config and never echo key text.
  ParserConfig broken;
  broken.channels.push_back({"X", "secret$$$value"});
  CHECK(!parser.configure(broken, &err));
  CHECK(err.find("secret") == std::string::npos && err.find("channel 0") == 0);
  std::string jerr;
  CHECK(!mt::parse_config_json(R"({"v":2})", cfg, &jerr));
  CHECK(!mt::parse_config_json(R"({"v":1,"preset":"Nope"})", cfg, &jerr));
  CHECK(!mt::parse_config_json(R"({"v":1,"channels":[{"name":"x"}]})", cfg, &jerr));
  CHECK(mt::parse_config_json(
      R"({"v":1,"preset":"ShortFast","channels":[{"name":"Ops","psk":"AQ=="}],"dropDuplicates":false})",
      cfg, &jerr));
  CHECK(cfg.preset == "ShortFast" && cfg.channels.size() == 1 && !cfg.drop_duplicates);

  // Events never contain configured key material.
  ParserConfig keyed;
  const std::string psk_b64 = "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=";
  keyed.channels.push_back({"Ops", psk_b64});
  PacketParser p2;
  CHECK(p2.configure(keyed));
  ev = p2.parse(pkt, sizeof pkt, meta_at(1));
  CHECK(ev.has_value());
  CHECK(ev->find(psk_b64) == std::string::npos);
  CHECK(ev->find("202122232425262728292a2b2c2d2e2f") == std::string::npos);

  // > 255 bytes cannot be a LoRa frame.
  std::vector<uint8_t> huge(256, 0);
  CHECK(!p2.parse(huge.data(), huge.size(), meta_at(2), &why) &&
        why == mt::DropReason::bad_length);
}

}  // namespace

// Deterministic random packets through every path (hash 0x08 forces AES +
// nanopb on garbage); run under ASan/UBSan to catch memory errors.
void test_random_robustness() {
  PacketParser parser;
  ParserConfig cfg;
  cfg.channels.push_back({"Open", "AA=="});  // plaintext path: raw garbage to nanopb
  CHECK(parser.configure(cfg));
  uint64_t s = 0x9E3779B97F4A7C15ull;
  auto rnd = [&]() {
    s ^= s << 13;
    s ^= s >> 7;
    s ^= s << 17;
    return s;
  };
  std::vector<uint8_t> buf(300);
  size_t events = 0;
  const uint8_t open_hash = static_cast<uint8_t>('O' ^ 'p' ^ 'e' ^ 'n');
  for (int i = 0; i < 20000; ++i) {
    const size_t len = rnd() % 260;
    for (auto& b : buf) b = static_cast<uint8_t>(rnd());
    if (len > 13) buf[13] = (i % 3 == 0) ? 0x08 : (i % 3 == 1) ? open_hash : buf[13];
    auto ev = parser.parse(buf.data(), len, meta_at(i * 61000LL));
    if (ev) {
      ++events;
      CHECK(!Json::parse(*ev, nullptr, false).is_discarded());
    }
  }
  CHECK(events > 15000);
}

int main() {
  test_header();
  test_keys();
  test_channel_hash();
  test_aes_ctr();
  test_oracle_vectors();
  test_native_semantics();
  test_random_robustness();
  if (g_failures) {
    std::fprintf(stderr, "%d check(s) failed\n", g_failures);
    return 1;
  }
  std::printf("meshtastic packet tests passed\n");
  return 0;
}
