// SPDX-License-Identifier: GPL-3.0-or-later
//
// Meshtastic packet layer. See meshtastic.h for the behavioural references.
#include "meshtastic.h"

#include <algorithm>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <nlohmann/json.hpp>
#include <pb_common.h>
#include <pb_decode.h>

#include <meshtastic/mesh.pb.h>
#include <meshtastic/paxcount.pb.h>
#include <meshtastic/portnums.pb.h>
#include <meshtastic/remote_hardware.pb.h>
#include <meshtastic/storeforward.pb.h>

#include "pb_reflect.h"

extern "C" {
#include "aes.h"
}

namespace sdrcore::meshtastic {

using Json = nlohmann::ordered_json;

const std::array<uint8_t, 16> kDefaultPsk = {
    0xd4, 0xf1, 0xbb, 0x3a, 0x20, 0x29, 0x07, 0x59,
    0xf0, 0xbc, 0xff, 0xab, 0xcf, 0x4e, 0x69, 0x01};

namespace {

uint32_t le32(const uint8_t* p) {
  return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16) |
         (static_cast<uint32_t>(p[3]) << 24);
}

void put_le32(uint8_t* p, uint32_t v) {
  for (int i = 0; i < 4; ++i) p[i] = static_cast<uint8_t>(v >> (8 * i));
}

std::string lower(std::string_view s) {
  std::string out(s);
  for (char& c : out)
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
  return out;
}

std::string_view strip(std::string_view s) {
  // Python str.strip() whitespace subset relevant to typed/pasted keys.
  auto ws = [](char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' ||
           c == '\v';
  };
  while (!s.empty() && ws(s.front())) s.remove_prefix(1);
  while (!s.empty() && ws(s.back())) s.remove_suffix(1);
  return s;
}

int hex_value(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

int b64_value(char c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+') return 62;
  if (c == '/') return 63;
  return -1;
}

// base64.b64decode(s, validate=True): alphabet only, '=' only as trailing
// padding, total length a multiple of four.
bool b64_strict(std::string_view s, std::vector<uint8_t>& out) {
  out.clear();
  if (s.size() % 4 != 0) return false;
  size_t pad = 0;
  while (pad < 2 && pad < s.size() && s[s.size() - 1 - pad] == '=') ++pad;
  uint32_t acc = 0;
  int bits = 0;
  for (size_t i = 0; i < s.size() - pad; ++i) {
    int v = b64_value(s[i]);
    if (v < 0) return false;
    acc = (acc << 6) | static_cast<uint32_t>(v);
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push_back(static_cast<uint8_t>(acc >> bits));
    }
  }
  return true;
}

std::string b64_encode(const uint8_t* p, size_t n) {
  static const char* tbl =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  out.reserve((n + 2) / 3 * 4);
  for (size_t i = 0; i < n; i += 3) {
    uint32_t v = static_cast<uint32_t>(p[i]) << 16;
    if (i + 1 < n) v |= static_cast<uint32_t>(p[i + 1]) << 8;
    if (i + 2 < n) v |= p[i + 2];
    out.push_back(tbl[(v >> 18) & 63]);
    out.push_back(tbl[(v >> 12) & 63]);
    out.push_back(i + 1 < n ? tbl[(v >> 6) & 63] : '=');
    out.push_back(i + 2 < n ? tbl[v & 63] : '=');
  }
  return out;
}

// bytes.decode("utf-8", errors="replace") with CPython's maximal-subpart
// replacement: each maximal invalid prefix becomes one U+FFFD.
std::string utf8_replace(const uint8_t* p, size_t n) {
  static const char kRepl[] = "\xEF\xBF\xBD";
  std::string out;
  out.reserve(n);
  size_t i = 0;
  while (i < n) {
    uint8_t c = p[i];
    if (c < 0x80) {
      out.push_back(static_cast<char>(c));
      ++i;
      continue;
    }
    size_t need;
    uint8_t lo = 0x80, hi = 0xBF;
    if (c >= 0xC2 && c <= 0xDF) {
      need = 1;
    } else if (c >= 0xE0 && c <= 0xEF) {
      need = 2;
      if (c == 0xE0) lo = 0xA0;
      if (c == 0xED) hi = 0x9F;
    } else if (c >= 0xF0 && c <= 0xF4) {
      need = 3;
      if (c == 0xF0) lo = 0x90;
      if (c == 0xF4) hi = 0x8F;
    } else {
      out += kRepl;
      ++i;
      continue;
    }
    size_t j = 1;
    for (; j <= need; ++j) {
      if (i + j >= n) break;
      uint8_t cc = p[i + j];
      uint8_t l = (j == 1) ? lo : 0x80, h = (j == 1) ? hi : 0xBF;
      if (cc < l || cc > h) break;
    }
    if (j == need + 1) {
      out.append(reinterpret_cast<const char*>(p + i), need + 1);
      i += need + 1;
    } else {
      out += kRepl;
      i += j;  // maximal subpart consumed (j >= 1)
    }
  }
  return out;
}

// protobuf type_checkers.ToShortestFloat: the shortest %.{6..9}g decimal
// that rounds back to the same 32-bit float.
double shortest_float(float f) {
  for (int prec = 6; prec <= 9; ++prec) {
    char buf[64];
    std::snprintf(buf, sizeof buf, "%.*g", prec, static_cast<double>(f));
    double rounded = std::strtod(buf, nullptr);
    if (static_cast<float>(rounded) == f) return rounded;
  }
  return static_cast<double>(f);
}

Json float_json(double v, bool is_float32) {
  if (std::isnan(v)) return "NaN";
  if (std::isinf(v)) return v < 0 ? "-Infinity" : "Infinity";
  return is_float32 ? shortest_float(static_cast<float>(v)) : v;
}

int64_t read_signed(const void* p, size_t size) {
  switch (size) {
    case 1: { int8_t v; std::memcpy(&v, p, 1); return v; }
    case 2: { int16_t v; std::memcpy(&v, p, 2); return v; }
    case 4: { int32_t v; std::memcpy(&v, p, 4); return v; }
    default: { int64_t v; std::memcpy(&v, p, 8); return v; }
  }
}

uint64_t read_unsigned(const void* p, size_t size) {
  switch (size) {
    case 1: { uint8_t v; std::memcpy(&v, p, 1); return v; }
    case 2: { uint16_t v; std::memcpy(&v, p, 2); return v; }
    case 4: { uint32_t v; std::memcpy(&v, p, 4); return v; }
    default: { uint64_t v; std::memcpy(&v, p, 8); return v; }
  }
}

bool all_zero(const void* p, size_t n) {
  const auto* b = static_cast<const uint8_t*>(p);
  for (size_t i = 0; i < n; ++i)
    if (b[i]) return false;
  return true;
}

Json message_to_json(const pb_msgdesc_t* desc, const void* msg);

Json value_to_json(const pbjson::FieldInfo& fi, pb_field_iter_t& it,
                   const void* p) {
  switch (fi.kind) {
    case pbjson::Kind::boolean: return *static_cast<const bool*>(p);
    case pbjson::Kind::sint: return read_signed(p, it.data_size);
    case pbjson::Kind::uint: return read_unsigned(p, it.data_size);
    case pbjson::Kind::sint64: return std::to_string(read_signed(p, 8));
    case pbjson::Kind::uint64: return std::to_string(read_unsigned(p, 8));
    case pbjson::Kind::f32: {
      float f;
      std::memcpy(&f, p, sizeof f);
      return float_json(f, true);
    }
    case pbjson::Kind::f64: {
      double d;
      std::memcpy(&d, p, sizeof d);
      return float_json(d, false);
    }
    case pbjson::Kind::enumeration: {
      int64_t v = read_signed(p, it.data_size);
      const char* name = fi.enum_name ? fi.enum_name(v) : nullptr;
      if (name) return name;
      return v;  // proto3 open enum: unknown values print as integers
    }
    case pbjson::Kind::string: {
      const char* s = static_cast<const char*>(p);
      return std::string(s, strnlen(s, it.data_size));
    }
    case pbjson::Kind::bytes: {
      const auto* b = static_cast<const pb_bytes_array_t*>(p);
      return b64_encode(b->bytes, b->size);
    }
    case pbjson::Kind::fixed_bytes:
      return b64_encode(static_cast<const uint8_t*>(p), it.data_size);
    case pbjson::Kind::message:
      return message_to_json(it.submsg_desc, p);
    case pbjson::Kind::unsupported:
      break;
  }
  return nullptr;
}

bool singular_present(const pbjson::FieldInfo& fi, const pb_field_iter_t& it) {
  const void* p = it.pData;
  switch (fi.kind) {
    case pbjson::Kind::string: return static_cast<const char*>(p)[0] != '\0';
    case pbjson::Kind::bytes:
      return static_cast<const pb_bytes_array_t*>(p)->size != 0;
    case pbjson::Kind::message: return true;
    case pbjson::Kind::f32: {
      float f;
      std::memcpy(&f, p, sizeof f);
      return f != 0.0f || std::signbit(f);
    }
    case pbjson::Kind::f64: {
      double d;
      std::memcpy(&d, p, sizeof d);
      return d != 0.0 || std::signbit(d);
    }
    default: return !all_zero(p, it.data_size);
  }
}

// json_format.MessageToDict(msg, preserving_proto_field_name=True):
// fields with presence when set, proto3 implicit scalars when non-default,
// repeated fields when non-empty.
Json message_to_json(const pb_msgdesc_t* desc, const void* msg) {
  Json out = Json::object();
  const pbjson::MessageInfo* info = pbjson::find_message(desc);
  if (!info) return out;
  pb_field_iter_t it;
  if (!pb_field_iter_begin_const(&it, desc, msg)) return out;
  do {
    const pbjson::FieldInfo* fi = nullptr;
    for (size_t i = 0; i < info->field_count; ++i)
      if (info->fields[i].tag == it.tag) fi = &info->fields[i];
    if (!fi || fi->kind == pbjson::Kind::unsupported) continue;
    const pb_type_t htype = PB_HTYPE(it.type);
    if (htype == PB_HTYPE_ONEOF) {
      if (!it.pSize || *static_cast<const pb_size_t*>(it.pSize) != it.tag)
        continue;
      out[fi->name] = value_to_json(*fi, it, it.pData);
    } else if (htype == PB_HTYPE_REPEATED) {
      pb_size_t count =
          it.pSize ? *static_cast<const pb_size_t*>(it.pSize) : 0;
      if (count == 0) continue;
      Json arr = Json::array();
      for (pb_size_t i = 0; i < count && i < it.array_size; ++i)
        arr.push_back(value_to_json(
            *fi, it, static_cast<const uint8_t*>(it.pData) + i * it.data_size));
      out[fi->name] = std::move(arr);
    } else if (it.pSize) {  // explicit presence (has_ field)
      if (!*static_cast<const bool*>(it.pSize)) continue;
      out[fi->name] = value_to_json(*fi, it, it.pData);
    } else {
      if (!singular_present(*fi, it)) continue;
      out[fi->name] = value_to_json(*fi, it, it.pData);
    }
  } while (pb_field_iter_next(&it));
  return out;
}

struct AlignedBuffer {
  explicit AlignedBuffer(size_t size)
      : storage((size + sizeof(std::max_align_t) - 1) /
                    sizeof(std::max_align_t) +
                1) {}
  void* data() { return storage.data(); }
  std::vector<std::max_align_t> storage;
};

// Decode `payload` as message `desc` into JSON; false on protobuf error.
bool decode_to_json(const pb_msgdesc_t* desc, const uint8_t* payload,
                    size_t len, Json& out) {
  const pbjson::MessageInfo* info = pbjson::find_message(desc);
  if (!info) return false;
  AlignedBuffer buf(info->struct_size);
  pb_istream_t stream = pb_istream_from_buffer(payload, len);
  if (!pb_decode(&stream, desc, buf.data())) return false;
  out = message_to_json(desc, buf.data());
  return true;
}

// OpenWebRX+ APP_PROTO_DECODERS (owrx/meshtastic.py), restricted to the
// messages generated here. ADMIN_APP (6), ATAK_PLUGIN (72) and
// POWERSTRESS_APP (74) are reported as raw payloads; see STATUS-meshtastic.md.
const pb_msgdesc_t* app_decoder(uint32_t port) {
  switch (port) {
    case meshtastic_PortNum_REMOTE_HARDWARE_APP: return &meshtastic_HardwareMessage_msg;
    case meshtastic_PortNum_POSITION_APP: return &meshtastic_Position_msg;
    case meshtastic_PortNum_NODEINFO_APP: return &meshtastic_User_msg;
    case meshtastic_PortNum_ROUTING_APP: return &meshtastic_Routing_msg;
    case meshtastic_PortNum_WAYPOINT_APP: return &meshtastic_Waypoint_msg;
    case meshtastic_PortNum_PAXCOUNTER_APP: return &meshtastic_Paxcount_msg;
    case meshtastic_PortNum_STORE_FORWARD_APP: return &meshtastic_StoreAndForward_msg;
    case meshtastic_PortNum_TELEMETRY_APP: return &meshtastic_Telemetry_msg;
    case meshtastic_PortNum_TRACEROUTE_APP: return &meshtastic_RouteDiscovery_msg;
    case meshtastic_PortNum_NEIGHBORINFO_APP: return &meshtastic_NeighborInfo_msg;
    default: return nullptr;
  }
}

std::string port_name(uint32_t port) {
  const char* n = meshtastic_PortNum_name(static_cast<meshtastic_PortNum>(port));
  if (n && std::strcmp(n, "unknown") != 0) return n;
  return std::to_string(port);  // Python PortNum.Name raises; we keep the number
}

constexpr int64_t kDedupTtlMs = 60 * 1000;   // MeshtasticParser.DEDUP_TTL
constexpr size_t kDedupMax = 4096;           // MeshtasticParser.DEDUP_MAX
constexpr int64_t kNodeTtlMs = 7LL * 24 * 60 * 60 * 1000;  // CACHE_TTL
constexpr size_t kNodeMax = 2048;            // bound; OpenWebRX+ is unbounded
constexpr size_t kMaxChannels = 8;           // firmware MAX_NUM_CHANNELS

}  // namespace

