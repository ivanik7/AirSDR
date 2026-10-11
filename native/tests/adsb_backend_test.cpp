// SPDX-License-Identifier: GPL-3.0-or-later
// Adapter regression: real upstream Mode S decode/tracking and bounded snapshot.
#include "decoder.hpp"
extern "C" {
#include "dump1090.h"
}
#include <nlohmann/json.hpp>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstring>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace sdrcore::decoder { std::unique_ptr<Decoder> create_adsb(); }

int main(int argc, char** argv) {
  using namespace sdrcore::decoder;
  auto backend = create_adsb();
  assert(backend);
  assert(!create_adsb()); // The upstream tables and track list are global.
  assert(!backend->configure("{"));
  assert(backend->configure("{\"version\":1,\"settings\":{}}"));
  assert(!backend->configure("{\"version\":1,\"settings\":{\"fix\":true}}"));
  if (argc == 3) {
    const int expected = std::stoi(argv[2]);
    std::ifstream input(argv[1], std::ios::binary);
    assert(input);
    std::vector<int16_t> iq;
    int16_t sample;
    while (input.read(reinterpret_cast<char*>(&sample), sizeof(sample))) iq.push_back(sample);
    assert(iq.size() % 2 == 0);
    const std::vector<size_t> chunks = {16320, 61, 3, 173, 16400, 787, 27129};
    size_t offset = 0;
    size_t ci = 0;
    while (offset < iq.size() / 2) {
      const auto frames = std::min(chunks[ci++ % chunks.size()], iq.size() / 2 - offset);
      std::vector<float> floats(frames * 2);
      for (size_t i = 0; i < floats.size(); ++i)
        floats[i] = static_cast<float>(iq[2 * offset + i]) / 32767.0f;
      backend->process(floats.data(), frames, 2400000);
      offset += frames;
    }
    assert(Modes.stats_current.messages_total == static_cast<uint32_t>(expected));
    assert(Modes.stats_current.demod_accepted[0] == static_cast<uint32_t>(expected));
    std::this_thread::sleep_for(std::chrono::milliseconds(1050));
    const std::vector<float> zeros(2 * 8192);
    backend->process(zeros.data(), 8192, 2400000);
    Event result{};
    assert(backend->take_event(result));
    auto doc = nlohmann::json::parse(result.payload);
    assert(doc["aircraft"].size() == 1);
    assert(doc["aircraft"][0]["icao"] == "40621D");
    assert(doc["aircraft"][0]["messages"] == expected);
    assert(doc["aircraft"][0]["altitude_ft"] == 38000);
    std::cout << doc.dump() << '\n';
    backend->reset();
    assert(!Modes.aircrafts);
    assert(!backend->take_event(result));
    return 0;
  }
  // Public airborne-CPR example (both exact frames reproduced in):
  // https://github.com/junzis/pyModeS/issues/68
  // Only two short frame values are reproduced; no recording is vendored.
  const unsigned char even[] = {0x8d,0x40,0x62,0x1d,0x58,0xc3,0x82,0xd6,0x90,0xc8,0xac,0x28,0x63,0xa7};
  const unsigned char odd[]  = {0x8d,0x40,0x62,0x1d,0x58,0xc3,0x86,0x43,0x5c,0xc4,0x12,0x69,0x2a,0xd6};
  assert(modesChecksum(even, MODES_LONG_MSG_BITS) == 0);
  auto damaged = std::vector<unsigned char>(even, even + sizeof(even));
  damaged[6] ^= 0x01;
  assert(modesChecksum(damaged.data(), MODES_LONG_MSG_BITS) != 0);
  modesMessage rejected{};
  assert(decodeModesMessage(&rejected, damaged.data()) < 0);
  Modes.nfix_crc = 1;
  modesChecksumInit(1);
  modesMessage repaired{};
  assert(decodeModesMessage(&repaired, damaged.data()) == 0);
  assert(repaired.correctedbits == 1);
  assert(repaired.addr == 0x40621d);
  assert(modesChecksum(repaired.msg, MODES_LONG_MSG_BITS) == 0);
  Modes.nfix_crc = 0;
  modesChecksumInit(0);
  double lat = 0, lon = 0;
  assert(decodeCPRairborne(93000, 51372, 74158, 50194, 1, &lat, &lon) == 0);
  assert(std::abs(lat - 52.26578) < 0.00001);
  assert(std::abs(lon - 3.93891) < 0.00001);
  assert(decodeCPRrelative(lat, lon, 93000, 51372, 0, 0, &lat, &lon) == 0);
  assert(std::abs(lat - 52.2572) < 0.02);
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
  // Simulate 140 reliable tracks, including one past the native 300 s TTL.
  // Serializer must exclude expired fields, cap at 128, and never leak a
  // stale track into a subsequent snapshot or across a retune/reset.
  const auto stamp = mstime();
  for (unsigned i = 0; i < 140; ++i) {
    auto* a = static_cast<aircraft*>(std::calloc(1, sizeof(aircraft)));
    assert(a);
    a->addr = 0x500000 + i;
    a->reliable = 1;
    a->seen = i == 139 ? stamp - TRACK_AIRCRAFT_TTL - 1 : stamp;
    a->messages = 2;
    std::memcpy(a->callsign, "EXPIRED ", 8);
    a->callsign_valid.source = SOURCE_ADSB;
    a->callsign_valid.expires = stamp - 1;
    a->next = Modes.aircrafts;
    Modes.aircrafts = a;
  }
  backend->process(zeros.data(), 8192, 2400000);
  std::this_thread::sleep_for(std::chrono::milliseconds(1050));
  backend->process(zeros.data(), 8192, 2400000);
  assert(backend->take_event(event));
  snapshot = nlohmann::json::parse(event.payload);
  assert(snapshot["aircraft"].size() == 128);
  assert(event.payload.size() <= 65536);
  for (const auto& row : snapshot["aircraft"]) {
    assert(!row.contains("callsign"));
    assert(row["icao"] != "50008B");
  }
  for (auto* a = Modes.aircrafts; a; a = a->next)
    a->seen = mstime() - TRACK_AIRCRAFT_TTL - 1;
  std::this_thread::sleep_for(std::chrono::milliseconds(1050));
  backend->process(zeros.data(), 8192, 2400000);
  assert(backend->take_event(event));
  snapshot = nlohmann::json::parse(event.payload);
  assert(snapshot["aircraft"].empty());
  assert(!Modes.aircrafts);
  backend->reset();
  assert(!Modes.aircrafts && !backend->take_event(event));
  backend.reset();
  assert(create_adsb());
  return 0;
}
