#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>
#include <limits>

namespace sdrcore::meshcore {
struct PhyMeta {
  uint64_t timestamp_ms = 0;
  uint64_t frequency_hz = 0;
  int crc = 0;
  int sf = 0;
  double bw_khz = std::numeric_limits<double>::quiet_NaN();
  int cr = 0;
  double level_db = std::numeric_limits<double>::quiet_NaN();
  double snr_db = std::numeric_limits<double>::quiet_NaN();
};

class PacketParser {
 public:
  bool configure(std::string_view versioned_json);
  void reset();
  std::optional<std::string> parse(const uint8_t* packet, size_t length, const PhyMeta& phy);
 private:
  struct Channel {
    std::string name;
    std::array<uint8_t,32> key{};
    uint8_t hash = 0;
  };
  std::vector<Channel> channels_;
};
}  // namespace sdrcore::meshcore