bool parse_header(const uint8_t* data, size_t len, Header& out) {
  if (!data || len < kHeaderLength) return false;
  out.dst = le32(data);
  out.src = le32(data + 4);
  out.packet_id = le32(data + 8);
  out.flags = data[12];
  out.channel_hash = data[13];
  out.next_hop = data[14];
  out.relay_node = data[15];
  return true;
}

bool resolve_key(std::string_view text, Key& out, std::string* error) {
  auto fail = [&](const char* msg) {
    if (error) *error = msg;
    return false;
  };
  const std::string_view raw = strip(text);
  const std::string low = lower(raw);
  std::vector<uint8_t> bytes;
  if (low == "default" || low == "aq==") {
    bytes = {1};
  } else {
    std::string candidate(raw);
    if (low.rfind("0x", 0) == 0) candidate = candidate.substr(2);
    candidate.erase(std::remove_if(candidate.begin(), candidate.end(),
                                   [](char c) { return c == ':' || c == '-'; }),
                    candidate.end());
    bool is_hex = candidate.size() % 2 == 0 &&
                  std::all_of(candidate.begin(), candidate.end(),
                              [](char c) { return hex_value(c) >= 0; });
    if (is_hex) {
      for (size_t i = 0; i < candidate.size(); i += 2)
        bytes.push_back(static_cast<uint8_t>(hex_value(candidate[i]) * 16 +
                                             hex_value(candidate[i + 1])));
    } else if (!b64_strict(raw, bytes)) {
      return fail("key is neither hex nor valid base64");
    }
  }
  Key k;
  if (bytes.empty()) return fail("key is empty");
  if (bytes.size() > 32) return fail("key longer than 32 bytes");
  if (bytes.size() == 1) {
    // firmware Channels::getKey short-PSK expansion
    if (bytes[0] == 0) {
      k.length = 0;
    } else {
      std::copy(kDefaultPsk.begin(), kDefaultPsk.end(), k.bytes.begin());
      k.bytes[15] = static_cast<uint8_t>(k.bytes[15] + bytes[0] - 1);
      k.length = 16;
    }
  } else {
    std::copy(bytes.begin(), bytes.end(), k.bytes.begin());
    k.length = bytes.size() <= 16 ? 16 : 32;
  }
  out = k;
  return true;
}

