// SPDX-License-Identifier: GPL-3.0-or-later
//
// Meshtastic packet layer (parsing, channel keys, AES-CTR, protobuf payload
// decoding) for packets delivered by a LoRa PHY. Behavioural reference:
// OpenWebRX+ owrx/meshtastic.py (MeshtasticParser) and owrx/lora.py, with the
// key/channel-hash rules of the Meshtastic firmware (src/mesh/Channels.cpp,
// CryptoEngine.cpp, Router.cpp::perhapsDecode). See STATUS-meshtastic.md.
//
// Pure, synchronous and allocation-bounded: no I/O, no logging, no threads.
// The caller (later: the decoder backend on the native DSP worker) owns the
// instance. Configured channel keys never appear in returned events or error
// strings.
#pragma once

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace sdrcore::meshtastic {

inline constexpr size_t kHeaderLength = 16;     // firmware MESHTASTIC_HEADER_LENGTH
inline constexpr size_t kMaxLoraPayload = 255;  // firmware MAX_LORA_PAYLOAD_LEN
inline constexpr uint32_t kBroadcast = 0xFFFFFFFFu;

// 16-byte over-the-air header (firmware RadioInterface.h PacketHeader).
struct Header {
  uint32_t dst = 0;
  uint32_t src = 0;
  uint32_t packet_id = 0;
  uint8_t flags = 0;
  uint8_t channel_hash = 0;
  uint8_t next_hop = 0;
  uint8_t relay_node = 0;

  uint8_t hop_limit() const { return flags & 0x07; }
  uint8_t hop_start() const { return (flags >> 5) & 0x07; }
  bool want_ack() const { return (flags & 0x08) != 0; }
  bool via_mqtt() const { return (flags & 0x10) != 0; }
};

// Returns false when fewer than 16 bytes are available.
bool parse_header(const uint8_t* data, size_t len, Header& out);

// AES key as used by the firmware's CryptoKey: length 0 = encryption disabled
// (plaintext Data), otherwise 16 (AES-128) or 32 (AES-256).
struct Key {
  std::array<uint8_t, 32> bytes{};
  size_t length = 0;
  bool operator==(const Key& o) const {
    return length == o.length && bytes == o.bytes;
  }
};

// Firmware `defaultpsk` (Channels.h); identical to OpenWebRX+ DEFAULT_KEY.
extern const std::array<uint8_t, 16> kDefaultPsk;

// Resolve a user-entered PSK string with OpenWebRX+ `_resolve_key` precedence:
//   "default"/"AQ==" (case-insensitive) -> default key;
//   even-length hex (optional 0x prefix, ':'/'-' separators ignored) -> bytes;
//   otherwise strict base64.
// Then the firmware `Channels::getKey` expansion: 1 byte = short PSK index
// (0 = no encryption [firmware rule; OpenWebRX+ would derive a key], n>=1 =
// default key with the last byte + n-1), 2..15 bytes zero-padded to 16,
// 17..31 zero-padded to 32. Empty or >32 bytes are rejected. The error string
// never contains the key material.
bool resolve_key(std::string_view text, Key& out, std::string* error = nullptr);

// Firmware Channels::generateHash: xor(channel name bytes) ^ xor(key bytes).
uint8_t channel_hash(std::string_view channel_name, const Key& key);

// Meshtastic AES-CTR nonce: packet id (u64 LE) | from node (u32 LE) | 0 (u32);
// the final 32 bits are a big-endian block counter starting at 0.
std::array<uint8_t, 16> packet_nonce(uint32_t packet_id, uint32_t src);
// Raw AES-CTR (128/256 by key.length) with a caller-supplied 16-byte initial
// counter block. `in` and `out` may alias. Key length must be 16 or 32.
void aes_ctr(const Key& key, const std::array<uint8_t, 16>& nonce,
             const uint8_t* in, size_t len, uint8_t* out);

// Modem preset display names exactly as firmware DisplayFormatters
// (used as the implicit channel name of an unnamed primary channel).
const std::vector<std::string>& preset_channel_names();

// Lowercase hex of bytes, no separators.
std::string to_hex(const uint8_t* data, size_t len);

// PHY metadata accompanying each packet. Field meanings follow lorarx's JSON
// (`sendjson` in dxlAPRS src/lorarx.c): crc 1 = CRC ok, 0 = CRC failed,
// -1 = no payload CRC. Floating fields set to NaN, and integers set to
// INT32_MIN, are "unknown" and omitted from the event.
struct PhyMeta {
  int64_t timestamp_ms = 0;   // UTC wall-clock of reception (event "timestamp")
  int64_t monotonic_ms = 0;   // monotonic clock for duplicate suppression
  uint64_t frequency_hz = 0;  // receiver dial frequency, 0 = unknown
  int crc = 1;
  double bw_khz = NAN;
  int sf = INT32_MIN;
  int cr = INT32_MIN;
  int inverted = INT32_MIN;   // lorarx "invers"
  int preamble = INT32_MIN;   // lorarx "preamb" (symbols)
  int duration_ms = INT32_MIN;
  double level_db = NAN;
  double snr_db = NAN;
  double noise_floor_db = NAN;       // lorarx "nfloor"
  double peak_noise_floor_db = NAN;  // lorarx "pknfloor"
  int afc_hz = INT32_MIN;
  int fec = INT32_MIN;
};

struct ChannelConfig {
  std::string name;  // channel name; empty = preset display name
  std::string psk;   // user-entered key text (see resolve_key)
};

struct ParserConfig {
  // Modem preset display name of the default (unnamed) primary channel.
  std::string preset = "LongFast";
  // User channels in priority order (firmware tries channel indices in order).
  std::vector<ChannelConfig> channels;
  // Try the public default key under every preset display name as well as the
  // configured preset (covers default-key channels of other presets).
  bool default_key_all_presets = true;
  // OpenWebRX+ drops packets whose (src, packet id) was seen in the last 60 s.
  bool drop_duplicates = true;
};

// Parse settings JSON {"v":1,"preset":"LongFast","channels":[{"name":..,"psk":..}],
// "defaultKeyAllPresets":true,"dropDuplicates":true}. On failure returns false
// and a key-free error message.
bool parse_config_json(std::string_view json, ParserConfig& out,
                       std::string* error = nullptr);

// bad_length: < 16 header bytes (OpenWebRX+ rule) or > 255 (not a LoRa frame).
enum class DropReason { none, crc, bad_length, duplicate };

struct ParseStats {
  uint64_t packets = 0;
  uint64_t dropped_crc = 0;
  uint64_t dropped_length = 0;
  uint64_t dropped_duplicate = 0;
  uint64_t decrypted = 0;
  uint64_t encrypted = 0;
};

class PacketParser {
 public:
  PacketParser();
  ~PacketParser();
  PacketParser(const PacketParser&) = delete;
  PacketParser& operator=(const PacketParser&) = delete;

  // Replaces the configuration. Returns false (keeping the previous config)
  // when a channel key cannot be resolved; the error names the channel index
  // only. Clears duplicate state; keeps the node cache.
  bool configure(const ParserConfig& config, std::string* error = nullptr);

  // Parse one LoRa payload. Returns the UTF-8 JSON event, or nullopt when the
  // packet is dropped like OpenWebRX+ does (CRC not ok, < 16 bytes, duplicate).
  std::optional<std::string> parse(const uint8_t* data, size_t len,
                                   const PhyMeta& meta,
                                   DropReason* reason = nullptr);

  // Stream discontinuity (retune/restart): forget duplicate state.
  void reset();
  // Forget learned node names/positions as well.
  void clear_nodes();

  const ParseStats& stats() const { return stats_; }

 private:
  struct Candidate {
    std::string name;
    Key key;
    uint8_t hash = 0;
    int index = -1;  // configured channel index, -1 = built-in default key
  };
  struct Node;
  bool is_duplicate(uint32_t src, uint32_t id, int64_t now_ms);

  std::vector<Candidate> candidates_;
  bool drop_duplicates_ = true;
  std::map<std::pair<uint32_t, uint32_t>, int64_t> seen_;
  std::unique_ptr<std::map<uint32_t, Node>> nodes_;
  ParseStats stats_;
};

}  // namespace sdrcore::meshtastic
