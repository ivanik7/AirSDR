// SPDX-License-Identifier: GPL-3.0-or-later
// Host-only replay through the actual tuned-VFO branch, then the embedded
// rtl_433 engine. The source capture is 250 kS/s CU8; zero-order interpolation
// to 2.5 MS/s exercises the integer /10 decimator without claiming this is a
// physical RTL capture at 2.5 MS/s. Compare device fields against upstream.
#include "../src/dsp/receiver.h"
#include "decoder.hpp"
#include <algorithm>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

int main(int argc, char** argv) {
  if (argc != 2 && argc != 3) return 2;
  const bool inactive = argc == 3 && std::string(argv[2]) == "--inactive";
  if (argc == 3 && !inactive) return 2;
  const auto& entry = sdrcore::decoder::registry().at(1);
  auto engine = entry.create();
  if (!engine || !engine->configure(R"({"version":1,"settings":{}})")) return 3;
  auto rx = sdrcore::dsp::make_receiver();
  SdrV3Controls controls{};
  controls.size = sizeof controls;
  controls.revision = SDR_V3_REVISION;
  controls.sample_rate = 2500000;
  controls.center_frequency_hz = 433920000;
  controls.bandwidth_hz = 12000;
  controls.mode = SDR_V3_NFM;
  controls.volume = 1;
  SdrV3Display display{};
  display.size = sizeof display;
  display.revision = SDR_V3_REVISION;
  display.width = 256;
  display.view_bandwidth_hz = controls.sample_rate;
  rx->configure(controls, display);
  if (!inactive && rx->set_decoder(engine.get()) != 250000) return 4;
  std::ifstream input(argv[1], std::ios::binary);
  if (!input) return 5;
  std::vector<uint8_t> source(32768), interpolated(327680);
  sdrcore::dsp::ProcessResult result;
  sdrcore::decoder::Event event{};
  auto drain = [&] {
    while (engine->take_event(event)) {
      std::cout.write(reinterpret_cast<const char*>(event.payload.data()),
                      event.payload.size());
      std::cout << '\n';
    }
  };
  while (input) {
    input.read(reinterpret_cast<char*>(source.data()), source.size());
    const size_t count = static_cast<size_t>(input.gcount());
    if (count & 1) return 6;
    for (size_t i = 0; i < count / 2; ++i) {
      for (size_t j = 0; j < 10; ++j) {
        interpolated[20 * i + 2 * j] = source[2 * i];
        interpolated[20 * i + 2 * j + 1] = source[2 * i + 1];
      }
    }
    if (count) rx->process(interpolated.data(), count * 10, result);
    drain();
  }
  std::fill(interpolated.begin(), interpolated.end(), 127);
  rx->process(interpolated.data(), interpolated.size(), result);
  drain();
}