uint8_t channel_hash(std::string_view channel_name, const Key& key) {
  uint8_t h = 0;
  for (char c : channel_name) h ^= static_cast<uint8_t>(c);
  for (size_t i = 0; i < key.length; ++i) h ^= key.bytes[i];
  return h;
}

std::array<uint8_t, 16> packet_nonce(uint32_t packet_id, uint32_t src) {
  std::array<uint8_t, 16> n{};
  put_le32(n.data(), packet_id);  // u64 LE packet id; upper 32 bits are zero
  put_le32(n.data() + 8, src);
  return n;
}

void aes_ctr(const Key& key, const std::array<uint8_t, 16>& nonce,
             const uint8_t* in, size_t len, uint8_t* out) {
  WORD schedule[60];
  aes_key_setup(key.bytes.data(), schedule, static_cast<int>(key.length * 8));
  std::array<uint8_t, 16> ctr = nonce;
  uint8_t stream[16];
  for (size_t off = 0; off < len; off += 16) {
    aes_encrypt(ctr.data(), stream, schedule, static_cast<int>(key.length * 8));
    const size_t n = std::min<size_t>(16, len - off);
    for (size_t i = 0; i < n; ++i) out[off + i] = in[off + i] ^ stream[i];
    // Crypto library CTR with setCounterSize(4): 32-bit big-endian counter.
    for (int i = 15; i >= 12; --i)
      if (++ctr[i] != 0) break;
  }
  std::memset(schedule, 0, sizeof schedule);
  std::memset(stream, 0, sizeof stream);
}

