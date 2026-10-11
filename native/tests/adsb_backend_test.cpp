// SPDX-License-Identifier: GPL-3.0-or-later
// Adapter regression: real upstream Mode S decode/tracking and bounded snapshot.
#include "decoder.hpp"
extern "C" {
#include "dump1090.h"
}
#include <nlohmann/json.hpp>
#include <cassert>
#include <chrono>
#include <cstring>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace sdrcore::decoder { std::unique_ptr<Decoder> create_adsb(); }

int main() {
  using namespace sdrcore::decoder;
  auto backend = create_adsb();
  assert(backend);
  assert(!create_adsb()); // The upstream tables and track list are global.
  assert(!backend->configure("{"));
  assert(backend->configure("{\"version\":1,\"settings\":{}}"));
  assert(!backend->configure("{\"version\":1,\"settings\":{\"fix\":true}}"));
  // Public airborne-CPR example (both exact frames reproduced in):
  // https://github.com/junzis/pyModeS/issues/68
  // Only two short frame values are reproduced; no recording is vendored.
  const unsigned char even[] = {0x8d,0x40,0x62,0x1d,0x58,0xc3,0x82,0xd6,0x90,0xc8,0xac,0x28,0x63,0xa7};
  const unsigned char odd[]  = {0x8d,0x40,0x62,0x1d,0x58,0xc3,0x86,0x43,0x5c,0xc4,0x12,0x69,0x2a,0xd6};
  const uint64_t now = mstime();
  for (auto* msg : {even, odd}) {
    modesMessage mm{};
    mm.sysTimestampMsg = now;
    mm.signalLevel = 0.01;
    assert(decodeModesMessage(&mm, msg) == 0);
    assert(mm.addr == 0x40621d);
    useModesMessage(&mm);
  }
  assert(Modes.aircrafts && Modes.aircrafts->reliable);
  Event event{};
  const std::vector<float> zeros(2 * 8192);
  backend->process(zeros.data(), 8192, 2400000);
  assert(!backend->take_event(event));
  std::this_thread::sleep_for(std::chrono::milliseconds(1050));
  backend->process(zeros.data(), 8192, 2400000);
  assert(backend->take_event(event));
  assert(event.kind == Result::aircraft);
  assert(event.payload.size() < 65536);
  auto snapshot = nlohmann::json::parse(event.payload);
  assert(snapshot["version"] == 1);
  assert(snapshot["input_rate_hz"] == 2400000);
  assert(snapshot["aircraft"].size() == 1);
  assert(snapshot["aircraft"][0]["icao"] == "40621D");
  assert(snapshot["aircraft"][0]["messages"] == 2);
  assert(snapshot["aircraft"][0].contains("latitude"));
  assert(snapshot["aircraft"][0].contains("longitude"));
  assert(snapshot["crc_fixed"] == 0);
  assert(!backend->take_event(event));
  backend->reset();
  assert(!Modes.aircrafts);
  assert(!backend->take_event(event));
  assert(!modeAC_count[0]);
  backend.reset();
  assert(create_adsb());
  return 0;
}
