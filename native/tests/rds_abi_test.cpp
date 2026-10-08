// SPDX-License-Identifier: GPL-3.0-or-later
#include "sdrcore_decoder_v1.h"
#include "sdrcore_v3.h"

#include <array>
#include <cassert>
#include <cstdint>
#include <string>

static std::string poll(SdrHandle* h, uint64_t& cursor) {
  SdrDecoderEvent header{};
  header.size = sizeof(header);
  header.revision = SDR_DECODER_REVISION;
  std::array<uint8_t, SDR_DECODER_MAX_PAYLOAD> payload{};
  const int rc = sdr_decoder_poll(h, cursor, &header, payload.data(), payload.size());
  if (rc == SDR_DECODER_NO_DATA) return {};
  assert(rc == SDR_OK);
  assert(header.sequence > cursor && header.kind == SDR_DECODER_MESSAGE);
  cursor = header.sequence;
  return std::string(payload.begin(), payload.begin() + header.payload_bytes);
}

int main() {
  assert(sdr_rds_set_rbds(nullptr, 1) == SDR_INVALID_ARGUMENT);
  SdrHandle* h = sdr_create();
  assert(h);
  assert(sdr_rds_set_rbds(h, 0) == SDR_INVALID_STATE);
  assert(sdr_v2_open_synthetic(h, 300000) == SDR_OK);
  SdrV3Controls c{};
  c.size = sizeof(c);
  c.revision = SDR_V3_REVISION;
  c.center_frequency_hz = 100000000;
  c.sample_rate = 300000;
  c.mode = SDR_V3_WFM;
  c.bandwidth_hz = 150000;
  c.squelch = SDR_V3_SQUELCH_OFF;
  c.squelch_level_db = -50;
  c.volume = 1;
  assert(sdr_v3_set_controls(h, &c) == SDR_OK);
  assert(sdr_rds_set_rbds(h, 2) == SDR_INVALID_ARGUMENT);
  assert(sdr_v3_start(h) == SDR_OK);
  uint64_t cursor = 0;
  auto message = poll(h, cursor);
  assert(message.find("\"reason\":\"generation\"") != std::string::npos);
  assert(message.find("\"frequency_hz\":100000000") != std::string::npos);
  assert(sdr_rds_set_rbds(h, 1) == SDR_OK);
  message = poll(h, cursor);
  assert(message.find("\"reason\":\"rbds\"") != std::string::npos);
  assert(message.find("\"rbds\":true") != std::string::npos);
  assert(sdr_rds_set_rbds(h, 1) == SDR_OK);
  assert(poll(h, cursor).empty());
  c.vfo_offset_hz = 1000;
  assert(sdr_v3_set_controls(h, &c) == SDR_OK);
  message = poll(h, cursor);
  assert(message.find("\"reason\":\"retune\"") != std::string::npos);
  assert(message.find("\"frequency_hz\":100001000") != std::string::npos);
  c.mode = SDR_V3_AM;
  c.bandwidth_hz = 12000;
  assert(sdr_v3_set_controls(h, &c) == SDR_OK);
  message = poll(h, cursor);
  assert(message.find("\"reason\":\"mode\"") != std::string::npos);
  assert(sdr_v3_stop(h) == SDR_OK);
  assert(poll(h, cursor).empty());
  assert(sdr_v2_close(h) == SDR_OK);
  sdr_destroy(h);
  return 0;
}