const std::vector<std::string>& preset_channel_names() {
  // firmware DisplayFormatters::getModemPresetDisplayName(.., false, true)
  static const std::vector<std::string> names = {
      "LongFast",  "LongSlow",  "VLongSlow", "MediumSlow", "MediumFast",
      "ShortSlow", "ShortFast", "LongMod",   "ShortTurbo", "LongTurbo",
      "LiteFast",  "LiteSlow",  "NarrowFast", "NarrowSlow", "TinyFast",
      "TinySlow",  "MediumTurbo"};
  return names;
}

std::string to_hex(const uint8_t* data, size_t len) {
  static const char* digits = "0123456789abcdef";
  std::string s;
  s.reserve(len * 2);
  for (size_t i = 0; i < len; ++i) {
    s.push_back(digits[data[i] >> 4]);
    s.push_back(digits[data[i] & 15]);
  }
  return s;
}

bool parse_config_json(std::string_view json, ParserConfig& out,
                       std::string* error) {
  auto fail = [&](const std::string& msg) {
    if (error) *error = msg;
    return false;
  };
  Json j = Json::parse(json.begin(), json.end(), nullptr, false);
  if (j.is_discarded() || !j.is_object()) return fail("settings are not a JSON object");
  if (!j.contains("v") || !j["v"].is_number_integer() || j["v"].get<int>() != 1)
    return fail("unsupported settings version");
  ParserConfig cfg;
  if (j.contains("preset")) {
    if (!j["preset"].is_string()) return fail("preset must be a string");
    cfg.preset = j["preset"].get<std::string>();
    const auto& names = preset_channel_names();
    if (std::find(names.begin(), names.end(), cfg.preset) == names.end())
      return fail("unknown preset");
  }
  if (j.contains("channels")) {
    if (!j["channels"].is_array()) return fail("channels must be an array");
    if (j["channels"].size() > kMaxChannels) return fail("too many channels");
    size_t idx = 0;
    for (const auto& c : j["channels"]) {
      if (!c.is_object() || !c.contains("psk") || !c["psk"].is_string() ||
          (c.contains("name") && !c["name"].is_string()))
        return fail("channel " + std::to_string(idx) + " is malformed");
      ChannelConfig ch;
      ch.psk = c["psk"].get<std::string>();
      if (c.contains("name")) ch.name = c["name"].get<std::string>();
      if (ch.name.size() > 11)  // ChannelSettings.name max_size:12 incl. NUL
        return fail("channel " + std::to_string(idx) + " name too long");
      cfg.channels.push_back(std::move(ch));
      ++idx;
    }
  }
  if (j.contains("defaultKeyAllPresets")) {
    if (!j["defaultKeyAllPresets"].is_boolean())
      return fail("defaultKeyAllPresets must be boolean");
    cfg.default_key_all_presets = j["defaultKeyAllPresets"].get<bool>();
  }
  if (j.contains("dropDuplicates")) {
    if (!j["dropDuplicates"].is_boolean())
      return fail("dropDuplicates must be boolean");
    cfg.drop_duplicates = j["dropDuplicates"].get<bool>();
  }
  out = std::move(cfg);
  return true;
}

