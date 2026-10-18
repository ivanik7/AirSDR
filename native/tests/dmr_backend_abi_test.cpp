// SPDX-License-Identifier: GPL-3.0-or-later
#include "sdrcore_decoder_v1.h"
#include <cassert>
#include <cstring>
#include <string>

int main() {
  uint32_t count = 0;
  assert(sdr_decoder_count(&count) == SDR_OK);
  bool found = false;
  for (uint32_t i = 0; i < count; ++i) {
    SdrDecoderDescriptor d{};
    d.size = sizeof d;
    d.revision = SDR_DECODER_REVISION;
    assert(sdr_decoder_descriptor(i, &d) == SDR_OK);
    if (std::string(d.id) != "dmr") continue;
    found = true;
    assert(d.available == 1 && d.input == SDR_DECODER_BASEBAND);
    assert(d.required_rate_hz == 0 && d.required_mode == UINT32_MAX);
    assert(d.exclusive_receiver == 0 && d.result == SDR_DECODER_MESSAGE);
  }
  assert(found);
  auto* h = sdr_create();
  assert(sdr_v2_open_synthetic(h, 300000) == SDR_OK);
  SdrV3Controls c{};
  c.size = sizeof c;
  c.revision = SDR_V3_REVISION;
  c.center_frequency_hz = 446000000;
  c.sample_rate = 300000;
  c.mode = SDR_V3_NFM;
  c.bandwidth_hz = 12500;
  c.squelch = SDR_V3_SQUELCH_OFF;
  c.volume = 1;
  assert(sdr_v3_set_controls(h, &c) == SDR_OK);
  const char* config = R"({"schema":"dmr/1","slot_filter":3,"color_code":-1,"voice":true})";
  assert(sdr_decoder_select(h, "dmr", 3, "{}", 2) == SDR_INVALID_ARGUMENT);
  assert(sdr_decoder_select(h, "dmr", 3, config, std::strlen(config)) == SDR_OK);
  SdrV3Snapshot snap{};
  snap.size = sizeof snap;
  snap.revision = SDR_V3_REVISION;
  assert(sdr_v3_snapshot(h, &snap) == SDR_OK);
  assert(snap.center_frequency_hz == c.center_frequency_hz && snap.mode == c.mode);
  assert(sdr_decoder_select(h, nullptr, 0, nullptr, 0) == SDR_OK);
  assert(sdr_v2_close(h) == SDR_OK);
  sdr_destroy(h);
}
