// SPDX-License-Identifier: GPL-3.0-or-later
#include "decoder.hpp"
#include <cassert>
#include <cstring>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

int main(int argc, char** argv) {
  const auto& entries = sdrcore::decoder::registry();
  const auto& entry = entries.at(1);
  assert(std::strcmp(entry.descriptor.id, "rtl_433") == 0);
  assert(entry.create && "rtl_433 needs a real in-process factory");
  auto engine = entry.create();
  assert(engine);
  assert(engine->configure(R"({"version":1,"settings":{}})"));
  assert(!engine->configure(R"({"version":2,"settings":{}})"));
  assert(!engine->configure(R"({"version":1,"settings":{"unknown":true}})"));
  assert(!engine->configure(R"({"version":1,"settings":{},"extra":0})"));
  assert(!engine->configure(R"({"version":1,"version":1,"settings":{}})"));
  assert(!engine->configure(R"({"version":1.0,"settings":{}})"));
  assert(!engine->configure(R"({"version":1,"settings":{"frequency_hz":433920000}})"));
  assert(!engine->configure(R"({"version":1,"settings":{}}]})"));
  assert(engine->configure(" \n {\"settings\": {}, \"version\": 1} \t"));
  engine->reset();
  sdrcore::decoder::Event event{};
  assert(!engine->take_event(event));
  float quiet[8192]{};
  engine->process(quiet, 4096, 250000);
  assert(!engine->take_event(event));
  if (argc == 1) {
    std::cout << "rtl_433 engine contract OK\n";
    return 0;
  }
  assert(argc == 3);
  engine->reset();
  std::ifstream input(argv[1], std::ios::binary);
  assert(input);
  auto rate = static_cast<uint32_t>(std::stoul(argv[2]));
  std::vector<uint8_t> iq(32768);
  std::vector<float> normalized(iq.size());
  auto feed = [&] {
    while (engine->take_event(event)) {
      std::cout.write(reinterpret_cast<const char*>(event.payload.data()), event.payload.size());
      std::cout << '\n';
    }
  };
  while (input) {
    input.read(reinterpret_cast<char*>(iq.data()), iq.size());
    size_t count = static_cast<size_t>(input.gcount());
    assert(count % 2 == 0);
    for (size_t i = 0; i < count; ++i)
      normalized[i] = (static_cast<float>(iq[i]) - 127.5f) / 128.0f;
    engine->process(normalized.data(), count / 2, rate);
    feed();
  }
  // Drive the pulse detector through the trailing silence that rtl_433's
  // file reader supplies at EOF; without silence a pulse at EOF is incomplete.
  // Complete the adapter's fixed upstream-sized frame, then one more frame.
  std::fill(normalized.begin(), normalized.end(), 0.0f);
  for (int i = 0; i < 9; ++i) {
    engine->process(normalized.data(), normalized.size() / 2, rate);
    feed();
  }
  return 0;
}