struct PacketParser::Node {
  Json fields = Json::object();  // OpenWebRX+ MeshtasticCache cacheable keys
  int64_t seen_ms = 0;
};

PacketParser::PacketParser() : nodes_(std::make_unique<std::map<uint32_t, Node>>()) {
  configure(ParserConfig{});
}

PacketParser::~PacketParser() {
  for (auto& c : candidates_) c.key.bytes.fill(0);
}

bool PacketParser::configure(const ParserConfig& config, std::string* error) {
  std::vector<Candidate> next;
  auto add = [&](std::string name, const Key& key, int index) {
    const uint8_t hash = channel_hash(name, key);
    for (const auto& c : next)
      if (c.hash == hash && c.key == key && c.name == name) return;
    next.push_back(Candidate{std::move(name), key, hash, index});
  };
  if (config.channels.size() > kMaxChannels) {
    if (error) *error = "too many channels";
    return false;
  }
  for (size_t i = 0; i < config.channels.size(); ++i) {
    Key k;
    std::string why;
    if (!resolve_key(config.channels[i].psk, k, &why)) {
      if (error) *error = "channel " + std::to_string(i) + ": " + why;
      return false;
    }
    const std::string name =
        config.channels[i].name.empty() ? config.preset : config.channels[i].name;
    add(name, k, static_cast<int>(i));
  }
  Key def;
  resolve_key("AQ==", def);
  add(config.preset, def, -1);
  if (config.default_key_all_presets)
    for (const auto& p : preset_channel_names()) add(p, def, -1);
  for (auto& c : candidates_) c.key.bytes.fill(0);
  candidates_ = std::move(next);
  drop_duplicates_ = config.drop_duplicates;
  seen_.clear();
  return true;
}

void PacketParser::reset() { seen_.clear(); }

void PacketParser::clear_nodes() { nodes_->clear(); }

bool PacketParser::is_duplicate(uint32_t src, uint32_t id, int64_t now_ms) {
  const auto key = std::make_pair(src, id);
  auto it = seen_.find(key);
  if (it != seen_.end() && now_ms - it->second < kDedupTtlMs) return true;
  seen_[key] = now_ms;
  if (seen_.size() > kDedupMax) {
    const int64_t cutoff = now_ms - kDedupTtlMs;
    for (auto i = seen_.begin(); i != seen_.end();)
      i = (i->second > cutoff) ? std::next(i) : seen_.erase(i);
  }
  return false;
}

std::optional<std::string> PacketParser::parse(const uint8_t* data, size_t len,
                                               const PhyMeta& meta,
                                               DropReason* reason) {
  auto drop = [&](DropReason r) -> std::optional<std::string> {
    if (reason) *reason = r;
    return std::nullopt;
  };
  if (reason) *reason = DropReason::none;
  // MeshtasticParser.parse: payload must carry a valid CRC ("crc" >= 1).
  if (meta.crc < 1) {
    ++stats_.dropped_crc;
    return drop(DropReason::crc);
  }
  Header h;
  if (!parse_header(data, len, h) || len > kMaxLoraPayload) {
    ++stats_.dropped_length;
    return drop(DropReason::bad_length);
  }
  if (drop_duplicates_ && is_duplicate(h.src, h.packet_id, meta.monotonic_ms)) {
    ++stats_.dropped_duplicate;
    return drop(DropReason::duplicate);
  }
  ++stats_.packets;

  Json out = Json::object();
  out["mode"] = "Meshtastic";
  out["timestamp"] = meta.timestamp_ms;
  out["comment"] = std::to_string(len) + " bytes, hop " +
                   std::to_string(static_cast<int>(h.hop_start()) -
                                  static_cast<int>(h.hop_limit())) +
                   "/" + std::to_string(h.hop_start());
  out["dst"] = h.dst;
  out["src"] = h.src;
  if (meta.frequency_hz) out["freq"] = meta.frequency_hz;
  out["packet_id"] = h.packet_id;
  out["hop_limit"] = h.hop_limit();
  out["hop_start"] = h.hop_start();
  out["want_ack"] = h.want_ack();
  out["via_mqtt"] = h.via_mqtt();
  out["channel_hash"] = h.channel_hash;
  out["next_hop"] = h.next_hop;
  out["relay_node"] = h.relay_node;
  out["length"] = len;

  Json phy = Json::object();
  phy["crc"] = meta.crc;
  if (!std::isnan(meta.bw_khz)) phy["bw"] = meta.bw_khz;
  if (meta.sf != INT32_MIN) phy["sf"] = meta.sf;
  if (meta.cr != INT32_MIN) phy["cr"] = meta.cr;
  if (meta.inverted != INT32_MIN) phy["invers"] = meta.inverted;
  if (meta.preamble != INT32_MIN) phy["preamb"] = meta.preamble;
  if (meta.duration_ms != INT32_MIN) phy["duration"] = meta.duration_ms;
  if (!std::isnan(meta.level_db)) phy["level"] = meta.level_db;
  if (meta.afc_hz != INT32_MIN) phy["afc"] = meta.afc_hz;
  if (!std::isnan(meta.noise_floor_db)) phy["nfloor"] = meta.noise_floor_db;
  if (!std::isnan(meta.peak_noise_floor_db)) phy["pknfloor"] = meta.peak_noise_floor_db;
  if (!std::isnan(meta.snr_db)) phy["snr"] = meta.snr_db;
  if (meta.fec != INT32_MIN) phy["fec"] = meta.fec;
  out["phy"] = std::move(phy);

  const uint8_t* cipher = data + kHeaderLength;
  const size_t clen = len - kHeaderLength;
  if (clen == 0) {
    out["encrypted"] = false;
    out["decrypt"] = "no_payload";
  } else {
    // firmware Router::perhapsDecode channel loop: only channels whose hash
    // matches, accept the first that yields a valid Data with portnum != 0.
    bool matched = false, ok = false;
    uint8_t plain[kMaxLoraPayload];
    meshtastic_Data decoded;
    const Candidate* used = nullptr;
    for (const auto& c : candidates_) {
      if (c.hash != h.channel_hash) continue;
      matched = true;
      if (c.key.length == 0) {
        std::memcpy(plain, cipher, clen);
      } else {
        aes_ctr(c.key, packet_nonce(h.packet_id, h.src), cipher, clen, plain);
      }
      std::memset(&decoded, 0, sizeof decoded);
      pb_istream_t s = pb_istream_from_buffer(plain, clen);
      if (pb_decode(&s, &meshtastic_Data_msg, &decoded) &&
          decoded.portnum != meshtastic_PortNum_UNKNOWN_APP) {
        ok = true;
        used = &c;
        break;
      }
    }
    std::memset(plain, 0, sizeof plain);
    if (!ok) {
      ++stats_.encrypted;
      out["encrypted"] = true;
      out["decrypt"] = matched ? "failed" : "unknown_key";
      // firmware PKI DM candidate: channel hash 0 to a single node, AES-CCM
      // with the recipient's private key - never decryptable by a listener.
      if (h.channel_hash == 0 && h.dst != kBroadcast && clen > 12)
        out["pki_possible"] = true;
      out["ciphertext"] = to_hex(cipher, clen);
    } else {
      ++stats_.decrypted;
      out["encrypted"] = false;
      out["decrypt"] = used->key.length == 0 ? "plaintext" : "ok";
      out["channel"] = used->name;
      out["channel_index"] = used->index;
      const uint32_t port = decoded.portnum;
      const uint8_t* payload = decoded.payload.bytes;
      const size_t plen = decoded.payload.size;
      // OpenWebRX+ MeshtasticParser.parsePayload
      out["port"] = port;
      out["type"] = port_name(port);
      if (decoded.request_id) out["request_id"] = decoded.request_id;
      if (decoded.reply_id) out["reply_id"] = decoded.reply_id;
      if (decoded.emoji) out["emoji"] = decoded.emoji;
      if (port == meshtastic_PortNum_TEXT_MESSAGE_APP ||
          port == meshtastic_PortNum_TEXT_MESSAGE_COMPRESSED_APP) {
        out["message"] = utf8_replace(payload, plen);
        if (port == meshtastic_PortNum_TEXT_MESSAGE_COMPRESSED_APP)
          out["raw"] = to_hex(payload, plen);
      } else if (const pb_msgdesc_t* desc = app_decoder(port)) {
        Json d;
        if (!decode_to_json(desc, payload, plen, d)) {
          out["raw"] = to_hex(payload, plen);
          out["payload_error"] = "protobuf decode failed";
        } else {
          if (port == meshtastic_PortNum_POSITION_APP) {
            if (d.contains("latitude_i"))
              out["lat"] = d["latitude_i"].get<int64_t>() / 10000000.0;
            if (d.contains("longitude_i"))
              out["lon"] = d["longitude_i"].get<int64_t>() / 10000000.0;
            if (d.contains("altitude")) out["altitude"] = d["altitude"];
          } else if (port == meshtastic_PortNum_ROUTING_APP) {
            if (d.contains("error_reason") && d["error_reason"] == "NONE")
              d.erase("error_reason");
          } else if (port == meshtastic_PortNum_WAYPOINT_APP) {
            if (d.contains("name") && d.contains("latitude_i") &&
                d.contains("longitude_i"))
              out["waypoint"] = {
                  {"name", d["name"]},
                  {"lat", d["latitude_i"].get<int64_t>() / 10000000.0},
                  {"lon", d["longitude_i"].get<int64_t>() / 10000000.0}};
          } else if (port == meshtastic_PortNum_TELEMETRY_APP) {
            if (d.contains("device_metrics")) {
              const Json& m = d["device_metrics"];
              if (m.contains("voltage")) out["battery"] = m["voltage"];
              if (m.contains("uptime_seconds")) out["uptime"] = m["uptime_seconds"];
              if (m.contains("channel_utilization"))
                out["channelUse"] = m["channel_utilization"];
              if (m.contains("air_util_tx")) out["airtimeUse"] = m["air_util_tx"];
            }
            if (d.contains("environment_metrics")) {
              const Json& m = d["environment_metrics"];
              Json weather = Json::object();
              if (m.contains("temperature")) weather["temperature"] = m["temperature"];
              if (m.contains("relative_humidity"))
                weather["humidity"] = m["relative_humidity"];
              if (m.contains("barometric_pressure"))
                weather["barometricpressure"] = m["barometric_pressure"];
              if (!weather.empty()) out["weather"] = std::move(weather);
            }
          }
          out["data"] = d;
          // MeshtasticCache.cacheNode: POSITION caches `out`, NODEINFO `data`.
          const Json* src = nullptr;
          if (port == meshtastic_PortNum_POSITION_APP) src = &out;
          if (port == meshtastic_PortNum_NODEINFO_APP) src = &d;
          if (src) {
            Json updates = Json::object();
            for (const char* k : {"lat", "lon", "altitude", "long_name",
                                  "short_name", "role", "hw_model", "is_licensed"})
              if (src->contains(k)) updates[k] = (*src)[k];
            if (!updates.empty()) {
              if (nodes_->size() >= kNodeMax && !nodes_->count(h.src)) {
                auto oldest = std::min_element(
                    nodes_->begin(), nodes_->end(), [](const auto& a, const auto& b) {
                      return a.second.seen_ms < b.second.seen_ms;
                    });
                nodes_->erase(oldest);
              }
              Node& n = (*nodes_)[h.src];
              n.fields.update(updates);
              n.seen_ms = meta.monotonic_ms;
            }
          }
        }
      } else if (plen) {
        out["raw"] = to_hex(payload, plen);  // portnum without a decoder
      }
    }
  }

  // Annotate src/dst with cached node information (OpenWebRX+ parsePacket).
  auto cached = [&](uint32_t id) -> const Node* {
    auto it = nodes_->find(id);
    if (it == nodes_->end()) return nullptr;
    if (meta.monotonic_ms - it->second.seen_ms >= kNodeTtlMs) return nullptr;
    return &it->second;
  };
  if (const Node* n = cached(h.src)) {
    static const std::pair<const char*, const char*> map[] = {
        {"short_name", "nickName"}, {"long_name", "longName"}, {"role", "role"},
        {"hw_model", "device"},     {"lat", "lat"},            {"lon", "lon"},
        {"altitude", "altitude"}};
    for (const auto& [k, f] : map)
      if (n->fields.contains(k)) out[f] = n->fields[k];
  }
  if (h.dst != kBroadcast) {
    if (const Node* n = cached(h.dst)) {
      if (n->fields.contains("short_name")) out["dstNickName"] = n->fields["short_name"];
      if (n->fields.contains("long_name")) out["dstLongName"] = n->fields["long_name"];
    }
  }
  return out.dump(-1, ' ', false, Json::error_handler_t::replace);
}

}  // namespace sdrcore::meshtastic
